package net_test

import "core:math"
import "core:math/rand"
import "core:slice"
import "core:testing"
import net "engine:net"

Kind :: enum u8 { A, B, C }
Flag :: enum { X, Y, Z }

Unit :: struct {
	pos:   [2]f32        `net:"q=0.01"`,
	aim:   f32           `net:"angle,bits=12"`,
	hp:    u8            `net:"server"`,
	kind:  Kind          `net:""`,
	flags: bit_set[Flag] `net:""`,
	delta: i16           `net:"bits=10"`,
	speed: f64           `net:""`,
	local: f32,
}

Bullet :: struct {
	pos:  [2]f32        `net:"q=0.1"`,
	from: net.Player_Id `net:""`,
}

Test_State :: struct {
	time:    f32                  `net:"q=0.05"`,
	scores:  [4]i32               `net:""`,
	ref:     net.Handle           `net:""`,
	units:   net.Pool(Unit, 8)    `net:""`,
	bullets: net.Pool(Bullet, 32) `net:""`,
	cache:   [dynamic]int,
}

UNITS   :: 1
BULLETS :: 2

make_schema :: proc(t: ^testing.T) -> net.Schema {
	schema, err := net.build_schema(Test_State)
	testing.expect(t, err == "", err)
	return schema
}

fill_state :: proc(s: ^Test_State) {
	s.time = 12.34
	s.scores = {1, -2, 300, 0}
	s.ref, _ = net.pool_spawn(&s.units, Unit{pos = {1.234, -5.678}, aim = 1, hp = 100, kind = .B, flags = {.X, .Z}, delta = -300, speed = 3.14159, local = 99}, owner = 1)
	net.pool_spawn(&s.units, Unit{pos = {10, 20}, hp = 50, kind = .C})
	for i in 0 ..< 5 {
		net.pool_spawn(&s.bullets, Bullet{pos = {f32(i), f32(i) * 2}, from = 1})
	}
}

// Encodes `cur` against `base`, decodes it against `client_base`, and returns the decoded snapshot.
send :: proc(t: ^testing.T, schema: ^net.Schema, base, cur, client_base: ^net.Snapshot) -> (got: net.Snapshot, size: int) {
	buf: [4096]u8
	w := net.writer_init(buf[:])
	net.delta_encode(&w, schema, base, cur)
	testing.expect(t, !w.overflow)

	got = net.snapshot_make(schema)
	r := net.reader_init(net.writer_bytes(&w))
	testing.expect(t, net.delta_decode(&r, schema, client_base, &got))
	return got, len(net.writer_bytes(&w))
}

@(test)
bits_roundtrip :: proc(t: ^testing.T) {
	buf: [64]u8
	w := net.writer_init(buf[:])
	net.write_bits(&w, 5, 3)
	net.write_bool(&w, true)
	net.write_bits(&w, 0xdead_beef_cafe, 48)
	net.write_varint(&w, 300)
	net.write_varint(&w, max(u64))
	net.write_bits(&w, max(u64), 64)
	testing.expect(t, !w.overflow)

	r := net.reader_init(net.writer_bytes(&w))
	testing.expect_value(t, net.read_bits(&r, 3), 5)
	testing.expect_value(t, net.read_bool(&r), true)
	testing.expect_value(t, net.read_bits(&r, 48), 0xdead_beef_cafe)
	testing.expect_value(t, net.read_varint(&r), 300)
	testing.expect_value(t, net.read_varint(&r), max(u64))
	testing.expect_value(t, net.read_bits(&r, 64), max(u64))
	testing.expect(t, !r.overflow)

	net.read_bits(&r, 8)
	testing.expect(t, r.overflow)
}

@(test)
bits_overflow :: proc(t: ^testing.T) {
	buf: [2]u8
	w := net.writer_init(buf[:])
	net.write_bits(&w, 0, 16)
	testing.expect(t, !w.overflow)
	net.write_bool(&w, true)
	testing.expect(t, w.overflow)
}

@(test)
zigzag_roundtrip :: proc(t: ^testing.T) {
	for v in ([]i64{0, -1, 1, -2, 1000, -1000, min(i64), max(i64)}) {
		testing.expect_value(t, net.zigzag_decode(net.zigzag_encode(v)), v)
	}
	testing.expect_value(t, net.zigzag_encode(-1), 1)
}

@(test)
schema_layout :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)

	testing.expect_value(t, len(schema.sections), 3)
	globals, units, bullets := schema.sections[0], schema.sections[UNITS], schema.sections[BULLETS]
	testing.expect_value(t, len(globals.fields), 1 + 4 + 2)
	testing.expect_value(t, len(units.fields), 8)
	testing.expect_value(t, len(bullets.fields), 3)
	testing.expect_value(t, units.count, 8)
	testing.expect_value(t, schema.value_count, 7 + 8 * 9 + 32 * 4)

	testing.expect_value(t, units.fields[0].kind, net.Field_Kind.Float_Quant)
	testing.expect_value(t, units.fields[2].kind, net.Field_Kind.Angle)
	testing.expect_value(t, units.fields[3].authority, net.Authority.Server)
	testing.expect_value(t, units.fields[5].bits, 3) // bit_set[Flag] has 3 elements
	testing.expect_value(t, units.fields[7].kind, net.Field_Kind.Float_Raw)
}

