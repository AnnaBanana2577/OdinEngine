package net

MAX_PACKET :: 1 << 16

// Every packet starts with an 8-bit Message_Kind.
//	Hello          C→S reliable    protocol hash (u64)
//	Welcome        S→C reliable    player id (u8), tick rate (u16), server tick (u32)
//	Client_Update  C→S unreliable  client tick (u32), acked snapshot tick (u32), input, owned entities
//	Snapshot       S→C unreliable  server tick (u32), baseline tick (u32, 0 = none), echoed client tick (u32), delta
//	Event          both, reliable  tick (u32), from (u8), event
Message_Kind :: enum u8 {
	Hello,
	Welcome,
	Client_Update,
	Snapshot,
	Event,
}

write_message_header :: proc(w: ^Bit_Writer, kind: Message_Kind) {
	write_bits(w, u64(kind), 8)
}

read_message_header :: proc(r: ^Bit_Reader) -> (kind: Message_Kind, ok: bool) {
	k := read_bits(r, 8)
	if r.overflow || k > u64(max(Message_Kind)) do return {}, false
	return Message_Kind(k), true
}

// Everything both sides must agree on to talk: the state, input and event layouts.
protocol_hash :: proc(schema: ^Schema, events: ^Event_Schema) -> u64 {
	return hash_mix(hash_mix(schema.hash, events.hash), u64(MAX_PLAYERS))
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
Core :: struct($S, $I, $V: typeid) {
	game:         Game(S, I, V),
	config:       Config,
	transport:    Transport,
	state:        ^S,
	table:        Player_Table(I),
	schema:       Schema, // root 0: the game state, root 1: the player table
	events:       Event_Schema,
	input_fields: []Field,
	ring:         Snapshot_Ring,
	ctx:          Context,
	queue:        Event_Queue,
	packet:       []u8,
	time:         f64, // unspent time, less than one tick
}

@(private)
core_init :: proc(c: ^Core($S, $I, $V), state: ^S, game: Game(S, I, V), transport: Transport, config: Config, is_server: bool) -> (err: string) {
	assert(game.tick != nil, "net: Game.tick is required")
	c.game = game
	c.state = state
	c.transport = transport
	c.config = config
	if c.config.tick_rate <= 0 do c.config.tick_rate = DEFAULT_CONFIG.tick_rate
	if c.config.snapshot_every <= 0 do c.config.snapshot_every = DEFAULT_CONFIG.snapshot_every
	if c.config.max_catchup <= 0 do c.config.max_catchup = DEFAULT_CONFIG.max_catchup

	c.schema, err = build_schema(S)
	if err != "" do return
	if err = schema_append(&c.schema, Player_Table(I)); err != "" do return
	c.events, err = build_event_schema(V)
	if err != "" {
		schema_destroy(&c.schema)
		return
	}
	c.input_fields = c.schema.sections[len(c.schema.sections) - 1].fields

	ring_init(&c.ring, &c.schema)
	c.packet = make([]u8, MAX_PACKET)
	c.ctx = {
		dt           = 1 / f32(c.config.tick_rate),
		is_server    = is_server,
		local_player = NO_PLAYER,
		queue        = &c.queue,
		events       = &c.events,
	}
	return ""
}

@(private)
core_destroy :: proc(c: ^Core($S, $I, $V)) {
	ring_destroy(&c.ring)
	schema_destroy(&c.schema)
	event_schema_destroy(&c.events)
	event_queue_destroy(&c.queue)
	delete(c.packet)
}

// Adds frame time and returns how many fixed ticks to run now.
@(private)
ticks_due :: proc(c: ^Core($S, $I, $V), dt: f32) -> int {
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
