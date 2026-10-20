package net_test

import "core:testing"
import net "engine:net"

// A tiny game: every player owns a mover that walks by its input. hp is server-owned.

L_Input :: struct {
	move: [2]i8 `net:""`,
}

Mover :: struct {
	pos: [2]f32 `net:"q=0.01"`,
	hp:  u8     `net:"server"`,
}

Ping   :: struct { value: i32 `net:""` }
Damage :: struct { target: net.Handle `net:""` }
L_Event :: union { Ping, Damage }

L_State :: struct {
	ticks:     u32                         `net:""`,
	avatar:    [net.MAX_PLAYERS]net.Handle `net:""`,
	movers:    net.Pool(Mover, 16)         `net:""`,
	pings:     int, // local only
	last_ping: i32,
}

SPEED :: 0.1

l_game :: proc() -> net.Game(L_State, L_Input, L_Event) {
	return {tick = l_tick, on_event = l_event, on_join = l_join, on_leave = l_leave}
}

l_tick :: proc(ctx: ^net.Context, s: ^L_State, inputs: ^[net.MAX_PLAYERS]L_Input) {
	if ctx.is_server do s.ticks += 1
	it := net.iter(&s.movers)
	for m, h in net.next(&it) {
		o := net.owner(&s.movers, h)
		if o == net.NO_PLAYER do continue
		m.pos += {f32(inputs[o].move.x), f32(inputs[o].move.y)} * SPEED
	}
}

l_event :: proc(ctx: ^net.Context, s: ^L_State, from: net.Player_Id, ev: L_Event) {
	switch e in ev {
	case Ping:
		s.pings += 1
		s.last_ping = e.value
		if ctx.is_server do net.emit(ctx, Ping{e.value * 2})
	case Damage:
		if !ctx.is_server do return
		if m, ok := net.get(&s.movers, e.target); ok do m.hp -= 10
	}
}

l_join :: proc(ctx: ^net.Context, s: ^L_State, p: net.Player_Id) {
	s.avatar[p] = net.spawn(ctx, &s.movers, Mover{pos = {f32(p) * 10, 0}, hp = 100}, owner = p)
}

l_leave :: proc(ctx: ^net.Context, s: ^L_State, p: net.Player_Id) {
	net.despawn(ctx, &s.movers, s.avatar[p])
	s.avatar[p] = {}
}

// Harness: one server and N clients over loopback, stepped at 60 fps.

DT :: f32(1.0 / 60.0)

L_Peer :: struct {
	cl:      net.Client(L_State, L_Input, L_Event),
	state:   L_State,
	input:   L_Input,
	stopped: bool,
}

L_World :: struct {
	lb:    net.Loopback,
	srv:   net.Server(L_State, L_Input, L_Event),
	state: L_State,
	peers: [dynamic]^L_Peer,
}

world_make :: proc(t: ^testing.T, clients: int, config := net.Loopback_Config{}) -> ^L_World {
	w := new(L_World)
	net.loopback_init(&w.lb, config)
	err := net.server_start(&w.srv, &w.state, l_game(), net.loopback_server(&w.lb))
	testing.expect(t, err == "", err)
	for _ in 0 ..< clients {
		p := new(L_Peer)
		err = net.client_start(&p.cl, &p.state, l_game(), net.loopback_client(&w.lb))
		testing.expect(t, err == "", err)
		append(&w.peers, p)
	}
	return w
}

world_destroy :: proc(w: ^L_World) {
	for p in w.peers {
		if !p.stopped do net.client_stop(&p.cl)
		free(p)
	}
	delete(w.peers)
	net.server_stop(&w.srv)
	net.loopback_destroy(&w.lb)
	free(w)
}

world_run :: proc(w: ^L_World, frames: int) {
	for _ in 0 ..< frames {
		net.server_update(&w.srv, DT)
		for p in w.peers {
			if !p.stopped do net.client_update(&p.cl, DT, p.input)
		}
	}
}

avatar :: proc(s: ^L_State, p: net.Player_Id) -> ^Mover {
	return net.get(&s.movers, s.avatar[p])
}

count_movers :: proc(s: ^L_State) -> (n: int) {
	it := net.iter(&s.movers)
	for _ in net.next(&it) do n += 1
	return
}

near :: proc(a, b: [2]f32) -> bool {
	return abs(a.x - b.x) <= 0.011 && abs(a.y - b.y) <= 0.011
}

@(test)
loop_connect_and_join :: proc(t: ^testing.T) {
	w := world_make(t, 2)
	defer world_destroy(w)
	world_run(w, 10)

	for p, i in w.peers {
		testing.expect_value(t, net.status(&p.cl), net.Client_Status.Connected)
		testing.expect_value(t, net.local_player(&p.cl), net.Player_Id(i))
		testing.expect_value(t, count_movers(&p.state), 2)
		testing.expect(t, net.player_connected(&p.cl, 0) && net.player_connected(&p.cl, 1))
		testing.expect(t, p.state.ticks > 0 && p.state.ticks <= w.state.ticks)
	}
}

