// The hi-res target on the host GPU (not a PS1 feature): with BOF4_GL=1 the
// hi-res target's pixels live in OpenGL textures and its draws run in a
// fragment shader that is a port of plot, pixel for pixel. VRAM (targets[0])
// stays on the CPU, exact, and is the textures' source: the cells queued
// draws read are uploaded when they differ from what the GPU holds.
//
// Draws are queued as they come (raster_queue) and submitted at raster_sync.
// The GPU draws a run of primitives in one call without ordering a pixel's
// read of the target after another primitive's write in the same call, so
// the queue is cut into segments, with a texture barrier between them,
// wherever a primitive reading its pixels (blending, the mask check, fading)
// would meet one drawn earlier in the segment, or a primitive would write
// over one that read: overlap is judged in 8x8 VRAM cells. The two triangles
// of a proper quad, and the points of a line, cover distinct pixels and are
// never cut from each other.
//
// What the shader keeps besides the picture: the walk's door tags (walk << 8 |
// door, one u32 per pixel, picture.odin) and the ghost layer (an image: pixel
// | alpha << 24, and the depth as float bits). Pixel reads of the target by
// the CPU (pictures, presenting, move_image) pull the area into the target's
// CPU buffers first, and writes push it back. Checkpoint passes swap the
// picture texture as they swap Target.rgb.
//
// Depth and perspective are computed per pixel where the software steps them
// along a row, so fades and depth tests may differ in the last bit.
package psx

import "base:intrinsics"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:time"
import gl "vendor:OpenGL"
import sdl "vendor:sdl2"

import "ps:core"

// Primitives queued at once, draw levels among them (Gl_Level), and
// portals they use.
@(private)
GL_PRIMS :: 1 << 16
@(private)
GL_LEVELS :: 255
@(private)
GL_PORTALS :: 256
// Primitives queued before they are sent on unasked (gl_add).
@(private)
GL_EAGER :: 512

// Conversions whose black flags are kept (gl_frame_bright): more than
// convert in the presents an extra picture waits to be shown.
@(private)
GL_MARKS :: 16
// VRAM uploads are staged in a ring of this many pixels, in GL_STAGE_PARTS
// parts (gl_vram_sync): uploading from a buffer lets Mesa's GL thread queue
// them, where an upload from program memory waits for it to catch up.
@(private)
GL_STAGE_N :: VRAM_W * VRAM_H * 4
@(private)
GL_STAGE_PARTS :: 4
// Fences kept in the timeline (gl_point): more points unwaited than this
// wait for the oldest.
@(private)
GL_FENCES :: 64

// A primitive as the shader reads it (std430). See gl_prim_tri for the
// fields.
@(private)
Gl_Prim :: struct {
	box:  [4]i32,
	h:    [4]i32,
	t:    [4]i32,
	m:    [4]i32,
	a:    [4]i32,
	b:    [4]i32,
	c:    [4]i32,
	w:    [4]i32,
	z:    [4]f32,
	e:    [4]f32,
}

// Prim flags (Gl_Prim.h.x).
@(private)
Gl_Flag :: enum u32 {
	Rect,
	Textured,
	Raw,
	Semi,
	Gouraud,
	Dither, // unused: the hi-res target keeps 8 bits a channel, undithered
	Depth,
	Persp,
	Flat,
	Sprite,
	Set_Mask,
	Check_Mask,
	See_Active,
	See_Direct,
	Read_Ok,
	Flip_X,
	Flip_Y,
	Depth_On,
	Ghost_Acc,
	Bias0,
	Bias1,
	Bias2,
	Smooth,
	Glow,
	Smooth_All,
	Fog,
	Z_Test,
	Z_Write,
	Z_Plane,
	Z_Exact,
	Z_Decal,
}

@(private)
Gl_Flags :: bit_set[Gl_Flag;u32]

// A portal as the shader reads it: 8 corners two to a vec4, then n, turn,
// inside.
@(private)
Gl_Portal :: struct {
	corner: [4][4]f32,
	info:   [4]f32,
}

// The highest draw levels of one VRAM cell's queued primitives: drawing
// there, reading it back, touching the ghost layer, and touching it by
// fading (whose order counts; a solid pixel only hides ghosts behind it,
// which any order does alike). 0 is none.
//
// A primitive draws at the level after the last one it must follow (it
// reads what that one drew, draws over what it read, or both touch the
// ghost layer where order counts) and at least at the level of the last
// that drew where it draws. Each level is then one draw call with no wait
// inside, in queue order, and levels wait for those before.
@(private)
Gl_Level :: struct {
	written, read, ghost, fade: u8,
}

@(private)
gpu_gl: struct {
	// Asked for (BOF4_GL=1) and working.
	on:          bool,
	win:         ^sdl.Window,
	ctx:         sdl.GLContext,
	// The target's picture (R32UI, hi-res target pixels), door tags (R32UI) and ghost layer
	// (RG32UI); VRAM as the GPU holds it, and staged CPU writes (R32UI,
	// c | 1 << 16).
	main, tag:   u32,
	ghost:       u32,
	// The depth buffer (R32UI, depth_buffer.odin's words).
	zbuf:        u32,
	vram_tex:    u32,
	puts_tex:    u32,
	fbo:         u32,
	vao:         u32,
	prim_buf:    u32,
	portal_buf:  u32,
	draw_prog:   u32,
	pass_prog:   u32,
	// Uniform locations.
	u_k, u_size, u_see0, u_see1, u_see2:    i32,
	u_fog0, u_fog_c, u_zpass:               i32,
	// The fog of the last fogged primitive queued (Plot_Env.fog): one a
	// flush, it changing only between maps.
	fog:                                    Fog,
	p_k, p_size, p_box, p_mode:             i32,
	p_tag, p_org, p_pic_size, p_pic_k:      i32,
	p_warped, p_warp:                       i32,
	p_tag2, p_alpha, p_holes, p_hole:       i32,
	p_blank:                                i32,
	// VRAM-resolution pictures laid (picture_lay) and their size; the
	// texture the lay pass reads.
	pic_tex:     u32,
	pic_w, pic_h: i32,
	pic_use:     u32,
	// move_image's go-between and its size.
	move_tex:    u32,
	move_w, move_h: i32,
	prims:       [GL_PRIMS]Gl_Prim,
	prim_n:      int,
	portals:     [GL_PORTALS]Gl_Portal,
	portal_src:  [GL_PORTALS]^Portal,
	portal_n:    int,
	// Each cell's levels, the rows of cells holding any (bit y / 8), and
	// each queued primitive's level.
	levels:      [VRAM_H / 8][VRAM_W / 8]Gl_Level,
	level_rows:  u64,
	level_of:    [GL_PRIMS]u8,
	// The highest level taken, the lowest the next may take (raised past
	// all taken where depth_on changes, so a level has one) and each
	// level's depth_on.
	level_top:   u8,
	level_floor: u8,
	level_depth: [GL_LEVELS + 1]bool,
	// Levels holding primitives that write depth: each lays its depths
	// down first (gl_submit).
	level_z:     [GL_LEVELS + 1]bool,
	// The queue by level (gl_submit), as the shader reads it.
	order:       [GL_PRIMS]i32,
	order_buf:   u32,
	// A group's cells as Gl_Level has them, held until it ends to be taken
	// at its highest level, so its primitives never wait for each other;
	// the rows they touch (bit y / 8).
	held_written, held_read, held_ghost, held_fade: Cells,
	held_rows:   u64,
	held_level:  u8,
	group:       bool,
	// Cells holding ghosts since the last flush.
	ghost_live:  Cells,
	// CPU writes (vram_put) waiting for the target, and their VRAM box (hi
	// exclusive; empty when lo >= hi).
	puts:        [VRAM_W * VRAM_H]u32,
	puts_lo:     [2]i32,
	puts_hi:     [2]i32,
	// VRAM as last uploaded into vram_tex: the chosen one of `copies`.
	shadow:      ^[VRAM_W * VRAM_H]u16,
	// GPU copies of VRAM, one per VRAM a pass swaps in (a room's,
	// vram_world), so swapping one in and back uploads only what changed in
	// each; each with its contents as uploaded and the key last chosen.
	copies:      [GL_VRAM_COPIES]struct {
		tex:    u32,
		shadow: [VRAM_W * VRAM_H]u16,
		key:    u32,
		used:   u64,
	},
	copy_key:    u32,
	copy_clock:  u64,
	// The upload staging ring (GL_STAGE_N), mapped for good; the next free
	// pixel, and each part's fence from when the ring last left it (the
	// part may be written again once its uploads are done).
	stage_buf:   u32,
	stage:       [^]u16,
	stage_at:    int,
	stage_part:  int,
	stage_done:  [GL_STAGE_PARTS]int,
	// The fence timeline (gl_point): the fence of point n is fences[n %
	// GL_FENCES]; `points` made so far, `done` the last known passed, and
	// whether work was asked to be fenced since the last one was made.
	fences:      [GL_FENCES]gl.sync_t,
	points:      int,
	done:        int,
	want:        bool,
	// Door tags pulled (picture_lay).
	tags:        [dynamic]u32,
	// Converted pictures read back (gl_frame): one per extra picture, then
	// the display's.
	frames:      [EXTRA_FRAMES + 1]Gl_Frame,
	conv_prog:   u32,
	// Whether each of the last GL_MARKS conversions has a pixel above black
	// (frame_black), set by the conversion shader: mapped flags, the point
	// each is set by, and the conversions made so far (conversion n uses
	// flag n % GL_MARKS).
	bright_buf:  u32,
	bright:      [^]u32,
	bright_done: [GL_MARKS]int,
	marks:       int,
	// The SDL renderer's own context, when it is OpenGL and shares objects
	// with ours: present then fills the window texture from a frame slot's
	// buffer on the GPU (gl_show) instead of copying the pixels in. `shows`
	// holds the window textures' GL names, `shown` the renderer's fence
	// after its last draw from them.
	host_ctx:    sdl.GLContext,
	shows:       [2]Gl_Show,
	shown:       gl.sync_t,
	c_area, c_size, c_mark: i32,
	c_bloom, c_gain:        i32,
	c_k, c_dof, c_graded, c_grade, c_vig: i32,
	// The glow's program and its stages' textures (BLOOM_CS), at the PS1's
	// resolution.
	bloom_prog:  u32,
	glow_tex:    [3]u32,
	b_area, b_size, b_k, b_stage, b_every: i32,
	// The depth of field's blur, the same way (dof_prepare).
	blur_tex:    [3]u32,
	// Work since the last .Perf report (gl_perf).
	stat:        Gl_Stats,
}

// An area of the target converted to XRGB8888 by the GPU into a buffer
// mapped for good, `px` pixels; ready once point `done` is (gl_frame_take),
// and shown from the buffer itself.
@(private)
Gl_Frame :: struct {
	buf:   u32,
	ptr:   [^]u32,
	cap:   int,
	px:    int,
	// Width of the converted area: the buffer's row length.
	w:     i32,
	// The conversion's number (gl_frame_bright).
	mark:  int,
	done:  int,
}

// A window texture (SDL's) and its GL name in the shared contexts, 0 when
// it has none we can fill.
@(private)
Gl_Show :: struct {
	tex:  ^sdl.Texture,
	name: u32,
}

// GL work counted between .Perf reports: submits, segments, primitives,
// VRAM uploads, pulls with their pixels, and wall time in submits and pulls.
@(private)
Gl_Stats :: struct {
	submits, segs, prims, uploads, pulls, pull_px: int,
	submit_t, pull_t:                              time.Duration,
}

@(private = "file")
DRAW_VS :: `#version 450
struct Prim { ivec4 box, h, t, m, a, b, c, w; vec4 z, e; };
layout(std430, binding = 0) readonly buffer Prims { Prim prims[]; };
layout(std430, binding = 3) readonly buffer Order { int order[]; };
uniform vec2 size;
flat out int pid;
void main() {
	int id = order[gl_VertexID / 6];
	int c = int[6](0, 1, 2, 2, 1, 3)[gl_VertexID % 6];
	ivec4 box = prims[id].box;
	vec2 p = vec2((c & 1) != 0 ? box.z + 1 : box.x, (c & 2) != 0 ? box.w + 1 : box.y);
	gl_Position = vec4(p / size * 2.0 - 1.0, 0.0, 1.0);
	pid = id;
}
`

@(private = "file")
COMMON_FS :: `#version 450
#extension GL_ARB_gpu_shader_int64 : require
layout(binding = 1) uniform usampler2D main_tex;
layout(binding = 2) uniform usampler2D vram_tex;
layout(binding = 3) uniform usampler2D puts_tex;
layout(binding = 4) uniform usampler2D tag_tex;
layout(binding = 5) uniform usampler2D pic_tex;
layout(binding = 0, rg32ui) coherent uniform uimage2D ghost_img;
uniform int k;
layout(location = 0) out uint out_c;
layout(location = 1) out uint out_tag;

uint vfetch(int x, int y) {
	return texelFetch(vram_tex, ivec2(x & 1023, y & 511), 0).r;
}

const uint HI_MASK = 0x80000000u, HI_GLOW = 0x01000000u, HI_DEPTH = 0x7e000000u;
// The bits a pixel laid over another takes from it (pixel_kept).
const uint HI_KEPT = HI_MASK | HI_DEPTH;

// View depth z (0 unknown) as HI_DEPTH bits (depth_bits).
uint depth_bits(float z) {
	if (z <= 0.0) {
		return 0u;
	}
	return uint(clamp(int(min(z, 65536.0)) >> 6, 1, 63)) << 25;
}

// VRAM pixel c as a target pixel (hi_pixel).
uint hi(uint c) {
	return (c & 31u) << 19 | (c >> 5 & 31u) << 11 | (c >> 10 & 31u) << 3 | (c & 0x8000u) << 16;
}

uint fade_mix(uint back, uint front, float a) {
	uint o = front & HI_MASK;
	for (int s = 0; s < 24; s += 8) {
		precise float b = float((back >> s) & 255u);
		precise float f = float((front >> s) & 255u);
		precise float v = b + (f - b) * a + 0.5;
		o |= uint(v) << s;
	}
	return o;
}
`

