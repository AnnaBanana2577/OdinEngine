package net

Client :: struct($S, $I, $V, $M: typeid) {
	using core:  Core(S, I, V, M),
	status:      Client_Status,
	input:       I,
	received:    Tick, // newest snapshot received (and acked)
	applied:     Tick, // newest snapshot written into the state
	scratch:     Snapshot,
	rtt:         f32,
	server_echo: Tick,           // newest client tick the server has confirmed
	last_event:  u32,            // newest server event id received
	incoming:    [dynamic][]u8, // received server events, fired when their snapshot is applied
}

Client_Status :: enum u8 {
	Connecting,
	Connected,
	Disconnected,
}

// `state` must stay at the same address until client_stop. The transport should already be
// connecting; the handshake runs inside client_update.
client_start :: proc(cl: ^Client($S, $I, $V, $M), state: ^S, game: Game(S, I, V, M), transport: Transport, config := DEFAULT_CONFIG) -> (err: string) {
	if err = core_init(&cl.core, state, game, transport, config, is_server = false); err != "" do return
	cl.scratch = snapshot_make(&cl.schema)
	cl.status = .Connecting
	return ""
}

client_stop :: proc(cl: ^Client($S, $I, $V, $M)) {
	if cl.status != .Disconnected do transport_disconnect(cl.transport, SERVER_PEER)
	transport_destroy(cl.transport)
	for data in cl.incoming do delete(data)
	delete(cl.incoming)
	snapshot_destroy(&cl.scratch)
	core_destroy(&cl.core)
}

// Call once per frame with the input sampled this frame.
client_update :: proc(cl: ^Client($S, $I, $V, $M), dt: f32, input: I) {
	transport_update(cl.transport, dt)
	cl.input = input
	client_receive(cl)

	switch cl.status {
	case .Connecting: // keep messages queued until connected
	case .Connected:
		for _ in 0 ..< ticks_due(&cl.core, dt) do client_tick(cl)
		for m in cl.messages.items {
			transport_send(cl.transport, SERVER_PEER, .Reliable, cl.messages.bytes[m.start:m.end])
		}
		message_queue_clear(&cl.messages)
	case .Disconnected:
		message_queue_clear(&cl.messages)
	}
	transport_flush(cl.transport)
}

status :: proc(cl: ^Client($S, $I, $V, $M)) -> Client_Status {
	return cl.status
}

local_player :: proc(cl: ^Client($S, $I, $V, $M)) -> Player_Id {
	return cl.ctx.local_player
}

// Round-trip time in seconds, measured in whole ticks.
ping :: proc(cl: ^Client($S, $I, $V, $M)) -> f32 {
	return cl.rtt
}

// How far the client is between the last tick and the next, 0..1. Use it to interpolate rendering.
alpha :: proc(cl: ^Client($S, $I, $V, $M)) -> f32 {
	return f32(cl.time * f64(cl.config.tick_rate))
}

// Whether player `p` is connected, as last seen in a snapshot.
player_connected :: proc(cl: ^Client($S, $I, $V, $M), p: Player_Id) -> bool {
	return int(p) < MAX_PLAYERS && cl.table.slots.meta[p].alive
}

@(private)
client_tick :: proc(cl: ^Client($S, $I, $V, $M)) {
	event_tick_begin(&cl.ctx) // events emitted from here on go out in this tick's update
	defer event_tick_end(&cl.ctx)

	if cl.received > cl.applied {
		snapshot_apply(&cl.schema, ring_get(&cl.ring, cl.received), cl.ctx.local_player, cl.state, &cl.table)
		cl.applied = cl.received
		fire_events(cl)
	}

	cl.table.slots.items[cl.ctx.local_player] = cl.input
	cl.game.tick(&cl.ctx, cl.state, &cl.table.slots.items)

	#reverse for e, i in cl.event_log.items {
		if cl.ctx.tick > e.expire do event_log_remove(&cl.event_log, i)
	}

	w := writer_init(cl.packet)
	write_message_header(&w, .Client_Update)
	write_bits(&w, u64(cl.ctx.tick), 32)
	write_bits(&w, u64(cl.received), 32)
	write_values(&w, cl.input_fields, &cl.input)
	write_owned(&w, &cl.schema, cl.state, cl.ctx.local_player)
	prev: u32
	for &e in cl.event_log.items do write_event(&w, &e, cl.ctx.tick, &prev)
	write_bool(&w, false)
	transport_send(cl.transport, SERVER_PEER, .Unreliable, writer_bytes(&w))
}

