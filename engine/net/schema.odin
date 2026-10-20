package net

import "base:runtime"
import "core:fmt"
import "core:reflect"
import "core:strconv"
import "core:strings"

Field_Kind :: enum u8 {
	Bool,
	Int,
	Uint,
	Float_Raw,
	Float_Quant,
	Angle,
}

Authority :: enum u8 {
	Owner,  // whoever owns the entity (the server for globals and unowned entities)
	Server, // always the server, even on client-owned entities
}

// One replicated leaf value. Nested structs and arrays are flattened into many Fields.
Field :: struct {
	offset:    uintptr, // from the start of the item (pools) or of the state (globals)
	size:      u8,      // bytes in memory
	kind:      Field_Kind,
	bits:      u8,      // bits on the wire; 0 = varint
	q:         f32,     // Float_Quant step
	authority: Authority,
}

// A run of `count` items that share one field list: the globals (count 1) or one Pool.
Section :: struct {
	name:    string,
	root:    int, // which root pointer this section reads from (see schema_append)
	is_pool: bool,
	items:   uintptr, // offset of the first item within the state
	stride:  int,     // bytes between items
	meta:    uintptr, // offset of the pool's [N]Slot_Meta within the state
	count:   int,
	fields:  []Field,
	first:   int, // index of this section's first value in a Snapshot
	width:   int, // values per item: one per field, plus one for slot meta in pools
}

Schema :: struct {
	sections:    [dynamic]Section, // each root starts with its globals section
	roots:       int,
	value_count: int,
	hash:        u64,
}

// Builds the schema for a game state type from its `net` struct tags.
// On failure `err` describes the offending field; it is allocated with context.temp_allocator.
build_schema :: proc(T: typeid, allocator := context.allocator) -> (schema: Schema, err: string) {
	schema.sections = make([dynamic]Section, allocator)
	err = schema_append(&schema, T, allocator)
	return
}

// Adds another root type to a schema made by build_schema. Its sections come after the existing
// ones, and snapshot_capture/snapshot_apply then take one pointer per root, in order.
// The engine uses this to replicate its player table next to the game state.
// On failure the whole schema is destroyed.
schema_append :: proc(schema: ^Schema, T: typeid, allocator := context.allocator) -> (err: string) {
	ti, ok := runtime.type_info_base(type_info_of(T)).variant.(runtime.Type_Info_Struct)
	if !ok {
		schema_destroy(schema, allocator)
		return fmt.tprintf("net schema: %v is not a struct", T)
	}

	b := Builder {
		schema    = schema,
		root      = schema.roots,
		allocator = allocator,
	}
	schema.roots += 1
	globals := make([dynamic]Field, allocator)
	append(&schema.sections, Section{name = strings.clone("globals", allocator), root = b.root, count = 1})
	g := len(schema.sections) - 1
	walk_struct(&b, ti, 0, fmt.tprint(T), false, &globals, true)
	schema.sections[g].fields = globals[:]

	if b.err != "" {
		schema_destroy(schema, allocator)
		return b.err
	}

	schema.value_count = 0
	schema.hash = 0xcbf29ce484222325
	for &sec in schema.sections {
		sec.width = len(sec.fields) + (1 if sec.is_pool else 0)
		sec.first = schema.value_count
		schema.value_count += sec.width * sec.count

		schema.hash = hash_mix(schema.hash, u64(sec.count))
		schema.hash = hash_mix(schema.hash, u64(sec.width))
		for f in sec.fields {
			schema.hash = hash_mix(schema.hash, u64(f.kind) | u64(f.size) << 8 | u64(f.bits) << 16 | u64(f.authority) << 24)
			schema.hash = hash_mix(schema.hash, u64(transmute(u32)f.q))
		}
	}
	return ""
}

schema_destroy :: proc(s: ^Schema, allocator := context.allocator) {
	for sec in s.sections {
		delete(sec.name, allocator)
		delete(sec.fields, allocator)
	}
	delete(s.sections)
	s^ = {}
}

@(private = "file")
Builder :: struct {
	schema:    ^Schema,
	root:      int,
	err:       string,
	allocator: runtime.Allocator,
}

@(private = "file")
Tag_Options :: struct {
	q:      f32,
	bits:   int,
	angle:  bool,
	raw:    bool,
	server: bool,
}

@(private = "file")
walk_struct :: proc(b: ^Builder, ti: runtime.Type_Info_Struct, offset: uintptr, path: string, server: bool, out: ^[dynamic]Field, allow_pools: bool) {
	for i in 0 ..< int(ti.field_count) {
		tag, tagged := reflect.struct_tag_lookup(reflect.Struct_Tag(ti.tags[i]), "net")
		if !tagged do continue

		field_path := fmt.tprintf("%s.%s", path, ti.names[i])
		opts, ok := parse_tag(tag)
		if !ok {
			fail(b, field_path, "bad tag `net:\"%s\"`", tag)
			return
		}
		opts.server = opts.server || server
		walk_value(b, ti.types[i], offset + ti.offsets[i], field_path, opts, out, allow_pools)
		if b.err != "" do return
	}
}

