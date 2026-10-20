package main

import "core:fmt"
import "core:math"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import net "engine:net"
import gl "vendor:OpenGL"
import "vendor:glfw"

USAGE :: `Odin netcode demo

  demo host     [-bots=3] [-lag=ms] [-jitter=ms] [-loss=percent]
                  server + you + bots in one process, over loopback (fake network optional)
  demo server   [-port=7777]
                  headless dedicated server over UDP
  demo client   [-addr=127.0.0.1] [-port=7777]
                  connect to a server over UDP
  demo selftest [-bots=4] [-lag=ms] [-jitter=ms] [-loss=percent] [-seconds=20]
                  headless host with bots only; checks that everyone stays in sync

Controls: WASD/arrows move, mouse aims, left click or space shoots.`

Mode :: enum { Host, Server, Client, Selftest }

Options :: struct {
	mode:     Mode,
	addr:     string,
	port:     u16,
	bots:     int,
	seconds:  f32,
	loopback: net.Loopback_Config,
}

main :: proc() {
	opts, ok := parse_args(os.args[1:])
	if !ok {
		fmt.eprintln(USAGE)
		os.exit(1)
	}
	switch opts.mode {
	case .Host:     run_host(opts)
	case .Server:   run_server(opts)
	case .Client:   run_client(opts)
	case .Selftest: os.exit(0 if run_selftest(opts) else 1)
	}
}

parse_args :: proc(args: []string) -> (opts: Options, ok: bool) {
	opts = {addr = "127.0.0.1", port = 7777, bots = 3, seconds = 20}
	if len(args) == 0 do return
	switch args[0] {
	case "host":     opts.mode = .Host
	case "server":   opts.mode = .Server
	case "client":   opts.mode = .Client
	case "selftest": opts.mode = .Selftest; opts.bots = 4
	case:            return
	}
	for arg in args[1:] {
		key, _, value := strings.partition(strings.trim_left(arg, "-"), "=")
		n, is_number := strconv.parse_f32(value)
		switch {
		case key == "addr":                 opts.addr = value
		case key == "port" && is_number:    opts.port = u16(n)
		case key == "bots" && is_number:    opts.bots = int(n)
		case key == "seconds" && is_number: opts.seconds = n
		case key == "lag" && is_number:     opts.loopback.lag = n / 1000
		case key == "jitter" && is_number:  opts.loopback.jitter = n / 1000
		case key == "loss" && is_number:    opts.loopback.loss = n / 100
		case:
			fmt.eprintfln("unknown or bad option: %s", arg)
			return
		}
	}
	return opts, true
}

run_server :: proc(opts: Options) {
	transport, ok := net.enet_host(opts.port)
	if !ok {
		fmt.eprintfln("could not listen on port %d", opts.port)
		return
	}
	state: Game_State
	defer game_state_destroy(&state)
	srv: Net_Server
	if err := net.server_start(&srv, &state, make_game(), transport); err != "" do panic(err)
	defer net.server_stop(&srv)
	net.server_validate(&srv, &state.players, validate_player)
	fmt.printfln("server listening on UDP port %d", opts.port)

	last := time.tick_now()
	for {
		net.server_update(&srv, f32(time.duration_seconds(time.tick_lap_time(&last))))
		free_all(context.temp_allocator)
		time.sleep(time.Millisecond)
	}
}

run_client :: proc(opts: Options) {
	win, ok := window_open("Odin netcode demo - client")
	if !ok do return
	defer window_close(&win)

	transport, transport_ok := net.enet_connect(opts.addr, opts.port)
	if !transport_ok {
		fmt.eprintfln("could not resolve %s", opts.addr)
		return
	}
	state: Game_State
	defer game_state_destroy(&state)
	cl: Net_Client
	if err := net.client_start(&cl, &state, make_game(), transport); err != "" do panic(err)
	defer net.client_stop(&cl)

	for !glfw.WindowShouldClose(win.handle) {
		dt := window_frame(&win)
		local := net.local_player(&cl)
		net.client_update(&cl, dt, sample_input(&win, &state, local))
		window_present(&win, &state, &cl, net.status(&cl) == .Disconnected ? "disconnected" : "")
	}
}