@(private = "file")
DRAW_FS :: `
struct Prim { ivec4 box, h, t, m, a, b, c, w; vec4 z, e; };
layout(std430, binding = 0) readonly buffer Prims { Prim prims[]; };
struct Port { vec4 corner[4]; vec4 info; };
layout(std430, binding = 1) readonly buffer Ports { Port ports[]; };
uniform vec4 see0; // h, of.x, of.y, reach2
uniform vec4 see1; // target, stop
uniform vec4 see2; // across, drop
uniform vec4 fog0; // near, inv, most
uniform uint fog_c;
// 1 while a level lays down its depths (gl_submit).
uniform int zpass;
layout(binding = 1, r32ui) coherent uniform uimage2D z_img;
flat in int pid;

const int F_RECT = 1 << 0, F_TEXTURED = 1 << 1, F_RAW = 1 << 2, F_SEMI = 1 << 3,
	F_GOURAUD = 1 << 4, F_DITHER = 1 << 5, F_DEPTH = 1 << 6, F_PERSP = 1 << 7,
	F_FLAT = 1 << 8, F_SPRITE = 1 << 9, F_SET_MASK = 1 << 10, F_CHECK_MASK = 1 << 11,
	F_SEE_ACTIVE = 1 << 12, F_SEE_DIRECT = 1 << 13, F_READ_OK = 1 << 14,
	F_FLIP_X = 1 << 15, F_FLIP_Y = 1 << 16, F_GHOST_ACC = 1 << 18, F_SMOOTH = 1 << 22,
	F_GLOW = 1 << 23, F_SMOOTH_ALL = 1 << 24, F_FOG = 1 << 25, F_Z_TEST = 1 << 26,
	F_Z_WRITE = 1 << 27, F_Z_PLANE = 1 << 28, F_Z_EXACT = 1 << 29, F_Z_DECAL = 1 << 30;
// depth_buffer.odin's Z_BIAS, Z_BIAS_SPRITE, Z_BIAS_SHIFT, Z_LIFT.
const uint Z_BIAS = 8u, Z_BIAS_SPRITE = 192u, Z_BIAS_SHIFT = 7u;
const float Z_LIFT = 4.0;
// gpu.odin's GLOW_FLOOR.
const int GLOW_FLOOR = 48;

// View depth z as a depth step (z_step).
uint z_step(float z) {
	precise float q = clamp(z * 4.0 + 0.5, 1.0, 65535.0);
	return uint(q);
}


int64_t edge(ivec2 a, ivec2 b, int64_t px, int64_t py) {
	return int64_t(b.x - a.x) * (py - int64_t(a.y)) - int64_t(b.y - a.y) * (px - int64_t(a.x));
}

// floor((w0 a0 + w1 a1 + w2 a2 + area / 2) / area), as attr_start.
int attr(int64_t w0, int64_t w1, int64_t w2, int a0, int a1, int a2, int64_t area) {
	int64_t n = w0 * int64_t(a0) + w1 * int64_t(a1) + w2 * int64_t(a2) + (area >> 1);
	int64_t q = int64_t(floor(double(n) / double(area)));
	int64_t r = n - q * area;
	if (r < 0) {
		q -= 1;
	} else if (r >= area) {
		q += 1;
	}
	return int(q);
}

// attr split for smoothing (smooth_split): the texel at or before the
// exact value, the one after, within lo ..= hi, and the place between them
// in 256ths.
ivec3 attr_split(int64_t w0, int64_t w1, int64_t w2, int a0, int a1, int a2, int64_t area, int lo, int hi) {
	int64_t n = w0 * int64_t(a0) + w1 * int64_t(a1) + w2 * int64_t(a2) + (area >> 1);
	int64_t q = int64_t(floor(double(n) / double(area)));
	int64_t r = n - q * area;
	if (r < 0) {
		q -= 1;
		r += area;
	} else if (r >= area) {
		q += 1;
		r -= area;
	}
	int64_t h = 2l * r - area;
	if (h < 0) {
		q -= 1;
		h += 2l * area;
	}
	int64_t fn = h * 128l;
	int64_t f = int64_t(floor(double(fn) / double(area)));
	int64_t fr = fn - f * area;
	if (fr < 0) {
		f -= 1;
	} else if (fr >= area) {
		f += 1;
	}
	return ivec3(clamp(int(q), lo, hi), clamp(int(q) + 1, lo, hi), int(f));
}

// persp_coord: n / d in 256ths, rounded down (gpu.odin).
int persp_coord(int64_t n, int64_t d) {
	if (d <= 0l) {
		return 0;
	}
	n *= 256l;
	if (n >= (d << 17)) {
		return 1 << 17;
	}
	if (n < -(d << 16)) {
		return -(1 << 16);
	}
	int64_t q = int64_t(floor(double(n) / double(d)));
	int64_t r = n - q * d;
	if (r < 0l) {
		q -= 1l;
	} else if (r >= d) {
		q += 1l;
	}
	return int(q);
}

// smooth_split_p: a coordinate t in 256ths split for smoothing.
ivec3 split_p(int t, int lo, int hi) {
	int q = t >> 8;
	return ivec3(clamp(q, lo, hi), clamp(q + 1, lo, hi), t & 255);
}

float smooth_step(float lo, float hi, float v) {
	precise float t = clamp((v - lo) / (hi - lo), 0.0, 1.0);
	precise float s = t * t * (3.0 - 2.0 * t);
	return s;
}

float see_cover_alpha(float x, float y, float z, float weight, bool sprite) {
	precise float near = smooth_step(64.0, 160.0, z);
	if (weight <= 0.0 || near <= 0.0) {
		return near;
	}
	// As unproject (see_through.odin): the GTE's divide stops at 0x1ffff.
	precise float k = max(z, see0.x * (65536.0 / 131071.0)) / see0.x;
	precise vec3 p = vec3((x - see0.y) * k, (y - see0.z) * k, z);
	precise float t = (p.x * see1.x + p.y * see1.y + p.z * see1.z) / see0.w;
	if (t >= see1.w) {
		return near;
	}
	t = max(t, 0.0);
	precise vec3 q = p - see1.xyz * t;
	precise float d = sqrt(q.x * q.x + q.y * q.y + q.z * q.z);
	precise float r = max(t, 0.05);
	precise float below = -(q.x * see2.x + q.y * see2.y + q.z * see2.z) - see2.w * r;
	precise float inside = weight * (1.0 - smooth_step(96.0 * r, 160.0 * r, d)) * (1.0 - smooth_step(8.0 * r, 40.0 * r, below));
	vec2 g = sprite ? vec2(0.25, 0.4) : vec2(0.3, 0.45);
	precise float ghost = g.x + (g.y - g.x) * t / see1.w;
	precise float a = min(near, 1.0 - inside * (1.0 - ghost));
	return a;
}

float see_alpha(float x, float y, float z, vec4 e, bool sprite) {
	precise float a = see_cover_alpha(x, y, z, e.x, sprite) * (1.0 - e.z);
	return a;
}

vec2 port_corner(int pi, int i) {
	vec4 c = ports[pi].corner[i >> 1];
	return (i & 1) != 0 ? c.zw : c.xy;
}

bool portal_lets(int pi, vec2 at) {
	int n = int(ports[pi].info.x);
	float turn = ports[pi].info.y;
	bool holds = n >= 3;
	for (int i = 0; i < n && holds; i++) {
		vec2 a = port_corner(pi, i);
		vec2 b = port_corner(pi, (i + 1) % n);
		precise float c = ((b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x)) * turn;
		if (c < 0.0) {
			holds = false;
		}
	}
	return holds == (ports[pi].info.z != 0.0);
}

// An 8-bit color channel, kept at 8 bits (to8).
uint to8(int c) {
	return uint(clamp(c, 0, 255));
}

uint blend(int abr, uint back, uint front) {
	ivec3 b = ivec3(back & 255u, (back >> 8) & 255u, (back >> 16) & 255u);
	ivec3 f = ivec3(front & 255u, (front >> 8) & 255u, (front >> 16) & 255u);
	ivec3 o;
	if (abr == 0) {
		o = (b + f) >> 1;
	} else if (abr == 1) {
		o = b + f;
	} else if (abr == 2) {
		o = b - f;
	} else {
		o = b + (f >> 2);
	}
	o = clamp(o, 0, 255);
	return uint(o.r) | uint(o.g) << 8 | uint(o.b) << 16 | (front & HI_MASK);
}

uint texel(Prim P, int u_in, int v_in) {
	uint tw = uint(P.m.y);
	uint mx = tw & 31u, my = (tw >> 5) & 31u, ox = (tw >> 10) & 31u, oy = (tw >> 15) & 31u;
	uint u = (uint(u_in) & 0xffu & ~(mx * 8u)) | ((ox & mx) * 8u);
	uint v = (uint(v_in) & 0xffu & ~(my * 8u)) | ((oy & my) * 8u);
	int tp = P.m.x & 3;
	if (tp == 0) {
		uint w = vfetch(P.t.x + int(u >> 2), P.t.y + int(v));
		int idx = int((w >> ((u & 3u) * 4u)) & 0xfu);
		return vfetch(P.t.z + idx, P.t.w);
	}
	if (tp == 1) {
		uint w = vfetch(P.t.x + int(u >> 1), P.t.y + int(v));
		int idx = int((w >> ((u & 1u) * 8u)) & 0xffu);
		return vfetch(P.t.z + idx, P.t.w);
	}
	return vfetch(P.t.x + int(u), P.t.y + int(v));
}

// The four texels s (u0, u1, v0, v1) names mixed by weights f, as a hi-res
// pixel (smooth_texel).
uint smooth_texel(Prim P, ivec4 s, ivec2 f, uint near) {
	uint q[4] = uint[4](texel(P, s.x, s.z), texel(P, s.y, s.z), texel(P, s.x, s.w), texel(P, s.y, s.w));
	uint o = (near & 0x8000u) << 16;
	for (int i = 0; i < 3; i++) {
		int c[4];
		for (int j = 0; j < 4; j++) {
			uint t = q[j] == 0u ? near : q[j];
			c[j] = int((t >> (5 * i)) & 31u) << 3;
		}
		int top = c[0] * (256 - f.x) + c[1] * f.x;
		int bottom = c[2] * (256 - f.x) + c[3] * f.x;
		o |= uint((top * (256 - f.y) + bottom * f.y + 32768) >> 16) << (16 - 8 * i);
	}
	return o;
}

void main() {
	Prim P = prims[pid];
	int fl = P.h.x;
	if (zpass != 0 && (fl & F_Z_WRITE) == 0) {
		discard;
	}
	ivec2 xy = ivec2(gl_FragCoord.xy);
	int x = xy.x, y = xy.y;
	int r, g, b, u = 0, v = 0;
	float z = 0.0;
	bool soft = false;
	ivec4 su;
	ivec2 sf;
	ivec2 sp = ivec2(0);
	if ((fl & F_RECT) == 0) {
		int st = 16 >> k;
		ivec2 p0 = P.a.xy, p1 = P.a.zw, p2 = P.b.xy;
		int64_t px = int64_t(x * st), py = int64_t(y * st);
		int64_t w0 = edge(p1, p2, px, py);
		int64_t w1 = edge(p2, p0, px, py);
		int64_t w2 = edge(p0, p1, px, py);
		int64_t b0 = (fl & (1 << 19)) != 0 ? -1l : 0l;
		int64_t b1 = (fl & (1 << 20)) != 0 ? -1l : 0l;
		int64_t b2 = (fl & (1 << 21)) != 0 ? -1l : 0l;
		if (w0 + b0 < 0l || w1 + b1 < 0l || w2 + b2 < 0l) {
			discard;
		}
		int64_t area = edge(p0, p1, int64_t(p2.x), int64_t(p2.y));
		int64_t o = int64_t(st / 2 - 8);
		int64_t a0 = w0 + o * int64_t((p2.x - p1.x) - (p2.y - p1.y));
		int64_t a1 = w1 + o * int64_t((p0.x - p2.x) - (p0.y - p2.y));
		int64_t a2 = w2 + o * int64_t((p1.x - p0.x) - (p1.y - p0.y));
		ivec3 c0 = ivec3(P.b.z & 255, (P.b.z >> 8) & 255, (P.b.z >> 16) & 255);
		// Laying down depths needs no colour or smoothing.
		if ((fl & F_GOURAUD) != 0 && zpass == 0) {
			ivec3 c1 = ivec3(P.b.w & 255, (P.b.w >> 8) & 255, (P.b.w >> 16) & 255);
			ivec3 c2 = ivec3(P.c.x & 255, (P.c.x >> 8) & 255, (P.c.x >> 16) & 255);
			r = attr(a0, a1, a2, c0.r, c1.r, c2.r, area);
			g = attr(a0, a1, a2, c0.g, c1.g, c2.g, area);
			b = attr(a0, a1, a2, c0.b, c1.b, c2.b, area);
		} else {
			r = c0.r;
			g = c0.g;
			b = c0.b;
		}
		ivec3 us = ivec3(P.c.y & 255, P.c.z & 255, P.c.w & 255);
		ivec3 vs = ivec3((P.c.y >> 8) & 255, (P.c.z >> 8) & 255, (P.c.w >> 8) & 255);
		// Mapped with perspective, u and v come below.
		if ((fl & F_TEXTURED) != 0 && (fl & (F_DEPTH | F_PERSP)) != (F_DEPTH | F_PERSP)) {
			u = attr(a0, a1, a2, us.x, us.y, us.z, area);
			v = attr(a0, a1, a2, vs.x, vs.y, vs.z, area);
		}
		if ((fl & F_DEPTH) != 0) {
			precise float fa = float(area);
			precise float iz = (float(w0) / P.z.x + float(w1) / P.z.y + float(w2) / P.z.z) / fa;
			z = iz > 0.0 ? 1.0 / iz : 0.0;
			if ((fl & F_PERSP) != 0) {
				int64_t q0 = (a0 >> P.w.w) * int64_t(P.w.x);
				int64_t q1 = (a1 >> P.w.w) * int64_t(P.w.y);
				int64_t q2 = (a2 >> P.w.w) * int64_t(P.w.z);
				int64_t pd = q0 + q1 + q2;
				sp = ivec2(persp_coord(q0 * int64_t(us.x) + q1 * int64_t(us.y) + q2 * int64_t(us.z), pd),
					persp_coord(q0 * int64_t(vs.x) + q1 * int64_t(vs.y) + q2 * int64_t(vs.z), pd));
				u = clamp((sp.x + 128) >> 8, min(us.x, min(us.y, us.z)), max(us.x, max(us.y, us.z)));
				v = clamp((sp.y + 128) >> 8, min(vs.x, min(vs.y, vs.z)), max(vs.x, max(vs.y, vs.z)));
			}
		}
		if ((fl & F_READ_OK) != 0) {
			u = clamp(u, (P.m.z << 16) >> 16, P.m.z >> 16);
			v = clamp(v, (P.m.w << 16) >> 16, P.m.w >> 16);
		}
		if ((fl & (F_SMOOTH | F_TEXTURED)) == (F_SMOOTH | F_TEXTURED) && zpass == 0) {
			ivec4 lo = ivec4(min(us.x, min(us.y, us.z)), max(us.x, max(us.y, us.z)),
				min(vs.x, min(vs.y, vs.z)), max(vs.x, max(vs.y, vs.z)));
			if ((fl & F_READ_OK) != 0) {
				lo = ivec4((P.m.z << 16) >> 16, P.m.z >> 16, (P.m.w << 16) >> 16, P.m.w >> 16);
			}
			ivec3 a, c;
			if ((fl & F_PERSP) != 0) {
				a = split_p(sp.x, lo.x, lo.y);
				c = split_p(sp.y, lo.z, lo.w);
			} else {
				a = attr_split(a0, a1, a2, us.x, us.y, us.z, area, lo.x, lo.y);
				c = attr_split(a0, a1, a2, vs.x, vs.y, vs.z, area, lo.z, lo.w);
			}
			su = ivec4(a.xy, c.xy);
			sf = ivec2(a.z, c.z);
			soft = true;
		}
	} else {
		r = P.b.z & 255;
		g = (P.b.z >> 8) & 255;
		b = (P.b.z >> 16) & 255;
		int du = (fl & F_FLIP_X) != 0 ? -1 : 1;
		int dv = (fl & F_FLIP_Y) != 0 ? -1 : 1;
		u = P.a.z + ((x >> k) - P.a.x) * du;
		v = P.a.w + ((y >> k) - P.a.y) * dv;
	}
	// plot
	uint dst = 0u;
	bool have = false;
	if ((fl & F_CHECK_MASK) != 0) {
		dst = texelFetch(main_tex, xy, 0).r;
		have = true;
		if ((dst & HI_MASK) != 0u) {
			discard;
		}
	}
	precise float unit = 1.0 / float(1 << k);
	precise float sx = float(x) * unit - float(P.h.y);
	precise float sy = float(y) * unit - float(P.h.z);
	if (P.h.w >= 0 && !portal_lets(P.h.w, vec2(sx + 0.5 * unit, sy + 0.5 * unit))) {
		discard;
	}
	// The depth buffer (plot, z_test).
	uint zw = 0u;
	if ((fl & F_Z_TEST) != 0) {
		float zd = z;
		if ((fl & F_Z_PLANE) != 0) {
			precise float iz = max(intBitsToFloat(P.w.x) * sy + intBitsToFloat(P.w.y), intBitsToFloat(P.w.z));
			zd = iz > 0.0 ? 1.0 / iz : 0.0;
		}
		if ((fl & F_Z_DECAL) != 0) {
			zd = max(zd - Z_LIFT, 0.5 * zd);
		}
		if (zd > 0.0) {
			uint key = uint(P.e.y) << 16;
			zw = key | z_step(zd);
			uint s = imageLoad(z_img, xy).r;
			uint d = s & 0xffffu;
			bool sprite = (fl & F_Z_PLANE) != 0;
			if (zpass == 0 && (s >> 16) == (key >> 16) &&
				(zw & 0xffffu) > d + (sprite ? Z_BIAS_SPRITE : Z_BIAS) + ((fl & F_Z_EXACT) != 0 ? 0u : d >> Z_BIAS_SHIFT)) {
				discard;
			}
		}
	}
	bool see_active = (fl & F_SEE_ACTIVE) != 0;
	float alpha = 1.0;
	if (z > 0.0 && see_active) {
		alpha = see_alpha(sx, sy, z, P.e, (fl & F_SPRITE) != 0);
		if (alpha <= 0.0) {
			discard;
		}
	}
	bool semi = (fl & F_SEMI) != 0;
	// Laying down depths: only solid pixels drawn in full, after the texel
	// (below) when textured.
	if (zpass != 0 && (alpha < 1.0 || (fl & F_TEXTURED) == 0)) {
		if (alpha >= 1.0 && !semi && zw != 0u) {
			imageAtomicMin(z_img, xy, zw);
		}
		discard;
	}
	if (!have && (alpha < 1.0 || semi)) {
		dst = texelFetch(main_tex, xy, 0).r;
	}
	uint under = dst;
	bool ghost = false;
	if (alpha < 1.0 && (fl & F_FLAT) != 0) {
		uvec2 gv = imageLoad(ghost_img, xy).xy;
		uint ga = gv.x >> 24;
		if (ga != 0u && uintBitsToFloat(gv.y) > z) {
			imageStore(ghost_img, xy, uvec4(gv.x & 0xffffffu, gv.y, 0u, 0u));
			under = fade_mix(under, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | under & HI_KEPT;
		}
	} else if (alpha < 1.0 && (fl & F_SEE_DIRECT) == 0) {
		uvec2 gv = imageLoad(ghost_img, xy).xy;
		if ((gv.x >> 24) == 0u) {
			dst = under;
		} else if (z > uintBitsToFloat(gv.y)) {
			discard;
		} else {
			dst = gv.x & 0xffffffu;
		}
		ghost = true;
	}
	uint c;
	if ((fl & F_TEXTURED) != 0) {
		uint tx = texel(P, u, v);
		if (tx == 0u) {
			discard;
		}
		semi = semi && (tx & 0x8000u) != 0u;
		if (zpass != 0) {
			if (!semi && zw != 0u) {
				imageAtomicMin(z_img, xy, zw);
			}
			discard;
		}
		uint t8;
		if (soft && (semi || (fl & F_SMOOTH_ALL) != 0)) {
			int sk = int(P.e.w);
			if (sk > 0) {
				sk <<= k;
				sf = clamp(((sf - 128) * sk >> 8) + 128, 0, 256);
			}
			t8 = smooth_texel(P, su, sf, tx);
		} else {
			t8 = hi(tx);
		}
		// A filed sprite's additive texels less GLOW_FLOOR (glow_floor).
		if (semi && (fl & F_FLAT) != 0 && ((P.m.x >> 2) & 3) == 1) {
			uint o = t8 & HI_MASK;
			for (int i = 0; i < 3; i++) {
				o |= uint(max(int((t8 >> (8 * i)) & 255u) - GLOW_FLOOR, 0)) << (8 * i);
			}
			t8 = o;
		}
		if ((fl & F_RAW) != 0) {
			c = t8;
		} else {
			uint cr = to8((int((t8 >> 16) & 255u) * r) >> 7);
			uint cg = to8((int((t8 >> 8) & 255u) * g) >> 7);
			uint cb = to8((int(t8 & 255u) * b) >> 7);
			c = cr << 16 | cg << 8 | cb | t8 & HI_MASK;
		}
	} else {
		c = to8(r) << 16 | to8(g) << 8 | to8(b);
	}
	// Distance fog (fog_mix).
	if ((fl & F_FOG) != 0 && z > 0.0 && !semi) {
		precise float ft = clamp((z - fog0.x) * fog0.y, 0.0, 1.0);
		precise float fw = ft * fog0.z;
		int w = int(fw);
		if (w > 0) {
			uint o = c & HI_MASK;
			for (int i = 0; i < 3; i++) {
				int a = int((c >> (8 * i)) & 255u), b = int((fog_c >> (8 * i)) & 255u);
				o |= uint((a * (256 - w) + b * w + 128) >> 8) << (8 * i);
			}
			c = o;
		}
	}
	// A pixel without depth drawn after a ghost: the ghost is laid down
	// under it (ghost_settle).
	if (z <= 0.0 && see_active && (fl & F_GHOST_ACC) != 0 && (fl & F_SEE_DIRECT) == 0) {
		uvec2 gv = imageLoad(ghost_img, xy).xy;
		uint ga = gv.x >> 24;
		if (ga != 0u) {
			imageStore(ghost_img, xy, uvec4(gv.x & 0xffffffu, gv.y, 0u, 0u));
			if (semi) {
				dst = fade_mix(dst, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | dst & HI_KEPT;
			}
		}
	}
	if (semi) {
		c = blend((P.m.x >> 2) & 3, dst, c);
		if ((fl & F_GLOW) != 0 && ((P.m.x >> 2) & 3) == 1) {
			c |= HI_GLOW;
		}
	}
	if ((fl & F_SET_MASK) != 0) {
		c |= HI_MASK;
	}
	if (ghost) {
		precise float fa = max(1.0, alpha * 255.0);
		imageStore(ghost_img, xy, uvec4(c & 0xffffffu | uint(fa) << 24, floatBitsToUint(z), 0u, 0u));
		discard;
	}
	if (alpha < 1.0) {
		c = fade_mix(under, c, alpha);
	} else if (z > 0.0 && see_active && (fl & F_GHOST_ACC) != 0) {
		uvec2 gv = imageLoad(ghost_img, xy).xy;
		if ((gv.x >> 24) != 0u && uintBitsToFloat(gv.y) > z) {
			imageStore(ghost_img, xy, uvec4(gv.x & 0xffffffu, gv.y, 0u, 0u));
		}
	}
	out_c = c & ~HI_DEPTH | (semi ? dst & HI_DEPTH : depth_bits(z));
	out_tag = (uint(P.m.x) >> 16) << 8 | ((uint(P.m.x) >> 8) & 255u);
}
`

