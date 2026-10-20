package net

import "core:math"

// Every field is converted to a canonical u64 (its "quantized value") when captured.
// Snapshots store, diff and send these values. Restoring converts them back.
// Capturing a restored value gives the same quantized value again, so diffs stay stable.

@(private = "file")
MAX_QUANT :: f64(1 << 53)

field_capture :: proc(f: Field, p: rawptr) -> u64 {
	switch f.kind {
	case .Bool:
		return 1 if load(p, f.size) != 0 else 0
	case .Uint:
		return truncate(load(p, f.size), f.bits)
	case .Int:
		v := sign_extend(load(p, f.size), int(f.size) * 8)
		return truncate(u64(v), f.bits) if f.bits > 0 else zigzag_encode(v)
	case .Float_Raw:
		return load(p, f.size)
	case .Float_Quant:
		x := load_float(p, f.size) / f64(f.q)
		if math.is_nan(x) do return 0
		return zigzag_encode(i64(math.round(clamp(x, -MAX_QUANT, MAX_QUANT))))
	case .Angle:
		turns := load_float(p, f.size) / math.TAU
		if math.is_nan(turns) || math.is_inf(turns) do return 0
		turns -= math.floor(turns)
		return truncate(u64(math.round(turns * f64(u64(1) << f.bits))), f.bits)
	case .String:
		panic("net: strings are only sent in full (events, messages)")
	}
	return 0
}

field_restore :: proc(f: Field, p: rawptr, v: u64) {
	switch f.kind {
	case .Bool:
		store(p, f.size, v & 1)
	case .Uint, .Float_Raw:
		store(p, f.size, v)
	case .Int:
		x := sign_extend(v, int(f.bits)) if f.bits > 0 else zigzag_decode(v)
		store(p, f.size, u64(x))
	case .Float_Quant:
		store_float(p, f.size, f64(zigzag_decode(v)) * f64(f.q))
	case .Angle:
		// Angles come back in [0, TAU).
		store_float(p, f.size, f64(v) / f64(u64(1) << f.bits) * math.TAU)
	case .String:
		panic("net: strings are only sent in full (events, messages)")
	}
}

field_write :: proc(w: ^Bit_Writer, f: Field, v: u64) {
	if f.bits > 0 {
		write_bits(w, v, int(f.bits))
	} else {
		write_varint(w, v)
	}
}

field_read :: proc(r: ^Bit_Reader, f: Field) -> u64 {
	if f.bits > 0 {
		return read_bits(r, int(f.bits))
	}
	return read_varint(r)
}

MAX_STRING_BYTES :: 4096

// Writes the fields of the struct at `p` in full (no baseline). `filter` limits it to one authority.
write_values :: proc(w: ^Bit_Writer, fields: []Field, p: rawptr, filter: Maybe(Authority) = nil) {
	for f in fields {
		if a, ok := filter.?; ok && f.authority != a do continue
		ptr := rawptr(uintptr(p) + f.offset)
		if f.kind == .String {
			write_string(w, (^string)(ptr)^)
		} else {
			field_write(w, f, field_capture(f, ptr))
		}
	}
}

// Reads what write_values wrote into the struct at `p`.
// Strings are allocated with context.temp_allocator; copy them if you keep them.
read_values :: proc(r: ^Bit_Reader, fields: []Field, p: rawptr, filter: Maybe(Authority) = nil) {
	for f in fields {
		if a, ok := filter.?; ok && f.authority != a do continue
		ptr := rawptr(uintptr(p) + f.offset)
		if f.kind == .String {
			(^string)(ptr)^ = read_string(r)
		} else {
			field_restore(f, ptr, field_read(r, f))
		}
	}
}

// Length (varint) then bytes. Longer strings are cut at MAX_STRING_BYTES.
@(private = "file")
write_string :: proc(w: ^Bit_Writer, s: string) {
	n := min(len(s), MAX_STRING_BYTES)
	write_varint(w, u64(n))
	for i in 0 ..< n do write_bits(w, u64(s[i]), 8)
}

@(private = "file")
read_string :: proc(r: ^Bit_Reader) -> string {
	n := read_varint(r)
	if n > MAX_STRING_BYTES {
		r.overflow = true
		return ""
	}
	buf := make([]u8, n, context.temp_allocator)
	for &c in buf do c = u8(read_bits(r, 8))
	return "" if r.overflow else string(buf)
}

@(private = "file")
truncate :: proc(v: u64, bits: u8) -> u64 {
	if bits == 0 || bits >= 64 do return v
	return v & ((u64(1) << bits) - 1)
}

@(private = "file")
sign_extend :: proc(v: u64, bits: int) -> i64 {
	shift := uint(64 - bits)
	return i64(v << shift) >> shift
}

@(private)
load :: proc(p: rawptr, size: u8) -> u64 {
	switch size {
	case 1: return u64((^u8)(p)^)
	case 2: return u64((^u16)(p)^)
	case 4: return u64((^u32)(p)^)
	case 8: return (^u64)(p)^
	}
	panic("net: bad field size")
}

@(private)
store :: proc(p: rawptr, size: u8, v: u64) {
	switch size {
	case 1: (^u8)(p)^ = u8(v)
	case 2: (^u16)(p)^ = u16(v)
	case 4: (^u32)(p)^ = u32(v)
	case 8: (^u64)(p)^ = v
	case:   panic("net: bad field size")
	}
}

@(private = "file")
load_float :: proc(p: rawptr, size: u8) -> f64 {
	return f64((^f32)(p)^) if size == 4 else (^f64)(p)^
}

@(private = "file")
store_float :: proc(p: rawptr, size: u8, v: f64) {
	if size == 4 {
		(^f32)(p)^ = f32(v)
	} else {
		(^f64)(p)^ = v
	}
}