run_host :: proc(opts: Options) {
	win, ok := window_open("Odin netcode demo - host")
	if !ok do return
	defer window_close(&win)

	lb: net.Loopback
	net.loopback_init(&lb, opts.loopback)
	defer net.loopback_destroy(&lb)

	server_state, client_state: Game_State
	defer game_state_destroy(&server_state)
	defer game_state_destroy(&client_state)
	srv: Net_Server
	cl: Net_Client
	if err := net.server_start(&srv, &server_state, make_game(), net.loopback_server(&lb)); err != "" do panic(err)
	defer net.server_stop(&srv)
	net.server_validate(&srv, &server_state.players, validate_player)
	if err := net.client_start(&cl, &client_state, make_game(), net.loopback_client(&lb)); err != "" do panic(err)
	defer net.client_stop(&cl)

	bots := start_bots(&lb, opts.bots)
	defer stop_bots(bots)

	for !glfw.WindowShouldClose(win.handle) {
		dt := window_frame(&win)
		net.server_update(&srv, dt)
		net.client_update(&cl, dt, sample_input(&win, &client_state, net.local_player(&cl)))
		for b in bots do net.client_update(&b.cl, dt, bot_input(b, dt))
		window_present(&win, &client_state, &cl, "")
	}
}

// Runs a host with bots only, as fast as possible, then checks every client agrees with the server.
run_selftest :: proc(opts: Options) -> bool {
	lb: net.Loopback
	net.loopback_init(&lb, opts.loopback)
	defer net.loopback_destroy(&lb)

	state: Game_State
	defer game_state_destroy(&state)
	srv: Net_Server
	if err := net.server_start(&srv, &state, make_game(), net.loopback_server(&lb)); err != "" do panic(err)
	defer net.server_stop(&srv)
	net.server_validate(&srv, &state.players, validate_player)

	bots := start_bots(&lb, max(opts.bots, 2))
	defer stop_bots(bots)

	DT :: f32(1.0 / 60.0)
	frames := int(opts.seconds / DT)
	settle := 120 // last two seconds: bots stand still so views can converge
	for frame in 0 ..< frames + settle {
		net.server_update(&srv, DT)
		for b in bots {
			input := bot_input(b, DT)
			if frame >= frames do input.move = {}
			if frame >= frames do input.buttons = {}
			net.client_update(&b.cl, DT, input)
		}
		free_all(context.temp_allocator)
	}

	ok := true
	kills := 0
	for score in state.scores do kills += int(score)
	for b, i in bots {
		if net.status(&b.cl) != .Connected {
			fmt.printfln("bot %d is not connected", i)
			ok = false
			continue
		}
		it := net.iter(&state.players)
		for truth, h in net.next(&it) {
			seen, found := net.get(&b.state.players, h)
			if !found || math.abs(seen.pos.x - truth.pos.x) > 0.02 || math.abs(seen.pos.y - truth.pos.y) > 0.02 || seen.hp != truth.hp {
				fmt.printfln("bot %d disagrees with the server about %v", i, h)
				ok = false
			}
		}
		if b.state.scores != state.scores {
			fmt.printfln("bot %d has scores %v, server %v", i, b.state.scores[:len(bots)], state.scores[:len(bots)])
			ok = false
		}
	}
	fmt.printfln("selftest: %d bots, %.0fs, lag %.0fms, loss %.0f%%: %d frags, ping %.0fms, %s",
		len(bots), opts.seconds, opts.loopback.lag * 1000, opts.loopback.loss * 100, kills,
		net.ping(&bots[0].cl) * 1000, "OK" if ok else "FAILED")
	return ok && kills > 0
}

start_bots :: proc(lb: ^net.Loopback, count: int) -> []^Bot {
	bots := make([]^Bot, count)
	for &b in bots {
		b = new(Bot)
		if err := net.client_start(&b.cl, &b.state, make_game(), net.loopback_client(lb)); err != "" do panic(err)
	}
	return bots
}

stop_bots :: proc(bots: []^Bot) {
	for b in bots {
		net.client_stop(&b.cl)
		game_state_destroy(&b.state)
		free(b)
	}
	delete(bots)
}

