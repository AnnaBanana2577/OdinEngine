package net

// Bit_Writer packs values LSB-first into a caller-owned buffer.
// Writing past the end sets `overflow` instead of panicking; check it once when done.
Bit_Writer :: struct {
	buf:      []u8,
	bit_pos:  int,
	overflow: bool,
}

// Bit_Reader reads what a Bit_Writer wrote.
// Reading past the end sets `overflow` and returns zeros.
Bit_Reader :: struct {
	buf:      []u8,
	bit_pos:  int,
	overflow: bool,
}

@(private = "file")
MAX_VARINT_GROUPS :: 10 // ceil(64 / 7)

writer_init :: proc(buf: []u8) -> Bit_Writer {
	return {buf = buf}
}

// The bytes written so far, rounded up to a whole byte.
writer_bytes :: proc(w: ^Bit_Writer) -> []u8 {
	return w.buf[:(w.bit_pos + 7) / 8]
}

write_bits :: proc(w: ^Bit_Writer, value: u64, count: int) {
	assert(count >= 0 && count <= 64)
	value, count := value, count
	for count > 0 {
		byte_index := w.bit_pos >> 3
		if byte_index >= len(w.buf) {
			w.overflow = true
			return
		}
		shift := uint(w.bit_pos & 7)
		n := min(8 - int(shift), count)
		bits := u8((value & ((u64(1) << uint(n)) - 1)) << shift)
		if shift == 0 {
			w.buf[byte_index] = bits // first write into this byte: no need to pre-zero the buffer
		} else {
			w.buf[byte_index] |= bits
		}
		value >>= uint(n)
		count -= n
		w.bit_pos += n
	}
}

write_bool :: proc(w: ^Bit_Writer, b: bool) {
	write_bits(w, 1 if b else 0, 1)
}

// 7 bits per group plus a continue bit: values below 128 cost 8 bits.
write_varint :: proc(w: ^Bit_Writer, value: u64) {
	value := value
	for {
		write_bits(w, value & 0x7f, 7)
		value >>= 7
		write_bool(w, value != 0)
		if value == 0 do break
	}
}

reader_init :: proc(buf: []u8) -> Bit_Reader {
	return {buf = buf}
}

read_bits :: proc(r: ^Bit_Reader, count: int) -> u64 {
	assert(count >= 0 && count <= 64)
	result: u64
	got := 0
	for got < count {
		byte_index := r.bit_pos >> 3
		if byte_index >= len(r.buf) {
			r.overflow = true
			return 0
		}
		shift := uint(r.bit_pos & 7)
		n := min(8 - int(shift), count - got)
		bits := (u64(r.buf[byte_index]) >> shift) & ((u64(1) << uint(n)) - 1)
		result |= bits << uint(got)
		got += n
		r.bit_pos += n
	}
	return result
}

read_bool :: proc(r: ^Bit_Reader) -> bool {
	return read_bits(r, 1) != 0
}

read_varint :: proc(r: ^Bit_Reader) -> u64 {
	result: u64
	for i in 0 ..< MAX_VARINT_GROUPS {
		result |= read_bits(r, 7) << uint(7 * i)
		if !read_bool(r) do return result
	}
	r.overflow = true
	return 0
}

// Maps signed to unsigned so small negative numbers stay small: 0, -1, 1, -2 -> 0, 1, 2, 3.
zigzag_encode :: #force_inline proc "contextless" (v: i64) -> u64 {
	return u64((v << 1) ~ (v >> 63))
}

zigzag_decode :: #force_inline proc "contextless" (v: u64) -> i64 {
	return i64(v >> 1) ~ -i64(v & 1)
}