Bad_Slice       :: struct { xs: []int `net:""` }
Bad_Q_On_Int    :: struct { x: i32 `net:"q=0.1"` }
Bad_Key         :: struct { x: f32 `net:"precision=2"` }
Bad_Bits        :: struct { x: u8 `net:"bits=9"` }
Bad_Float_Bits  :: struct { x: f32 `net:"bits=8"` }
Pool_Item       :: struct { inner: net.Pool(Bullet, 2) `net:""` }
Bad_Nested_Pool :: struct { outer: net.Pool(Pool_Item, 2) `net:""` }

@(test)
schema_errors :: proc(t: ^testing.T) {
	for T in ([]typeid{Bad_Slice, Bad_Q_On_Int, Bad_Key, Bad_Bits, Bad_Float_Bits, Bad_Nested_Pool}) {
		schema, err := net.build_schema(T)
		testing.expectf(t, err != "", "%v should fail to build", T)
		net.schema_destroy(&schema)
	}
}

@(test)
schema_hash_changes_with_tags :: proc(t: ^testing.T) {
	A :: struct { x: f32 `net:"q=0.01"` }
	B :: struct { x: f32 `net:"q=0.1"` }
	a, _ := net.build_schema(A)
	b, _ := net.build_schema(B)
	defer net.schema_destroy(&a)
	defer net.schema_destroy(&b)
	testing.expect(t, a.hash != b.hash)
}

@(test)
full_snapshot_roundtrip :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)

	server: Test_State
	fill_state(&server)
	snap := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&snap)
	net.snapshot_capture(&schema, &snap, &server)

	got, _ := send(t, &schema, nil, &snap, nil)
	defer net.snapshot_destroy(&got)
	testing.expect(t, slice.equal(snap.values, got.values))

	client: Test_State
	net.snapshot_apply(&schema, &got, net.NO_PLAYER, &client)
	testing.expect_value(t, client.scores, server.scores)
	testing.expect_value(t, client.ref, server.ref)
	testing.expect(t, abs(client.time - 12.34) <= 0.025)

	u, ok := net.get(&client.units, server.ref)
	testing.expect(t, ok)
	if !ok do return
	testing.expect(t, abs(u.pos.x - 1.234) <= 0.005 && abs(u.pos.y + 5.678) <= 0.005)
	testing.expect(t, abs(u.aim - 1) <= math.TAU / 4096)
	testing.expect_value(t, u.hp, 100)
	testing.expect_value(t, u.kind, Kind.B)
	testing.expect_value(t, u.flags, bit_set[Flag]{.X, .Z})
	testing.expect_value(t, u.delta, -300)
	testing.expect_value(t, u.speed, 3.14159)
	testing.expect_value(t, u.local, 0) // never replicated
	testing.expect_value(t, net.owner(&client.units, server.ref), 1)

	alive := 0
	it := net.iter(&client.bullets)
	for _ in net.next(&it) do alive += 1
	testing.expect_value(t, alive, 5)
}

@(test)
capture_is_stable :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)

	server, client: Test_State
	fill_state(&server)
	a := net.snapshot_make(&schema)
	b := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&a)
	defer net.snapshot_destroy(&b)

	// Values that came back from a snapshot must quantize to the same values again,
	// or every snapshot would see phantom changes.
	net.snapshot_capture(&schema, &a, &server)
	net.snapshot_apply(&schema, &a, net.NO_PLAYER, &client)
	net.snapshot_capture(&schema, &b, &client)
	testing.expect(t, slice.equal(a.values, b.values))
}

@(test)
delta_unchanged_is_tiny :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)

	server: Test_State
	fill_state(&server)
	base := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&base)
	net.snapshot_capture(&schema, &base, &server)

	client_base := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&client_base)
	copy(client_base.values, base.values)

	got, size := send(t, &schema, &base, &base, &client_base)
	defer net.snapshot_destroy(&got)
	testing.expect(t, slice.equal(got.values, base.values))
	testing.expectf(t, size <= 2, "unchanged delta took %d bytes", size)
}