// Window

Window :: struct {
	handle:      glfw.WindowHandle,
	renderer:    Renderer,
	last_time:   f64,
	title_timer: f32,
}

window_open :: proc(title: cstring) -> (win: Window, ok: bool) {
	if !glfw.Init() {
		fmt.eprintln("glfw init failed")
		return
	}
	glfw.WindowHint(glfw.CONTEXT_VERSION_MAJOR, 3)
	glfw.WindowHint(glfw.CONTEXT_VERSION_MINOR, 3)
	glfw.WindowHint(glfw.OPENGL_PROFILE, glfw.OPENGL_CORE_PROFILE)
	win.handle = glfw.CreateWindow(1280, 720, title, nil, nil)
	if win.handle == nil {
		fmt.eprintln("could not create a window")
		glfw.Terminate()
		return
	}
	glfw.MakeContextCurrent(win.handle)
	glfw.SwapInterval(1)
	gl.load_up_to(3, 3, glfw.gl_set_proc_address)
	if !renderer_init(&win.renderer) {
		fmt.eprintln("shader compile failed")
		window_close(&win)
		return
	}
	win.last_time = glfw.GetTime()
	return win, true
}

window_close :: proc(win: ^Window) {
	renderer_destroy(&win.renderer)
	glfw.DestroyWindow(win.handle)
	glfw.Terminate()
}

// Polls events and returns the frame time.
window_frame :: proc(win: ^Window) -> f32 {
	free_all(context.temp_allocator)
	glfw.PollEvents()
	now := glfw.GetTime()
	dt := f32(min(now - win.last_time, 0.25))
	win.last_time = now
	win.title_timer -= dt
	return dt
}

window_present :: proc(win: ^Window, s: ^Game_State, cl: ^Net_Client, status: string) {
	w, h := glfw.GetFramebufferSize(win.handle)
	draw_begin(&win.renderer, w, h)
	draw_game(&win.renderer, s, net.local_player(cl))
	glfw.SwapBuffers(win.handle)

	if win.title_timer <= 0 {
		win.title_timer = 0.25
		local := net.local_player(cl)
		title: cstring
		switch {
		case status != "":
			title = fmt.ctprintf("Odin netcode demo - %s", status)
		case local == net.NO_PLAYER:
			title = "Odin netcode demo - connecting..."
		case:
			title = fmt.ctprintf("Odin netcode demo - player %d | score %d | ping %.0f ms", local, s.scores[local], net.ping(cl) * 1000)
		}
		glfw.SetWindowTitle(win.handle, title)
	}
}

sample_input :: proc(win: ^Window, s: ^Game_State, local: net.Player_Id) -> (input: Input) {
	if glfw.GetWindowAttrib(win.handle, glfw.FOCUSED) == 0 do return
	key :: proc(win: ^Window, a, b: i32) -> bool {
		return glfw.GetKey(win.handle, a) == glfw.PRESS || glfw.GetKey(win.handle, b) == glfw.PRESS
	}
	if key(win, glfw.KEY_A, glfw.KEY_LEFT) do input.move.x -= 1
	if key(win, glfw.KEY_D, glfw.KEY_RIGHT) do input.move.x += 1
	if key(win, glfw.KEY_S, glfw.KEY_DOWN) do input.move.y -= 1
	if key(win, glfw.KEY_W, glfw.KEY_UP) do input.move.y += 1
	if glfw.GetMouseButton(win.handle, glfw.MOUSE_BUTTON_LEFT) == glfw.PRESS || glfw.GetKey(win.handle, glfw.KEY_SPACE) == glfw.PRESS {
		input.buttons += {.Fire}
	}

	if local == net.NO_PLAYER do return
	if me, ok := net.get(&s.players, s.avatar[local]); ok {
		mx, my := glfw.GetCursorPos(win.handle)
		ww, wh := glfw.GetWindowSize(win.handle)
		to := screen_to_world(&win.renderer, f32(mx), f32(my), {f32(ww), f32(wh)}) - me.pos
		input.aim = math.atan2(to.y, to.x)
	}
	return
}
