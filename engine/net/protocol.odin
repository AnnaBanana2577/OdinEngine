package net

MAX_PACKET :: 1 << 16

// Every packet starts with an 8-bit Message_Kind.
//	Hello          C→S reliable    protocol hash (u64)
//	Welcome        S→C reliable    player id (u8), tick rate (u16), server tick (u32)
//	Client_Update  C→S unreliable  client tick (u32), acked snapshot tick (u32), input, owned entities, events
//	Snapshot       S→C unreliable  server tick (u32), baseline tick (u32, 0 = none), echoed client tick (u32), delta, events
//	Message        both, reliable  message
Message_Kind :: enum u8 {
	Hello,
	Welcome,
	Client_Update,
	Snapshot,
	Message,
}

write_message_header :: proc(w: ^Bit_Writer, kind: Message_Kind) {
	write_bits(w, u64(kind), 8)
}

read_message_header :: proc(r: ^Bit_Reader) -> (kind: Message_Kind, ok: bool) {
	k := read_bits(r, 8)
	if r.overflow || k > u64(max(Message_Kind)) do return {}, false
	return Message_Kind(k), true
}

// Everything both sides must agree on to talk: the state, input, event and message layouts.
protocol_hash :: proc(c: ^Core($S, $I, $V, $M)) -> u64 {
	h := hash_mix(c.schema.hash, c.event_schema.hash)
	return hash_mix(hash_mix(h, c.message_schema.hash), u64(MAX_PLAYERS))
}

// Owned entities in a Client_Update, per pool section of the game state:
//	for each entity owned by the client: 1 bit, slot index (varint), gen (16), override (8),
//	owner fields in full. A final 0 bit ends the section.
write_owned :: proc(w: ^Bit_Writer, schema: ^Schema, state: rawptr, local: Player_Id) {
	for sec in schema.sections {
		if sec.root != 0 || !sec.is_pool do continue
		for i in 0 ..< sec.count {
			meta := slot_meta(state, sec, i)
			if !meta.alive || meta.owner != local do continue
			write_bool(w, true)
			write_varint(w, u64(i))
			write_bits(w, u64(meta.gen), 16)
			write_bits(w, u64(meta.override), 8)
			write_values(w, sec.fields, item_ptr(state, sec, i), Authority.Owner)
		}
		write_bool(w, false)
	}
}

// Engine-owned replicated data next to the game state: who is connected and their last input.
Player_Table :: struct($I: typeid) {
	slots: Pool(I, MAX_PLAYERS) `net:""`, // slot index = player id, alive = connected
}

// The parts shared by Server and Client.
Core :: struct($S, $I, $V, $M: typeid) {
	game:           Game(S, I, V, M),
	config:         Config,
	transport:      Transport,
	state:          ^S,
	table:          Player_Table(I),
	schema:         Schema, // root 0: the game state, root 1: the player table
	event_schema:   Union_Schema,
	message_schema: Union_Schema,
	input_fields:   []Field,
	ring:           Snapshot_Ring,
	ctx:            Context,
	event_log:      Event_Log,     // events this peer emitted that may not be acked yet
	messages:       Message_Queue, // messages to send at the end of the update
	packet:         []u8,
	time:           f64, // unspent time, less than one tick
}

@(private)
core_init :: proc(c: ^Core($S, $I, $V, $M), state: ^S, game: Game(S, I, V, M), transport: Transport, config: Config, is_server: bool) -> (err: string) {
	assert(game.tick != nil, "net: Game.tick is required")
	c.game = game
	c.state = state
	c.transport = transport
	c.config = config
	if c.config.tick_rate <= 0 do c.config.tick_rate = DEFAULT_CONFIG.tick_rate
	if c.config.snapshot_every <= 0 do c.config.snapshot_every = DEFAULT_CONFIG.snapshot_every
	if c.config.max_catchup <= 0 do c.config.max_catchup = DEFAULT_CONFIG.max_catchup
	if c.config.event_ttl == 0 do c.config.event_ttl = DEFAULT_CONFIG.event_ttl

	c.schema, err = build_schema(S)
	if err != "" do return
	if err = schema_append(&c.schema, Player_Table(I)); err != "" do return
	if c.event_schema, err = build_union_schema(V); err != "" {
		schema_destroy(&c.schema)
		return
	}
	if c.message_schema, err = build_union_schema(M); err != "" {
		schema_destroy(&c.schema)
		union_schema_destroy(&c.event_schema)
		return
	}
	c.input_fields = c.schema.sections[len(c.schema.sections) - 1].fields

	ring_init(&c.ring, &c.schema)
	c.packet = make([]u8, MAX_PACKET)
	c.ctx = {
		dt             = 1 / f32(c.config.tick_rate),
		is_server      = is_server,
		local_player   = NO_PLAYER,
		event_log      = &c.event_log,
		event_schema   = &c.event_schema,
		event_ttl      = c.config.event_ttl,
		messages       = &c.messages,
		message_schema = &c.message_schema,
	}
	return ""
}

@(private)
core_destroy :: proc(c: ^Core($S, $I, $V, $M)) {
	ring_destroy(&c.ring)
	schema_destroy(&c.schema)
	union_schema_destroy(&c.event_schema)
	union_schema_destroy(&c.message_schema)
	event_log_destroy(&c.event_log)
	message_queue_destroy(&c.messages)
	delete(c.packet)
}

// Adds frame time and returns how many fixed ticks to run now.
@(private)
ticks_due :: proc(c: ^Core($S, $I, $V, $M), dt: f32) -> int {
	step := 1 / f64(c.config.tick_rate)
	c.time += f64(dt)
	n := int(c.time / step)
	if n > c.config.max_catchup {
		c.time = 0 // too far behind (breakpoint, hitch): drop the time instead of spiraling
		return c.config.max_catchup
	}
	c.time -= f64(n) * step
	return n
}
