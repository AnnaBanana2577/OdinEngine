package net

import "core:log"
import "core:mem"

Server :: struct($S, $I, $V, $M: typeid) {
	using core: Core(S, I, V, M),
	clients:    [MAX_PLAYERS]Connection, // index = player id
	validators: []Validator,             // per schema section
	scratch:    []u8,                    // one pool item, for validating client updates
}

Connection :: struct {
	state:       Connection_State,
	peer:        Peer_Id,
	joined_tick: Tick, // events from before this tick are not sent to this client
	ack:         Tick, // newest snapshot the client has: the delta baseline, and what events it has
	client_tick: Tick, // newest client update received; older ones are dropped
	last_event:  u32,  // newest event id received from this client
}

Connection_State :: enum u8 {
	Free,
	Pending, // transport connected, waiting for Hello
	Joined,
}

Validator :: #type proc(ctx: ^Context, from: Player_Id, old, new: rawptr) -> bool

// `state` must stay at the same address until server_stop.
server_start :: proc(srv: ^Server($S, $I, $V, $M), state: ^S, game: Game(S, I, V, M), transport: Transport, config := DEFAULT_CONFIG) -> (err: string) {
	if err = core_init(&srv.core, state, game, transport, config, is_server = true); err != "" do return
	srv.validators = make([]Validator, len(srv.schema.sections))
	stride := 0
	for sec in srv.schema.sections do stride = max(stride, sec.stride)
	srv.scratch = make([]u8, stride)
	return ""
}

server_stop :: proc(srv: ^Server($S, $I, $V, $M)) {
	for c in srv.clients {
		if c.state != .Free do transport_disconnect(srv.transport, c.peer)
	}
	transport_destroy(srv.transport)
	delete(srv.validators)
	delete(srv.scratch)
	core_destroy(&srv.core)
}

// Registers a check for owner-written fields that clients send for entities in `pool`.
// `old` is the server's current entity, `new` is what the client claims. Return false to reject.
server_validate :: proc(srv: ^Server($S, $I, $V, $M), pool: ^Pool($T, $N), fn: proc(ctx: ^Context, from: Player_Id, old, new: ^T) -> bool) {
	offset := uintptr(&pool.items) - uintptr(srv.state)
	for sec, i in srv.schema.sections {
		if sec.root == 0 && sec.is_pool && sec.items == offset {
			srv.validators[i] = transmute(Validator)fn
			return
		}
	}
	panic("net.server_validate: pool is not a replicated part of the server's state")
}

server_update :: proc(srv: ^Server($S, $I, $V, $M), dt: f32) {
	transport_update(srv.transport, dt)
	for _ in 0 ..< ticks_due(&srv.core, dt) do server_tick(srv)

	for m in srv.messages.items {
		for c, p in srv.clients {
			if c.state == .Joined && is_for(m.target, m.player, Player_Id(p)) {
				transport_send(srv.transport, c.peer, .Reliable, srv.messages.bytes[m.start:m.end])
			}
		}
	}
	message_queue_clear(&srv.messages)
	transport_flush(srv.transport)
}

// Disconnects a player. on_leave runs right away.
kick :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id) {
	if int(p) >= MAX_PLAYERS || srv.clients[p].state == .Free do return
	transport_disconnect(srv.transport, srv.clients[p].peer)
	drop_client(srv, p)
}

@(private)
server_tick :: proc(srv: ^Server($S, $I, $V, $M)) {
	event_tick_begin(&srv.ctx)
	defer event_tick_end(&srv.ctx)
	server_receive(srv)
	srv.game.tick(&srv.ctx, srv.state, &srv.table.slots.items)

	snap := ring_put(&srv.ring, srv.ctx.tick)
	snapshot_capture(&srv.schema, snap, srv.state, &srv.table)
	if int(srv.ctx.tick) % srv.config.snapshot_every == 0 {
		for &c, p in srv.clients {
			if c.state == .Joined do send_snapshot(srv, &c, Player_Id(p), snap)
		}
	}

	// Forget events that expired or that every client they are for has acked.
	#reverse for e, i in srv.event_log.items {
		if srv.ctx.tick <= e.expire && event_still_needed(srv, e) do continue
		event_log_remove(&srv.event_log, i)
	}
}

@(private)
event_still_needed :: proc(srv: ^Server($S, $I, $V, $M), e: Logged_Event) -> bool {
	for c, p in srv.clients {
		if c.state == .Joined && wants_event(c, Player_Id(p), e) do return true
	}
	return false
}

// Whether `e` still has to go out to this client.
@(private)
wants_event :: proc(c: Connection, p: Player_Id, e: Logged_Event) -> bool {
	return e.tick > c.ack && e.tick >= c.joined_tick && is_for(e.target, e.player, p)
}

@(private)
server_receive :: proc(srv: ^Server($S, $I, $V, $M)) {
	for {
		te, ok := transport_poll(srv.transport)
		if !ok do break
		switch te.kind {
		case .Connect:
			p, free := find_free(srv)
			if !free {
				transport_disconnect(srv.transport, te.peer) // server full
				continue
			}
			srv.clients[p] = {state = .Pending, peer = te.peer}
		case .Disconnect:
			if p, found := find_peer(srv, te.peer); found do drop_client(srv, p)
		case .Packet:
			if p, found := find_peer(srv, te.peer); found do server_handle_packet(srv, p, te.data)
		}
	}
}

