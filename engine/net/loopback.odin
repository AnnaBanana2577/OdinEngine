package net

import "base:runtime"
import "core:math/rand"

// Loopback is an in-process network: one server endpoint and any number of client endpoints.
// Use it for listen servers, singleplayer and headless tests. It can fake lag, jitter and loss.
// Time only passes when endpoints are updated, so tests are deterministic.
Loopback :: struct {
	config:    Loopback_Config,
	server:    Loopback_Endpoint,
	clients:   [dynamic]^Loopback_Endpoint, // clients[peer - 1]
	allocator: runtime.Allocator,
}

Loopback_Config :: struct {
	lag:    f32, // one-way delay in seconds
	jitter: f32, // extra random delay for unreliable packets, 0..jitter seconds
	loss:   f32, // chance to drop an unreliable packet, 0..1
}

Loopback_Endpoint :: struct {
	lb:      ^Loopback,
	peer:    Peer_Id, // what the server calls this endpoint; SERVER_PEER for the server
	inbox:   [dynamic]Loopback_Packet,
	current: []u8, // the last polled packet, freed on the next poll
	closed:  bool,
}

@(private = "file")
Loopback_Packet :: struct {
	kind:    Transport_Event_Kind,
	from:    Peer_Id,
	channel: Channel,
	data:    []u8,
	delay:   f32,
}

loopback_init :: proc(lb: ^Loopback, config := Loopback_Config{}, allocator := context.allocator) {
	lb^ = {
		config    = config,
		clients   = make([dynamic]^Loopback_Endpoint, allocator),
		allocator = allocator,
	}
	lb.server = {lb = lb, peer = SERVER_PEER, inbox = make([dynamic]Loopback_Packet, allocator)}
}

loopback_destroy :: proc(lb: ^Loopback) {
	endpoint_destroy(&lb.server)
	for c in lb.clients {
		endpoint_destroy(c)
		free(c, lb.allocator)
	}
	delete(lb.clients)
	lb^ = {}
}

loopback_server :: proc(lb: ^Loopback) -> Transport {
	return endpoint_transport(&lb.server)
}

// Creates a client endpoint and connects it to the server right away.
loopback_client :: proc(lb: ^Loopback) -> Transport {
	c := new(Loopback_Endpoint, lb.allocator)
	append(&lb.clients, c)
	c^ = {lb = lb, peer = Peer_Id(len(lb.clients)), inbox = make([dynamic]Loopback_Packet, lb.allocator)}
	deliver(&lb.server, {kind = .Connect, from = c.peer})
	deliver(c, {kind = .Connect, from = SERVER_PEER})
	return endpoint_transport(c)
}

@(private = "file")
endpoint_transport :: proc(e: ^Loopback_Endpoint) -> Transport {
	return {
		data = e,
		update = proc(data: rawptr, dt: f32) {
			for &p in (^Loopback_Endpoint)(data).inbox do p.delay -= dt
		},
		poll = endpoint_poll,
		send = endpoint_send,
		disconnect = endpoint_disconnect,
	}
}

@(private = "file")
endpoint_poll :: proc(data: rawptr) -> (event: Transport_Event, ok: bool) {
	e := (^Loopback_Endpoint)(data)
	delete(e.current, e.lb.allocator)
	e.current = nil
	for p, i in e.inbox {
		if p.delay > 0 do continue
		ordered_remove(&e.inbox, i)
		e.current = p.data
		return {kind = p.kind, peer = p.from, channel = p.channel, data = p.data}, true
	}
	return {}, false
}

@(private = "file")
endpoint_send :: proc(data: rawptr, peer: Peer_Id, channel: Channel, bytes: []u8) {
	e := (^Loopback_Endpoint)(data)
	to := remote(e, peer)
	if e.closed || to == nil || to.closed do return

	cfg := e.lb.config
	delay := cfg.lag
	if channel == .Unreliable {
		if cfg.loss > 0 && rand.float32() < cfg.loss do return
		delay += rand.float32() * cfg.jitter
	}
	copied := make([]u8, len(bytes), e.lb.allocator)
	copy(copied, bytes)
	deliver(to, {kind = .Packet, from = e.peer, channel = channel, data = copied, delay = delay})
}

@(private = "file")
endpoint_disconnect :: proc(data: rawptr, peer: Peer_Id) {
	e := (^Loopback_Endpoint)(data)
	to := remote(e, peer)
	if to == nil do return
	if e.peer == SERVER_PEER {
		to.closed = true // the server drops this client
	} else {
		e.closed = true // this client leaves
	}
	deliver(to, {kind = .Disconnect, from = e.peer, delay = e.lb.config.lag})
}

// The endpoint on the other end: the server for a client, or client `peer` for the server.
@(private = "file")
remote :: proc(e: ^Loopback_Endpoint, peer: Peer_Id) -> ^Loopback_Endpoint {
	if e.peer != SERVER_PEER do return &e.lb.server
	i := int(peer) - 1
	if i < 0 || i >= len(e.lb.clients) do return nil
	return e.lb.clients[i]
}

@(private = "file")
deliver :: proc(to: ^Loopback_Endpoint, p: Loopback_Packet) {
	append(&to.inbox, p)
}

@(private = "file")
endpoint_destroy :: proc(e: ^Loopback_Endpoint) {
	for p in e.inbox do delete(p.data, e.lb.allocator)
	delete(e.inbox)
	delete(e.current, e.lb.allocator)
}