// Glow shared by BLOOM_CS and CONV_CS (bloom.odin): a pixel's channels as
// lanes and back.
@(private = "file")
BLOOM_COMMON :: `
ivec3 lanes(uint c) {
	return ivec3(c >> 16 & 255u, c >> 8 & 255u, c & 255u);
}

uint pack(ivec3 v) {
	return uint(v.x) << 16 | uint(v.y) << 8 | uint(v.z);
}
`

// The glow of the target's area at `area`.xy, `area`.zw pixels (wrapping)
// at the PS1's resolution (bloom_prepare): stage 0 averages each block of
// glowing pixels into dst, 1 blurs src across into dst, 2 blurs it down.
// With `every`, all pixels are averaged: the depth of field's blur
// (dof_prepare).
@(private = "file")
BLOOM_CS :: `#version 450
layout(local_size_x = 16, local_size_y = 16) in;
layout(binding = 1) uniform usampler2D main_tex;
layout(binding = 1, r32ui) readonly uniform uimage2D src_img;
layout(binding = 2, r32ui) writeonly uniform uimage2D dst_img;
uniform ivec4 area;
uniform ivec2 size;
uniform int k;
uniform int stage;
uniform int every;
const int TAPS[9] = int[9](1, 8, 28, 56, 70, 56, 28, 8, 1);
` + BLOOM_COMMON + `
void main() {
	ivec2 n = area.zw >> k;
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x >= n.x || p.y >= n.y) {
		return;
	}
	ivec3 acc = ivec3(0);
	if (stage == 0) {
		int s = 1 << k;
		for (int dy = 0; dy < s; dy++) {
			for (int dx = 0; dx < s; dx++) {
				uint c = texelFetch(main_tex, (area.xy + (p << k) + ivec2(dx, dy)) & (size - 1), 0).r;
				if (every != 0 || (c & 0x01000000u) != 0u) {
					acc += lanes(c);
				}
			}
		}
		acc = (acc + ((1 << (2 * k)) >> 1)) >> (2 * k);
	} else {
		ivec2 d = stage == 1 ? ivec2(1, 0) : ivec2(0, 1);
		for (int i = 0; i < 9; i++) {
			ivec2 q = clamp(p + (i - 4) * d, ivec2(0), n - 1);
			acc += lanes(imageLoad(src_img, q).r) * TAPS[i];
		}
		acc = (acc + 128) >> 8;
	}
	imageStore(dst_img, p, uvec4(pack(acc), 0u, 0u, 0u));
}
`