@(private)
server_handle_packet :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id, data: []u8) {
	c := &srv.clients[p]
	r := reader_init(data)
	kind, ok := read_message_header(&r)
	if !ok do return

	#partial switch kind {
	case .Hello:
		hash := read_bits(&r, 64)
		if c.state != .Pending do return
		if r.overflow || hash != protocol_hash(&srv.core) {
			log.warnf("net: player %d has a different game build, disconnecting", p)
			kick(srv, p)
			return
		}
		join_client(srv, p)

	case .Client_Update:
		if c.state == .Joined do read_client_update(srv, p, &r)

	case .Message:
		if c.state != .Joined || srv.game.on_message == nil do return
		msg: M
		if union_decode(&r, &srv.message_schema, &msg) do srv.game.on_message(&srv.ctx, srv.state, p, msg)
	}
}

@(private)
join_client :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id) {
	srv.clients[p].state = .Joined
	srv.clients[p].joined_tick = srv.ctx.tick
	m := &srv.table.slots.meta[p]
	gen := m.gen + 1
	if gen == 0 do gen = 1
	m^ = {gen = gen, alive = true, owner = p}
	srv.table.slots.items[p] = {}

	w := writer_init(srv.packet)
	write_message_header(&w, .Welcome)
	write_bits(&w, u64(p), 8)
	write_bits(&w, u64(srv.config.tick_rate), 16)
	write_bits(&w, u64(srv.ctx.tick), 32)
	transport_send(srv.transport, srv.clients[p].peer, .Reliable, writer_bytes(&w))

	if srv.game.on_join != nil do srv.game.on_join(&srv.ctx, srv.state, p)
}

@(private)
drop_client :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id) {
	if srv.clients[p].state == .Joined {
		if srv.game.on_leave != nil do srv.game.on_leave(&srv.ctx, srv.state, p)
		srv.table.slots.meta[p].alive = false
		srv.table.slots.items[p] = {}
	}
	srv.clients[p] = {}
}

// Input, then owned entities, then events, so a client's events see its state from the same tick.
@(private)
read_client_update :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id, r: ^Bit_Reader) {
	c := &srv.clients[p]
	client_tick := Tick(read_bits(r, 32))
	ack := Tick(read_bits(r, 32))
	input: I
	read_values(r, srv.input_fields, &input)
	if r.overflow || client_tick <= c.client_tick do return // malformed, late or duplicate

	c.client_tick = client_tick
	if ack > c.ack && ack <= srv.ctx.tick do c.ack = ack
	srv.table.slots.items[p] = input

	for sec, s in srv.schema.sections {
		if sec.root != 0 || !sec.is_pool do continue
		for read_bool(r) {
			i := read_varint(r)
			gen := u16(read_bits(r, 16))
			override := u8(read_bits(r, 8))
			if i >= u64(sec.count) do return

			item := item_ptr(srv.state, sec, int(i))
			claimed := raw_data(srv.scratch)
			mem.copy(claimed, item, sec.stride)
			read_values(r, sec.fields, claimed, Authority.Owner)
			if r.overflow do return

			// Stale (despawned, reassigned, or the server forced a correction the client hasn't seen yet).
			meta := slot_meta(srv.state, sec, int(i))
			if !meta.alive || meta.gen != gen || meta.owner != p || meta.override != override do continue
			if v := srv.validators[s]; v != nil && !v(&srv.ctx, p, item, claimed) do continue
			mem.copy(item, claimed, sec.stride)
		}
	}

	prev: u32
	for read_bool(r) {
		id, _, bits, ok := read_event_header(r, client_tick, &prev)
		if !ok do return
		end := r.bit_pos + bits
		if id > c.last_event {
			c.last_event = id
			ev: V
			if union_decode(r, &srv.event_schema, &ev) && srv.game.on_event != nil {
				srv.game.on_event(&srv.ctx, srv.state, p, ev)
			}
		}
		r.bit_pos = end
	}
}

@(private)
send_snapshot :: proc(srv: ^Server($S, $I, $V, $M), c: ^Connection, p: Player_Id, snap: ^Snapshot) {
	base: ^Snapshot
	if c.ack != 0 do base = ring_get(&srv.ring, c.ack)

	w := writer_init(srv.packet)
	write_message_header(&w, .Snapshot)
	write_bits(&w, u64(snap.tick), 32)
	write_bits(&w, u64(base.tick) if base != nil else 0, 32)
	write_bits(&w, u64(c.client_tick), 32)
	delta_encode(&w, &srv.schema, base, snap)

	prev: u32
	for &e in srv.event_log.items {
		if srv.ctx.tick <= e.expire && wants_event(c^, p, e) do write_event(&w, &e, snap.tick, &prev)
	}
	write_bool(&w, false)

	if w.overflow {
		log.errorf("net: snapshot for player %d is larger than %d bytes, not sent", p, MAX_PACKET)
		return
	}
	transport_send(srv.transport, c.peer, .Unreliable, writer_bytes(&w))
}

@(private)
find_peer :: proc(srv: ^Server($S, $I, $V, $M), peer: Peer_Id) -> (Player_Id, bool) {
	for c, p in srv.clients {
		if c.state != .Free && c.peer == peer do return Player_Id(p), true
	}
	return NO_PLAYER, false
}

@(private)
find_free :: proc(srv: ^Server($S, $I, $V, $M)) -> (Player_Id, bool) {
	for c, p in srv.clients {
		if c.state == .Free do return Player_Id(p), true
	}
	return NO_PLAYER, false
}