@(test)
delta_changes :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)

	server: Test_State
	fill_state(&server)
	base := net.snapshot_make(&schema)
	cur := net.snapshot_make(&schema)
	client_base := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&base)
	defer net.snapshot_destroy(&cur)
	defer net.snapshot_destroy(&client_base)
	net.snapshot_capture(&schema, &base, &server)
	copy(client_base.values, base.values)

	client: Test_State
	net.snapshot_apply(&schema, &client_base, net.NO_PLAYER, &client)

	// Move a unit, replace bullet 2 with a new bullet in the same slot, advance the clock.
	old_bullet := net.Handle{2, server.bullets.meta[2].gen}
	net.get(&server.units, server.ref).pos.x += 1
	net.pool_despawn(&server.bullets, old_bullet)
	new_bullet, _ := net.pool_spawn(&server.bullets, Bullet{pos = {7, 7}, from = 3})
	testing.expect_value(t, new_bullet.index, 2)
	server.time += 0.5
	net.snapshot_capture(&schema, &cur, &server)

	full, full_size := send(t, &schema, nil, &cur, nil)
	defer net.snapshot_destroy(&full)
	got, size := send(t, &schema, &base, &cur, &client_base)
	defer net.snapshot_destroy(&got)
	testing.expect(t, slice.equal(got.values, cur.values))
	testing.expectf(t, size < full_size / 2, "delta %d bytes vs full %d bytes", size, full_size)

	net.snapshot_apply(&schema, &got, net.NO_PLAYER, &client)
	_, old_ok := net.get(&client.bullets, old_bullet)
	b, new_ok := net.get(&client.bullets, new_bullet)
	testing.expect(t, !old_ok)
	testing.expect(t, new_ok)
	if new_ok do testing.expect_value(t, b.from, 3)
	testing.expect(t, abs(net.get(&client.units, server.ref).pos.x - 2.234) <= 0.005)
}

@(test)
owned_entity_apply :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)
	LOCAL :: net.Player_Id(1)

	server, client: Test_State
	fill_state(&server)
	snap := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&snap)
	net.snapshot_capture(&schema, &snap, &server)
	net.snapshot_apply(&schema, &snap, LOCAL, &client)

	mine := net.get(&client.units, server.ref)
	other := net.Handle{1, client.units.meta[1].gen}

	// The client moves its own unit and (wrongly) a server-owned one; the server changes hp.
	mine.pos = {50, 50}
	net.get(&client.units, other).pos = {99, 99}
	net.get(&server.units, server.ref).hp = 10
	net.snapshot_capture(&schema, &snap, &server)
	net.snapshot_apply(&schema, &snap, LOCAL, &client)

	testing.expect_value(t, mine.pos, [2]f32{50, 50}) // owner field kept
	testing.expect_value(t, mine.hp, 10)              // server field taken
	testing.expect_value(t, net.get(&client.units, other).pos, [2]f32{10, 20})

	// The server forces a correction (e.g. a respawn).
	net.get(&server.units, server.ref).pos = {0, 0}
	server.units.meta[server.ref.index].override += 1
	net.snapshot_capture(&schema, &snap, &server)
	net.snapshot_apply(&schema, &snap, LOCAL, &client)
	testing.expect_value(t, mine.pos, [2]f32{0, 0})
}

@(test)
ring_lookup :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)
	ring: net.Snapshot_Ring
	net.ring_init(&ring, &schema)
	defer net.ring_destroy(&ring)

	net.ring_put(&ring, 5)
	testing.expect(t, net.ring_get(&ring, 5) != nil)
	testing.expect(t, net.ring_get(&ring, 6) == nil)
	testing.expect(t, net.ring_get(&ring, 5 + net.SNAPSHOT_RING_SIZE) == nil)
	net.ring_put(&ring, 5 + net.SNAPSHOT_RING_SIZE)
	testing.expect(t, net.ring_get(&ring, 5) == nil)
}

@(test)
decode_garbage_does_not_crash :: proc(t: ^testing.T) {
	schema := make_schema(t)
	defer net.schema_destroy(&schema)
	out := net.snapshot_make(&schema)
	defer net.snapshot_destroy(&out)

	buf: [96]u8
	for _ in 0 ..< 2000 {
		n := rand.int_max(len(buf))
		for &b in buf[:n] do b = u8(rand.uint32())
		r := net.reader_init(buf[:n])
		net.delta_decode(&r, &schema, nil, &out)
	}
}

Bad_String_State :: struct { name: string `net:""` }

@(test)
strings_only_in_unions :: proc(t: ^testing.T) {
	schema, err := net.build_schema(Bad_String_State)
	testing.expect(t, err != "", "strings must be rejected in replicated state")
	net.schema_destroy(&schema)

	Named :: struct { id: u8 `net:""`, name: string `net:""` }
	Msg :: union { Named }
	us, union_err := net.build_union_schema(Msg)
	defer net.union_schema_destroy(&us)
	testing.expect(t, union_err == "", union_err)

	buf: [256]u8
	w := net.writer_init(buf[:])
	net.union_encode(&w, &us, Named, &Named{id = 7, name = "Ödin ✓"})
	r := net.reader_init(net.writer_bytes(&w))
	out: Msg
	testing.expect(t, net.union_decode(&r, &us, &out))
	got, ok := out.(Named)
	testing.expect(t, ok && got.id == 7 && got.name == "Ödin ✓")
}