@(private)
fire_events :: proc(cl: ^Client($S, $I, $V, $M)) {
	for data in cl.incoming {
		r := reader_init(data)
		ev: V
		if union_decode(&r, &cl.event_schema, &ev) && cl.game.on_event != nil {
			cl.game.on_event(&cl.ctx, cl.state, NO_PLAYER, ev)
		}
		delete(data)
	}
	clear(&cl.incoming)
}

@(private)
client_receive :: proc(cl: ^Client($S, $I, $V, $M)) {
	for {
		te, ok := transport_poll(cl.transport)
		if !ok do break
		switch te.kind {
		case .Connect:
			w := writer_init(cl.packet)
			write_message_header(&w, .Hello)
			write_bits(&w, protocol_hash(&cl.core), 64)
			transport_send(cl.transport, SERVER_PEER, .Reliable, writer_bytes(&w))
		case .Disconnect:
			cl.status = .Disconnected
		case .Packet:
			client_handle_packet(cl, te.data)
		}
	}
}

@(private)
client_handle_packet :: proc(cl: ^Client($S, $I, $V, $M), data: []u8) {
	r := reader_init(data)
	kind, ok := read_message_header(&r)
	if !ok do return

	#partial switch kind {
	case .Welcome:
		p := Player_Id(read_bits(&r, 8))
		rate := int(read_bits(&r, 16))
		tick := Tick(read_bits(&r, 32))
		if r.overflow || cl.status != .Connecting || rate == 0 || int(p) >= MAX_PLAYERS do return
		cl.status = .Connected
		cl.config.tick_rate = rate
		cl.ctx.dt = 1 / f32(rate)
		cl.ctx.tick = tick
		event_tick_end(&cl.ctx)
		cl.ctx.local_player = p

	case .Snapshot:
		read_snapshot(cl, &r)

	case .Message:
		if cl.status != .Connected || cl.game.on_message == nil do return
		msg: M
		if union_decode(&r, &cl.message_schema, &msg) do cl.game.on_message(&cl.ctx, cl.state, NO_PLAYER, msg)
	}
}

@(private)
read_snapshot :: proc(cl: ^Client($S, $I, $V, $M), r: ^Bit_Reader) {
	tick := Tick(read_bits(r, 32))
	base_tick := Tick(read_bits(r, 32))
	echo := Tick(read_bits(r, 32))
	if r.overflow || cl.status != .Connected || tick <= cl.received do return

	base: ^Snapshot
	if base_tick != 0 {
		base = ring_get(&cl.ring, base_tick)
		if base == nil do return // baseline too old; the server will fall back once it sees our ack
	}
	if !delta_decode(r, &cl.schema, base, &cl.scratch) do return
	copy(ring_put(&cl.ring, tick).values, cl.scratch.values)
	cl.received = tick

	if echo > cl.server_echo {
		cl.server_echo = echo
		if cl.ctx.tick >= echo do cl.rtt = f32(cl.ctx.tick - echo) * cl.ctx.dt
		#reverse for e, i in cl.event_log.items {
			if e.tick <= echo do event_log_remove(&cl.event_log, i) // the server has it
		}
	}

	prev: u32
	for read_bool(r) {
		id, _, bits, ok := read_event_header(r, tick, &prev)
		if !ok do return
		if id > cl.last_event {
			cl.last_event = id
			append(&cl.incoming, read_bits_to_slice(r, bits))
		} else {
			r.bit_pos += bits // already have it
		}
	}
}
