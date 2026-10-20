package net

// Pool is a fixed array of entities of one kind. Tag a Pool field with `net:""` to replicate it.
// Slots are reused; Handle.gen tells a reused slot apart from the entity that lived there before.
Pool :: struct($T: typeid, $N: int) where N > 0 && N <= 1 << 16 {
	items: [N]T,
	meta:  [N]Slot_Meta,
}

Slot_Meta :: struct {
	gen:      u16,
	alive:    bool,
	owner:    Player_Id, // NO_PLAYER = server authority
	override: u8,        // bumped by the server to force-correct an owned entity
}

// The zero Handle never refers to a live entity, because generations start at 1.
Handle :: struct {
	index: u16 `net:""`,
	gen:   u16 `net:""`,
}

Pool_Iterator :: struct($T: typeid, $N: int) {
	pool:  ^Pool(T, N),
	index: int,
}

// Spawns without authority checks. Game code should use `spawn`, which only works on the server.
pool_spawn :: proc(p: ^Pool($T, $N), item: T, owner := NO_PLAYER) -> (h: Handle, ok: bool) {
	for &m, i in p.meta {
		if m.alive do continue
		gen := m.gen + 1
		if gen == 0 do gen = 1
		m = {gen = gen, alive = true, owner = owner}
		p.items[i] = item
		return {u16(i), gen}, true
	}
	return {}, false
}

// Despawns without authority checks. Game code should use `despawn`.
pool_despawn :: proc(p: ^Pool($T, $N), h: Handle) {
	if _, ok := get(p, h); !ok do return
	p.meta[h.index].alive = false
	p.items[h.index] = {}
}

get :: proc(p: ^Pool($T, $N), h: Handle) -> (item: ^T, ok: bool) #optional_ok {
	if int(h.index) >= N do return nil, false
	m := p.meta[h.index]
	if !m.alive || m.gen != h.gen do return nil, false
	return &p.items[h.index], true
}

owner :: proc(p: ^Pool($T, $N), h: Handle) -> Player_Id {
	if _, ok := get(p, h); !ok do return NO_PLAYER
	return p.meta[h.index].owner
}

// Usage:
//	it := net.iter(&s.players)
//	for p, h in net.next(&it) { ... }
iter :: proc(p: ^Pool($T, $N)) -> Pool_Iterator(T, N) {
	return {pool = p}
}

next :: proc(it: ^Pool_Iterator($T, $N)) -> (item: ^T, h: Handle, ok: bool) {
	for it.index < N {
		i := it.index
		it.index += 1
		if m := it.pool.meta[i]; m.alive {
			return &it.pool.items[i], {u16(i), m.gen}, true
		}
	}
	return nil, {}, false
}
