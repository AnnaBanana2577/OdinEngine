package main

import "core:math"
import "core:math/linalg"
import gl "vendor:OpenGL"
import net "engine:net"

// Everything is drawn as rotated, colored rectangles in world units (y up).

Renderer :: struct {
	program, vao, vbo: u32,
	u_view, u_center, u_size, u_angle, u_color: i32,
	view: [4]f32, // world → NDC: xy scale, zw offset
	pixels_per_unit: f32,
	viewport: [2]f32,
}

@(private = "file")
VERTEX_SHADER :: `#version 330 core
layout(location = 0) in vec2 a_pos;
uniform vec4 u_view;
uniform vec2 u_center;
uniform vec2 u_size;
uniform float u_angle;
void main() {
	vec2 p = a_pos * u_size;
	float c = cos(u_angle), s = sin(u_angle);
	p = vec2(p.x * c - p.y * s, p.x * s + p.y * c) + u_center;
	gl_Position = vec4(p * u_view.xy + u_view.zw, 0.0, 1.0);
}`

@(private = "file")
FRAGMENT_SHADER :: `#version 330 core
uniform vec4 u_color;
out vec4 o_color;
void main() { o_color = u_color; }`

PALETTE := [8][4]f32 {
	{0.95, 0.35, 0.35, 1},
	{0.35, 0.65, 0.95, 1},
	{0.45, 0.85, 0.45, 1},
	{0.95, 0.80, 0.30, 1},
	{0.75, 0.45, 0.95, 1},
	{0.30, 0.90, 0.85, 1},
	{0.95, 0.55, 0.20, 1},
	{0.85, 0.85, 0.85, 1},
}

renderer_init :: proc(r: ^Renderer) -> bool {
	program, ok := gl.load_shaders_source(VERTEX_SHADER, FRAGMENT_SHADER)
	if !ok do return false
	r.program = program
	r.u_view = gl.GetUniformLocation(program, "u_view")
	r.u_center = gl.GetUniformLocation(program, "u_center")
	r.u_size = gl.GetUniformLocation(program, "u_size")
	r.u_angle = gl.GetUniformLocation(program, "u_angle")
	r.u_color = gl.GetUniformLocation(program, "u_color")

	quad := [?]f32{-0.5, -0.5, 0.5, -0.5, 0.5, 0.5, -0.5, -0.5, 0.5, 0.5, -0.5, 0.5}
	gl.GenVertexArrays(1, &r.vao)
	gl.GenBuffers(1, &r.vbo)
	gl.BindVertexArray(r.vao)
	gl.BindBuffer(gl.ARRAY_BUFFER, r.vbo)
	gl.BufferData(gl.ARRAY_BUFFER, size_of(quad), &quad, gl.STATIC_DRAW)
	gl.EnableVertexAttribArray(0)
	gl.VertexAttribPointer(0, 2, gl.FLOAT, false, 2 * size_of(f32), 0)

	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)
	return true
}

renderer_destroy :: proc(r: ^Renderer) {
	gl.DeleteBuffers(1, &r.vbo)
	gl.DeleteVertexArrays(1, &r.vao)
	gl.DeleteProgram(r.program)
}

// Fits the arena into the framebuffer, letterboxed.
draw_begin :: proc(r: ^Renderer, width, height: i32) {
	w, h := f32(max(width, 1)), f32(max(height, 1))
	s := min(w / ARENA.x, h / ARENA.y)
	r.pixels_per_unit = s
	r.viewport = {w, h}
	r.view = {2 * s / w, 2 * s / h, -ARENA.x * s / w, -ARENA.y * s / h}

	gl.Viewport(0, 0, width, height)
	gl.ClearColor(0.05, 0.05, 0.07, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.UseProgram(r.program)
	gl.BindVertexArray(r.vao)
	gl.Uniform4fv(r.u_view, 1, &r.view[0])
}

draw_rect :: proc(r: ^Renderer, center, size: [2]f32, color: [4]f32, angle: f32 = 0) {
	center, size, color := center, size, color
	gl.Uniform2fv(r.u_center, 1, &center[0])
	gl.Uniform2fv(r.u_size, 1, &size[0])
	gl.Uniform1f(r.u_angle, angle)
	gl.Uniform4fv(r.u_color, 1, &color[0])
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
}

draw_line :: proc(r: ^Renderer, from, to: [2]f32, width: f32, color: [4]f32) {
	d := to - from
	draw_rect(r, (from + to) / 2, {linalg.length(d), width}, color, math.atan2(d.y, d.x))
}

draw_game :: proc(r: ^Renderer, s: ^Game_State, local: net.Player_Id) {
	draw_rect(r, ARENA / 2, ARENA, {0.12, 0.12, 0.15, 1})

	for t in s.tracers {
		c := PALETTE[int(t.shooter) % len(PALETTE)]
		c.a = t.life / TRACER_LIFE
		draw_line(r, t.from, t.to, 0.08, c)
	}

	it := net.iter(&s.players)
	for p, h in net.next(&it) {
		o := net.owner(&s.players, h)
		color := PALETTE[int(o) % len(PALETTE)]
		if o == local do draw_rect(r, p.pos, PLAYER_SIZE + 0.2, {1, 1, 1, 1}) // outline yourself
		draw_rect(r, p.pos, PLAYER_SIZE, color)

		aim := [2]f32{math.cos(p.aim), math.sin(p.aim)}
		draw_line(r, p.pos, p.pos + aim * 0.9, 0.15, color * {0.6, 0.6, 0.6, 1})

		bar := p.pos + {0, 0.85}
		frac := f32(p.hp) / MAX_HP
		draw_rect(r, bar, {1, 0.12}, {0.4, 0.1, 0.1, 1})
		draw_rect(r, bar - {(1 - frac) / 2, 0}, {frac, 0.12}, {0.3, 0.9, 0.3, 1})
	}
}

// Window pixel position (origin top-left) → world position.
screen_to_world :: proc(r: ^Renderer, px, py: f32, window_size: [2]f32) -> [2]f32 {
	// The cursor is in window coordinates, which can differ from the framebuffer on HiDPI.
	s := r.pixels_per_unit * window_size.x / max(r.viewport.x, 1)
	return {(px - window_size.x / 2) / s + ARENA.x / 2, (window_size.y / 2 - py) / s + ARENA.y / 2}
}
