package main

import "core:fmt"
import "core:math"
import "core:math/linalg"
import "core:math/rand"
import net "engine:net"

// Squares in an arena. Everyone simulates movement; the owner decides when it shoots and what it hit.
// The server validates hits and owns hp, score and respawns.

ARENA         :: [2]f32{32, 18}
PLAYER_SIZE   :: f32(1)
SPEED         :: f32(8)
FIRE_COOLDOWN :: f32(0.2)
SHOT_RANGE    :: f32(40)
DAMAGE        :: 20
MAX_HP        :: 100
TRACER_LIFE   :: f32(0.15)

Button :: enum u8 { Fire }

Input :: struct {
	move:    [2]i8               `net:""`,
	aim:     f32                 `net:"angle,bits=12"`,
	buttons: bit_set[Button; u8] `net:""`,
}

Player :: struct {
	pos:      [2]f32 `net:"q=0.01"`,
	aim:      f32    `net:"angle,bits=10"`,
	hp:       u8     `net:"server"`,
	cooldown: f32, // local only
}

Game_State :: struct {
	scores:  [net.MAX_PLAYERS]i16              `net:""`,
	avatar:  [net.MAX_PLAYERS]net.Handle       `net:""`,
	players: net.Pool(Player, net.MAX_PLAYERS) `net:""`,

	tracers: [dynamic]Tracer, // local only
}

Tracer :: struct {
	from, to: [2]f32,
	shooter:  net.Player_Id,
	life:     f32,
}

Shot :: struct {
	shooter: net.Player_Id `net:""`,
	from:    [2]f32        `net:"q=0.01"`,
	to:      [2]f32        `net:"q=0.01"`,
}
Hit  :: struct { target: net.Handle `net:""` }
Kill :: struct { killer, victim: net.Player_Id `net:""` }
Event :: union { Shot, Hit, Kill } // gameplay: ride in snapshots, line up with state

// Messages: reliable, any time, not tied to ticks.
Announce :: struct { text: string `net:""` }
Message :: union { Announce }

Net_Server :: net.Server(Game_State, Input, Event, Message)
Net_Client :: net.Client(Game_State, Input, Event, Message)

make_game :: proc() -> net.Game(Game_State, Input, Event, Message) {
	return {tick = tick, on_event = on_event, on_message = on_message, on_join = on_join, on_leave = on_leave}
}

game_state_destroy :: proc(s: ^Game_State) {
	delete(s.tracers)
}

tick :: proc(ctx: ^net.Context, s: ^Game_State, inputs: ^[net.MAX_PLAYERS]Input) {
	it := net.iter(&s.players)
	for p, h in net.next(&it) {
		o := net.owner(&s.players, h)
		if o == net.NO_PLAYER do continue
		input := inputs[o]

		move := [2]f32{f32(input.move.x), f32(input.move.y)}
		if linalg.length(move) > 0 do move = linalg.normalize(move)
		p.pos += move * SPEED * ctx.dt
		p.pos.x = clamp(p.pos.x, PLAYER_SIZE / 2, ARENA.x - PLAYER_SIZE / 2)
		p.pos.y = clamp(p.pos.y, PLAYER_SIZE / 2, ARENA.y - PLAYER_SIZE / 2)
		p.aim = input.aim

		if net.is_mine(ctx, &s.players, h) {
			p.cooldown = max(p.cooldown - ctx.dt, 0)
			if .Fire in input.buttons && p.cooldown == 0 do fire(ctx, s, o, h, p)
		}
	}

	#reverse for &t, i in s.tracers {
		t.life -= ctx.dt
		if t.life <= 0 do unordered_remove(&s.tracers, i)
	}
}

// Hitscan from the shooter's point of view: what it sees is what it hits.
fire :: proc(ctx: ^net.Context, s: ^Game_State, me: net.Player_Id, h: net.Handle, p: ^Player) {
	p.cooldown = FIRE_COOLDOWN
	dir := [2]f32{math.cos(p.aim), math.sin(p.aim)}
	dist := min(SHOT_RANGE, ray_exit_arena(p.pos, dir))

	target: net.Handle
	it := net.iter(&s.players)
	for other, oh in net.next(&it) {
		if oh == h do continue
		if t, hit := ray_box(p.pos, dir, other.pos, PLAYER_SIZE / 2); hit && t < dist {
			dist = t
			target = oh
		}
	}

	to := p.pos + dir * dist
	add_tracer(s, me, p.pos, to)
	net.emit(ctx, Shot{me, p.pos, to})
	if target != {} do net.emit(ctx, Hit{target})
}

