package net

import "base:runtime"
import "core:fmt"
import "core:mem"

// Event_Schema describes the game's Event union. Each variant is a struct whose
// `net`-tagged fields are sent in full (events have no baseline).
Event_Schema :: struct {
	union_id:   typeid,
	size:       int,
	tag_offset: uintptr,
	tag_size:   u8,
	tag_first:  u64, // tag value of variants[0]: 1, or 0 for #no_nil unions
	index_bits: int,
	variants:   []Event_Variant,
	hash:       u64,
}

Event_Variant :: struct {
	id:     typeid,
	fields: []Field,
	schema: Schema,
}

build_event_schema :: proc(V: typeid, allocator := context.allocator) -> (es: Event_Schema, err: string) {
	info, ok := runtime.type_info_base(type_info_of(V)).variant.(runtime.Type_Info_Union)
	if !ok || len(info.variants) == 0 do return {}, fmt.tprintf("net events: %v must be a union of structs", V)

	es.union_id = V
	es.size = size_of(V)
	es.tag_offset = info.tag_offset
	es.tag_size = u8(info.tag_type.size)
	es.tag_first = 0 if info.no_nil else 1
	es.index_bits = 1
	for (1 << uint(es.index_bits)) < len(info.variants) do es.index_bits += 1
	es.variants = make([]Event_Variant, len(info.variants), allocator)
	es.hash = 0xcbf29ce484222325

	for v, i in info.variants {
		schema, schema_err := build_schema(v.id, allocator)
		if schema_err == "" && len(schema.sections) != 1 {
			schema_destroy(&schema, allocator)
			schema_err = fmt.tprintf("net events: %v cannot contain pools", v.id)
		}
		if schema_err != "" {
			event_schema_destroy(&es, allocator)
			return {}, schema_err
		}
		es.variants[i] = {id = v.id, fields = schema.sections[0].fields, schema = schema}
		es.hash = hash_mix(es.hash, schema.hash)
	}
	return es, ""
}

event_schema_destroy :: proc(es: ^Event_Schema, allocator := context.allocator) {
	for &v in es.variants do schema_destroy(&v.schema, allocator)
	delete(es.variants, allocator)
	es^ = {}
}

// Encodes either a whole union value (`id` is the union) or one of its variants.
event_encode :: proc(w: ^Bit_Writer, es: ^Event_Schema, id: typeid, data: rawptr) {
	index := -1
	if id == es.union_id {
		tag := load(rawptr(uintptr(data) + es.tag_offset), es.tag_size)
		assert(tag >= es.tag_first, "net: cannot emit a nil event")
		index = int(tag - es.tag_first)
	} else {
		for v, i in es.variants {
			if v.id == id do index = i
		}
		fmt.assertf(index >= 0, "net: %v is not a variant of %v", id, es.union_id)
	}
	write_bits(w, u64(index), es.index_bits)
	write_values(w, es.variants[index].fields, data) // variant data lives at the start of the union
}

// Decodes an event into `out`, which must point to a value of the union type.
event_decode :: proc(r: ^Bit_Reader, es: ^Event_Schema, out: rawptr) -> bool {
	index := int(read_bits(r, es.index_bits))
	if index >= len(es.variants) do return false
	mem.zero(out, es.size)
	read_values(r, es.variants[index].fields, out)
	store(rawptr(uintptr(out) + es.tag_offset), es.tag_size, u64(index) + es.tag_first)
	return !r.overflow
}

// Event_Queue holds encoded event messages until the end of the tick.
Event_Queue :: struct {
	bytes: [dynamic]u8,
	items: [dynamic]Queued_Event,
}

Queued_Event :: struct {
	start, end: int,
	target:     Event_Target,
	player:     Player_Id, // for .Only and .Except
}

Event_Target :: enum u8 {
	All,
	Only,
	Except,
}

event_queue_destroy :: proc(q: ^Event_Queue) {
	delete(q.bytes)
	delete(q.items)
}

event_queue_clear :: proc(q: ^Event_Queue) {
	clear(&q.bytes)
	clear(&q.items)
}

// Returns whether a queued event goes to player `p`.
event_is_for :: proc(e: Queued_Event, p: Player_Id) -> bool {
	switch e.target {
	case .All:    return true
	case .Only:   return p == e.player
	case .Except: return p != e.player
	}
	return false
}