// Convert the target's area at `area`.xy, `area`.zw pixels (wrapping) to
// XRGB8888 as convert_rows does, row by row into `px`, with the effects
// (post_pixel): `dof` (focus step, 0 off; DOF_BAND; DOF_RAMP) mixing toward
// the blur in blur_img, with `bloom` (on or off) the glow in glow_img added,
// with `graded` the grade (columns 0..2 of the mix, then the offset), with
// `vig`.x the vignette (VIGNETTE_FROM, VIGNETTE_MOST). k is the target's
// shift.
@(private = "file")
CONV_CS :: `#version 450
layout(local_size_x = 16, local_size_y = 16) in;
layout(binding = 1) uniform usampler2D main_tex;
layout(binding = 3, r32ui) readonly uniform uimage2D glow_img;
layout(binding = 4, r32ui) readonly uniform uimage2D blur_img;
layout(std430, binding = 2) writeonly buffer Out { uint px[]; };
layout(std430, binding = 4) buffer Bright { uint bright[]; };
uniform ivec4 area;
uniform ivec2 size;
uniform int mark;
uniform int bloom;
uniform int gain;
uniform int k;
uniform ivec3 dof;
uniform int graded;
uniform ivec3 grade[4];
uniform ivec3 vig;
shared bool lit;
` + BLOOM_COMMON + `
// Where pixel p falls between glow pixels (bloom_split): the two it mixes
// and the second's weight in 256ths.
ivec3 split(int p, int n) {
	int s = 1 << k;
	int q = 2 * p + 1 - s;
	int lo = (q + 2 * s) / (2 * s) - 1;
	int f = (q - lo * 2 * s) * 128 / s;
	return ivec3(max(lo, 0), min(lo + 1, n - 1), f);
}

// Four pixels of a PS1-resolution image (top left, top right, bottom left,
// bottom right) mixed by the splits sx, sy (bloom_sample).
ivec3 bilerp(uvec4 q, ivec3 sx, ivec3 sy) {
	ivec3 top = lanes(q.x) * (256 - sx.z) + lanes(q.y) * sx.z;
	ivec3 bottom = lanes(q.z) * (256 - sx.z) + lanes(q.w) * sx.z;
	return (top * (256 - sy.z) + bottom * sy.z + 32768) >> 16;
}

void main() {
	if (gl_LocalInvocationIndex == 0u) {
		lit = false;
	}
	barrier();
	ivec2 p = ivec2(gl_GlobalInvocationID.xy);
	if (p.x < area.z && p.y < area.w) {
		uint c = texelFetch(main_tex, (area.xy + p) & (size - 1), 0).r;
		ivec2 n = area.zw >> k;
		ivec3 sx = split(p.x, n.x), sy = split(p.y, n.y);
		int z = int(c >> 25 & 63u);
		int w = z == 0 || dof.x == 0 ? 0 : clamp((abs(z - dof.x) - dof.y) * 256 / dof.z, 0, 256);
		if (w > 0) {
			uvec4 q = uvec4(imageLoad(blur_img, ivec2(sx.x, sy.x)).r, imageLoad(blur_img, ivec2(sx.y, sy.x)).r, imageLoad(blur_img, ivec2(sx.x, sy.y)).r, imageLoad(blur_img, ivec2(sx.y, sy.y)).r);
			c = pack((lanes(c) * (256 - w) + bilerp(q, sx, sy) * w + 128) >> 8);
		}
		if (bloom > 0) {
			uvec4 q = uvec4(imageLoad(glow_img, ivec2(sx.x, sy.x)).r, imageLoad(glow_img, ivec2(sx.y, sy.x)).r, imageLoad(glow_img, ivec2(sx.x, sy.y)).r, imageLoad(glow_img, ivec2(sx.y, sy.y)).r);
			c = pack(min(lanes(c) + ((bilerp(q, sx, sy) * gain + 128) >> 8), ivec3(255)));
		}
		if (graded != 0) {
			ivec3 l = lanes(c);
			ivec3 v = grade[0] * l.x + grade[1] * l.y + grade[2] * l.z + grade[3] + 128;
			c = pack(clamp(v, 0, 255 * 256 + 255) >> 8);
		}
		if (vig.x != 0) {
			int nx = abs(2 * p.x + 1 - area.z) * 256 / area.z;
			int ny = abs(2 * p.y + 1 - area.w) * 256 / area.w;
			int r2 = (nx * nx + ny * ny) >> 8;
			int dark = clamp((r2 - vig.y) * vig.z / (512 - vig.y), 0, vig.z);
			c = pack((lanes(c) * (256 - dark) + 128) >> 8);
		}
		c &= 0xffffffu;
		px[p.y * area.z + p.x] = c;
		// A channel byte above BLACK_MAX (0x10).
		if (max(c & 255u, max(c >> 8 & 255u, c >> 16 & 255u)) > 0x10u) {
			lit = true;
		}
	}
	barrier();
	if (gl_LocalInvocationIndex == 0u && lit) {
		atomicOr(bright[mark], 1u);
	}
}
`

@(private = "file")
PASS_VS :: `#version 450
uniform ivec4 box;
uniform vec2 size;
void main() {
	int c = int[6](0, 1, 2, 2, 1, 3)[gl_VertexID];
	vec2 p = vec2((c & 1) != 0 ? box.z + 1 : box.x, (c & 2) != 0 ? box.w + 1 : box.y);
	gl_Position = vec4(p / size * 2.0 - 1.0, 0.0, 1.0);
}
`

// Passes: 0 lays the ghost layer over the picture (ghost_rows), 1 copies
// VRAM in as blocks, 2 lays the staged CPU writes.
@(private = "file")
PASS_FS :: `
uniform int mode;
uniform vec2 size;
uniform uint pic_tag;
uniform ivec2 pic_org;
uniform ivec2 pic_size;
uniform int pic_k;
uniform int pic_warped;
uniform mat3 pic_warp;
uniform uint pic_tag2;
uniform float pic_alpha;
uniform int pic_holes;
uniform vec3 pic_hole[8];
uniform int pic_blank;
void main() {
	ivec2 xy = ivec2(gl_FragCoord.xy);
	if (mode == 0) {
		uvec2 gv = imageLoad(ghost_img, xy).xy;
		uint ga = gv.x >> 24;
		if (ga == 0u) {
			discard;
		}
		uint m = texelFetch(main_tex, xy, 0).r;
		imageStore(ghost_img, xy, uvec4(gv.x & 0xffffffu, gv.y, 0u, 0u));
		out_c = fade_mix(m, gv.x & 0xffffffu, float(ga) / 255.0) & 0xffffffu | m & HI_KEPT;
	} else if (mode == 1) {
		out_c = hi(vfetch(xy.x >> k, xy.y >> k));
	} else if (mode == 2) {
		uint p = texelFetch(puts_tex, xy >> k, 0).r;
		if ((p & 0x10000u) == 0u) {
			discard;
		}
		out_c = hi(p & 0xffffu);
	} else {
		// A picture laid over its doorway back's pixels (picture_lay), and a
		// cover over pic_tag2's but where its opening shows.
		ivec2 at = (xy - pic_org) & (ivec2(size) - 1);
		uint tag = texelFetch(tag_tex, xy, 0).r;
		if (tag != pic_tag) {
			if (tag != pic_tag2) {
				discard;
			}
		}
		ivec2 pp = at;
		if (pic_warped != 0) {
			float sc = float(1 << k);
			vec3 from = pic_warp * vec3(vec2(at) / sc, 1.0);
			if (from.z <= 0.0) {
				discard;
			}
			pp = ivec2(from.xy / from.z * sc + 0.5);
			// A cover covers the frame to its edges: its own edge stands
			// for what lies past it.
			if (pic_tag2 == ~0u && (any(lessThan(pp, ivec2(0))) || any(greaterThanEqual(pp, pic_size)))) {
				discard;
			}
			pp = clamp(pp, ivec2(0), pic_size - 1);
		}
		uint c = texelFetch(pic_tex, pp >> pic_k, 0).r;
		// A VRAM-resolution picture holds VRAM pixels.
		if (pic_k != 0) {
			c = hi(c);
		}
		// The cover's town shows its doorway's curtain (left out, black)
		// within its opening: the room's own drawn shows through.
		if (tag != pic_tag && (c & 0xf8f8f8u) == 0u && pic_holes > 0) {
			vec2 pos = (vec2(pp) + 0.5) / float(1 << k);
			bool inside = true;
			for (int e = 0; e < pic_holes; e++) {
				inside = inside && dot(pic_hole[e], vec3(pos, 1.0)) >= 0.0;
			}
			if (inside) {
				discard;
			}
		}
		if ((c & 0xf8f8f8u) == 0u && pic_tag2 == ~0u && pic_blank == 0) {
			discard;
		}
		uint m = texelFetch(main_tex, xy, 0).r;
		if (pic_alpha > 0.0 && pic_alpha < 1.0) {
			c = fade_mix(m, c, pic_alpha);
		}
		out_c = c & 0xffffffu | m & HI_KEPT;
	}
	out_tag = 0u;
}
`

// Draw the hi-res target on the GPU ([window] hardware); set before
// platform_init. BOF4_GL=1 or BOF4_GL=0 overrides it.
hardware_renderer := true

// Make the GL context: on any failure the hi-res target stays in software.
// Call after the SDL renderer exists.
@(private)
gl_init :: proc() {
	switch os.get_env("BOF4_GL", context.temp_allocator) {
	case "0":
		return
	case "1":
	case:
		if !hardware_renderer {
			return
		}
	}
	g := &gpu_gl
	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 4)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 5)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLprofile.CORE))
	defer sdl.GL_ResetAttributes()
	g.win = sdl.CreateWindow("bof4 gl", 0, 0, 16, 16, {.OPENGL, .HIDDEN})
	if g.win == nil {
		fmt.eprintln("BOF4_GL: window:", sdl.GetError())
		return
	}
	// Share objects with an OpenGL renderer's context (current since the
	// renderer was made), so present can fill its window texture on the GPU.
	info: sdl.RendererInfo
	if sdl.GetRendererInfo(host.renderer, &info) == 0 && info.name == "opengl" {
		g.host_ctx = sdl.GL_GetCurrentContext()
	}
	if g.host_ctx != nil {
		sdl.GL_SetAttribute(.SHARE_WITH_CURRENT_CONTEXT, 1)
		g.ctx = sdl.GL_CreateContext(g.win)
		if g.ctx == nil {
			g.host_ctx = nil
			sdl.GL_SetAttribute(.SHARE_WITH_CURRENT_CONTEXT, 0)
		}
	}
	if g.ctx == nil {
		g.ctx = sdl.GL_CreateContext(g.win)
	}
	if g.ctx == nil {
		fmt.eprintln("BOF4_GL: context:", sdl.GetError())
		sdl.DestroyWindow(g.win)
		return
	}
	gl.load_up_to(4, 5, sdl.gl_set_proc_address)
	ok: bool
	g.draw_prog, ok = gl.load_shaders_source(DRAW_VS, COMMON_FS + DRAW_FS)
	if !ok {
		msg, _, _, _ := gl.get_last_error_messages()
		fmt.eprintln("BOF4_GL: draw shader:", msg)
		return
	}
	g.pass_prog, ok = gl.load_shaders_source(PASS_VS, COMMON_FS + PASS_FS)
	if !ok {
		msg, _, _, _ := gl.get_last_error_messages()
		fmt.eprintln("BOF4_GL: pass shader:", msg)
		return
	}
	g.conv_prog, ok = gl.load_compute_source(CONV_CS)
	if !ok {
		fmt.eprintln("BOF4_GL: conversion shader failed")
		return
	}
	g.c_area = gl.GetUniformLocation(g.conv_prog, "area")
	g.c_size = gl.GetUniformLocation(g.conv_prog, "size")
	g.c_mark = gl.GetUniformLocation(g.conv_prog, "mark")
	g.c_bloom = gl.GetUniformLocation(g.conv_prog, "bloom")
	g.c_gain = gl.GetUniformLocation(g.conv_prog, "gain")
	g.c_k = gl.GetUniformLocation(g.conv_prog, "k")
	g.c_dof = gl.GetUniformLocation(g.conv_prog, "dof")
	g.c_graded = gl.GetUniformLocation(g.conv_prog, "graded")
	g.c_grade = gl.GetUniformLocation(g.conv_prog, "grade")
	g.c_vig = gl.GetUniformLocation(g.conv_prog, "vig")
	g.bloom_prog, ok = gl.load_compute_source(BLOOM_CS)
	if !ok {
		fmt.eprintln("BOF4_GL: glow shader failed")
		return
	}
	g.b_area = gl.GetUniformLocation(g.bloom_prog, "area")
	g.b_size = gl.GetUniformLocation(g.bloom_prog, "size")
	g.b_k = gl.GetUniformLocation(g.bloom_prog, "k")
	g.b_stage = gl.GetUniformLocation(g.bloom_prog, "stage")
	g.b_every = gl.GetUniformLocation(g.bloom_prog, "every")
	{
		flags := u32(gl.MAP_READ_BIT | gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
		gl.CreateBuffers(1, &g.bright_buf)
		gl.NamedBufferStorage(g.bright_buf, GL_MARKS * 4, nil, flags | gl.CLIENT_STORAGE_BIT)
		g.bright = ([^]u32)(gl.MapNamedBufferRange(g.bright_buf, 0, GL_MARKS * 4, flags))
	}
	{
		flags := u32(gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
		gl.CreateBuffers(1, &g.stage_buf)
		gl.NamedBufferStorage(g.stage_buf, GL_STAGE_N * 2, nil, flags)
		g.stage = ([^]u16)(gl.MapNamedBufferRange(g.stage_buf, 0, GL_STAGE_N * 2, flags))
	}
	g.u_k = gl.GetUniformLocation(g.draw_prog, "k")
	g.u_size = gl.GetUniformLocation(g.draw_prog, "size")
	g.u_see0 = gl.GetUniformLocation(g.draw_prog, "see0")
	g.u_see1 = gl.GetUniformLocation(g.draw_prog, "see1")
	g.u_see2 = gl.GetUniformLocation(g.draw_prog, "see2")
	g.u_fog0 = gl.GetUniformLocation(g.draw_prog, "fog0")
	g.u_fog_c = gl.GetUniformLocation(g.draw_prog, "fog_c")
	g.u_zpass = gl.GetUniformLocation(g.draw_prog, "zpass")
	g.p_k = gl.GetUniformLocation(g.pass_prog, "k")
	g.p_size = gl.GetUniformLocation(g.pass_prog, "size")
	g.p_box = gl.GetUniformLocation(g.pass_prog, "box")
	g.p_mode = gl.GetUniformLocation(g.pass_prog, "mode")
	g.p_tag = gl.GetUniformLocation(g.pass_prog, "pic_tag")
	g.p_org = gl.GetUniformLocation(g.pass_prog, "pic_org")
	g.p_pic_size = gl.GetUniformLocation(g.pass_prog, "pic_size")
	g.p_pic_k = gl.GetUniformLocation(g.pass_prog, "pic_k")
	g.p_warped = gl.GetUniformLocation(g.pass_prog, "pic_warped")
	g.p_warp = gl.GetUniformLocation(g.pass_prog, "pic_warp")
	g.p_tag2 = gl.GetUniformLocation(g.pass_prog, "pic_tag2")
	g.p_alpha = gl.GetUniformLocation(g.pass_prog, "pic_alpha")
	g.p_holes = gl.GetUniformLocation(g.pass_prog, "pic_holes")
	g.p_hole = gl.GetUniformLocation(g.pass_prog, "pic_hole")
	g.p_blank = gl.GetUniformLocation(g.pass_prog, "pic_blank")
	for &c in g.copies {
		c.tex = gl_texture(gl.R16UI, VRAM_W, VRAM_H)
		zero: u32
		gl.ClearTexImage(c.tex, 0, gl.RED_INTEGER, gl.UNSIGNED_SHORT, &zero)
		c.shadow = {}
	}
	g.copy_key = max(u32)
	gl_vram_use(vram_key)
	g.puts_tex = gl_texture(gl.R32UI, VRAM_W, VRAM_H)
	for &tex in g.glow_tex {
		tex = gl_texture(gl.R32UI, VRAM_W, VRAM_H)
	}
	for &tex in g.blur_tex {
		tex = gl_texture(gl.R32UI, VRAM_W, VRAM_H)
	}
	gl.CreateFramebuffers(1, &g.fbo)
	bufs := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}
	gl.NamedFramebufferDrawBuffers(g.fbo, 2, &bufs[0])
	gl.CreateVertexArrays(1, &g.vao)
	gl.CreateBuffers(1, &g.prim_buf)
	gl.NamedBufferStorage(g.prim_buf, size_of(g.prims), nil, gl.DYNAMIC_STORAGE_BIT)
	gl.CreateBuffers(1, &g.order_buf)
	gl.NamedBufferStorage(g.order_buf, size_of(g.order), nil, gl.DYNAMIC_STORAGE_BIT)
	gl.CreateBuffers(1, &g.portal_buf)
	gl.NamedBufferStorage(g.portal_buf, size_of(g.portals), nil, gl.DYNAMIC_STORAGE_BIT)
	g.puts_lo = {VRAM_W, VRAM_H}
	g.on = true
	fmt.eprintln("BOF4_GL:", cstring(gl.GetString(gl.RENDERER)), g.host_ctx != nil ? "(window texture filled on the GPU)" : "")
}

