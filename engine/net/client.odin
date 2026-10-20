package net

Client :: struct($S, $I, $V: typeid) {
	using core: Core(S, I, V),
	status:     Client_Status,
	input:      I,
	received:   Tick, // newest snapshot received (and acked)
	applied:    Tick, // newest snapshot written into the state
	scratch:    Snapshot,
	rtt:        f32,
}

Client_Status :: enum u8 {
	Connecting,
	Connected,
	Disconnected,
}

// `state` must stay at the same address until client_stop. The transport should already be
// connecting; the handshake runs inside client_update.
client_start :: proc(cl: ^Client($S, $I, $V), state: ^S, game: Game(S, I, V), transport: Transport, config := DEFAULT_CONFIG) -> (err: string) {
	if err = core_init(&cl.core, state, game, transport, config, is_server = false); err != "" do return
	cl.scratch = snapshot_make(&cl.schema)
	cl.status = .Connecting
	return ""
}

client_stop :: proc(cl: ^Client($S, $I, $V)) {
	if cl.status != .Disconnected do transport_disconnect(cl.transport, SERVER_PEER)
	transport_destroy(cl.transport)
	snapshot_destroy(&cl.scratch)
	core_destroy(&cl.core)
}

// Call once per frame with the input sampled this frame.
client_update :: proc(cl: ^Client($S, $I, $V), dt: f32, input: I) {
	transport_update(cl.transport, dt)
	cl.input = input
	client_receive(cl)
	if cl.status == .Connected {
		for _ in 0 ..< ticks_due(&cl.core, dt) do client_tick(cl)
	}
	transport_flush(cl.transport)
}

status :: proc(cl: ^Client($S, $I, $V)) -> Client_Status {
	return cl.status
}

local_player :: proc(cl: ^Client($S, $I, $V)) -> Player_Id {
	return cl.ctx.local_player
}

// Round-trip time in seconds, measured in whole ticks.
ping :: proc(cl: ^Client($S, $I, $V)) -> f32 {
	return cl.rtt
}

// How far the client is between the last tick and the next, 0..1. Use it to interpolate rendering.
alpha :: proc(cl: ^Client($S, $I, $V)) -> f32 {
	return f32(cl.time * f64(cl.config.tick_rate))
}

// Whether player `p` is connected, as last seen in a snapshot.
player_connected :: proc(cl: ^Client($S, $I, $V), p: Player_Id) -> bool {
	return int(p) < MAX_PLAYERS && cl.table.slots.meta[p].alive
}

@(private)
client_tick :: proc(cl: ^Client($S, $I, $V)) {
	if cl.received > cl.applied {
		snapshot_apply(&cl.schema, ring_get(&cl.ring, cl.received), cl.ctx.local_player, cl.state, &cl.table)
		cl.applied = cl.received
	}

	cl.ctx.tick += 1
	cl.table.slots.items[cl.ctx.local_player] = cl.input
	cl.game.tick(&cl.ctx, cl.state, &cl.table.slots.items)

	w := writer_init(cl.packet)
	write_message_header(&w, .Client_Update)
	write_bits(&w, u64(cl.ctx.tick), 32)
	write_bits(&w, u64(cl.received), 32)
	write_values(&w, cl.input_fields, &cl.input)
	write_owned(&w, &cl.schema, cl.state, cl.ctx.local_player)
	transport_send(cl.transport, SERVER_PEER, .Unreliable, writer_bytes(&w))

	for e in cl.queue.items {
		transport_send(cl.transport, SERVER_PEER, .Reliable, cl.queue.bytes[e.start:e.end])
	}
	event_queue_clear(&cl.queue)
}

@(private)
client_receive :: proc(cl: ^Client($S, $I, $V)) {
	for {
		te, ok := transport_poll(cl.transport)
		if !ok do break
		switch te.kind {
		case .Connect:
			w := writer_init(cl.packet)
			write_message_header(&w, .Hello)
			write_bits(&w, protocol_hash(&cl.schema, &cl.events), 64)
			transport_send(cl.transport, SERVER_PEER, .Reliable, writer_bytes(&w))
		case .Disconnect:
			cl.status = .Disconnected
		case .Packet:
			client_handle_packet(cl, te.data)
		}
	}
}

@(private)
client_handle_packet :: proc(cl: ^Client($S, $I, $V), data: []u8) {
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
		cl.ctx.local_player = p

	case .Snapshot:
		tick := Tick(read_bits(&r, 32))
		base_tick := Tick(read_bits(&r, 32))
		echo := Tick(read_bits(&r, 32))
		if r.overflow || cl.status != .Connected || tick <= cl.received do return

		base: ^Snapshot
		if base_tick != 0 {
			base = ring_get(&cl.ring, base_tick)
			if base == nil do return // baseline too old; the server will fall back once it sees our ack
		}
		if !delta_decode(&r, &cl.schema, base, &cl.scratch) do return
		copy(ring_put(&cl.ring, tick).values, cl.scratch.values)
		cl.received = tick
		if echo != 0 && cl.ctx.tick >= echo do cl.rtt = f32(cl.ctx.tick - echo) * cl.ctx.dt

	case .Event:
		if cl.status != .Connected || cl.game.on_event == nil do return
		read_bits(&r, 32) // tick
		from := Player_Id(read_bits(&r, 8))
		ev: V
		if event_decode(&r, &cl.events, &ev) do cl.game.on_event(&cl.ctx, cl.state, from, ev)
	}
}
