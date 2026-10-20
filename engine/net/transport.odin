package net

// Transport moves packets between peers. Server and Client only talk through this,
// so the same code runs over ENet, in-process loopback, or anything else.
// The Server/Client it is given calls `destroy` (if set) in server_stop/client_stop.
Transport :: struct {
	data:       rawptr,
	update:     proc(data: rawptr, dt: f32), // optional
	// Returns the next event. Packet data is only valid until the next poll.
	poll:       proc(data: rawptr) -> (event: Transport_Event, ok: bool),
	send:       proc(data: rawptr, peer: Peer_Id, channel: Channel, bytes: []u8),
	flush:      proc(data: rawptr), // optional: push queued sends out now
	disconnect: proc(data: rawptr, peer: Peer_Id),
	destroy:    proc(data: rawptr), // optional
}

// Server side: identifies a connected client. Client side: the server is always SERVER_PEER.
Peer_Id :: distinct u32

SERVER_PEER :: Peer_Id(0)

Channel :: enum u8 {
	Unreliable, // may be lost or arrive out of order (snapshots, client updates)
	Reliable,   // arrives once, in order (events, handshake)
}

Transport_Event_Kind :: enum u8 {
	Connect,
	Disconnect,
	Packet,
}

Transport_Event :: struct {
	kind:    Transport_Event_Kind,
	peer:    Peer_Id,
	channel: Channel,
	data:    []u8,
}

transport_update :: proc(t: Transport, dt: f32) {
	if t.update != nil do t.update(t.data, dt)
}

transport_poll :: proc(t: Transport) -> (Transport_Event, bool) {
	return t.poll(t.data)
}

transport_send :: proc(t: Transport, peer: Peer_Id, channel: Channel, bytes: []u8) {
	t.send(t.data, peer, channel, bytes)
}

transport_flush :: proc(t: Transport) {
	if t.flush != nil do t.flush(t.data)
}

transport_disconnect :: proc(t: Transport, peer: Peer_Id) {
	t.disconnect(t.data, peer)
}

transport_destroy :: proc(t: Transport) {
	if t.destroy != nil do t.destroy(t.data)
}