@(test)
loop_owner_movement_replicates :: proc(t: ^testing.T) {
	w := world_make(t, 2)
	defer world_destroy(w)
	a, b := w.peers[0], w.peers[1]
	world_run(w, 10)

	a.input.move = {1, 0}
	world_run(w, 60)
	a.input = {}
	world_run(w, 10)

	mine := avatar(&a.state, 0).pos
	testing.expectf(t, mine.x >= 5.8 && mine.x <= 6.2, "moved to %v, expected ~6", mine)
	testing.expectf(t, near(avatar(&w.state, 0).pos, mine), "server %v vs owner %v", avatar(&w.state, 0).pos, mine)
	testing.expectf(t, near(avatar(&b.state, 0).pos, mine), "other client %v vs owner %v", avatar(&b.state, 0).pos, mine)
}

@(test)
loop_server_fields_win :: proc(t: ^testing.T) {
	w := world_make(t, 2)
	defer world_destroy(w)
	a, b := w.peers[0], w.peers[1]
	world_run(w, 10)

	avatar(&a.state, 0).hp = 255 // a client cheating on a server field of its own entity
	net.emit(&a.cl.ctx, Damage{a.state.avatar[1]})
	world_run(w, 10)

	testing.expect_value(t, avatar(&w.state, 1).hp, 90)
	testing.expect_value(t, avatar(&a.state, 1).hp, 90)
	testing.expect_value(t, avatar(&b.state, 1).hp, 90) // own entity, but hp is a server field
	testing.expect_value(t, avatar(&a.state, 0).hp, 100)
}

@(test)
loop_events_roundtrip :: proc(t: ^testing.T) {
	w := world_make(t, 2)
	defer world_destroy(w)
	world_run(w, 10)

	net.emit(&w.peers[0].cl.ctx, Ping{21})
	world_run(w, 10)

	testing.expect_value(t, w.state.pings, 1)
	testing.expect_value(t, w.state.last_ping, 21)
	for p in w.peers {
		testing.expect_value(t, p.state.pings, 1)
		testing.expect_value(t, p.state.last_ping, 42)
	}
}

@(test)
loop_converges_under_lag_and_loss :: proc(t: ^testing.T) {
	w := world_make(t, 2, {lag = 0.05, jitter = 0.03, loss = 0.2})
	defer world_destroy(w)
	a, b := w.peers[0], w.peers[1]
	world_run(w, 60)

	a.input.move = {1, 1}
	b.input.move = {-1, 0}
	world_run(w, 120)
	a.input, b.input = {}, {}
	world_run(w, 120)

	for p in 0 ..< 2 {
		owner := avatar(&w.peers[p].state, net.Player_Id(p)).pos
		views := [?][2]f32{avatar(&w.state, net.Player_Id(p)).pos, avatar(&a.state, net.Player_Id(p)).pos, avatar(&b.state, net.Player_Id(p)).pos}
		for v in views do testing.expectf(t, near(v, owner), "player %d: view %v vs owner %v", p, v, owner)
	}
	testing.expectf(t, a.cl.rtt > 0.09, "rtt %v should include 2x50ms lag", a.cl.rtt)
}

@(test)
loop_disconnect_removes_player :: proc(t: ^testing.T) {
	w := world_make(t, 2)
	defer world_destroy(w)
	a, b := w.peers[0], w.peers[1]
	world_run(w, 10)

	net.client_stop(&b.cl)
	b.stopped = true
	world_run(w, 10)

	testing.expect_value(t, count_movers(&w.state), 1)
	testing.expect_value(t, count_movers(&a.state), 1)
	testing.expect(t, !net.player_connected(&a.cl, 1))
}

@(test)
loop_validator_rejects :: proc(t: ^testing.T) {
	w := world_make(t, 1)
	defer world_destroy(w)
	net.server_validate(&w.srv, &w.state.movers, proc(ctx: ^net.Context, from: net.Player_Id, old, new: ^Mover) -> bool {
		return abs(new.pos.x - old.pos.x) < 1
	})
	world_run(w, 10)

	avatar(&w.peers[0].state, 0).pos.x += 50 // teleport hack
	world_run(w, 10)
	testing.expectf(t, abs(avatar(&w.state, 0).pos.x) < 0.01, "server accepted teleport to %v", avatar(&w.state, 0).pos)
}

Other_State :: struct {
	x: f32 `net:""`,
}

@(test)
loop_rejects_other_build :: proc(t: ^testing.T) {
	w := world_make(t, 0)
	defer world_destroy(w)

	other_state: Other_State
	other: net.Client(Other_State, L_Input, L_Event)
	game := net.Game(Other_State, L_Input, L_Event) {
		tick = proc(ctx: ^net.Context, s: ^Other_State, inputs: ^[net.MAX_PLAYERS]L_Input) {},
	}
	err := net.client_start(&other, &other_state, game, net.loopback_client(&w.lb))
	testing.expect(t, err == "", err)
	defer net.client_stop(&other)

	for _ in 0 ..< 10 {
		net.server_update(&w.srv, DT)
		net.client_update(&other, DT, L_Input{})
	}
	testing.expect_value(t, net.status(&other), net.Client_Status.Disconnected)
}