on_event :: proc(ctx: ^net.Context, s: ^Game_State, from: net.Player_Id, ev: Event) {
	switch e in ev {
	case Shot:
		if ctx.is_server {
			relay := e
			relay.shooter = from // don't trust the claimed shooter
			net.emit_except(ctx, from, relay)
		} else {
			add_tracer(s, e.shooter, e.from, e.to)
		}

	case Hit:
		if !ctx.is_server do return
		shooter, shooter_ok := net.get(&s.players, s.avatar[from])
		target, target_ok := net.get(&s.players, e.target)
		if !shooter_ok || !target_ok || e.target == s.avatar[from] do return
		if linalg.distance(shooter.pos, target.pos) > SHOT_RANGE + 2 do return // implausible
		if target.hp > DAMAGE {
			target.hp -= DAMAGE
			return
		}
		victim := net.owner(&s.players, e.target)
		s.scores[from] += 1
		respawn(ctx, s, e.target)
		net.emit(ctx, Kill{from, victim}, ttl = net.FOREVER) // a kill must arrive, however late

	case Kill:
		fmt.printfln("player %d fragged player %d", e.killer, e.victim)
	}
}

on_message :: proc(ctx: ^net.Context, s: ^Game_State, from: net.Player_Id, msg: Message) {
	switch m in msg {
	case Announce:
		if !ctx.is_server do fmt.println(m.text)
	}
}

on_join :: proc(ctx: ^net.Context, s: ^Game_State, p: net.Player_Id) {
	s.avatar[p] = net.spawn(ctx, &s.players, Player{pos = spawn_point(), hp = MAX_HP}, owner = p)
	net.send(ctx, Announce{fmt.tprintf("player %d joined", p)})
}

on_leave :: proc(ctx: ^net.Context, s: ^Game_State, p: net.Player_Id) {
	net.despawn(ctx, &s.players, s.avatar[p])
	s.avatar[p] = {}
	s.scores[p] = 0
	net.send(ctx, Announce{fmt.tprintf("player %d left", p)})
}

respawn :: proc(ctx: ^net.Context, s: ^Game_State, h: net.Handle) {
	p := net.get(&s.players, h)
	p.pos = spawn_point()
	p.hp = MAX_HP
	net.force_sync(ctx, &s.players, h) // the owner must take the new position
}

// Server-side check on positions sent by clients: no teleporting.
validate_player :: proc(ctx: ^net.Context, from: net.Player_Id, old, new: ^Player) -> bool {
	return linalg.distance(old.pos, new.pos) <= SPEED * 0.25
}

spawn_point :: proc() -> [2]f32 {
	return {rand.float32_range(2, ARENA.x - 2), rand.float32_range(2, ARENA.y - 2)}
}

add_tracer :: proc(s: ^Game_State, shooter: net.Player_Id, from, to: [2]f32) {
	append(&s.tracers, Tracer{from = from, to = to, shooter = shooter, life = TRACER_LIFE})
}

// Distance along the ray to the box (center, half size), if it hits.
ray_box :: proc(origin, dir, center: [2]f32, half: f32) -> (t: f32, hit: bool) {
	t_min, t_max := f32(0), f32(math.F32_MAX)
	for axis in 0 ..< 2 {
		lo, hi := center[axis] - half, center[axis] + half
		if abs(dir[axis]) < 1e-6 {
			if origin[axis] < lo || origin[axis] > hi do return 0, false
			continue
		}
		t1, t2 := (lo - origin[axis]) / dir[axis], (hi - origin[axis]) / dir[axis]
		t_min = max(t_min, min(t1, t2))
		t_max = min(t_max, max(t1, t2))
	}
	return t_min, t_min <= t_max
}

// Distance along the ray until it leaves the arena.
ray_exit_arena :: proc(origin, dir: [2]f32) -> f32 {
	t := f32(math.F32_MAX)
	arena := ARENA
	for axis in 0 ..< 2 {
		if dir[axis] > 1e-6 do t = min(t, (arena[axis] - origin[axis]) / dir[axis])
		if dir[axis] < -1e-6 do t = min(t, -origin[axis] / dir[axis])
	}
	return t
}

// Bots are regular clients with generated input: wander, aim at the nearest player, shoot when close.
Bot :: struct {
	cl:     Net_Client,
	state:  Game_State,
	wander: [2]i8,
	think:  f32,
	firing: bool,
}

bot_input :: proc(b: ^Bot, dt: f32) -> Input {
	b.think -= dt
	if b.think <= 0 {
		b.think = rand.float32_range(0.4, 1.2)
		b.wander = {i8(rand.int_max(3) - 1), i8(rand.int_max(3) - 1)}
		b.firing = rand.float32() < 0.6
	}
	input := Input{move = b.wander}

	me := net.local_player(&b.cl)
	if me == net.NO_PLAYER do return input
	mine, ok := net.get(&b.state.players, b.state.avatar[me])
	if !ok do return input

	best := f32(math.F32_MAX)
	it := net.iter(&b.state.players)
	for other, h in net.next(&it) {
		if h == b.state.avatar[me] do continue
		if d := linalg.distance(mine.pos, other.pos); d < best {
			best = d
			to := other.pos - mine.pos
			input.aim = math.atan2(to.y, to.x) + rand.float32_range(-0.12, 0.12)
		}
	}
	if b.firing && best < 14 do input.buttons += {.Fire}
	return input
}
