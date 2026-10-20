package net

// Game is everything the engine needs from the game. S is the state, I the per-player input,
// V the Event union. Only `tick` is required.
Game :: struct($S, $I, $V: typeid) {
	// Advances the whole game one tick. Same proc on server and clients.
	// inputs[p] = live input for the local player, last known input for everyone else.
	tick:     proc(ctx: ^Context, s: ^S, inputs: ^[MAX_PLAYERS]I),

	// Server: an event from client `from`. Validate it, then apply or reject it.
	// Client: an event from the server (`from` is NO_PLAYER). Play effects.
	on_event: proc(ctx: ^Context, s: ^S, from: Player_Id, ev: V),

	// Server only: a player finished connecting / disconnected.
	on_join:  proc(ctx: ^Context, s: ^S, p: Player_Id),
	on_leave: proc(ctx: ^Context, s: ^S, p: Player_Id),
}

Config :: struct {
	tick_rate:      int, // ticks per second (server decides; clients take it from the server)
	snapshot_every: int, // send a snapshot every N ticks
	max_catchup:    int, // most ticks run in one update before dropping time
}

DEFAULT_CONFIG :: Config {
	tick_rate      = 60,
	snapshot_every = 1,
	max_catchup    = 8,
}

// Context is passed to every game callback.
Context :: struct {
	tick:         Tick,
	dt:           f32,
	is_server:    bool,
	local_player: Player_Id, // NO_PLAYER on the server

	// Internal: where emitted events go.
	queue:  ^Event_Queue,
	events: ^Event_Schema,
}

@(private = "file")
MAX_EVENT_BYTES :: 1024

// Client: sends to the server. Server: sends to every client.
emit :: proc(ctx: ^Context, ev: $T) {
	ev := ev
	queue_event(ctx, typeid_of(T), &ev, .All, NO_PLAYER)
}

// Server only: sends to one client.
emit_to :: proc(ctx: ^Context, p: Player_Id, ev: $T) {
	assert(ctx.is_server, "net.emit_to: server only")
	ev := ev
	queue_event(ctx, typeid_of(T), &ev, .Only, p)
}

// Server only: sends to every client except `p`. Use this to relay a client's event to the others.
emit_except :: proc(ctx: ^Context, p: Player_Id, ev: $T) {
	assert(ctx.is_server, "net.emit_except: server only")
	ev := ev
	queue_event(ctx, typeid_of(T), &ev, .Except, p)
}

spawn :: proc(ctx: ^Context, p: ^Pool($T, $N), item: T, owner := NO_PLAYER) -> Handle {
	assert(ctx.is_server, "net.spawn: server only (guard with ctx.is_server)")
	h, ok := pool_spawn(p, item, owner)
	assert(ok, "net.spawn: pool is full")
	return h
}

despawn :: proc(ctx: ^Context, p: ^Pool($T, $N), h: Handle) {
	assert(ctx.is_server, "net.despawn: server only (guard with ctx.is_server)")
	pool_despawn(p, h)
}

// Server only: makes the owning client accept the server's state for this entity
// (teleports, respawns). Without it the owner's own state wins.
force_sync :: proc(ctx: ^Context, p: ^Pool($T, $N), h: Handle) {
	assert(ctx.is_server, "net.force_sync: server only")
	if _, ok := get(p, h); ok do p.meta[h.index].override += 1
}

// Whether the local player owns this entity. Always false on the server.
is_mine :: proc(ctx: ^Context, p: ^Pool($T, $N), h: Handle) -> bool {
	return ctx.local_player != NO_PLAYER && owner(p, h) == ctx.local_player
}

// Whether this peer is the authority for the entity: the owner, or the server for unowned entities.
has_authority :: proc(ctx: ^Context, p: ^Pool($T, $N), h: Handle) -> bool {
	o := owner(p, h)
	return ctx.is_server ? o == NO_PLAYER : (o != NO_PLAYER && o == ctx.local_player)
}

@(private = "file")
queue_event :: proc(ctx: ^Context, id: typeid, data: rawptr, target: Event_Target, player: Player_Id) {
	buf: [MAX_EVENT_BYTES]u8
	w := writer_init(buf[:])
	write_message_header(&w, .Event)
	write_bits(&w, u64(ctx.tick), 32)
	write_bits(&w, u64(ctx.local_player), 8)
	event_encode(&w, ctx.events, id, data)
	assert(!w.overflow, "net: event too large")

	bytes := writer_bytes(&w)
	start := len(ctx.queue.bytes)
	append(&ctx.queue.bytes, ..bytes)
	append(&ctx.queue.items, Queued_Event{start = start, end = start + len(bytes), target = target, player = player})
}
