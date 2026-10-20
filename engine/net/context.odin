package net

import "core:math"
import "core:slice"

// Game is everything the engine needs from the game. S is the state, I the per-player input,
// V the Event union, M the Message union. Only `tick` is required.
Game :: struct($S, $I, $V, $M: typeid) {
	// Advances the whole game one tick. Same proc on server and clients.
	// inputs[p] = live input for the local player, last known input for everyone else.
	tick:       proc(ctx: ^Context, s: ^S, inputs: ^[MAX_PLAYERS]I),

	// Server: an event from client `from`, right after that client's state for the same tick.
	// Validate it, then apply or reject it.
	// Client: an event from the server (`from` is NO_PLAYER), right after the matching snapshot.
	on_event:   proc(ctx: ^Context, s: ^S, from: Player_Id, ev: V),

	// Server: a message from client `from`. Client: a message from the server (`from` is NO_PLAYER).
	on_message: proc(ctx: ^Context, s: ^S, from: Player_Id, msg: M),

	// Server only: a player finished connecting / disconnected.
	on_join:    proc(ctx: ^Context, s: ^S, p: Player_Id),
	on_leave:   proc(ctx: ^Context, s: ^S, p: Player_Id),
}

Config :: struct {
	tick_rate:      int, // ticks per second (server decides; clients take it from the server)
	snapshot_every: int, // send a snapshot every N ticks
	max_catchup:    int, // most ticks run in one update before dropping time
	event_ttl:      f32, // seconds an event is resent before it is dropped (unless emitted with FOREVER)
}

DEFAULT_CONFIG :: Config {
	tick_rate      = 60,
	snapshot_every = 1,
	max_catchup    = 8,
	event_ttl      = 1,
}

// Context is passed to every game callback.
Context :: struct {
	tick:         Tick,
	dt:           f32,
	is_server:    bool,
	local_player: Player_Id, // NO_PLAYER on the server

	// Internal: where events and messages go.
	event_tick:     Tick, // tick of the next packet that will carry a new event (see event_tick_*)
	event_log:      ^Event_Log,
	event_schema:   ^Union_Schema,
	event_ttl:      f32,
	messages:       ^Message_Queue,
	message_schema: ^Union_Schema,
}

@(private = "file")
MAX_EVENT_BYTES :: 8192

@(private = "file")
MAX_MESSAGE_BYTES :: 8192

// Gameplay event. Client: to the server. Server: to every client.
// `ev` is the Event union or one of its variants. `ttl` in seconds overrides Config.event_ttl;
// pass FOREVER for events that must arrive (they are resent until acked).
emit :: proc(ctx: ^Context, ev: $T, ttl: Maybe(f32) = nil) {
	ev := ev
	log_event(ctx, typeid_of(T), &ev, .All, NO_PLAYER, ttl)
}

// Server only: event to one client.
emit_to :: proc(ctx: ^Context, p: Player_Id, ev: $T, ttl: Maybe(f32) = nil) {
	assert(ctx.is_server, "net.emit_to: server only")
	ev := ev
	log_event(ctx, typeid_of(T), &ev, .Only, p, ttl)
}

// Server only: event to every client except `p`. Use it to relay a client's event to the others.
emit_except :: proc(ctx: ^Context, p: Player_Id, ev: $T, ttl: Maybe(f32) = nil) {
	assert(ctx.is_server, "net.emit_except: server only")
	ev := ev
	log_event(ctx, typeid_of(T), &ev, .Except, p, ttl)
}

// Message. Client: to the server. Server: to every client.
// Takes a Context (inside callbacks), a ^Client or a ^Server (anywhere else).
send :: proc {
	send_ctx,
	send_client,
	send_server,
}

// Server only: message to one client.
send_to :: proc {
	send_to_ctx,
	send_to_server,
}

// Server only: message to every client except `p`.
send_except :: proc {
	send_except_ctx,
	send_except_server,
}

send_ctx :: proc(ctx: ^Context, msg: $T) {
	msg := msg
	queue_message(ctx, typeid_of(T), &msg, .All, NO_PLAYER)
}

send_client :: proc(cl: ^Client($S, $I, $V, $M), msg: $T) {
	send_ctx(&cl.ctx, msg)
}

send_server :: proc(srv: ^Server($S, $I, $V, $M), msg: $T) {
	send_ctx(&srv.ctx, msg)
}

send_to_ctx :: proc(ctx: ^Context, p: Player_Id, msg: $T) {
	assert(ctx.is_server, "net.send_to: server only")
	msg := msg
	queue_message(ctx, typeid_of(T), &msg, .Only, p)
}

send_to_server :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id, msg: $T) {
	send_to_ctx(&srv.ctx, p, msg)
}

send_except_ctx :: proc(ctx: ^Context, p: Player_Id, msg: $T) {
	assert(ctx.is_server, "net.send_except: server only")
	msg := msg
	queue_message(ctx, typeid_of(T), &msg, .Except, p)
}

send_except_server :: proc(srv: ^Server($S, $I, $V, $M), p: Player_Id, msg: $T) {
	send_except_ctx(&srv.ctx, p, msg)
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

// An event is stamped with the tick of the first packet that carries it, because acks and echoes
// say "I have everything up to tick N". Inside a tick that is the current tick; between ticks
// (UI code, message handlers) it is the next one.
@(private)
event_tick_begin :: proc(ctx: ^Context) {
	ctx.tick += 1
	ctx.event_tick = ctx.tick
}

@(private)
event_tick_end :: proc(ctx: ^Context) {
	ctx.event_tick = ctx.tick + 1
}

@(private = "file")
log_event :: proc(ctx: ^Context, id: typeid, data: rawptr, target: Event_Target, player: Player_Id, ttl: Maybe(f32)) {
	buf: [MAX_EVENT_BYTES]u8
	w := writer_init(buf[:])
	union_encode(&w, ctx.event_schema, id, data)
	assert(!w.overflow, "net: event too large")

	seconds := ttl.? or_else ctx.event_ttl
	expire := max(Tick) if seconds < 0 else ctx.event_tick + Tick(math.ceil(seconds / ctx.dt))
	ctx.event_log.next_id += 1
	append(&ctx.event_log.items, Logged_Event {
		id     = ctx.event_log.next_id,
		tick   = ctx.event_tick,
		expire = expire,
		target = target,
		player = player,
		data   = slice.clone(writer_bytes(&w)),
		bits   = w.bit_pos,
	})
}

@(private = "file")
queue_message :: proc(ctx: ^Context, id: typeid, data: rawptr, target: Event_Target, player: Player_Id) {
	buf: [MAX_MESSAGE_BYTES]u8
	w := writer_init(buf[:])
	write_message_header(&w, .Message)
	union_encode(&w, ctx.message_schema, id, data)
	assert(!w.overflow, "net: message too large")

	bytes := writer_bytes(&w)
	start := len(ctx.messages.bytes)
	append(&ctx.messages.bytes, ..bytes)
	append(&ctx.messages.items, Queued_Message{start = start, end = start + len(bytes), target = target, player = player})
}