// Make the GL context current (the SDL renderer makes its own current when
// it draws).
@(private)
gl_enter :: #force_inline proc() {
	if sdl.GL_GetCurrentContext() != gpu_gl.ctx {
		sdl.GL_MakeCurrent(gpu_gl.win, gpu_gl.ctx)
	}
}

// A texture of one integer channel format, sampled texel by texel.
@(private)
gl_texture :: proc(format: u32, w, h: i32) -> u32 {
	gl_enter()
	tex: u32
	gl.CreateTextures(gl.TEXTURE_2D, 1, &tex)
	gl.TextureStorage2D(tex, 1, format, w, h)
	gl.TextureParameteri(tex, gl.TEXTURE_MIN_FILTER, gl.NEAREST)
	gl.TextureParameteri(tex, gl.TEXTURE_MAG_FILTER, gl.NEAREST)
	return tex
}

@(private)
gl_delete :: proc(tex: ^u32) {
	if tex^ != 0 {
		gl_enter()
		gl.DeleteTextures(1, tex)
		tex^ = 0
	}
}

// A forked child draws no hi-res target and leaves the parent's GL alone.
@(private)
gl_fork_child :: proc() {
	if gpu_gl.on {
		gpu_gl.on = false
		target_count = 1
	}
}

// Give target t (the hi-res one, just made) its textures, filled from VRAM.
@(private)
gl_target_make :: proc(t: ^Target) {
	g := &gpu_gl
	t.gl = true
	g.main = gl_texture(gl.R32UI, t.w, t.h)
	g.tag = gl_texture(gl.R32UI, t.w, t.h)
	g.ghost = gl_texture(gl.RG32UI, t.w, t.h)
	g.zbuf = gl_texture(gl.R32UI, t.w, t.h)
	gl.NamedFramebufferTexture(g.fbo, gl.COLOR_ATTACHMENT0, g.main, 0)
	gl.NamedFramebufferTexture(g.fbo, gl.COLOR_ATTACHMENT1, g.tag, 0)
	if s := gl.CheckNamedFramebufferStatus(g.fbo, gl.DRAW_FRAMEBUFFER); s != gl.FRAMEBUFFER_COMPLETE {
		fmt.eprintln("BOF4_GL: framebuffer incomplete:", s)
	}
	zero: [4]u32
	gl.ClearTexImage(g.tag, 0, gl.RED_INTEGER, gl.UNSIGNED_INT, &zero)
	gl.ClearTexImage(g.ghost, 0, gl.RG_INTEGER, gl.UNSIGNED_INT, &zero)
	empty := Z_EMPTY
	gl.ClearTexImage(g.zbuf, 0, gl.RED_INTEGER, gl.UNSIGNED_INT, &empty)
	gl_vram_load()
}

// Drop target t's textures.
@(private)
gl_target_drop :: proc(t: ^Target) {
	gl_settle()
	gl_delete(&gpu_gl.main)
	gl_delete(&gpu_gl.tag)
	gl_delete(&gpu_gl.ghost)
	gl_delete(&gpu_gl.zbuf)
	gpu_gl.ghost_live = {}
}

// Upload all of VRAM and lay it over the target as blocks (render_targets_set,
// vram_replace).
@(private)
gl_vram_load :: proc() {
	gl_vram_upload()
	t := &targets[1]
	gl_pass(1, {0, 0, t.w - 1, t.h - 1})
}

// Upload all of VRAM to the GPU's copy, the picture left as it is.
@(private)
gl_vram_upload :: proc() {
	g := &gpu_gl
	gl_enter()
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.TextureSubImage2D(g.vram_tex, 0, 0, 0, VRAM_W, VRAM_H, gl.RED_INTEGER, gl.UNSIGNED_SHORT, &vram[0])
	g.shadow^ = vram
}

// Most GPU copies of VRAM kept: the machine's and up to 8 rooms'.
@(private = "file")
GL_VRAM_COPIES :: 9

// Draw with the GPU copy of VRAM kept for `key` (vram_world), or else the
// one least lately used. Any copy is right to draw with, its shadow saying
// what to upload; the key only picks the one likely to need least. Call with
// no draw queued.
@(private)
gl_vram_use :: proc(key: u32) {
	g := &gpu_gl
	if key == g.copy_key {
		return
	}
	assert(g.prim_n == 0, "VRAM copy changed under queued draws")
	pick := 0
	for c, i in g.copies {
		if c.key == key {
			pick = i
			break
		}
		if c.used < g.copies[pick].used {
			pick = i
		}
	}
	c := &g.copies[pick]
	g.copy_clock += 1
	c.key, c.used = key, g.copy_clock
	g.copy_key = key
	g.vram_tex = c.tex
	g.shadow = &c.shadow
}

// Point the framebuffer at the picture texture (after a checkpoint swap).
@(private)
gl_attach_main :: proc() {
	gl_enter()
	gl.NamedFramebufferTexture(gpu_gl.fbo, gl.COLOR_ATTACHMENT0, gpu_gl.main, 0)
}

// Run pass `mode` (PASS_FS) over the target's box (inclusive pixels).
@(private)
gl_pass :: proc(mode: i32, box: [4]i32) {
	g := &gpu_gl
	t := &targets[1]
	gl_enter()
	gl.TextureBarrier()
	gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, g.fbo)
	gl.Viewport(0, 0, t.w, t.h)
	gl.UseProgram(g.pass_prog)
	gl.BindVertexArray(g.vao)
	gl_bind()
	gl.ProgramUniform1i(g.pass_prog, g.p_k, i32(t.shift))
	gl.ProgramUniform2f(g.pass_prog, g.p_size, f32(t.w), f32(t.h))
	gl.ProgramUniform4i(g.pass_prog, g.p_box, box.x, box.y, box.z, box.w)
	gl.ProgramUniform1i(g.pass_prog, g.p_mode, mode)
	gl.ColorMaski(1, false, false, false, false)
	gl.DrawArrays(gl.TRIANGLES, 0, 6)
}

@(private = "file")
gl_bind :: proc() {
	g := &gpu_gl
	gl.BindTextureUnit(1, g.main)
	gl.BindTextureUnit(2, g.vram_tex)
	gl.BindTextureUnit(3, g.puts_tex)
	gl.BindTextureUnit(4, g.tag)
	gl.BindTextureUnit(5, g.pic_use)
	gl.BindImageTexture(0, g.ghost, 0, false, 0, gl.READ_WRITE, gl.RG32UI)
	gl.BindImageTexture(1, g.zbuf, 0, false, 0, gl.READ_WRITE, gl.R32UI)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 0, g.prim_buf)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 1, g.portal_buf)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 3, g.order_buf)
}

// Stage a CPU write of VRAM pixel x, y for the target (vram_put).
@(private)
gl_put :: #force_inline proc(x, y: i32, c: u16) #no_bounds_check {
	g := &gpu_gl
	x, y := x & (VRAM_W - 1), y & (VRAM_H - 1)
	g.puts[y * VRAM_W + x] = u32(c) | 1 << 16
	g.puts_lo = {min(g.puts_lo.x, x), min(g.puts_lo.y, y)}
	g.puts_hi = {max(g.puts_hi.x, x + 1), max(g.puts_hi.y, y + 1)}
}

// Lay the staged CPU writes over the target.
@(private)
gl_puts_apply :: proc() #no_bounds_check {
	g := &gpu_gl
	if g.puts_lo.x >= g.puts_hi.x || !g.on {
		return
	}
	lo, hi := g.puts_lo, g.puts_hi
	gl_enter()
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, VRAM_W)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.TextureSubImage2D(g.puts_tex, 0, lo.x, lo.y, hi.x - lo.x, hi.y - lo.y, gl.RED_INTEGER, gl.UNSIGNED_INT, &g.puts[lo.y * VRAM_W + lo.x])
	k := targets[1].shift
	gl_pass(2, {lo.x << k, lo.y << k, (hi.x << k) - 1, (hi.y << k) - 1})
	for y in lo.y ..< hi.y {
		mem.zero_slice(g.puts[y * VRAM_W + lo.x:][:hi.x - lo.x])
	}
	g.puts_lo, g.puts_hi = {VRAM_W, VRAM_H}, {}
}

// Draw everything queued and lay staged writes: the target's textures are
// then up to date.
@(private)
gl_settle :: proc() {
	raster_sync()
	gl_puts_apply()
}

// The parts of the area x, y, w x h of a w_all x h_all buffer, wrapping as
// VRAM does: up to four rectangles (x, y, w, h).
@(private)
gl_pieces :: proc(x, y, w, h, w_all, h_all: i32) -> (r: [4][4]i32, n: int) {
	w, h := min(w, w_all), min(h, h_all)
	if w <= 0 || h <= 0 {
		return
	}
	x, y := x & (w_all - 1), y & (h_all - 1)
	xs := [2][2]i32{{x, min(w, w_all - x)}, {0, w - min(w, w_all - x)}}
	ys := [2][2]i32{{y, min(h, h_all - y)}, {0, h - min(h, h_all - y)}}
	for py in ys {
		for px in xs {
			if px.y > 0 && py.y > 0 {
				r[n] = {px.x, py.x, px.y, py.y}
				n += 1
			}
		}
	}
	return
}

// Copy the target's picture over the area (target pixels, wrapping) into
// Target.rgb, and with tags its door tags into Target.door and walk.
@(private)
gl_pull :: proc(x, y, w, h: i32, tags := false) #no_bounds_check {
	g := &gpu_gl
	t := &targets[1]
	start := time.tick_now()
	defer g.stat.pull_t += time.tick_since(start)
	gl_enter()
	pieces, n := gl_pieces(x, y, w, h, t.w, t.h)
	g.stat.pulls += 1
	for p in pieces[:n] {
		g.stat.pull_px += int(p.z * p.w)
		i := int(p.y * t.w + p.x)
		gl.PixelStorei(gl.PACK_ROW_LENGTH, t.w)
		gl.GetTextureSubImage(g.main, 0, p.x, p.y, 0, p.z, p.w, 1, gl.RED_INTEGER, gl.UNSIGNED_INT, i32((len(t.rgb) - i) * 4), &t.rgb[i])
		if !tags {
			continue
		}
		resize(&g.tags, int(p.z * p.w))
		gl.PixelStorei(gl.PACK_ROW_LENGTH, 0)
		gl.PixelStorei(gl.PACK_ALIGNMENT, 4)
		gl.GetTextureSubImage(g.tag, 0, p.x, p.y, 0, p.z, p.w, 1, gl.RED_INTEGER, gl.UNSIGNED_INT, i32(len(g.tags) * 4), &g.tags[0])
		for row in 0 ..< p.w {
			for col in 0 ..< p.z {
				tag := g.tags[row * p.z + col]
				o := (p.y + row) * t.w + p.x + col
				t.door[o] = u8(tag)
				t.walk[o] = u16(tag >> 8)
			}
		}
	}
	gl.PixelStorei(gl.PACK_ROW_LENGTH, 0)
}

// Convert the target's picture over the area (target pixels, wrapping) to
// XRGB8888 (convert_area) in frame slot `slot`, ready when gl_frame_take
// asks, letting the GPU finish meanwhile.
@(private)
gl_frame :: proc(slot: int, x, y, w, h: i32) {
	g := &gpu_gl
	t := &targets[1]
	f := &g.frames[slot]
	gl_settle()
	gl_enter()
	g.stat.pulls += 1
	g.stat.pull_px += int(w * h)
	px := int(w * h)
	if f.cap < px {
		if f.buf != 0 {
			gl.UnmapNamedBuffer(f.buf)
			gl.DeleteBuffers(1, &f.buf)
		}
		flags := u32(gl.MAP_READ_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT)
		gl.CreateBuffers(1, &f.buf)
		gl.NamedBufferStorage(f.buf, px * 4, nil, flags | gl.CLIENT_STORAGE_BIT)
		f.ptr = ([^]u32)(gl.MapNamedBufferRange(f.buf, 0, px * 4, flags))
		f.cap = px
	}
	f.px = px
	f.w = w
	f.mark = g.marks
	m := g.marks % GL_MARKS
	g.marks += 1
	// The flag is cleared here, not on the GPU, so gl_frame_bright can
	// trust one already set without waiting; the conversion that last used
	// it must be done first.
	gl_point_wait(g.bright_done[m])
	intrinsics.volatile_store(&g.bright[m], 0)
	gl.TextureBarrier()
	gl.MemoryBarrier(gl.ALL_BARRIER_BITS)
	gl.BindTextureUnit(1, g.main)
	post := post_now()
	if bloom_effects {
		gl_blur(g.glow_tex, false, x, y, w, h)
		gl.BindImageTexture(3, g.glow_tex[2], 0, false, 0, gl.READ_ONLY, gl.R32UI)
	}
	if post.focus > 0 {
		gl_blur(g.blur_tex, true, x, y, w, h)
		gl.BindImageTexture(4, g.blur_tex[2], 0, false, 0, gl.READ_ONLY, gl.R32UI)
	}
	gl_post_uniforms(&post)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 2, f.buf)
	gl.BindBufferBase(gl.SHADER_STORAGE_BUFFER, 4, g.bright_buf)
	gl.ProgramUniform4i(g.conv_prog, g.c_area, x, y, w, h)
	gl.ProgramUniform2i(g.conv_prog, g.c_size, t.w, t.h)
	gl.ProgramUniform1i(g.conv_prog, g.c_mark, i32(m))
	gl.DispatchCompute(u32(w + 15) / 16, u32(h + 15) / 16, 1)
	gl.MemoryBarrier(gl.CLIENT_MAPPED_BUFFER_BARRIER_BIT | gl.PIXEL_BUFFER_BARRIER_BIT)
	f.done = gl_point()
	g.bright_done[m] = f.done
	gl.Flush()
}