@(private = "file")
walk_value :: proc(b: ^Builder, ti: ^runtime.Type_Info, offset: uintptr, path: string, opts: Tag_Options, out: ^[dynamic]Field, allow_pools: bool) {
	base := runtime.type_info_base(ti)
	field := Field {
		offset    = offset,
		size      = u8(base.size),
		authority = .Server if opts.server else .Owner,
	}

	#partial switch v in base.variant {
	case runtime.Type_Info_Struct:
		if !is_pool(v) {
			walk_struct(b, v, offset, path, opts.server, out, allow_pools)
		} else if allow_pools {
			add_pool(b, v, offset, path, opts)
		} else {
			fail(b, path, "pools cannot be nested inside pool items")
		}

	case runtime.Type_Info_Array:
		for i in 0 ..< v.count {
			walk_value(b, v.elem, offset + uintptr(i * v.elem_size), fmt.tprintf("%s[%d]", path, i), opts, out, allow_pools)
		}

	case runtime.Type_Info_Enumerated_Array:
		for i in 0 ..< v.count {
			walk_value(b, v.elem, offset + uintptr(i * v.elem_size), fmt.tprintf("%s[%d]", path, i), opts, out, allow_pools)
		}

	case runtime.Type_Info_Boolean:
		if !check_int_opts(b, path, opts, 1) do return
		field.kind = .Bool
		field.bits = 1
		append(out, field)

	case runtime.Type_Info_Integer, runtime.Type_Info_Enum:
		info := runtime.type_info_core(base).variant.(runtime.Type_Info_Integer)
		if info.endianness == .Big || base.size > 8 {
			fail(b, path, "only native-endian integers up to 64 bits are supported")
			return
		}
		if !check_int_opts(b, path, opts, base.size * 8) do return
		field.kind = .Int if info.signed else .Uint
		field.bits = u8(opts.bits)
		append(out, field)

	case runtime.Type_Info_Bit_Set:
		if base.size > 8 {
			fail(b, path, "bit_sets larger than 64 bits are not supported")
			return
		}
		if !check_int_opts(b, path, opts, base.size * 8) do return
		field.kind = .Uint
		field.bits = u8(opts.bits if opts.bits > 0 else int(v.upper - v.lower + 1))
		append(out, field)

	case runtime.Type_Info_Float:
		if v.endianness == .Big || (base.size != 4 && base.size != 8) {
			fail(b, path, "only native-endian f32 and f64 are supported")
			return
		}
		switch {
		case opts.angle:
			if opts.q != 0 || opts.bits > 32 {
				fail(b, path, "angle takes `bits` (max 32), not `q`")
				return
			}
			field.kind = .Angle
			field.bits = u8(opts.bits if opts.bits > 0 else 16)
		case opts.q > 0:
			if opts.bits != 0 || opts.raw {
				fail(b, path, "`q` cannot be combined with `bits` or `raw`")
				return
			}
			field.kind = .Float_Quant
			field.q = opts.q
		case:
			if opts.bits != 0 {
				fail(b, path, "`bits` on a float needs `angle`; use `q` to quantize")
				return
			}
			field.kind = .Float_Raw
			field.bits = u8(base.size * 8)
		}
		append(out, field)

	case:
		fail(b, path, "type %v cannot be replicated", ti.id)
	}
}

@(private = "file")
check_int_opts :: proc(b: ^Builder, path: string, opts: Tag_Options, max_bits: int) -> bool {
	if opts.q != 0 || opts.angle || opts.raw {
		fail(b, path, "`q`, `angle` and `raw` only apply to floats")
		return false
	}
	if opts.bits > max_bits {
		fail(b, path, "bits=%d is larger than the type (%d bits)", opts.bits, max_bits)
		return false
	}
	return true
}

// A Pool(T, N) is recognized by its exact shape: `items: [N]T` then `meta: [N]Slot_Meta`.
@(private = "file")
is_pool :: proc(s: runtime.Type_Info_Struct) -> bool {
	if s.field_count != 2 || s.names[0] != "items" || s.names[1] != "meta" do return false
	meta, ok := runtime.type_info_base(s.types[1]).variant.(runtime.Type_Info_Array)
	return ok && meta.elem.id == typeid_of(Slot_Meta)
}

@(private = "file")
add_pool :: proc(b: ^Builder, pool: runtime.Type_Info_Struct, offset: uintptr, path: string, opts: Tag_Options) {
	items := runtime.type_info_base(pool.types[0]).variant.(runtime.Type_Info_Array)
	item, ok := runtime.type_info_base(items.elem).variant.(runtime.Type_Info_Struct)
	if !ok {
		fail(b, path, "pool items must be structs")
		return
	}
	fields := make([dynamic]Field, b.allocator)
	walk_struct(b, item, 0, path, opts.server, &fields, false)
	append(&b.schema.sections, Section {
		name    = strings.clone(path, b.allocator),
		root    = b.root,
		is_pool = true,
		items   = offset + pool.offsets[0],
		stride  = items.elem_size,
		meta    = offset + pool.offsets[1],
		count   = items.count,
		fields  = fields[:],
	})
}

// Tag grammar: comma separated, any of `q=<step>`, `bits=<n>`, `angle`, `raw`, `server`.
@(private = "file")
parse_tag :: proc(tag: string) -> (opts: Tag_Options, ok: bool) {
	rest := tag
	for part in strings.split_iterator(&rest, ",") {
		key, _, value := strings.partition(strings.trim_space(part), "=")
		value = strings.trim_space(value)
		switch strings.trim_space(key) {
		case "":
		case "server":
			opts.server = true
		case "angle":
			opts.angle = true
		case "raw":
			opts.raw = true
		case "q":
			q, q_ok := strconv.parse_f32(value)
			if !q_ok || q <= 0 do return {}, false
			opts.q = q
		case "bits":
			n, n_ok := strconv.parse_int(value)
			if !n_ok || n <= 0 || n > 64 do return {}, false
			opts.bits = n
		case:
			return {}, false
		}
	}
	return opts, true
}

@(private = "file")
fail :: proc(b: ^Builder, path: string, format: string, args: ..any) {
	if b.err != "" do return
	b.err = fmt.tprintf("net schema: %s: %s", path, fmt.tprintf(format, ..args))
}

@(private)
hash_mix :: proc(h, v: u64) -> u64 {
	return (h ~ v) * 0x100000001b3
}
