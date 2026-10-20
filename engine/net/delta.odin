package net

import "core:mem"

// Wire format, per section:
//	globals: for each field, 1 changed bit, then the value if changed.
//	pools:   for each slot that differs from the baseline:
//	             1 bit (more slots follow), slot index gap (varint), 2-bit Slot_Change, then:
//	             Removed: nothing
//	             Spawned: meta, then fields against zero
//	             Changed: 1 bit (meta changed) [+ meta], then fields against the baseline
//	         a final 0 bit ends the section.

@(private = "file")
Slot_Change :: enum u8 {
	Removed,
	Spawned,
	Changed,
}

// Writes `cur` as a diff against `base`. A nil base means "against all zeros", i.e. a full snapshot.
// Check w.overflow afterwards.
delta_encode :: proc(w: ^Bit_Writer, schema: ^Schema, base, cur: ^Snapshot) {
	base_values := base.values if base != nil else nil
	for sec in schema.sections {
		if !sec.is_pool {
			write_fields(w, sec.fields, base_values, cur.values, sec.first)
			continue
		}
		prev := -1
		for i in 0 ..< sec.count {
			at := sec.first + i * sec.width
			if !slot_changed(base_values, cur.values, at, sec.width) do continue

			write_bool(w, true)
			write_varint(w, u64(i - prev - 1))
			prev = i

			was := unpack_meta(value_at(base_values, at))
			now := unpack_meta(cur.values[at])
			switch {
			case !now.alive:
				write_bits(w, u64(Slot_Change.Removed), 2)
			case !was.alive || was.gen != now.gen:
				write_bits(w, u64(Slot_Change.Spawned), 2)
				write_meta(w, now)
				write_fields(w, sec.fields, nil, cur.values, at + 1)
			case:
				write_bits(w, u64(Slot_Change.Changed), 2)
				write_bool(w, was != now)
				if was != now do write_meta(w, now)
				write_fields(w, sec.fields, base_values, cur.values, at + 1)
			}
		}
		write_bool(w, false)
	}
}

// Rebuilds a snapshot from a diff against `base` (nil = all zeros) into `out`.
// Returns false for a malformed packet. `base` and `out` must be different snapshots.
delta_decode :: proc(r: ^Bit_Reader, schema: ^Schema, base, out: ^Snapshot) -> bool {
	if base != nil {
		if raw_data(base.values) == raw_data(out.values) do return false
		copy(out.values, base.values)
	} else {
		mem.zero_slice(out.values)
	}

	for sec in schema.sections {
		if !sec.is_pool {
			read_fields(r, sec.fields, out.values, sec.first)
			continue
		}
		i := -1
		for read_bool(r) {
			gap := read_varint(r)
			if gap >= u64(sec.count) do return false
			i += 1 + int(gap)
			if i >= sec.count do return false

			at := sec.first + i * sec.width
			slot := out.values[at:][:sec.width]
			switch Slot_Change(read_bits(r, 2)) {
			case .Removed:
				mem.zero_slice(slot)
			case .Spawned:
				mem.zero_slice(slot)
				slot[0] = read_meta(r)
				read_fields(r, sec.fields, out.values, at + 1)
			case .Changed:
				if read_bool(r) do slot[0] = read_meta(r)
				read_fields(r, sec.fields, out.values, at + 1)
			case:
				return false
			}
		}
	}
	return !r.overflow
}

@(private = "file")
write_fields :: proc(w: ^Bit_Writer, fields: []Field, base, cur: []u64, at: int) {
	for f, j in fields {
		v := cur[at + j]
		changed := v != value_at(base, at + j)
		write_bool(w, changed)
		if changed do field_write(w, f, v)
	}
}

@(private = "file")
read_fields :: proc(r: ^Bit_Reader, fields: []Field, out: []u64, at: int) {
	for f, j in fields {
		if read_bool(r) do out[at + j] = field_read(r, f)
	}
}

@(private = "file")
write_meta :: proc(w: ^Bit_Writer, m: Slot_Meta) {
	write_bits(w, u64(m.gen), 16)
	write_bits(w, u64(m.owner), 8)
	write_bits(w, u64(m.override), 8)
}

@(private = "file")
read_meta :: proc(r: ^Bit_Reader) -> u64 {
	return pack_meta({
		gen      = u16(read_bits(r, 16)),
		owner    = Player_Id(read_bits(r, 8)),
		override = u8(read_bits(r, 8)),
		alive    = true,
	})
}

@(private = "file")
slot_changed :: proc(base, cur: []u64, at, width: int) -> bool {
	for j in at ..< at + width {
		if cur[j] != value_at(base, j) do return true
	}
	return false
}

// Reads a baseline value; a nil baseline is all zeros.
@(private = "file")
value_at :: proc(values: []u64, i: int) -> u64 {
	if values == nil do return 0
	return values[i]
}