// Run BLOOM_CS's stages over the area into tex (the glow's, or with `every`
// the depth of field's blur).
@(private = "file")
gl_blur :: proc(tex: [3]u32, every: bool, x, y, w, h: i32) {
	g := &gpu_gl
	t := &targets[1]
	gl.UseProgram(g.bloom_prog)
	gl.ProgramUniform4i(g.bloom_prog, g.b_area, x, y, w, h)
	gl.ProgramUniform2i(g.bloom_prog, g.b_size, t.w, t.h)
	gl.ProgramUniform1i(g.bloom_prog, g.b_k, i32(t.shift))
	gl.ProgramUniform1i(g.bloom_prog, g.b_every, i32(every))
	for stage in 0 ..< i32(3) {
		if stage > 0 {
			gl.BindImageTexture(1, tex[stage - 1], 0, false, 0, gl.READ_ONLY, gl.R32UI)
		}
		gl.BindImageTexture(2, tex[stage], 0, false, 0, gl.WRITE_ONLY, gl.R32UI)
		gl.ProgramUniform1i(g.bloom_prog, g.b_stage, stage)
		gl.DispatchCompute(u32((w >> t.shift) + 15) / 16, u32((h >> t.shift) + 15) / 16, 1)
		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	}
}

// Hand CONV_CS the glow and the effects p.
@(private = "file")
gl_post_uniforms :: proc(p: ^Post) {
	g := &gpu_gl
	prog := g.conv_prog
	gl.UseProgram(prog)
	gl.ProgramUniform1i(prog, g.c_bloom, i32(bloom_effects))
	gl.ProgramUniform1i(prog, g.c_gain, BLOOM_GAIN)
	gl.ProgramUniform1i(prog, g.c_k, i32(targets[1].shift))
	gl.ProgramUniform3i(prog, g.c_dof, p.focus, DOF_BAND, DOF_RAMP)
	gl.ProgramUniform1i(prog, g.c_graded, i32(p.grade.on))
	cols: [4][3]i32
	for j in 0 ..< 3 {
		cols[j] = {p.grade.m[0][j], p.grade.m[1][j], p.grade.m[2][j]}
	}
	cols[3] = p.grade.add
	gl.ProgramUniform3iv(prog, g.c_grade, 4, &cols[0][0])
	gl.ProgramUniform3i(prog, g.c_vig, i32(p.vignette), VIGNETTE_FROM, VIGNETTE_MOST)
}

// Wait for fence `fence` (pull time).
@(private = "file")
gl_wait :: proc(fence: gl.sync_t) {
	start := time.tick_now()
	defer gpu_gl.stat.pull_t += time.tick_since(start)
	for {
		r := gl.ClientWaitSync(fence, gl.SYNC_FLUSH_COMMANDS_BIT, 1_000_000_000)
		if r == gl.ALREADY_SIGNALED || r == gl.CONDITION_SATISFIED {
			return
		}
		if r == gl.WAIT_FAILED {
			fmt.eprintln("BOF4_GL: frame wait failed")
			return
		}
	}
}

// The point the work queued so far is done at, to give gl_point_wait. Its
// fence is made later, when a wait or gl_show needs it: each fence flushes
// the driver's commands to the GPU, so one fence covers every point asked
// for since the last.
@(private = "file")
gl_point :: proc() -> int {
	g := &gpu_gl
	g.want = true
	return g.points + 1
}

// Make the fence of the asked-for point, if not made yet.
@(private = "file")
gl_fence :: proc() {
	g := &gpu_gl
	if !g.want {
		return
	}
	n := g.points + 1
	if g.fences[n % GL_FENCES] != nil {
		gl_retire(n - GL_FENCES)
	}
	g.fences[n % GL_FENCES] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
	g.points = n
	g.want = false
}

// Wait until point n (gl_point) is done; 0 is done from the start. Fences
// pass in order, so the points before n are done too.
@(private = "file")
gl_point_wait :: proc(n: int) {
	g := &gpu_gl
	if n <= g.done {
		return
	}
	gl_enter()
	if n > g.points {
		gl_fence()
	}
	gl_retire(n)
}

// Wait for made point n's fence and drop it and those before it.
@(private = "file")
gl_retire :: proc(n: int) {
	g := &gpu_gl
	assert(n > g.done && n <= g.points, "retiring a point not waiting")
	gl_wait(g.fences[n % GL_FENCES])
	for g.done < n {
		g.done += 1
		gl.DeleteSync(g.fences[g.done % GL_FENCES])
		g.fences[g.done % GL_FENCES] = nil
	}
}

// Whether conversion `mark` (Gl_Frame.mark) has a pixel above black,
// waiting for it unless its flag is already set; `known` false when its
// flag has since been reused.
@(private)
gl_frame_bright :: proc(mark: int) -> (bright, known: bool) {
	g := &gpu_gl
	if mark < 0 || mark >= g.marks || g.marks - mark > GL_MARKS {
		return false, false
	}
	m := mark % GL_MARKS
	if intrinsics.volatile_load(&g.bright[m]) != 0 {
		return true, true
	}
	gl_point_wait(g.bright_done[m])
	return intrinsics.volatile_load(&g.bright[m]) != 0, true
}

// Wait for frame slot `slot`'s conversion, if one is pending, and return
// its pixels: the mapped buffer itself, valid until the slot is converted
// again (a present shows it before then).
@(private)
gl_frame_take :: proc(slot: int) -> []u32 {
	g := &gpu_gl
	f := &g.frames[slot]
	gl_point_wait(f.done)
	return f.ptr[:f.px]
}

// Fill window texture `tex` with frame slot `slot`'s first fw x fh pixels
// on the GPU, ordered after the renderer's last draw from it and before its
// next; leaves the renderer's context current. False, doing nothing, when
// the renderer's context is not shared or the texture has no GL name (the
// caller then copies the pixels in itself).
@(private)
gl_show :: proc(tex: ^sdl.Texture, slot: int, fw, fh: i32) -> bool {
	g := &gpu_gl
	if g.host_ctx == nil {
		return false
	}
	name := gl_show_name(tex)
	if name == 0 {
		return false
	}
	f := &g.frames[slot]
	assert(f.w == fw && f.px >= int(fw * fh), "window texture filled from a smaller frame")
	gl_enter()
	if g.shown != nil {
		gl.WaitSync(g.shown, 0, gl.TIMEOUT_IGNORED)
		gl.DeleteSync(g.shown)
		g.shown = nil
	}
	// Unpack state is the context's: gl_puts_apply leaves VRAM's row length.
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, f.buf)
	gl.TextureSubImage2D(name, 0, 0, 0, fw, fh, gl.BGRA, gl.UNSIGNED_INT_8_8_8_8_REV, nil)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, 0)
	// The fence also covers the conversion (gl_frame) and anything else
	// waiting for one.
	gl_point()
	gl_fence()
	ready := g.fences[g.points % GL_FENCES]
	gl.Flush()
	sdl.GL_MakeCurrent(host.window, g.host_ctx)
	gl.WaitSync(ready, 0, gl.TIMEOUT_IGNORED)
	return true
}

// After the renderer's present: fence its draws from the window textures,
// which the next gl_show waits on before filling one.
@(private)
gl_shown :: proc() {
	g := &gpu_gl
	if g.host_ctx == nil || sdl.GL_GetCurrentContext() != g.host_ctx {
		return
	}
	if g.shown != nil {
		gl.DeleteSync(g.shown)
	}
	g.shown = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)
}

// Drop the window textures' GL names (render_scale_apply made new ones).
@(private)
gl_show_forget :: proc() {
	gpu_gl.shows = {}
}

// GL name of window texture tex, looked up once in the renderer's context.
@(private = "file")
gl_show_name :: proc(tex: ^sdl.Texture) -> u32 {
	g := &gpu_gl
	for s in g.shows {
		if s.tex == tex {
			return s.name
		}
	}
	slot := g.shows[0].tex == nil ? 0 : 1
	assert(g.shows[slot].tex == nil, "more than two window textures")
	sdl.GL_MakeCurrent(host.window, g.host_ctx)
	name: i32
	if sdl.GL_BindTexture(tex, nil, nil) == 0 {
		gl.GetIntegerv(gl.TEXTURE_BINDING_2D, &name)
		sdl.GL_UnbindTexture(tex)
	}
	g.shows[slot] = {tex, u32(name)}
	return u32(name)
}

// Copy Target.rgb over the area (target pixels, wrapping) into the target's
// picture.
@(private)
gl_push :: proc(x, y, w, h: i32) #no_bounds_check {
	t := &targets[1]
	gl_enter()
	pieces, n := gl_pieces(x, y, w, h, t.w, t.h)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, t.w)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 4)
	for p in pieces[:n] {
		gl.TextureSubImage2D(gpu_gl.main, 0, p.x, p.y, p.z, p.w, gl.RED_INTEGER, gl.UNSIGNED_INT, &t.rgb[p.y * t.w + p.x])
	}
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
}

// Fill the VRAM area x, y, w x h of the target with c (fill_rect), or with
// a colour per target row (Fill.rows), noting the fill in the door tags
// during a depth walk.
@(private)
gl_fill :: proc(x, y, w, h: i32, c: u16, rows: []u32) {
	g := &gpu_gl
	t := &targets[1]
	k := t.shift
	gl_settle()
	gl_enter()
	tag := u32(DOOR_CLEAR) | u32(depth_walk.now) << 8
	if depth_walk.on {
		pieces, n := gl_pieces(x << k, y << k, w << k, h << k, t.w, t.h)
		for p in pieces[:n] {
			gl.ClearTexSubImage(g.tag, 0, p.x, p.y, 0, p.z, p.w, 1, gl.RED_INTEGER, gl.UNSIGNED_INT, &tag)
		}
	}
	// One clear per run of rows of one colour.
	pix := hi_pixel(c)
	r0, all := i32(0), h << k
	for r0 < all {
		r1 := all
		if rows != nil {
			pix = rows[r0]
			r1 = r0 + 1
			for r1 < all && rows[r1] == pix {
				r1 += 1
			}
		}
		pieces, n := gl_pieces(x << k, y << k + r0, w << k, r1 - r0, t.w, t.h)
		for p in pieces[:n] {
			gl.ClearTexSubImage(g.main, 0, p.x, p.y, 0, p.z, p.w, 1, gl.RED_INTEGER, gl.UNSIGNED_INT, &pix)
		}
		r0 = r1
	}
}

// Zero the door tags' walks (picture_walk_begin, when the walk count wraps).
@(private)
gl_walks_clear :: proc() {
	gl_settle()
	gl_enter()
	zero: u32
	gl.ClearTexImage(gpu_gl.tag, 0, gl.RED_INTEGER, gl.UNSIGNED_INT, &zero)
}

// Empty the depth buffer (z_walk_begin, when the walk count wraps).
@(private)
gl_zbuf_clear :: proc() {
	gl_settle()
	gl_enter()
	empty := Z_EMPTY
	gl.ClearTexImage(gpu_gl.zbuf, 0, gl.RED_INTEGER, gl.UNSIGNED_INT, &empty)
}

// Lay the ghost layer over the target and clear it (gpu_ghost_flush).
@(private)
gl_ghost_flush :: proc(t: ^Target) {
	// The layer is the GPU's own: VRAM's stream need not be done.
	gl_submit()
	gl_puts_apply()
	g := &t.ghost
	if g.lo.x < g.hi.x && g.lo.y < g.hi.y {
		k := t.shift
		hi_touch(g.lo.x >> k, g.lo.y >> k, ((g.hi.x - 1) >> k) - (g.lo.x >> k) + 1, ((g.hi.y - 1) >> k) - (g.lo.y >> k) + 1)
		gl_pass(0, {g.lo.x, g.lo.y, g.hi.x - 1, g.hi.y - 1})
	}
	g.lo, g.hi = {t.w, t.h}, {0, 0}
	gpu_gl.ghost_live = {}
}

// Copy the target's tiles in mask (VRAM tiles, as vram_tiles) from texture
// src to dst (hi_copy_tiles).
@(private)
gl_copy_tiles :: proc(dst, src: u32, mask: u128) {
	if mask == 0 {
		return
	}
	gl_enter()
	n := i32(64) << targets[1].shift
	for ty in i32(0) ..< 8 {
		row := u16(mask >> u32(ty * 16))
		tx := i32(0)
		for tx < 16 {
			if row & (1 << u32(tx)) == 0 {
				tx += 1
				continue
			}
			x0 := tx
			for tx < 16 && row & (1 << u32(tx)) != 0 {
				tx += 1
			}
			gl.CopyImageSubData(src, gl.TEXTURE_2D, 0, x0 * n, ty * n, 0, dst, gl.TEXTURE_2D, 0, x0 * n, ty * n, 0, (tx - x0) * n, n, 1)
		}
	}
}

