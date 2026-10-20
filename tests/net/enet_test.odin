package net_test

import "core:testing"
import "core:time"
import net "engine:net"

// Same tiny game as loop_test.odin, but over real UDP sockets on localhost.

ENET_PORT :: 47913

L_Server :: net.Server(L_State, L_Input, L_Event, L_Message)

// Steps everything once per simulated frame, sleeping 1ms so packets actually cross the socket.
enet_step :: proc(srv: ^L_Server, peers: []L_Peer) {
	net.server_update(srv, DT)
	for &p in peers {
		if !p.stopped do net.client_update(&p.cl, DT, p.input)
	}
	time.sleep(time.Millisecond)
}

@(test)
enet_localhost :: proc(t: ^testing.T) {
	server_transport, ok := net.enet_host(ENET_PORT, "127.0.0.1")
	if !testing.expect(t, ok, "could not open the server socket") do return

	state: L_State
	srv: L_Server
	err := net.server_start(&srv, &state, l_game(), server_transport)
	testing.expect(t, err == "", err)
	defer net.server_stop(&srv)

	peers: [2]L_Peer
	for &p in peers {
		client_transport, client_ok := net.enet_connect("127.0.0.1", ENET_PORT)
		if !testing.expect(t, client_ok, "could not create the client socket") do return
		err = net.client_start(&p.cl, &p.state, l_game(), client_transport)
		testing.expect(t, err == "", err)
	}
	defer for &p in peers {
		if !p.stopped do net.client_stop(&p.cl)
	}
	a, b := &peers[0], &peers[1]

	// Connect.
	for _ in 0 ..< 2000 {
		if net.status(&a.cl) == .Connected && net.status(&b.cl) == .Connected && count_movers(&a.state) == 2 && count_movers(&b.state) == 2 do break
		enet_step(&srv, peers[:])
	}
	testing.expect_value(t, net.status(&a.cl), net.Client_Status.Connected)
	testing.expect_value(t, net.status(&b.cl), net.Client_Status.Connected)
	if net.status(&a.cl) != .Connected || net.status(&b.cl) != .Connected do return
	testing.expect_value(t, count_movers(&b.state), 2)

	// Movement: owner moves, server and the other client follow.
	a.input.move = {1, 0}
	for _ in 0 ..< 30 do enet_step(&srv, peers[:])
	a.input = {}
	for _ in 0 ..< 2000 {
		if near(avatar(&b.state, 0).pos, avatar(&a.state, 0).pos) && near(avatar(&state, 0).pos, avatar(&a.state, 0).pos) do break
		enet_step(&srv, peers[:])
	}
	mine := avatar(&a.state, 0).pos
	testing.expectf(t, mine.x > 2, "owner barely moved: %v", mine)
	testing.expectf(t, near(avatar(&state, 0).pos, mine), "server %v vs owner %v", avatar(&state, 0).pos, mine)
	testing.expectf(t, near(avatar(&b.state, 0).pos, mine), "other client %v vs owner %v", avatar(&b.state, 0).pos, mine)

	// Reliable events both ways.
	net.emit(&a.cl.ctx, Ping{21})
	for _ in 0 ..< 2000 {
		if b.state.pings == 1 do break
		enet_step(&srv, peers[:])
	}
	testing.expect_value(t, state.last_ping, 21)
	testing.expect_value(t, b.state.last_ping, 42)

	// Disconnect: the server removes the player and everyone sees it.
	net.client_stop(&b.cl)
	b.stopped = true
	for _ in 0 ..< 2000 {
		if count_movers(&a.state) == 1 do break
		enet_step(&srv, peers[:])
	}
	testing.expect_value(t, count_movers(&state), 1)
	testing.expect_value(t, count_movers(&a.state), 1)
	testing.expect(t, !net.player_connected(&a.cl, 1))
}
