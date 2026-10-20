package net

import "base:runtime"
import "core:fmt"
import "core:mem"

// Two ways to send things besides state:
//
//	Events (gameplay: shots, hits, explosions) are stamped with the tick they happened on and ride
//	inside snapshots (server → client) and client updates (client → server). Every packet repeats
//	the events the other side hasn't acked yet, until they expire (Config.event_ttl, or per emit;
//	FOREVER never expires). The receiver drops duplicates. Clients fire server events right after
//	applying the snapshot that carries them, so effects line up with the state.
//
//	Messages (chat, round announcements) go over the reliable channel, arrive in order, and are not
//	tied to ticks. They can be sent from anywhere, not just inside game callbacks.
//
// Both are unions of structs whose `net`-tagged fields are sent in full; strings are allowed.

// Union_Schema describes the game's Event or Message union.
Union_Schema :: struct {
	union_id:   typeid,
	size:       int,
	tag_offset: uintptr,
	tag_size:   u8,
	tag_first:  u64, // tag value of variants[0]: 1, or 0 for #no_nil unions
	index_bits: int,
	variants:   []Union_Variant,
	hash:       u64,
}

Union_Variant :: struct {
	id:     typeid,
	fields: []Field,
	schema: Schema,
}

build_union_schema :: proc(V: typeid, allocator := context.allocator) -> (us: Union_Schema, err: string) {
	info, ok := runtime.type_info_base(type_info_of(V)).variant.(runtime.Type_Info_Union)
	if !ok || len(info.variants) == 0 do return {}, fmt.tprintf("net: %v must be a union of structs", V)

	us.union_id = V
	us.size = size_of(V)
	us.tag_offset = info.tag_offset
	us.tag_size = u8(info.tag_type.size)
	us.tag_first = 0 if info.no_nil else 1
	us.index_bits = 1
	for (1 << uint(us.index_bits)) < len(info.variants) do us.index_bits += 1
	us.variants = make([]Union_Variant, len(info.variants), allocator)
	us.hash = 0xcbf29ce484222325

	for v, i in info.variants {
		schema: Schema
		schema.sections = make([dynamic]Section, allocator)
		schema_err := schema_append_ex(&schema, v.id, allocator, allow_strings = true)
		if schema_err == "" && len(schema.sections) != 1 {
			schema_destroy(&schema, allocator)
			schema_err = fmt.tprintf("net: %v cannot contain pools", v.id)
		}
		if schema_err != "" {
			union_schema_destroy(&us, allocator)
			return {}, schema_err
		}
		us.variants[i] = {id = v.id, fields = schema.sections[0].fields, schema = schema}
		us.hash = hash_mix(us.hash, schema.hash)
	}
	return us, ""
}

union_schema_destroy :: proc(us: ^Union_Schema, allocator := context.allocator) {
	for &v in us.variants do schema_destroy(&v.schema, allocator)
	delete(us.variants, allocator)
	us^ = {}
}

// Encodes either a whole union value (`id` is the union) or one of its variants.
union_encode :: proc(w: ^Bit_Writer, us: ^Union_Schema, id: typeid, data: rawptr) {
	index := -1
	if id == us.union_id {
		tag := load(rawptr(uintptr(data) + us.tag_offset), us.tag_size)
		assert(tag >= us.tag_first, "net: cannot send a nil union")
		index = int(tag - us.tag_first)
	} else {
		for v, i in us.variants {
			if v.id == id do index = i
		}
		fmt.assertf(index >= 0, "net: %v is not a variant of %v", id, us.union_id)
	}
	write_bits(w, u64(index), us.index_bits)
	write_values(w, us.variants[index].fields, data) // variant data lives at the start of the union
}

// Decodes into `out`, which must point to a value of the union type.
// Strings are allocated with context.temp_allocator.
union_decode :: proc(r: ^Bit_Reader, us: ^Union_Schema, out: rawptr) -> bool {
	index := int(read_bits(r, us.index_bits))
	if index >= len(us.variants) do return false
	mem.zero(out, us.size)
	read_values(r, us.variants[index].fields, out)
	store(rawptr(uintptr(out) + us.tag_offset), us.tag_size, u64(index) + us.tag_first)
	return !r.overflow
}

// Events

// Pass as `ttl` to emit: the event is resent until acked, however long that takes.
FOREVER :: f32(-1)

Logged_Event :: struct {
	id:     u32,  // increasing per sender; receivers drop ids they've seen
	tick:   Tick, // sender's tick when emitted
	expire: Tick, // not sent after this tick
	target: Event_Target,
	player: Player_Id, // for .Only and .Except
	data:   []u8,      // union_encode output
	bits:   int,
}

// Events this peer emitted that the other side may not have yet.
Event_Log :: struct {
	items:   [dynamic]Logged_Event,
	next_id: u32,
}

Event_Target :: enum u8 {
	All,
	Only,
	Except,
}

event_log_remove :: proc(log: ^Event_Log, i: int) {
	delete(log.items[i].data)
	ordered_remove(&log.items, i)
}

event_log_destroy :: proc(log: ^Event_Log) {
	for e in log.items do delete(e.data)
	delete(log.items)
}

// Wire format inside a packet: for each event, 1 bit, id gap (varint), ticks before the packet's
// tick (varint), payload length in bits (varint), payload. A final 0 bit ends the list.
write_event :: proc(w: ^Bit_Writer, e: ^Logged_Event, packet_tick: Tick, prev_id: ^u32) {
	write_bool(w, true)
	write_varint(w, u64(e.id - prev_id^))
	prev_id^ = e.id
	write_varint(w, u64(packet_tick - e.tick))
	write_varint(w, u64(e.bits))
	write_bits_from(w, e.data, e.bits)
}

// Reads the header after a 1 bit. The payload (`bits` long) is next in the reader.
read_event_header :: proc(r: ^Bit_Reader, packet_tick: Tick, prev_id: ^u32) -> (id: u32, tick: Tick, bits: int, ok: bool) {
	id = prev_id^ + u32(read_varint(r))
	prev_id^ = id
	tick = packet_tick - Tick(read_varint(r))
	n := read_varint(r)
	if r.overflow || n > u64(reader_remaining(r)) do return 0, 0, 0, false
	return id, tick, int(n), true
}

// Messages

// Encoded Message packets waiting to be sent at the end of the update.
Message_Queue :: struct {
	bytes: [dynamic]u8,
	items: [dynamic]Queued_Message,
}

Queued_Message :: struct {
	start, end: int,
	target:     Event_Target,
	player:     Player_Id,
}

message_queue_destroy :: proc(q: ^Message_Queue) {
	delete(q.bytes)
	delete(q.items)
}

message_queue_clear :: proc(q: ^Message_Queue) {
	clear(&q.bytes)
	clear(&q.items)
}

// Whether an event or message for `target`/`player` goes to player `p`.
is_for :: proc(target: Event_Target, player, p: Player_Id) -> bool {
	switch target {
	case .All:    return true
	case .Only:   return p == player
	case .Except: return p != player
	}
	return false
}