// Whether two triangles va vb vc and vb vc vd (a quad's halves) cover
// distinct pixels: the corners off the shared edge lie strictly on its two
// sides.
@(private)
quad_halves_apart :: proc(va, vb, vc, vd: Vertex) -> bool {
	s0 := edge(vb, vc, va.sx, va.sy)
	s3 := edge(vb, vc, vd.sx, vd.sy)
	return s0 > 0 && s3 < 0 || s0 < 0 && s3 > 0
}

// Start or end a group: primitives covering distinct pixels, which a
// segment never needs cutting between.
@(private)
gl_group :: proc(on: bool) {
	g := &gpu_gl
	if !on && g.group {
		gl_held_drop(true)
	}
	g.group = on
}

// Empty the group's held cells, giving them its level first when `take`.
@(private = "file")
gl_held_drop :: #force_inline proc(take: bool) #no_bounds_check {
	g := &gpu_gl
	rows := g.held_rows
	if take {
		g.level_rows |= rows
	}
	for rows != 0 {
		i := intrinsics.count_trailing_zeros(rows)
		rows &= rows - 1
		if take {
			lv := g.held_level
			row := &g.levels[i]
			level_take(row, g.held_written[i], lv, offset_of(Gl_Level, written))
			level_take(row, g.held_read[i], lv, offset_of(Gl_Level, read))
			level_take(row, g.held_ghost[i], lv, offset_of(Gl_Level, ghost))
			level_take(row, g.held_fade[i], lv, offset_of(Gl_Level, fade))
		}
		g.held_written[i], g.held_read[i], g.held_ghost[i], g.held_fade[i] = 0, 0, 0, 0
	}
	g.held_rows, g.held_level = 0, 0
}

// Raise the level at byte `field` of the row's cells set in `span` to lv.
@(private = "file")
level_take :: #force_inline proc(row: ^[VRAM_W / 8]Gl_Level, span: u128, lv: u8, field: uintptr) #no_bounds_check {
	span := span
	for span != 0 {
		j := intrinsics.count_trailing_zeros(span)
		span &= span - 1
		b := (^u8)(uintptr(&row[j]) + field)
		b^ = max(b^, lv)
	}
}

// The level a primitive over the VRAM area x, y, w x h (wrapping) takes:
// reading it back (reader), touching the ghost layer (acc), by fading
// (fade); at least floor.
@(private = "file")
level_need :: proc(x, y, w, h: i32, reader, acc, fade: bool, floor: u8) -> u8 #no_bounds_check {
	g := &gpu_gl
	lv := floor
	rows := h > VRAM_H - 8 ? VRAM_H / 8 : ((y + h - 1) >> 3) - (y >> 3) + 1
	cols := w > VRAM_W - 8 ? VRAM_W / 8 : ((x + w - 1) >> 3) - (x >> 3) + 1
	for i in 0 ..< rows {
		row := &g.levels[((y >> 3) + i) & (VRAM_H / 8 - 1)]
		for j in 0 ..< cols {
			c := row[((x >> 3) + j) & (VRAM_W / 8 - 1)]
			lv = max(lv, c.written, c.read + 1)
			if reader {lv = max(lv, c.written + 1)}
			if acc {lv = max(lv, fade ? c.ghost + 1 : c.fade + 1)}
		}
	}
	return lv
}

// Raise the levels of the VRAM area x, y, w x h (wrapping) to lv, as
// level_need takes them.
@(private = "file")
level_mark :: proc(x, y, w, h: i32, reader, acc, fade: bool, lv: u8) #no_bounds_check {
	g := &gpu_gl
	g.level_rows |= cell_rows(y, h)
	rows := h > VRAM_H - 8 ? VRAM_H / 8 : ((y + h - 1) >> 3) - (y >> 3) + 1
	cols := w > VRAM_W - 8 ? VRAM_W / 8 : ((x + w - 1) >> 3) - (x >> 3) + 1
	for i in 0 ..< rows {
		row := &g.levels[((y >> 3) + i) & (VRAM_H / 8 - 1)]
		for j in 0 ..< cols {
			c := &row[((x >> 3) + j) & (VRAM_W / 8 - 1)]
			c.written = max(c.written, lv)
			if reader {c.read = max(c.read, lv)}
			if acc {c.ghost = max(c.ghost, lv)}
			if acc && fade {c.fade = max(c.fade, lv)}
		}
	}
}

// Queue draw d of target t (raster_queue).
@(private)
gl_queue :: proc(t: ^Target, d: ^Draw) {
	gl_puts_apply()
	switch d.kind {
	case .Triangle:
		gl_queue_tri(t, d)
	case .Rect:
		gl_queue_rect(t, d)
	case .Line:
		gl_queue_line(t, d)
	case .Ghost:
		unreachable()
	}
}

// The flags and portal every primitive of d takes.
@(private = "file")
gl_common :: proc(d: ^Draw, p: ^Gl_Prim) -> Gl_Flags {
	g := &gpu_gl
	e, m := &d.env, &d.m
	f: Gl_Flags
	if m.textured {f += {.Textured}}
	if m.raw {f += {.Raw}}
	if m.semi {f += {.Semi}}
	if m.smooth {f += {.Smooth}}
	if m.glow {f += {.Glow}}
	if m.smooth_all {f += {.Smooth_All}}
	if e.fog.on {
		f += {.Fog}
		gpu_gl.fog = e.fog
	}
	if e.st.set_mask {f += {.Set_Mask}}
	if e.st.check_mask {f += {.Check_Mask}}
	if e.see_active {f += {.See_Active}}
	if e.see_direct {f += {.See_Direct}}
	if e.depth_on {f += {.Depth_On}}
	if e.st.flip_x {f += {.Flip_X}}
	if e.st.flip_y {f += {.Flip_Y}}
	portal := i32(-1)
	if e.portal != nil {
		if g.portal_n > 0 && g.portal_src[g.portal_n - 1] == e.portal {
			portal = i32(g.portal_n - 1)
		} else {
			for s, i in g.portal_src[:g.portal_n] {
				if s == e.portal {
					portal = i32(i)
					break
				}
			}
		}
		if portal < 0 {
			if g.portal_n == GL_PORTALS {
				gl_submit()
			}
			q := e.portal
			o := &g.portals[g.portal_n]
			for c, i in q.corner {
				o.corner[i >> 1][(i & 1) * 2] = c.x
				o.corner[i >> 1][(i & 1) * 2 + 1] = c.y
			}
			o.info = {f32(q.n), q.turn, q.inside ? 1 : 0, 0}
			g.portal_src[g.portal_n] = q
			portal = i32(g.portal_n)
			g.portal_n += 1
		}
	}
	st := &e.st
	p.h = {0, st.off_x, st.off_y, portal}
	p.t = {st.tex_x, st.tex_y, m.clut_x, m.clut_y}
	p.m = {
		i32(st.tp | st.abr << 2 | u32(m.door) << 8 | u32(depth_walk.now) << 16),
		i32(st.tw_mask_x | st.tw_mask_y << 5 | st.tw_off_x << 10 | st.tw_off_y << 15),
		0,
		0,
	}
	return f
}

@(private = "file")
rgb :: #force_inline proc(v: Vertex) -> i32 {
	return v.r | v.g << 8 | v.b << 16
}

@(private = "file")
gl_queue_tri :: proc(t: ^Target, d: ^Draw) {
	tri, m, e := &d.tri, &d.m, &d.env
	p: Gl_Prim
	f := gl_common(d, &p)
	v0, v1, v2 := tri.v0, tri.v1, tri.v2
	if m.gouraud {f += {.Gouraud}}
	if m.depth {f += {.Depth}}
	if tri.persp {f += {.Persp}}
	if m.flat {f += {.Flat}}
	if m.cover.sprite {f += {.Sprite}}
	if tri.read.ok {f += {.Read_Ok}}
	if tri.b0 != 0 {f += {.Bias0}}
	if tri.b1 != 0 {f += {.Bias1}}
	if tri.b2 != 0 {f += {.Bias2}}
	p.box = {tri.min_x, tri.min_y, tri.max_x, tri.max_y}
	p.m.z = tri.read.u.x & 0xffff | tri.read.u.y << 16
	p.m.w = tri.read.tv.x & 0xffff | tri.read.tv.y << 16
	p.a = {v0.sx, v0.sy, v1.sx, v1.sy}
	p.b = {v2.sx, v2.sy, rgb(v0), rgb(v1)}
	p.c = {rgb(v2), v0.u | v0.v << 8, v1.u | v1.v << 8, v2.u | v2.v << 8}
	p.z = {v0.z, v1.z, v2.z, 0}
	if tri.persp {
		p.w = {i32(tri.pw.w[0]), i32(tri.pw.w[1]), i32(tri.pw.w[2]), i32(tri.pw.shift)}
	}
	p.e = {m.cover.weight, 0, m.cover.clear, f32(m.sharp)}
	if m.z_mode != .Off && e.z_key != 0 {
		f += {.Z_Test}
		if m.z_mode == .Write {f += {.Z_Write}}
		if m.world {f += {.Z_Exact}}
		if m.decal {f += {.Z_Decal}}
		p.e.y = f32(e.z_key >> 16)
		// A sprite is never mapped with perspective: w is free.
		if m.z_plane != {} {
			f += {.Z_Plane}
			p.w.x, p.w.y, p.w.z = transmute(i32)m.z_plane.x, transmute(i32)m.z_plane.y, transmute(i32)m.z_plane.z
		}
	}
	fade := e.see_active && m.depth && (min(v0.z, v1.z, v2.z) < 161 || m.cover.weight > 0 || m.cover.clear > 0)
	gl_add(t, &p, f, fade)
}

@(private = "file")
gl_queue_rect :: proc(t: ^Target, d: ^Draw) {
	st := &d.env.st
	q := &d.rect
	k := t.shift
	p: Gl_Prim
	f := gl_common(d, &p) + {.Rect}
	p.box = {max(q.x, st.x1) << k, max(q.y, st.y1) << k, ((min(q.x + q.w - 1, st.x2) + 1) << k) - 1, ((min(q.y + q.h - 1, st.y2) + 1) << k) - 1}
	if p.box.x > p.box.z || p.box.y > p.box.w {
		return
	}
	p.a = {q.x, q.y, q.u, q.v}
	p.b.z = q.r | q.g << 8 | q.b << 16
	gl_add(t, &p, f, false)
}

// A line as draw_line steps it: each point a block of target pixels.
@(private = "file")
gl_queue_line :: proc(t: ^Target, d: ^Draw) {
	st := &d.env.st
	m := &d.m
	a, b := d.line[0], d.line[1]
	dx, dy := b.x - a.x, b.y - a.y
	if abs(dx) >= 1024 || abs(dy) >= 512 {
		return
	}
	k := t.shift
	p: Gl_Prim
	f := gl_common(d, &p) + {.Rect}
	gl_group(true)
	steps := max(abs(dx), abs(dy))
	for i: i32 = 0; i <= steps; i += 1 {
		x, y := a.x, a.y
		r, g, bl := a.r, a.g, a.b
		if steps > 0 {
			x = a.x + dx * i / steps
			y = a.y + dy * i / steps
			if m.gouraud {
				r = a.r + (b.r - a.r) * i / steps
				g = a.g + (b.g - a.g) * i / steps
				bl = a.b + (b.b - a.b) * i / steps
			}
		}
		if x >= st.x1 && x <= st.x2 && y >= st.y1 && y <= st.y2 {
			p.box = {x << k, y << k, (x << k) + (1 << k) - 1, (y << k) + (1 << k) - 1}
			p.a = {x, y, 0, 0}
			p.b.z = r | g << 8 | bl << 16
			gl_add(t, &p, f, false)
		}
	}
	gl_group(false)
}

// Add primitive p with flags f, fading possibly (fade), to the queue,
// cutting a segment where it must not share one with what came before.
@(private = "file")
gl_add :: proc(t: ^Target, p: ^Gl_Prim, f: Gl_Flags, fade: bool) {
	g := &gpu_gl
	f := f
	k := t.shift
	x0, y0 := p.box.x >> k, p.box.y >> k
	w, h := (p.box.z >> k) - x0 + 1, (p.box.w >> k) - y0 + 1
	// A ghost's pixels go to the ghost layer: the picture's own are read
	// only to blend.
	ghosts := fade && .Flat not_in f && .See_Direct not_in f
	reader := .Semi in f || .Check_Mask in f || fade && !ghosts
	// Takers: a solid pixel nearer than a ghost, or any pixel without depth
	// drawn over one before the flush, spends it.
	acc := fade && (.Flat in f || .See_Direct not_in f) || .See_Active in f && (.Depth in f || .See_Direct not_in f) && cells_hit(&g.ghost_live, x0, y0, w, h)
	if acc {
		f += {.Ghost_Acc}
	}
	depth_on := .Depth_On in f
	// Below GL_LEVELS, no level + 1 overflows.
	if g.prim_n == GL_PRIMS || g.level_top == GL_LEVELS {
		gl_submit()
	}
	if g.prim_n > 0 && g.level_depth[g.level_top] != depth_on {
		g.level_floor = g.level_top + 1
	}
	lv := level_need(x0, y0, w, h, reader, acc, fade, g.level_floor)
	g.level_top = max(g.level_top, lv)
	g.level_depth[lv] = depth_on
	if .Z_Write in f {g.level_z[lv] = true}
	g.level_of[g.prim_n] = lv
	if g.group {
		g.held_rows |= cell_rows(y0, h)
		g.held_level = max(g.held_level, lv)
		cells_add(&g.held_written, x0, y0, w, h)
		if reader {cells_add(&g.held_read, x0, y0, w, h)}
		if acc {cells_add(&g.held_ghost, x0, y0, w, h)}
		if acc && fade {cells_add(&g.held_fade, x0, y0, w, h)}
	} else {
		level_mark(x0, y0, w, h, reader, acc, fade, lv)
	}
	if ghosts {
		gh := &t.ghost
		gh.lo = {min(gh.lo.x, p.box.x), min(gh.lo.y, p.box.y)}
		gh.hi = {max(gh.hi.x, p.box.z + 1), max(gh.hi.y, p.box.w + 1)}
		cells_add(&g.ghost_live, x0, y0, w, h)
	}
	p.h.x = transmute(i32)f
	g.prims[g.prim_n] = p^
	g.prim_n += 1
	// Sent on before the frame ends, the GPU draws while the CPU runs on:
	// a pull then waits only for the rest.
	if g.prim_n >= GL_EAGER && !g.group {
		gl_submit()
	}
}

