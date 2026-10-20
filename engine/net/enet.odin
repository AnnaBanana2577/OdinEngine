package net

import "base:runtime"
import "core:strings"
import enet "vendor:ENet"

// ENet transport. Channel 0 is unreliable (sequenced: late packets are dropped),
// channel 1 is reliable and ordered. The Server/Client that receives the Transport destroys it.

@(private = "file")
Enet_Transport :: struct {
	host:      ^enet.Host,
	server:    ^enet.Peer, // client side: the connection to the server
	is_server: bool,
	current:   ^enet.Packet, // the last polled packet, destroyed on the next poll
	allocator: runtime.Allocator,
}

// Listens on `port`. `bind_address` "" means every interface; "127.0.0.1" keeps it local.
enet_host :: proc(port: u16, bind_address := "", max_clients := MAX_PLAYERS, allocator := context.allocator) -> (t: Transport, ok: bool) {
	if enet.initialize() != 0 do return {}, false
	address := enet.Address{host = enet.HOST_ANY, port = port}
	if bind_address != "" && !set_host(&address, bind_address) {
		enet.deinitialize()
		return {}, false
	}
	host := enet.host_create(&address, uint(max_clients), 2, 0, 0)
	if host == nil {
		enet.deinitialize()
		return {}, false
	}
	return make_transport(host, nil, true, allocator), true
}

// Starts connecting to a server. The connection finishes inside client_update.
enet_connect :: proc(address: string, port: u16, allocator := context.allocator) -> (t: Transport, ok: bool) {
	if enet.initialize() != 0 do return {}, false
	host := enet.host_create(nil, 1, 2, 0, 0)
	if host == nil {
		enet.deinitialize()
		return {}, false
	}
	remote := enet.Address{port = port}
	server: ^enet.Peer
	if set_host(&remote, address) do server = enet.host_connect(host, &remote, 2, 0)
	if server == nil {
		enet.host_destroy(host)
		enet.deinitialize()
		return {}, false
	}
	return make_transport(host, server, false, allocator), true
}

@(private = "file")
make_transport :: proc(host: ^enet.Host, server: ^enet.Peer, is_server: bool, allocator: runtime.Allocator) -> Transport {
	e := new(Enet_Transport, allocator)
	e^ = {host = host, server = server, is_server = is_server, allocator = allocator}
	return {
		data       = e,
		poll       = enet_poll,
		send       = enet_send,
		flush      = proc(data: rawptr) { enet.host_flush((^Enet_Transport)(data).host) },
		disconnect = enet_disconnect,
		destroy    = enet_destroy,
	}
}

@(private = "file")
enet_poll :: proc(data: rawptr) -> (event: Transport_Event, ok: bool) {
	e := (^Enet_Transport)(data)
	if e.current != nil {
		enet.packet_destroy(e.current)
		e.current = nil
	}
	ev: enet.Event
	for enet.host_service(e.host, &ev, 0) > 0 {
		switch ev.type {
		case .NONE:
		case .CONNECT:
			return {kind = .Connect, peer = peer_id(e, ev.peer)}, true
		case .DISCONNECT:
			id := peer_id(e, ev.peer)
			if !e.is_server do e.server = nil
			return {kind = .Disconnect, peer = id}, true
		case .RECEIVE:
			e.current = ev.packet
			return {
				kind    = .Packet,
				peer    = peer_id(e, ev.peer),
				channel = .Reliable if ev.channelID == 1 else .Unreliable,
				data    = ev.packet.data[:ev.packet.dataLength],
			}, true
		}
	}
	return {}, false
}

@(private = "file")
enet_send :: proc(data: rawptr, peer: Peer_Id, channel: Channel, bytes: []u8) {
	e := (^Enet_Transport)(data)
	p := enet_peer(e, peer)
	if p == nil do return
	flags := enet.PacketFlags{.RELIABLE} if channel == .Reliable else enet.PacketFlags{.UNRELIABLE_FRAGMENT}
	packet := enet.packet_create(raw_data(bytes), uint(len(bytes)), flags)
	if packet == nil do return
	if enet.peer_send(p, u8(channel), packet) != 0 do enet.packet_destroy(packet)
}

@(private = "file")
enet_disconnect :: proc(data: rawptr, peer: Peer_Id) {
	e := (^Enet_Transport)(data)
	if p := enet_peer(e, peer); p != nil do enet.peer_disconnect(p, 0)
	if !e.is_server do e.server = nil
}

@(private = "file")
enet_destroy :: proc(data: rawptr) {
	e := (^Enet_Transport)(data)
	if e.current != nil do enet.packet_destroy(e.current)
	enet.host_flush(e.host) // get pending disconnects out
	enet.host_destroy(e.host)
	enet.deinitialize()
	free(e, e.allocator)
}

// Server side, a peer's id is its slot in the host's peer array + 1 (so it is never SERVER_PEER).
@(private = "file")
peer_id :: proc(e: ^Enet_Transport, p: ^enet.Peer) -> Peer_Id {
	return Peer_Id(p.incomingPeerID) + 1 if e.is_server else SERVER_PEER
}

@(private = "file")
enet_peer :: proc(e: ^Enet_Transport, id: Peer_Id) -> ^enet.Peer {
	if !e.is_server do return e.server
	i := uint(id) - 1
	if id == SERVER_PEER || i >= e.host.peerCount do return nil
	return &e.host.peers[i]
}

@(private = "file")
set_host :: proc(address: ^enet.Address, name: string) -> bool {
	return enet.address_set_host(address, strings.clone_to_cstring(name, context.temp_allocator)) == 0
}
