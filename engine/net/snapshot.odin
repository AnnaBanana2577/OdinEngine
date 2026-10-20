package net

import "core:mem"

// Snapshot is the replicated part of a game state as quantized values, laid out by a Schema:
// section by section, item by item. Pool items start with their packed Slot_Meta.
// Dead pool slots are all zeros.
Snapshot :: struct {
	tick:   Tick,
	values: []u64,
}

snapshot_make :: proc(schema: ^Schema, allocator := context.allocator) -> Snapshot {
	return {values = make([]u64, schema.value_count, allocator)}
}

snapshot_destroy :: proc(snap: ^Snapshot, allocator := context.allocator) {
	delete(snap.values, allocator)
	snap^ = {}
}

// Reads every replicated value out of the roots (one pointer per schema root, in order).
snapshot_capture :: proc(schema: ^Schema, snap: ^Snapshot, roots: ..rawptr) {
	assert(len(roots) == schema.roots)
	for sec in schema.sections {
		state := roots[sec.root]
		for i in 0 ..< sec.count {
			out := snap.values[sec.first + i * sec.width:][:sec.width]
			item := item_ptr(state, sec, i)
			if sec.is_pool {
				meta := slot_meta(state, sec, i)^
				if !meta.alive {
					mem.zero_slice(out)
					continue
				}
				out[0] = pack_meta(meta)
				out = out[1:]
			}
			for f, j in sec.fields {
				out[j] = field_capture(f, rawptr(uintptr(item) + f.offset))
			}
		}
	}
}

// Writes a snapshot into the roots (one pointer per schema root, in order).
// An entity owned by `local_player` keeps its owner fields and only takes server fields,
// unless the server bumped `override`. Pass NO_PLAYER to apply everything.
snapshot_apply :: proc(schema: ^Schema, snap: ^Snapshot, local_player: Player_Id, roots: ..rawptr) {
	assert(len(roots) == schema.roots)
	for sec in schema.sections {
		state := roots[sec.root]
		for i in 0 ..< sec.count {
			values := snap.values[sec.first + i * sec.width:][:sec.width]
			item := item_ptr(state, sec, i)
			if !sec.is_pool {
				restore_fields(sec.fields, values, item, server_only = false)
				continue
			}

			meta := slot_meta(state, sec, i)
			incoming := unpack_meta(values[0])
			switch {
			case !incoming.alive:
				if meta.alive {
					mem.zero(item, sec.stride)
					meta^ = {}
				}
			case !meta.alive || meta.gen != incoming.gen:
				// A new entity: clear local-only fields left by the previous occupant.
				mem.zero(item, sec.stride)
				meta^ = incoming
				restore_fields(sec.fields, values[1:], item, server_only = false)
			case local_player != NO_PLAYER && incoming.owner == local_player && meta.owner == incoming.owner && meta.override == incoming.override:
				restore_fields(sec.fields, values[1:], item, server_only = true)
			case:
				meta^ = incoming
				restore_fields(sec.fields, values[1:], item, server_only = false)
			}
		}
	}
}

SNAPSHOT_RING_SIZE :: 64

// Snapshot_Ring keeps the last SNAPSHOT_RING_SIZE snapshots, indexed by tick.
Snapshot_Ring :: struct {
	slots: [SNAPSHOT_RING_SIZE]Snapshot,
	used:  [SNAPSHOT_RING_SIZE]bool,
}

ring_init :: proc(r: ^Snapshot_Ring, schema: ^Schema, allocator := context.allocator) {
	for &s in r.slots do s = snapshot_make(schema, allocator)
}

ring_destroy :: proc(r: ^Snapshot_Ring, allocator := context.allocator) {
	for &s in r.slots do snapshot_destroy(&s, allocator)
	r^ = {}
}

// Returns the slot for `tick`, replacing the snapshot that was there.
ring_put :: proc(r: ^Snapshot_Ring, tick: Tick) -> ^Snapshot {
	i := int(tick % SNAPSHOT_RING_SIZE)
	r.used[i] = true
	r.slots[i].tick = tick
	return &r.slots[i]
}

// Returns the snapshot for `tick`, or nil if it was never stored or has been replaced.
ring_get :: proc(r: ^Snapshot_Ring, tick: Tick) -> ^Snapshot {
	i := int(tick % SNAPSHOT_RING_SIZE)
	if !r.used[i] || r.slots[i].tick != tick do return nil
	return &r.slots[i]
}

pack_meta :: proc(m: Slot_Meta) -> u64 {
	if !m.alive do return 0
	return u64(m.gen) | u64(m.owner) << 16 | u64(m.override) << 24 | 1 << 32
}

unpack_meta :: proc(v: u64) -> Slot_Meta {
	return {gen = u16(v), owner = Player_Id(v >> 16), override = u8(v >> 24), alive = (v >> 32) & 1 != 0}
}

@(private = "file")
restore_fields :: proc(fields: []Field, values: []u64, item: rawptr, server_only: bool) {
	for f, j in fields {
		if server_only && f.authority != .Server do continue
		field_restore(f, rawptr(uintptr(item) + f.offset), values[j])
	}
}

@(private)
item_ptr :: proc(state: rawptr, sec: Section, i: int) -> rawptr {
	return rawptr(uintptr(state) + sec.items + uintptr(i * sec.stride))
}

@(private)
slot_meta :: proc(state: rawptr, sec: Section, i: int) -> ^Slot_Meta {
	return (^Slot_Meta)(uintptr(state) + sec.meta + uintptr(i * size_of(Slot_Meta)))
}