// Upload the VRAM cells queued draws read that changed since last
// uploaded.
@(private = "file")
gl_vram_sync :: proc() #no_bounds_check {
	g := &gpu_gl
	// Strips are staged packed, w pixels a row.
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 2)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, g.stage_buf)
	for cy in 0 ..< i32(len(Cells)) {
		row := raster.reads[cy]
		for row != 0 {
			a := i32(intrinsics.count_trailing_zeros(row))
			run := i32(intrinsics.count_trailing_zeros(~(row >> u32(a))))
			row &~= (~u128(0) >> u32(128 - run)) << u32(a)
			x, w := a * 8, run * 8
			same := true
			for y in cy * 8 ..< cy * 8 + 8 {
				i := y * VRAM_W + x
				if mem.compare_ptrs(&vram[i], &g.shadow[i], int(w) * 2) != 0 {
					same = false
					break
				}
			}
			if same {
				continue
			}
			at := gl_stage_take(int(w) * 8)
			for y in cy * 8 ..< cy * 8 + 8 {
				i := y * VRAM_W + x
				copy(g.shadow[i:][:w], vram[i:][:w])
				copy(g.stage[at + int((y - cy * 8) * w):][:w], vram[i:][:w])
			}
			g.stat.uploads += 1
			gl.TextureSubImage2D(g.vram_tex, 0, x, cy * 8, w, 8, gl.RED_INTEGER, gl.UNSIGNED_SHORT, rawptr(uintptr(at * 2)))
		}
	}
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, 0)
}

// Take n pixels of the staging ring, returning where they start; n fits in
// one part. Leaving a part takes a point (gl_point); entering one waits for
// its point, so its last uploads are done before it is written again.
@(private = "file")
gl_stage_take :: proc(n: int) -> int {
	g := &gpu_gl
	PART :: GL_STAGE_N / GL_STAGE_PARTS
	assert(n <= PART, "upload larger than a staging part")
	at := g.stage_at
	if at + n > (g.stage_part + 1) * PART {
		p := g.stage_part
		g.stage_done[p] = gl_point()
		q := (p + 1) % GL_STAGE_PARTS
		gl_point_wait(g.stage_done[q])
		g.stage_part = q
		at = q * PART
	}
	g.stage_at = at + n
	return at
}

// Draw the queue (raster_run, before its read cells are dropped).
@(private)
gl_submit :: proc() {
	g := &gpu_gl
	if g.prim_n == 0 {
		return
	}
	t := &targets[1]
	start := time.tick_now()
	defer g.stat.submit_t += time.tick_since(start)
	g.stat.submits += 1
	g.stat.prims += g.prim_n
	// Order the queue by level, keeping queue order within one.
	top := int(g.level_top)
	first: [GL_LEVELS + 2]i32
	for lv in g.level_of[:g.prim_n] {
		first[lv + 1] += 1
	}
	for lv in 1 ..= top {
		first[lv + 1] += first[lv]
	}
	next := first
	for lv, i in g.level_of[:g.prim_n] {
		g.order[next[lv]] = i32(i)
		next[lv] += 1
	}
	gl_enter()
	gl_vram_sync()
	gl.NamedBufferSubData(g.prim_buf, 0, g.prim_n * size_of(Gl_Prim), &g.prims[0])
	gl.NamedBufferSubData(g.order_buf, 0, g.prim_n * size_of(i32), &g.order[0])
	if g.portal_n > 0 {
		gl.NamedBufferSubData(g.portal_buf, 0, g.portal_n * size_of(Gl_Portal), &g.portals[0])
	}
	gl.BindFramebuffer(gl.DRAW_FRAMEBUFFER, g.fbo)
	gl.Viewport(0, 0, t.w, t.h)
	gl.UseProgram(g.draw_prog)
	gl.BindVertexArray(g.vao)
	gl_bind()
	s := &see_through
	gl.ProgramUniform1i(g.draw_prog, g.u_k, i32(t.shift))
	gl.ProgramUniform2f(g.draw_prog, g.u_size, f32(t.w), f32(t.h))
	gl.ProgramUniform4f(g.draw_prog, g.u_see0, s.h, s.of.x, s.of.y, see.reach2)
	gl.ProgramUniform4f(g.draw_prog, g.u_see1, s.target.x, s.target.y, s.target.z, see.stop)
	gl.ProgramUniform4f(g.draw_prog, g.u_see2, see.across.x, see.across.y, see.across.z, see.drop)
	gl.ProgramUniform4f(g.draw_prog, g.u_fog0, g.fog.near, g.fog.inv, f32(g.fog.most), 0)
	gl.ProgramUniform1ui(g.draw_prog, g.u_fog_c, g.fog.color)
	for lv in 1 ..= top {
		n := first[lv + 1] - first[lv]
		if n == 0 {
			continue
		}
		g.stat.segs += 1
		on := g.level_depth[lv]
		gl.TextureBarrier()
		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
		gl.ColorMaski(1, on, on, on, on)
		if g.level_z[lv] {
			g.level_z[lv] = false
			gl.ProgramUniform1i(g.draw_prog, g.u_zpass, 1)
			gl.DrawArrays(gl.TRIANGLES, first[lv] * 6, n * 6)
			gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
			gl.ProgramUniform1i(g.draw_prog, g.u_zpass, 0)
		}
		gl.DrawArrays(gl.TRIANGLES, first[lv] * 6, n * 6)
	}
	gl.Flush()
	g.prim_n, g.portal_n = 0, 0
	rows := g.level_rows
	for rows != 0 {
		i := intrinsics.count_trailing_zeros(rows)
		rows &= rows - 1
		g.levels[i] = {}
	}
	g.level_rows, g.level_top, g.level_floor = 0, 0, 1
	gl_held_drop(false)
}

// Before VRAM pixels x0..=x1, y0..=y1 are drawn straight away (no walk
// queues them), draw the target's queue if it reads them.
@(private)
gl_vram_write :: #force_inline proc(t: ^Target, x0, y0, x1, y1: i32) {
	if t.shift == 0 && gpu_gl.prim_n > 0 && x0 <= x1 && y0 <= y1 && cells_hit(&raster.reads, x0, y0, x1 - x0 + 1, y1 - y0 + 1) {
		raster_sync()
	}
}

// Swap the target's picture texture with checkpoint cp's (checkpoint_save,
// restore), giving cp one of the target's size first when saving.
@(private)
gl_hi_swap :: proc(cp: ^Checkpoint, saving: bool) {
	t := &targets[1]
	if saving && cp.hi_gl_w != t.w {
		gl_delete(&cp.hi_gl)
	}
	if cp.hi_gl == 0 {
		cp.hi_gl = gl_texture(gl.R32UI, t.w, t.h)
		cp.hi_gl_w = t.w
	}
	gpu_gl.main, cp.hi_gl = cp.hi_gl, gpu_gl.main
	gl_attach_main()
}

// Report the GL work since the last report (perf_report).
@(private)
gl_perf :: proc() {
	g := &gpu_gl
	if !g.on {
		return
	}
	st := &g.stat
	core.tracef(.Perf, "gl: %d submits, %d segments, %d prims, %d uploads; %d pulls of %d px; submit %.3f s, pull %.3f s", st.submits, st.segs, st.prims, st.uploads, st.pulls, st.pull_px, time.duration_seconds(st.submit_t), time.duration_seconds(st.pull_t))
	st^ = {}
	sync_perf()
}

// Lay picture p over the target's pixels its doorway back drew (tag
// depth_walk.now << 8 | door) in the box x0..=x1, y0..=y1 (target pixels
// from the drawing offset, picture_lay), on the GPU: from the picture's texture
// when `hi`, else from its VRAM pixels, uploaded.
@(private)
gl_picture_lay :: proc(p: ^Picture, door: u8, outside: Maybe(u8), x0, y0, x1, y1: i32, hi: bool) {
	g := &gpu_gl
	t := &targets[1]
	k := i32(t.shift)
	gl_settle()
	gl_enter()
	if hi {
		g.pic_use = p.hi.tex
	} else {
		if g.pic_w != p.w || g.pic_h != p.ht {
			gl_delete(&g.pic_tex)
			g.pic_tex = gl_texture(gl.R16UI, p.w, p.ht)
			g.pic_w, g.pic_h = p.w, p.ht
		}
		gl.PixelStorei(gl.UNPACK_ROW_LENGTH, 0)
		gl.PixelStorei(gl.UNPACK_ALIGNMENT, 2)
		gl.TextureSubImage2D(g.pic_tex, 0, 0, 0, p.w, p.ht, gl.RED_INTEGER, gl.UNSIGNED_SHORT, &p.pixels[0])
		g.pic_use = g.pic_tex
	}
	org := [2]i32{gpu.off_x << u32(k), gpu.off_y << u32(k)}
	gl.ProgramUniform1ui(g.pass_prog, g.p_tag, u32(depth_walk.now) << 8 | u32(door))
	// No tag is all ones: the walk count is 16 bits.
	tag2 := ~u32(0)
	if o, ok := outside.?; ok {
		tag2 = u32(depth_walk.now) << 8 | u32(o)
	}
	gl.ProgramUniform1ui(g.pass_prog, g.p_tag2, tag2)
	gl.ProgramUniform1f(g.pass_prog, g.p_alpha, p.alpha)
	gl.ProgramUniform1i(g.pass_prog, g.p_blank, i32(p.blank))
	gl.ProgramUniform1i(g.pass_prog, g.p_holes, i32(p.hole.n))
	hole := p.hole.edges
	gl.ProgramUniform3fv(g.pass_prog, g.p_hole, MAX_HOLE, &hole[0][0])
	gl.ProgramUniform2i(g.pass_prog, g.p_org, org.x, org.y)
	gl.ProgramUniform2i(g.pass_prog, g.p_pic_size, p.w << u32(k), p.ht << u32(k))
	gl.ProgramUniform1i(g.pass_prog, g.p_pic_k, hi ? 0 : k)
	gl.ProgramUniform1i(g.pass_prog, g.p_warped, i32(p.warped))
	warp := p.warp
	gl.ProgramUniformMatrix3fv(g.pass_prog, g.p_warp, 1, false, &warp[0, 0])
	pieces, n := gl_pieces(x0 + org.x, y0 + org.y, x1 - x0 + 1, y1 - y0 + 1, t.w, t.h)
	for q in pieces[:n] {
		gl_pass(3, {q.x, q.y, q.x + q.z - 1, q.y + q.w - 1})
	}
}

// Give hi a w x h texture.
@(private = "file")
gl_picture_size :: proc(hi: ^Picture_Hi, w, h: i32) {
	if hi.tex_w != w || hi.tex_h != h {
		gl_delete(&hi.tex)
		hi.tex = gl_texture(gl.R32UI, w, h)
		hi.tex_w, hi.tex_h = w, h
	}
}

// Copy the target's area x, y, w x h (target pixels, wrapping) into hi's
// texture (picture_take).
@(private)
gl_picture_take :: proc(hi: ^Picture_Hi, x, y, w, h: i32) {
	t := &targets[1]
	gl_settle()
	gl_enter()
	gl_picture_size(hi, w, h)
	pieces, n := gl_pieces(x, y, w, h, t.w, t.h)
	for q in pieces[:n] {
		dx, dy := (q.x - x) & (t.w - 1), (q.y - y) & (t.h - 1)
		gl.CopyImageSubData(gpu_gl.main, gl.TEXTURE_2D, 0, q.x, q.y, 0, hi.tex, gl.TEXTURE_2D, 0, dx, dy, 0, q.z, q.w, 1)
	}
	hi.held = true
}

// Copy src's texture into dst's (picture_hi_copy).
@(private)
gl_picture_copy :: proc(dst, src: ^Picture_Hi) {
	gl_enter()
	gl_picture_size(dst, src.tex_w, src.tex_h)
	gl.CopyImageSubData(src.tex, gl.TEXTURE_2D, 0, 0, 0, 0, dst.tex, gl.TEXTURE_2D, 0, 0, 0, 0, src.tex_w, src.tex_h, 1)
	dst.held = true
}

// Copy the target's area sx, sy, w x h to dx, dy (target pixels, wrapping)
// on the GPU (move_image), unless the areas overlap: then the copy's order
// matters and nothing is done (false).
@(private)
gl_move :: proc(sx, sy, dx, dy, w, h: i32) -> bool {
	g := &gpu_gl
	t := &targets[1]
	src, sn := gl_pieces(sx, sy, w, h, t.w, t.h)
	dst, dn := gl_pieces(dx, dy, w, h, t.w, t.h)
	for a in src[:sn] {
		for b in dst[:dn] {
			if a.x < b.x + b.z && b.x < a.x + a.z && a.y < b.y + b.w && b.y < a.y + a.w {
				return false
			}
		}
	}
	gl_settle()
	gl_enter()
	if g.move_w < w || g.move_h < h {
		gl_delete(&g.move_tex)
		g.move_w, g.move_h = max(g.move_w, w), max(g.move_h, h)
		g.move_tex = gl_texture(gl.R32UI, g.move_w, g.move_h)
	}
	for q in src[:sn] {
		gl.CopyImageSubData(g.main, gl.TEXTURE_2D, 0, q.x, q.y, 0, g.move_tex, gl.TEXTURE_2D, 0, (q.x - sx) & (t.w - 1), (q.y - sy) & (t.h - 1), 0, q.z, q.w, 1)
	}
	for q in dst[:dn] {
		gl.CopyImageSubData(g.move_tex, gl.TEXTURE_2D, 0, (q.x - dx) & (t.w - 1), (q.y - dy) & (t.h - 1), 0, g.main, gl.TEXTURE_2D, 0, q.x, q.y, 0, q.z, q.w, 1)
	}
	return true
}
