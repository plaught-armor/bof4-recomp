// Software GPU: 1 MiB VRAM plus a GP0 command interpreter and rasterizer.
//
// The game builds GP0 packets in RAM exactly as on hardware; DrawOTag walks the
// ordering table and feeds each packet here. Rendering targets VRAM so texture
// pages, CLUTs and framebuffers interact the same way they do on a PS1.
package psx

import "base:intrinsics"
import "core:math"
import "core:simd"
import "core:slice"


VRAM_W :: 1024
VRAM_H :: 512

vram: [VRAM_W * VRAM_H]u16

// What the camera sees through (see_through, not a PS1 feature): faded
// pixels are drawn as usual into this layer, starting from the target pixel
// under them, the nearest keeping the pixel along with its opacity, and
// gpu_ghost_flush lays the layer over the target once.
@(private)
Ghost_Layer :: struct {
	pix:    []u16, // VRAM's
	rgb:    []u32, // the hi-res target's
	alpha:  []u8, // 0 where nothing was drawn
	z:      []f32,
	lo, hi: [2]i32, // the box touched, hi exclusive; empty when lo >= hi
}

// A buffer the rasterizer draws into: VRAM itself, or its copy at a higher
// resolution (render_scale, not a PS1 feature). Every draw goes to each
// target: VRAM stays exactly as the PS1 has it, for textures and the game's
// reads, while the display shows the finer copy. Textures are always read
// from VRAM.
@(private)
Target :: struct {
	// VRAM's pixels; the hi-res target's are true colour (rgb, hi_pixel).
	pix:   []u16,
	rgb:   []u32,
	// Pixels per VRAM pixel along each axis, as a power of two; w, h the
	// buffer's size, unit the size of its pixel in VRAM pixels.
	shift: u32,
	w, h:  i32,
	unit:  f32,
	ghost: Ghost_Layer,
	// Per pixel, the picture whose doorway back drew it (picture.odin), and
	// the walk it was noted in.
	door:  []u8,
	walk:  []u16,
	// The hi-res target's depth buffer (depth_buffer.odin; on the host GPU
	// its own).
	zbuf:  []u32,
	// Drawn on the host GPU (gl_target.odin): pix, door and walk are then
	// scratch for pixels pulled from its textures, and the ghost layer
	// lives there.
	gl:    bool,
}

@(private)
targets: [2]Target
// Targets drawn into: VRAM, then the hi-res copy when there is one.
@(private)
target_count := 1

@(private)
vram_layers: struct {
	ghost_pix:   [VRAM_W * VRAM_H]u16,
	ghost_alpha: [VRAM_W * VRAM_H]u8,
	ghost_z:     [VRAM_W * VRAM_H]f32,
	door:        [VRAM_W * VRAM_H]u8,
	walk:        [VRAM_W * VRAM_H]u16,
}

@(init, private)
vram_target_init :: proc "contextless" () {
	l := &vram_layers
	targets[0] = {
		pix = vram[:],
		w = VRAM_W,
		h = VRAM_H,
		unit = 1,
		ghost = {pix = l.ghost_pix[:], alpha = l.ghost_alpha[:], z = l.ghost_z[:], lo = {VRAM_W, VRAM_H}},
		door = l.door[:],
		walk = l.walk[:],
	}
}

@(private)
live_targets :: #force_inline proc() -> []Target {
	return targets[:target_count]
}

// While an in-between pass draws (hi_only_begin): its picture is taken
// from the hi-res target alone and VRAM is put back after it, so VRAM's
// draws (polygons, rectangles, lines, ghost and picture lays) are left out.
// The draw areas they would have drawn into are noted (`cells`); a texture,
// image move or VRAM read from one of those (the frame drawing into a
// texture it then reads) marks the pass `missed`, to be drawn again in full.
// Fills, image moves and uploads still go to both: they are VRAM's data.
@(private)
hi_only: struct {
	on, missed: bool,
	// The draw area now set is in `cells`.
	area_noted: bool,
	cells:      Cells,
}

// Targets a draw goes to: both, or in a hi-only pass the hi-res one alone.
@(private)
drawn_targets :: #force_inline proc() -> []Target {
	if !hi_only.on {
		return targets[:target_count]
	}
	if !hi_only.area_noted {
		hi_only.area_noted = true
		if gpu.x2 >= gpu.x1 && gpu.y2 >= gpu.y1 {
			cells_add(&hi_only.cells, gpu.x1, gpu.y1, gpu.x2 - gpu.x1 + 1, gpu.y2 - gpu.y1 + 1)
		}
	}
	return targets[1:2]
}

// Draw only the hi-res target until hi_only_end; inside a pass, with one.
// False when it does not apply (nothing changes).
hi_only_begin :: proc() -> bool {
	if target_count != 2 || !events_frozen {
		return false
	}
	hi_only = {on = true}
	return true
}

// End the hi-only drawing; true when the pass read VRAM it left undrawn and
// its picture must be drawn again with both targets.
hi_only_end :: proc() -> (missed: bool) {
	missed = hi_only.on && hi_only.missed
	hi_only.on = false
	return
}

// A read of VRAM pixels x, y, w x h in a hi-only pass.
@(private)
hi_only_read :: #force_inline proc(x, y, w, h: i32) {
	if hi_only.on && !hi_only.missed && cells_hit(&hi_only.cells, x, y, w, h) {
		hi_only.missed = true
	}
}

// The target the display shows.
@(private)
shown_target :: #force_inline proc() -> ^Target {
	return &targets[target_count - 1]
}

// A hi-res target pixel holds 8-bit channels as the display shows them,
// r << 16 | g << 8 | b, and the mask bit at HI_MASK: draws shade and blend
// it at 8 bits a channel, undithered (not a PS1 feature), while VRAM keeps
// the PS1's 15-bit pixels.
@(private)
HI_MASK :: 0x8000_0000

// A hi-res target pixel's view depth, for the depth of field (post.odin):
// 64 view units a step from 1, 0 for none (menus, text, the party's
// sprites, fills, copies from VRAM). A see-through blend keeps the depth of
// what shows through it, and so do ghosts and pictures laid over a pixel.
@(private)
HI_DEPTH :: 0x7e00_0000
@(private)
HI_DEPTH_SHIFT :: 25

// View depth z (0 unknown) as HI_DEPTH bits.
@(private)
depth_bits :: #force_inline proc(z: f32) -> u32 {
	if z <= 0 {
		return 0
	}
	return u32(clamp(i32(min(z, 0x10000)) >> 6, 1, 63)) << HI_DEPTH_SHIFT
}

// Semi-transparent textured triangles (effects) on the hi-res target mix
// their four nearest texels instead of taking the nearest one (not a PS1
// feature). Set from the config ([window] smooth_effects).
smooth_effects := false

// All textured polygons drawn in 3D (the world, and people as see-through
// files them) on the hi-res target mix their four nearest texels too, solid
// ones included, the mix sharpened to the polygon's magnification so a
// texel stays a sharp square with a soft one-pixel edge (not a PS1 feature).
// Set from the config ([window] smooth_textures).
smooth_textures := false

// Distance fog (not a PS1 feature): on the hi-res target, a solid pixel
// with view depth z is mixed toward `color` (r << 16 | g << 8 | b) by
// most / 256 times where z stands from near to far (inv = 1 / (far - near)),
// so the far ground fades into the haze qol's backdrop draws there and the
// edge the game stops drawing at does not show. Set by qol at each frame's
// clear (stamp, vblanks) and lapsing FOG_VBLANKS after, so a screen that
// stops clearing is not left fogged; a draw keeps the fog of when it was
// queued (Plot_Env).
Fog :: struct {
	on:        bool,
	near, inv: f32,
	most:      i32,
	color:     u32,
	stamp:     u64,
}
fog: Fog
@(private)
FOG_VBLANKS :: 8

// Largest sharpness (Prim_Mode.sharp) a polygon takes: one whose texels
// are this many pixels wide or more mixes as nearest but at the edge pixel.
@(private)
SHARP_MAX :: 64 << 8

// VRAM pixel c as a hi-res target pixel.
@(private)
hi_pixel :: #force_inline proc(c: u16) -> u32 {
	return u32(c & 31) << 19 | u32(c >> 5 & 31) << 11 | u32(c >> 10 & 31) << 3 | u32(c & 0x8000) << 16
}

// What a filed sprite's additive texels lose on each channel (8 bits), for
// the hi-res target only. The footstep dust puff's soft gray runs out at
// 6 / 31, not 0, at the edges of its quad, so under the close camera it
// lifted a hard-edged box out of the leader's shadow at his feet; less
// that, its gradient meets the edges at nothing. GL_DRAW_FS has it too.
@(private)
GLOW_FLOOR :: 6 << 3

// Additive texel t8 (hi_pixel) less GLOW_FLOOR on each channel.
@(private)
glow_floor :: #force_inline proc(t8: u32) -> u32 {
	o := t8 & HI_MASK
	for s in u32(0) ..< 3 {
		o |= u32(max(i32(t8 >> (8 * s) & 255) - GLOW_FLOOR, 0)) << (8 * s)
	}
	return o
}

// Target t's pixels as type P: u16 for VRAM, u32 for the hi-res target.
@(private)
target_pix :: #force_inline proc(t: ^Target, $P: typeid) -> []P {
	when P == u32 {return t.rgb} else {return t.pix}
}

@(private)
ghost_pix :: #force_inline proc(g: ^Ghost_Layer, $P: typeid) -> []P {
	when P == u32 {return g.rgb} else {return g.pix}
}

// The mask bit of a pixel of type P.
@(private)
pixel_mask :: #force_inline proc($P: typeid) -> P {
	when P == u32 {return HI_MASK} else {return 0x8000}
}

// The bits a pixel of type P laid over another (a ghost, a picture) takes
// from the one under it: the mask bit, and the depth (HI_DEPTH).
@(private)
pixel_kept :: #force_inline proc($P: typeid) -> P {
	when P == u32 {return HI_MASK | HI_DEPTH} else {return 0x8000}
}

// Whether pixel c is black at VRAM's precision (its 5-bit channels zero).
@(private)
pixel_black :: #force_inline proc(c: $P) -> bool {
	when P == u32 {return c & 0xf8f8f8 == 0} else {return c & 0x7fff == 0}
}

// Index of target pixel x, y (wrapping as VRAM does).
@(private)
target_index :: #force_inline proc(t: ^Target, x, y: i32) -> i32 {
	return (y & (t.h - 1)) * t.w + (x & (t.w - 1))
}

// Draw at `scale` times VRAM's resolution (1, 2 or 4): make or drop the
// hi-res target, filling a new one from VRAM. Call between walks.
@(private)
render_targets_set :: proc(scale: i32) {
	shift: u32 = scale >= 4 ? 2 : scale >= 2 ? 1 : 0
	if target_count == 2 && targets[1].shift == shift {
		return
	}
	if target_count == 2 {
		t := &targets[1]
		if t.gl {
			gl_target_drop(t)
		}
		delete(t.rgb)
		delete(t.ghost.rgb)
		delete(t.ghost.alpha)
		delete(t.ghost.z)
		delete(t.door)
		delete(t.walk)
		delete(t.zbuf)
		t^ = {}
		target_count = 1
	}
	if shift == 0 {
		return
	}
	w, h := i32(VRAM_W) << shift, i32(VRAM_H) << shift
	n := int(w * h)
	t := &targets[1]
	if gpu_gl.on {
		raster_sync()
		t^ = {
			rgb = make([]u32, n),
			shift = shift,
			w = w,
			h = h,
			unit = 1 / f32(i32(1) << shift),
			ghost = {lo = {w, h}},
			door = make([]u8, n),
			walk = make([]u16, n),
		}
		target_count = 2
		gl_target_make(t)
		return
	}
	t^ = {
		rgb = make([]u32, n),
		shift = shift,
		w = w,
		h = h,
		unit = 1 / f32(i32(1) << shift),
		ghost = {rgb = make([]u32, n), alpha = make([]u8, n), z = make([]f32, n), lo = {w, h}},
		door = make([]u8, n),
		walk = make([]u16, n),
		zbuf = make([]u32, n),
	}
	slice.fill(t.zbuf, Z_EMPTY)
	for y in 0 ..< h {
		for x in 0 ..< w {
			t.rgb[y * w + x] = hi_pixel(vram[(y >> shift) * VRAM_W + (x >> shift)])
		}
	}
	target_count = 2
}

Draw_State :: struct {
	// Drawing area, inclusive.
	x1, y1, x2, y2: i32,
	off_x, off_y:   i32,
	// Texture page (E1).
	tex_x, tex_y:   i32,
	abr:            u32,
	tp:             u32,
	// E1 bit 9: dither shaded and texture-blended pixels (see plot).
	dither:         bool,
	// E1 bits 12/13: rectangles step texture coordinates backwards.
	flip_x, flip_y: bool,
	// Texture window (E2), in 8-pixel units.
	tw_mask_x, tw_mask_y, tw_off_x, tw_off_y: u32,
	// Mask bit control (E6).
	set_mask:       bool,
	check_mask:     bool,
}

gpu: Draw_State

// What a draw reads besides its target and VRAM's textures: the draw state
// and the walk's portal, see-through and picture state as they were when it
// was issued. A queued draw (raster.odin) runs after they have moved on.
@(private)
Plot_Env :: struct {
	st:         Draw_State,
	portal:     ^Portal,
	see_active: bool,
	see_direct: bool,
	depth_on:   bool,
	fog:        Fog,
	// The walk's depth buffer key (z_walk_begin), 0 drawing without.
	z_key:      u32,
}

@(private)
plot_env :: proc() -> Plot_Env {
	return {st = gpu, portal = portal_now, see_active = see.active, see_direct = see.direct, depth_on = depth_walk.on, z_key = see.z_key, fog = fog.on && vblanks() - fog.stamp <= FOG_VBLANKS ? fog : {}}
}

// One pass drawing into a target: the rows it draws, those whose band of
// 1 << BAND_SHIFT rows, counted round `bands`, is `band`; and the box of the
// target's ghost layer it touched, merged into the layer's when done.
@(private)
Raster :: struct {
	t:           ^Target,
	e:           ^Plot_Env,
	band, bands: i32,
	lo, hi:      [2]i32,
}

BAND_SHIFT :: 3

@(private)
raster_make :: proc(t: ^Target, e: ^Plot_Env, band: i32 = 0, bands: i32 = 1) -> Raster {
	return {t = t, e = e, band = band, bands = bands, lo = {t.w, t.h}}
}

@(private)
raster_mine :: #force_inline proc(ra: ^Raster, y: i32) -> bool {
	return ra.bands == 1 || (y >> BAND_SHIFT) % ra.bands == ra.band
}

@(private)
raster_ghost_merge :: proc(ra: ^Raster) {
	g := &ra.t.ghost
	if ra.lo.x < ra.hi.x {
		g.lo = {min(g.lo.x, ra.lo.x), min(g.lo.y, ra.lo.y)}
		g.hi = {max(g.hi.x, ra.hi.x), max(g.hi.y, ra.hi.y)}
	}
}

Vertex :: struct {
	x, y:    i32,
	// x, y in sixteenths of a pixel: past them by the exact projection's
	// sub-pixel part when the GTE projected the vertex.
	sx, sy:  i32,
	r, g, b: i32,
	u, v:    i32,
	// View depth from the GTE (see_through), 0 when unknown.
	z:       f32,
}

@(private)
Prim_Mode :: struct {
	textured:   bool,
	raw:        bool,
	semi:       bool,
	gouraud:    bool,
	dither:     bool,
	// Its vertices carry view depth: pixels are faded by see_alpha, as a
	// face covering the leader as `cover` says.
	depth:      bool,
	// Every vertex carries its own view depth (none filled in): textures
	// are mapped with perspective (not a PS1 feature) instead of warping
	// across the polygon.
	persp:      bool,
	cover:      See_Cover,
	// A sprite (see_flat_add): faded pixels blend straight into VRAM, over
	// any ghost behind them, so a ghost before it (a roof) does not hide it.
	flat:       bool,
	// The picture (index + 1) whose doorway back this is part of (0 none).
	door:       u8,
	// Mix the four nearest texels on the hi-res target (smooth_effects,
	// smooth_textures); solid texels too when smooth_all.
	smooth:     bool,
	smooth_all: bool,
	// VRAM pixels a texel spans, in 256ths (polygon_sharp), 0 for a plain
	// mix: the mix's weights are steepened by it on the hi-res target
	// (sharp_weight).
	sharp:      i32,
	// Mark additive see-through texels HI_GLOW (bloom_effects).
	glow:       bool,
	// Its part in the depth buffer (depth_buffer.odin), and for a sprite
	// the plane its depth is taken from (z_sprite_plane; zero for the
	// polygon's own).
	z_mode:     Z_Mode,
	z_plane:    [3]f32,
	// A world quad drawn in 3D (world.odin): no size limit.
	world:      bool,
	clut_x:     i32,
	clut_y:     i32,
}

vram_at :: #force_inline proc(x, y: i32) -> ^u16 #no_bounds_check {
	return &vram[(y & (VRAM_H - 1)) * VRAM_W + (x & (VRAM_W - 1))]
}

// Sign-extend an 11-bit GPU coordinate.
@(private)
sx11 :: #force_inline proc(v: u32) -> i32 {
	return i32(v << 21) >> 21
}

set_tpage :: proc(tp: u32) {
	gpu.tex_x = i32(tp & 0xf) * 64
	gpu.tex_y = i32((tp >> 4) & 1) * 256
	gpu.abr = (tp >> 5) & 3
	gpu.tp = (tp >> 7) & 3
}

@(private)
texel :: proc(st: ^Draw_State, m: ^Prim_Mode, u_in, v_in: i32) -> u16 #no_bounds_check {
	u := (u32(u_in) & 0xff & ~(st.tw_mask_x * 8)) | ((st.tw_off_x & st.tw_mask_x) * 8)
	v := (u32(v_in) & 0xff & ~(st.tw_mask_y * 8)) | ((st.tw_off_y & st.tw_mask_y) * 8)
	switch st.tp {
	case 0:
		w := vram_at(st.tex_x + i32(u >> 2), st.tex_y + i32(v))^
		idx := i32((w >> ((u & 3) * 4)) & 0xf)
		return vram_at(m.clut_x + idx, m.clut_y)^
	case 1:
		w := vram_at(st.tex_x + i32(u >> 1), st.tex_y + i32(v))^
		idx := i32((w >> ((u & 1) * 8)) & 0xff)
		return vram_at(m.clut_x + idx, m.clut_y)^
	case:
		return vram_at(st.tex_x + i32(u), st.tex_y + i32(v))^
	}
}

// A smoothed pixel's texels: columns u0, u1 and rows v0, v1 around it, and
// its place between them in 256ths (fu, fv).
@(private)
Smooth :: struct {
	u0, u1, v0, v1, fu, fv: i32,
}

// An attribute stepped as attr_start rounds it (nearest texel) split for
// smoothing: the texel at or before the exact value, the one after, both
// kept within lo ..= hi, and the exact value's place between them in 256ths.
@(private)
smooth_split :: #force_inline proc(s: Attr_Step, area: i64, lo, hi: i32) -> (i0, i1, f: i32) {
	// s.q + s.r / area - 1/2 is the exact value.
	q, n := s.q, 2 * s.r - area
	if n < 0 {
		q -= 1
		n += 2 * area
	}
	return clamp(i32(q), lo, hi), clamp(i32(q) + 1, lo, hi), i32(n * 128 / area)
}

// Perspective texture mapping (not a PS1 feature) in whole numbers, worked
// out the same way by both renderers (gl_target.odin, persp_coord): a
// corner's weight w is its nearness to the lens against the nearest
// corner's, in PERSP_ONEths, and a pixel's coordinate is
// sum(a t w) / sum(a w) over its edge weights a, shifted right by shift
// so the sums stay well within an i64.
@(private)
Persp :: struct {
	w:     [3]i64,
	shift: u32,
}
@(private)
PERSP_ONE :: 1 << 15
@(private)
PERSP_AREA_BITS :: 29

@(private)
persp_setup :: proc(v0, v1, v2: Vertex, area: i64) -> Persp {
	near := f64(min(v0.z, v1.z, v2.z))
	w :: #force_inline proc(near: f64, z: f32) -> i64 {return max(i64(near * PERSP_ONE / f64(z) + 0.5), 1)}
	bits := 64 - i32(intrinsics.count_leading_zeros(area))
	return {{w(near, v0.z), w(near, v1.z), w(near, v2.z)}, u32(max(0, bits - PERSP_AREA_BITS))}
}

// A coordinate n / d in 256ths, rounded down; d is sum(a w) and n
// sum(a t w), with t below 256, so in range |n| < 2^54 and d < 2^46.
@(private)
persp_coord :: #force_inline proc(n, d: i64) -> i32 {
	if d <= 0 {
		return 0
	}
	n := n * 256
	if n >= d << 17 {
		return 1 << 17
	}
	if n < -(d << 16) {
		return -(1 << 16)
	}
	q := n / d
	if n % d < 0 {
		q -= 1
	}
	return i32(q)
}

// sum(a u w), sum(a v w) and sum(a w) for edge weights a0, a1, a2.
@(private)
persp_sums :: #force_inline proc(a0, a1, a2: i64, v0, v1, v2: Vertex, p: Persp) -> (u, v, d: i64) {
	q0, q1, q2 := (a0 >> p.shift) * p.w[0], (a1 >> p.shift) * p.w[1], (a2 >> p.shift) * p.w[2]
	return q0 * i64(v0.u) + q1 * i64(v1.u) + q2 * i64(v2.u), q0 * i64(v0.v) + q1 * i64(v1.v) + q2 * i64(v2.v), q0 + q1 + q2
}

// VRAM pixels a texel of polygon vs spans, in 256ths: the square root of
// its screen area over its texture area, at least one (a texture shrunk
// gets the plain mix), at most SHARP_MAX.
@(private)
polygon_sharp :: proc(vs: []Vertex) -> i32 {
	tri :: proc(a, b, c: [2]i64) -> i64 {return abs((b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x))}
	xy, uv: [4][2]i64
	for v, k in vs {
		xy[k], uv[k] = {i64(v.x), i64(v.y)}, {i64(v.u), i64(v.v)}
	}
	screen, texture := tri(xy[0], xy[1], xy[2]), tri(uv[0], uv[1], uv[2])
	if len(vs) == 4 {
		screen += tri(xy[1], xy[2], xy[3])
		texture += tri(uv[1], uv[2], uv[3])
	}
	if screen * 256 * 256 >= texture * SHARP_MAX * SHARP_MAX {
		return SHARP_MAX
	}
	return max(256, i32(math.sqrt(f64(screen * 256 * 256) / f64(texture))))
}

// A mix weight f (256ths, smooth_split) steepened by sharpness k (hi-res
// pixels a texel spans, in 256ths): the blend between two texels takes one
// pixel instead of the texel's width.
@(private)
sharp_weight :: #force_inline proc(f, k: i32) -> i32 {
	return clamp(((f - 128) * k >> 8) + 128, 0, 256)
}

// Hi-res pixel c at view depth z mixed toward f's colour (Fog).
@(private)
fog_mix :: #force_inline proc(c: u32, z: f32, f: ^Fog) -> u32 {
	w := i32(clamp((z - f.near) * f.inv, 0, 1) * f32(f.most))
	if w <= 0 {
		return c
	}
	out := c & HI_MASK
	for sh in u32(0) ..< 3 {
		a, b := i32(c >> (8 * sh) & 255), i32(f.color >> (8 * sh) & 255)
		out |= u32((a * (256 - w) + b * w + 128) >> 8) << (8 * sh)
	}
	return out
}

// smooth_split for a coordinate t in 256ths (persp_coord).
@(private)
smooth_split_p :: #force_inline proc(t, lo, hi: i32) -> (i0, i1, f: i32) {
	q := t >> 8
	return clamp(q, lo, hi), clamp(q + 1, lo, hi), t & 255
}

// The four texels sm names mixed by its weights, as a hi-res target pixel
// (8 bits a channel). A clear texel (0) takes the nearest texel's colour,
// so the sprite's edge stays where the nearest texel puts it; the mask bit
// is the nearest texel's.
@(private)
smooth_texel :: proc(st: ^Draw_State, m: ^Prim_Mode, sm: ^Smooth, near: u16) -> u32 #no_bounds_check {
	q := [4]u16 {
		texel(st, m, sm.u0, sm.v0),
		texel(st, m, sm.u1, sm.v0),
		texel(st, m, sm.u0, sm.v1),
		texel(st, m, sm.u1, sm.v1),
	}
	for &t in q {
		if t == 0 {
			t = near
		}
	}
	out := u32(near & 0x8000) << 16
	for i in u32(0) ..< 3 {
		c: [4]i32
		for t, j in q {
			c[j] = i32(t >> (5 * i) & 31) << 3
		}
		top := c[0] * (256 - sm.fu) + c[1] * sm.fu
		bottom := c[2] * (256 - sm.fu) + c[3] * sm.fu
		out |= u32((top * (256 - sm.fv) + bottom * sm.fv + 32768) >> 16) << (16 - 8 * i)
	}
	return out
}

@(private)
blend :: proc {
	blend5,
	blend8,
}

@(private)
blend5 :: proc(abr: u32, back, front: u16) -> u16 #no_bounds_check {
	br, bg, bb := i32(back & 31), i32((back >> 5) & 31), i32((back >> 10) & 31)
	fr, fg, fb := i32(front & 31), i32((front >> 5) & 31), i32((front >> 10) & 31)
	r, g, b: i32
	switch abr {
	case 0:
		r, g, b = (br + fr) >> 1, (bg + fg) >> 1, (bb + fb) >> 1
	case 1:
		r, g, b = br + fr, bg + fg, bb + fb
	case 2:
		r, g, b = br - fr, bg - fg, bb - fb
	case:
		r, g, b = br + (fr >> 2), bg + (fg >> 2), bb + (fb >> 2)
	}
	r = clamp(r, 0, 31)
	g = clamp(g, 0, 31)
	b = clamp(b, 0, 31)
	return u16(r) | u16(g) << 5 | u16(b) << 10 | (front & 0x8000)
}

// blend5 at 8 bits a channel (hi-res target pixels).
@(private)
blend8 :: proc(abr: u32, back, front: u32) -> u32 #no_bounds_check {
	out := front & HI_MASK
	for shift in ([3]u32{0, 8, 16}) {
		b, f := i32((back >> shift) & 255), i32((front >> shift) & 255)
		v: i32
		switch abr {
		case 0:
			v = (b + f) >> 1
		case 1:
			v = b + f
		case 2:
			v = b - f
		case:
			v = b + (f >> 2)
		}
		out |= u32(clamp(v, 0, 255)) << shift
	}
	return out
}

// Lay each target's ghost layer over it and clear it.
gpu_ghost_flush :: proc() {
	// With VRAM's draws still running on the stream, its threads lay VRAM's
	// layer after them; the GPU target's only needs its queue submitted.
	streamed := stream_live()
	if !streamed {
		sync_cause = .Ghost
		raster_sync()
		sync_cause = .Other
	}
	for &t in drawn_targets() {
		g := &t.ghost
		if t.gl {
			gl_ghost_flush(&t)
		} else if streamed && t.shift == 0 {
			stream_ghost_flush(&t)
			continue
		} else if t.shift > 0 {
			k := t.shift
			hi_touch(g.lo.x >> k, g.lo.y >> k, ((g.hi.x - 1) >> k) - (g.lo.x >> k) + 1, ((g.hi.y - 1) >> k) - (g.lo.y >> k) + 1)
			raster_parallel(proc(band, bands: i32, data: rawptr) {
					t := (^Target)(data)
					y0, y1 := band_run(t.ghost.lo.y, t.ghost.hi.y, band, bands)
					ghost_rows(u32, t, y0, y1, t.ghost.lo.x, t.ghost.hi.x)
				}, &t)
		} else {
			ghost_rows(u16, &t, g.lo.y, g.hi.y, g.lo.x, g.hi.x)
		}
		g.lo, g.hi = {t.w, t.h}, {0, 0}
	}
}

// Lay target t's ghost layer over it in rows y0 ..< y1, columns x0 ..< x1.
@(private)
ghost_rows :: proc($P: typeid, t: ^Target, y0, y1, x0, x1: i32) #no_bounds_check {
	g := &t.ghost
	pix, gp := target_pix(t, P), ghost_pix(g, P)
	M := pixel_kept(P)
	for y in y0 ..< y1 {
		for x in x0 ..< x1 {
			i := y * t.w + x
			if a := g.alpha[i]; a != 0 {
				pix[i] = fade_mix(pix[i], gp[i], f32(a) / 255) &~ M | pix[i] & M
				g.alpha[i] = 0
			}
		}
	}
}

// Lay the rows pass ra owns of its target's ghost layer over it, in the box
// lo ..< hi joined with the ghosts ra drew, and clear them (a stream job).
@(private)
ghost_band :: proc($P: typeid, ra: ^Raster, lo, hi: [2]i32) {
	x0, y0 := min(lo.x, ra.lo.x), min(lo.y, ra.lo.y)
	x1, y1 := max(hi.x, ra.hi.x), max(hi.y, ra.hi.y)
	for y in y0 ..< y1 {
		if raster_mine(ra, y) {
			ghost_rows(P, ra.t, y, y + 1, x0, x1)
		}
	}
	ra.lo, ra.hi = {ra.t.w, ra.t.h}, {0, 0}
}

// Draw triangles too big for the PS1 GPU (1024 wide or 512 tall), which it
// leaves out, when their corners' depths are known and in front of the lens; set
// during an ordering-table walk with see_through. Under a
// close camera, floor polygons running under the lens have corners projected
// far off screen, and leaving them out leaves holes.
@(private)
gpu_big_triangles: bool

// `front` over `back` at opacity a (0..1); the mask bit is front's.
@(private)
fade_mix :: proc {
	fade_mix5,
	fade_mix8,
}

@(private)
fade_mix5 :: proc(back, front: u16, a: f32) -> u16 {
	out := front & 0x8000
	for shift in ([3]u16{0, 5, 10}) {
		b, f := f32((back >> shift) & 31), f32((front >> shift) & 31)
		out |= u16(b + (f - b) * a + 0.5) << shift
	}
	return out
}

// fade_mix5 at 8 bits a channel (hi-res target pixels).
@(private)
fade_mix8 :: proc(back, front: u32, a: f32) -> u32 {
	out := front & HI_MASK
	for shift in ([3]u32{0, 8, 16}) {
		b, f := f32((back >> shift) & 255), f32((front >> shift) & 255)
		out |= u32(b + (f - b) * a + 0.5) << shift
	}
	return out
}

// Offsets the GPU adds to 8-bit colors before cutting them to 5 bits, by
// screen position (y & 3, x & 3).
@(private)
DITHER := [4][4]i32{{-4, 0, -3, 1}, {2, -2, 3, -1}, {-3, 1, -4, 0}, {3, -1, 2, -2}}

// An 8-bit color channel plus dither offset d, cut to 5 bits.
@(private)
to5 :: #force_inline proc(c, d: i32) -> u16 {
	return u16(clamp(c + d, 0, 255) >> 3)
}

// An 8-bit color channel, kept at 8 bits (hi-res target pixels).
@(private)
to8 :: #force_inline proc(c: i32) -> u32 {
	return u32(clamp(c, 0, 255))
}

// Shade and write one pixel of the pass's target at its x, y. r,g,b are 8-bit vertex
// colors; z is the view depth (0 unknown), which fades the pixel by
// see_alpha, as a pixel of a face covering the leader as m.cover says. P is
// the target's pixel type (target_pix). u, v is the nearest texel; sm, when
// not nil, the texels a smoothed pixel mixes (hi-res target only).
@(private)
plot :: #force_inline proc($P: typeid, ra: ^Raster, m: ^Prim_Mode, x, y: i32, r, g, b: i32, u, v: i32, z: f32, sm: ^Smooth = nil) #no_bounds_check {
	t, e := ra.t, ra.e
	vx, vy := x & (t.w - 1), y & (t.h - 1)
	i := vy * t.w + vx
	M := pixel_mask(P)
	dst := &target_pix(t, P)[i]
	if e.st.check_mask && dst^ & M != 0 {
		return
	}
	// Where the pixel samples the scene, as packets hold positions.
	px := f32(x) * t.unit - f32(e.st.off_x)
	py := f32(y) * t.unit - f32(e.st.off_y)
	if e.portal != nil && !portal_lets(e.portal, px + 0.5 * t.unit, py + 0.5 * t.unit) {
		return
	}
	// The depth the depth buffer tests (depth_buffer.odin), 0 for none.
	zd: f32
	when P == u32 {
		if m.z_mode != .Off && e.z_key != 0 && t.zbuf != nil {
			zd = m.z_plane == {} ? z : z_on_plane(m.z_plane, py)
			if zd > 0 && !z_test(t, i, e.z_key, zd, m.z_plane != {}) {
				return
			}
		}
	}
	alpha := f32(1)
	if z > 0 && e.see_active {
		alpha = see_alpha(px, py, z, m.cover)
		if alpha <= 0 {
			return
		}
	}
	under := dst^
	ghost := i32(-1)
	if alpha < 1 && m.flat {
		under = ghost_settle(&t.ghost, i, under, z)
	} else if alpha < 1 && !e.see_direct {
		dst, ghost = ghost_pixel(ra, vx, vy, i, under, z)
		if ghost < 0 {
			return
		}
	}
	c: P
	semi := m.semi
	tx: u16
	if m.textured {
		tx = texel(&e.st, m, u, v)
		if tx == 0 {
			return
		}
		semi = semi && tx & 0x8000 != 0
	}
	when P == u32 {
		if m.textured {
			// Only see-through texels are smoothed, unless smooth_all: a
			// sprite's solid ones stay sharp.
			t8: u32
			if sm != nil && (semi || m.smooth_all) {
				w := sm^
				if m.sharp > 0 {
					k := m.sharp << t.shift
					w.fu, w.fv = sharp_weight(w.fu, k), sharp_weight(w.fv, k)
				}
				t8 = smooth_texel(&e.st, m, &w, tx)
			} else {
				t8 = hi_pixel(tx)
			}
			if semi && m.flat && e.st.abr == 1 {
				t8 = glow_floor(t8)
			}
			if m.raw {
				c = t8
			} else {
				// Texel (8 bits) times color (0x80 = 1.0), kept at 8 bits.
				cr := to8(i32(t8 >> 16 & 255) * r >> 7)
				cg := to8(i32(t8 >> 8 & 255) * g >> 7)
				cb := to8(i32(t8 & 255) * b >> 7)
				c = cr << 16 | cg << 8 | cb | t8 & HI_MASK
			}
		} else {
			c = to8(r) << 16 | to8(g) << 8 | to8(b)
		}
		if e.fog.on && z > 0 && !semi {
			c = fog_mix(c, z, &e.fog)
		}
	} else {
		d := m.dither ? DITHER[y & 3][x & 3] : 0
		if m.raw {
			c = tx
		} else if m.textured {
			// Texel (5 bits) times color (0x80 = 1.0), at 8-bit precision.
			cr := to5(i32(tx & 31) * r >> 4, d)
			cg := to5(i32((tx >> 5) & 31) * g >> 4, d)
			cb := to5(i32((tx >> 10) & 31) * b >> 4, d)
			c = cr | cg << 5 | cb << 10 | (tx & 0x8000)
		} else {
			c = to5(r, d) | to5(g, d) << 5 | to5(b, d) << 10
		}
	}
	// A pixel without depth (the party's sprites, shadows) drawn after a
	// ghost stands before it, the ordering table says: the ghost is laid
	// down under it now rather than over it at the flush.
	if z <= 0 && e.see_active && !e.see_direct {
		dst^ = ghost_settle(&t.ghost, i, dst^, 0)
	}
	if semi {
		c = blend(e.st.abr, dst^, c)
		when P == u32 {
			if m.glow && e.st.abr == 1 {
				c |= HI_GLOW
				bloom_mark(t, vx, vy)
			}
		}
	}
	if e.st.set_mask {
		c |= M
	}
	switch {
	case ghost >= 0:
		t.ghost.alpha[ghost] = u8(max(1, alpha * 255))
		t.ghost.z[ghost] = z
	case alpha < 1:
		c = fade_mix(under, c, alpha)
	case z > 0 && e.see_active:
		ghost_take(&t.ghost, i, z)
	}
	if e.depth_on && ghost < 0 {
		pixel_door_put(t, i, m.door)
	}
	when P == u32 {
		if ghost < 0 {
			c = c &~ HI_DEPTH | (semi ? dst^ & HI_DEPTH : depth_bits(z))
		}
		if zd > 0 && m.z_mode == .Write && ghost < 0 && alpha >= 1 && !semi {
			z_write(t, i, e.z_key, zd)
		}
	}
	dst^ = c
}

// The pass's ghost layer pixel vx, vy (index i) and its index for a
// ghost at depth z, starting from the target pixel `under` when nothing was
// drawn there yet; index -1 when a nearer ghost holds it.
@(private)
ghost_pixel :: proc(ra: ^Raster, vx, vy, i: i32, under: $P, z: f32) -> (^P, i32) #no_bounds_check {
	g := &ra.t.ghost
	gp := ghost_pix(g, P)
	if g.alpha[i] == 0 {
		gp[i] = under
		ra.lo = {min(ra.lo.x, vx), min(ra.lo.y, vy)}
		ra.hi = {max(ra.hi.x, vx + 1), max(ra.hi.y, vy + 1)}
	} else if z > g.z[i] {
		return nil, -1
	}
	return &gp[i], i
}

// The target pixel `under` at index i with any ghost behind depth z laid
// over it, that ghost spent: a faded pixel at z then blends over both.
@(private)
ghost_settle :: proc(g: ^Ghost_Layer, i: i32, under: $P, z: f32) -> P #no_bounds_check {
	if g.alpha[i] == 0 || g.z[i] <= z {
		return under
	}
	a := f32(g.alpha[i]) / 255
	g.alpha[i] = 0
	M := pixel_kept(P)
	return fade_mix(under, ghost_pix(g, P)[i], a) &~ M | under & M
}

// A solid pixel at depth z drawn at index i hides any ghost behind it there.
@(private)
ghost_take :: #force_inline proc(g: ^Ghost_Layer, i: i32, z: f32) #no_bounds_check {
	if g.alpha[i] != 0 && g.z[i] > z {
		g.alpha[i] = 0
	}
}

// Sub-pixel steps per pixel in Vertex.sx, sy.
SUB_PIXEL :: 16

// Edge weight of the point px, py (sixteenths of a pixel) against a, b.
@(private)
edge :: #force_inline proc(a, b: Vertex, px, py: i32) -> i64 {
	return i64(b.sx - a.sx) * i64(py - a.sy) - i64(b.sy - a.sy) * i64(px - a.sx)
}

// Top-left fill convention: an edge owns its pixels when it is a top edge or a left edge.
@(private)
owns_edge :: #force_inline proc(a, b: Vertex) -> bool {
	dy := b.sy - a.sy
	dx := b.sx - a.sx
	return dy < 0 || (dy == 0 && dx > 0)
}

// A vertex attribute along a row of a triangle. At barycentric weights
// w0..w2 (summing to area) the attribute is (w0*a0 + w1*a1 + w2*a2 + area/2)
// / area: the GPU steps attributes in fixed point from a half-unit bias, so a
// value lands on the nearest whole step; truncating instead reads one texel
// short along tile seams (black lines in battle backgrounds). The numerator
// grows by a constant per pixel, so the quotient is stepped with its
// remainder instead of divided at every pixel.
@(private)
Attr_Step :: struct {
	q, r:   i64,
	dq, dr: i64,
}

// An attribute's step per pixel, numerator dn over area, as a whole part q
// and a remainder r in 0 ..< area: worked out once per triangle (tri_setup)
// rather than on every row.
@(private)
Attr_Rate :: struct {
	q, r: i64,
}

@(private)
attr_rate :: #force_inline proc(d0, d1, d2: i64, a0, a1, a2: i32, area: i64) -> Attr_Rate {
	dn := d0 * i64(a0) + d1 * i64(a1) + d2 * i64(a2)
	s := Attr_Rate{dn / area, dn % area}
	if s.r < 0 {
		s.q -= 1
		s.r += area
	}
	return s
}

// Start an attribute at numerator n (weights w0..w2 of the first pixel) with
// step d per pixel. Weights may be a little negative just outside an edge (a
// finer target's sample point, draw_triangle).
@(private)
attr_start :: #force_inline proc(w0, w1, w2: i64, a0, a1, a2: i32, d: Attr_Rate, area: i64) -> Attr_Step {
	n := w0 * i64(a0) + w1 * i64(a1) + w2 * i64(a2) + area / 2
	s := Attr_Step{n / area, n % area, d.q, d.r}
	if s.r < 0 {
		s.q -= 1
		s.r += area
	}
	return s
}

@(private)
attr_next :: #force_inline proc(s: ^Attr_Step, area: i64) {
	s.q += s.dq
	s.r += s.dr
	if s.r >= area {
		s.q += 1
		s.r -= area
	}
}

// A triangle set up for drawing into a target: corners wound one way, its
// pixel box there (draw area applied), edge biases and weight steps per
// pixel, attribute steps, and the texels it may read (texels_read).
@(private)
Tri :: struct {
	v0, v1, v2:                 Vertex,
	area:                       i64,
	min_x, max_x, min_y, max_y: i32,
	b0, b1, b2:                 i64,
	d0, d1, d2:                 i64,
	dr, dg, db, du, dv:         Attr_Rate,
	ao0, ao1, ao2:              i64,
	u_lo, u_hi, v_lo, v_hi:     i32,
	persp:                      bool,
	pw:                         Persp,
	read:                       Texels_Read,
}

// Set up triangle va, vb, vc for target t under draw state st into tri,
// in place (a returned Tri is zeroed and copied on every triangle); false
// when it draws nothing, leaving tri part written.
@(private)
tri_setup :: proc(tri: ^Tri, t: ^Target, st: ^Draw_State, m: ^Prim_Mode, va, vb, vc: Vertex) -> bool #no_bounds_check {
	v0, v1, v2 := va, vb, vc
	area := edge(v0, v1, v2.sx, v2.sy)
	if area == 0 {
		return false
	}
	if area < 0 {
		v1, v2 = v2, v1
		area = -area
	}
	// Target pixels sit on whole steps of `step` sixteenths of a VRAM pixel:
	// the box's first and last.
	k := t.shift
	step := i32(SUB_PIXEL) >> k
	first :: #force_inline proc(s: i32, k: u32) -> i32 {return -((-s) >> (4 - k))}
	last :: #force_inline proc(s: i32, k: u32) -> i32 {return s >> (4 - k)}
	tri.min_x = max(first(min(v0.sx, v1.sx, v2.sx), k), st.x1 << k)
	tri.max_x = min(last(max(v0.sx, v1.sx, v2.sx), k), (st.x2 << k) + (1 << k) - 1)
	tri.min_y = max(first(min(v0.sy, v1.sy, v2.sy), k), st.y1 << k)
	tri.max_y = min(last(max(v0.sy, v1.sy, v2.sy), k), (st.y2 << k) + (1 << k) - 1)
	if tri.min_x > tri.max_x || tri.min_y > tri.max_y {
		return false
	}
	// Only a polygon whose corners all lie in front of the lens may be big:
	// one reaching behind it (filed at depth 1) was projected to nonsense.
	big := (gpu_big_triangles || m.world) && m.depth && min(va.z, vb.z, vc.z) > 1
	if !big &&
	   (max(v0.x, v1.x, v2.x) - min(v0.x, v1.x, v2.x) >= 1024 ||
			   max(v0.y, v1.y, v2.y) - min(v0.y, v1.y, v2.y) >= 512) {
		return false
	}
	tri.v0, tri.v1, tri.v2, tri.area = v0, v1, v2, area
	// Bias excludes pixels on edges that are not top/left.
	tri.b0 = owns_edge(v1, v2) ? 0 : -1
	tri.b1 = owns_edge(v2, v0) ? 0 : -1
	tri.b2 = owns_edge(v0, v1) ? 0 : -1
	// Weight change per pixel to the right.
	d0 := -i64(v2.sy - v1.sy) * i64(step)
	d1 := -i64(v0.sy - v2.sy) * i64(step)
	d2 := -i64(v1.sy - v0.sy) * i64(step)
	tri.d0, tri.d1, tri.d2 = d0, d1, d2
	tri.persp = m.persp && m.textured && min(v0.z, v1.z, v2.z) > 1
	if tri.persp {
		tri.pw = persp_setup(v0, v1, v2, area)
	}
	if !t.gl {
		tri_steps(tri, m, step)
	}
	// A finer target samples between the VRAM pixels and so can reach
	// texels the GPU never reads, such as the column past a scaled sprite's
	// edge (lines around sprites). It keeps to the texels the triangle reads
	// in VRAM. A sprite whose corners carry its anchor's sub-pixel part
	// reaches such texels at the VRAM scale too.
	off_pixel := (v0.sx | v1.sx | v2.sx | v0.sy | v1.sy | v2.sy) & (SUB_PIXEL - 1) != 0
	if (k > 0 || off_pixel) && m.textured {
		tri.read = texels_read(
			{v0, v1, v2},
			area,
			{tri.b0, tri.b1, tri.b2},
			{d0 << k, d1 << k, d2 << k},
			{max(first(min(v0.sx, v1.sx, v2.sx), 0), st.x1), min(last(max(v0.sx, v1.sx, v2.sx), 0), st.x2)},
			{max(first(min(v0.sy, v1.sy, v2.sy), 0), st.y1), min(last(max(v0.sy, v1.sy, v2.sy), 0), st.y2)},
			tri.persp,
			tri.pw,
		)
		if !tri.persp {
			texels_cell(&tri.read, v0, v1, v2)
		}
	} else {
		tri.read = {}
	}
	return true
}

// A sprite the third-person camera scales lands its pieces' edges between
// VRAM pixels, where rounding reads the texel past a piece's cell: the row
// under the top half of a body, transparent, cuts a line through the legs.
// For a triangle mapped straight onto the screen (u along x, v along y), the
// end each coordinate runs out at the right or bottom edge, which the GPU
// never draws at its own scale, is kept out of read.
@(private)
texels_cell :: proc(read: ^Texels_Read, v0, v1, v2: Vertex) {
	if !read.ok {
		return
	}
	x1, y1 := i64(v1.sx - v0.sx), i64(v1.sy - v0.sy)
	x2, y2 := i64(v2.sx - v0.sx), i64(v2.sy - v0.sy)
	area := x1 * y2 - x2 * y1
	u1, u2 := i64(v1.u - v0.u), i64(v2.u - v0.u)
	t1, t2 := i64(v1.v - v0.v), i64(v2.v - v0.v)
	// Each coordinate's change across and down, times area.
	du_x, du_y := u1 * y2 - u2 * y1, u2 * x1 - u1 * x2
	dv_x, dv_y := t1 * y2 - t2 * y1, t2 * x1 - t1 * x2
	if area == 0 || du_y != 0 || dv_x != 0 || du_x == 0 || dv_y == 0 {
		return
	}
	cell_end :: proc(r: ^[2]i32, lo, hi: i32, up: bool) {
		if up && r.y >= hi && r.y > r.x {
			r.y = hi - 1
		} else if !up && r.x <= lo && r.x < r.y {
			r.x = lo + 1
		}
	}
	cell_end(&read.u, min(v0.u, v1.u, v2.u), max(v0.u, v1.u, v2.u), (du_x > 0) == (area > 0))
	cell_end(&read.tv, min(v0.v, v1.v, v2.v), max(v0.v, v1.v, v2.v), (dv_y > 0) == (area > 0))
}

// What only tri_rows needs of a set-up triangle (the host GPU works these
// out itself): attribute steps, the sample point move, and the u, v ranges.
@(private)
tri_steps :: proc(tri: ^Tri, m: ^Prim_Mode, step: i32) #no_bounds_check {
	v0, v1, v2, area := tri.v0, tri.v1, tri.v2, tri.area
	d0, d1, d2 := tri.d0, tri.d1, tri.d2
	// Attribute change per pixel to the right, for the attributes tri_rows
	// steps: shades when gouraud, u and v when textured without perspective.
	if m.gouraud {
		tri.dr = attr_rate(d0, d1, d2, v0.r, v1.r, v2.r, area)
		tri.dg = attr_rate(d0, d1, d2, v0.g, v1.g, v2.g, area)
		tri.db = attr_rate(d0, d1, d2, v0.b, v1.b, v2.b, area)
	}
	if m.textured && !tri.persp {
		tri.du = attr_rate(d0, d1, d2, v0.u, v1.u, v2.u, area)
		tri.dv = attr_rate(d0, d1, d2, v0.v, v1.v, v2.v, area)
	}
	// The GPU reads a VRAM pixel's attributes at its top-left corner, for
	// the whole pixel. A finer target pixel reads them at its middle moved
	// back by half a VRAM pixel, so the pixels inside one VRAM pixel read
	// around its corner: a sprite's last texel column then covers its last
	// VRAM pixel whichever way u runs, instead of half of them rounding onto
	// the texel past the edge (lines around sprites). ao* are the weights'
	// change for that move.
	o := i64(step / 2 - SUB_PIXEL / 2)
	tri.ao0 = o * (i64(v2.sx - v1.sx) - i64(v2.sy - v1.sy))
	tri.ao1 = o * (i64(v0.sx - v2.sx) - i64(v0.sy - v2.sy))
	tri.ao2 = o * (i64(v1.sx - v0.sx) - i64(v1.sy - v0.sy))
	tri.u_lo, tri.u_hi = min(v0.u, v1.u, v2.u), max(v0.u, v1.u, v2.u)
	tri.v_lo, tri.v_hi = min(v0.v, v1.v, v2.v), max(v0.v, v1.v, v2.v)
}

// Draw the pass's rows of a set-up triangle.
@(private)
tri_rows :: proc($P: typeid, ra: ^Raster, m: ^Prim_Mode, tri: ^Tri) #no_bounds_check {
	v0, v1, v2, area := tri.v0, tri.v1, tri.v2, tri.area
	b0, b1, b2 := tri.b0, tri.b1, tri.b2
	d0, d1, d2 := tri.d0, tri.d1, tri.d2
	ao0, ao1, ao2 := tri.ao0, tri.ao1, tri.ao2
	min_x, max_x := tri.min_x, tri.max_x
	u_lo, u_hi, v_lo, v_hi := tri.u_lo, tri.u_hi, tri.v_lo, tri.v_hi
	persp := tri.persp
	linear := m.textured && !persp
	read := tri.read
	smooth := P == u32 && m.smooth && m.textured
	// The texels smoothing may read: those the triangle reads in VRAM.
	su, sv := [2]i32{u_lo, u_hi}, [2]i32{v_lo, v_hi}
	if read.ok {
		su, sv = read.u, read.tv
	}
	step := i32(SUB_PIXEL) >> ra.t.shift
	for y := tri.min_y; y <= tri.max_y; y += 1 {
		if !raster_mine(ra, y) {
			continue
		}
		w0 := edge(v1, v2, min_x * step, y * step)
		w1 := edge(v2, v0, min_x * step, y * step)
		w2 := edge(v0, v1, min_x * step, y * step)
		// The row's covered span: a triangle covers one contiguous span per
		// row, pixels min_x + s0 ..= min_x + s1.
		s0, s1 := i64(0), i64(max_x - min_x)
		span_clip(w0 + b0, d0, &s0, &s1)
		span_clip(w1 + b1, d1, &s0, &s1)
		span_clip(w2 + b2, d2, &s0, &s1)
		if s0 > s1 {
			continue
		}
		x := min_x + i32(s0)
		x_end := min_x + i32(s1)
		w0 += d0 * s0
		w1 += d1 * s0
		w2 += d2 * s0
		// 1 / depth runs straight across the screen.
		iz, diz: f32
		if m.depth {
			fa := f32(area)
			iz = (f32(w0) / v0.z + f32(w1) / v1.z + f32(w2) / v2.z) / fa
			diz = (f32(d0) / v0.z + f32(d1) / v1.z + f32(d2) / v2.z) / fa
		}
		a0, a1, a2 := w0 + ao0, w1 + ao1, w2 + ao2
		// Perspective texture coordinates: sum(a t w) and sum(a w) run
		// straight across the screen (persp_coord); stepped when unshifted,
		// else worked out from the stepped weights.
		pu, pv, pd, dpu, dpv, dpd: i64
		if persp {
			pu, pv, pd = persp_sums(a0, a1, a2, v0, v1, v2, tri.pw)
			dpu, dpv, dpd = persp_sums(d0, d1, d2, v0, v1, v2, {tri.pw.w, 0})
		}
		// Only the attributes the pixels use are stepped (tri_setup).
		r, g, b, u, v: Attr_Step
		if m.gouraud {
			r = attr_start(a0, a1, a2, v0.r, v1.r, v2.r, tri.dr, area)
			g = attr_start(a0, a1, a2, v0.g, v1.g, v2.g, tri.dg, area)
			b = attr_start(a0, a1, a2, v0.b, v1.b, v2.b, tri.db, area)
		}
		if linear {
			u = attr_start(a0, a1, a2, v0.u, v1.u, v2.u, tri.du, area)
			v = attr_start(a0, a1, a2, v0.v, v1.v, v2.v, tri.dv, area)
		}
		for ; x <= x_end; x += 1 {
			z := iz > 0 ? 1 / iz : 0
			tu, tv := i32(u.q), i32(v.q)
			sm: Smooth
			smp: ^Smooth
			if persp {
				if tri.pw.shift > 0 {
					pu, pv, pd = persp_sums(a0, a1, a2, v0, v1, v2, tri.pw)
					a0 += d0
					a1 += d1
					a2 += d2
				}
				pt := [2]i32{persp_coord(pu, pd), persp_coord(pv, pd)}
				// Nearest texel, kept within the corners' coordinates.
				tu = clamp((pt.x + 128) >> 8, u_lo, u_hi)
				tv = clamp((pt.y + 128) >> 8, v_lo, v_hi)
				if smooth {
					sm.u0, sm.u1, sm.fu = smooth_split_p(pt.x, su.x, su.y)
					sm.v0, sm.v1, sm.fv = smooth_split_p(pt.y, sv.x, sv.y)
					smp = &sm
				}
				pu += dpu
				pv += dpv
				pd += dpd
			} else if smooth {
				sm.u0, sm.u1, sm.fu = smooth_split(u, area, su.x, su.y)
				sm.v0, sm.v1, sm.fv = smooth_split(v, area, sv.x, sv.y)
				smp = &sm
			}
			if read.ok {
				tu = clamp(tu, read.u.x, read.u.y)
				tv = clamp(tv, read.tv.x, read.tv.y)
			}
			if m.gouraud {
				plot(P, ra, m, x, y, i32(r.q), i32(g.q), i32(b.q), tu, tv, z, smp)
			} else {
				plot(P, ra, m, x, y, v0.r, v0.g, v0.b, tu, tv, z, smp)
			}
			iz += diz
			if m.gouraud {
				attr_next(&r, area)
				attr_next(&g, area)
				attr_next(&b, area)
			}
			if linear {
				attr_next(&u, area)
				attr_next(&v, area)
			}
		}
	}
}

// The least and most u, v a triangle reads in VRAM; ok false when it covers
// no VRAM pixel. u and v run straight along a row (u / depth and v / depth
// with perspective), so each row's ends read its least and most.
@(private)
Texels_Read :: struct {
	ok:    bool,
	u, tv: [2]i32,
}

// For draw_triangle: corners v, edge biases b and weight steps d per VRAM
// pixel, the VRAM pixel box xs, ys (inclusive). Four rows go through at once,
// one per f64 lane: every weight, product and quotient stays a whole number
// below 2^53, so the lanes work it out exactly as the integer rows would.
@(private)
texels_read :: proc(v: [3]Vertex, area: i64, b, d: [3]i64, xs, ys: [2]i32, persp: bool, pw: Persp) -> Texels_Read #no_bounds_check {
	F :: #simd[4]f64
	LANE :: F{0, 1, 2, 3}
	// a / d rounded down, for whole a and d > 0: the quotient's rounding
	// leaves it at most one off, which the remainder puts right.
	floor_div :: #force_inline proc(a: F, d: f64) -> F {
		q := simd.floor(a / F(d))
		r := a - q * F(d)
		q = simd.select(simd.lanes_lt(r, F(0)), q - 1, q)
		return simd.select(simd.lanes_ge(r, F(d)), q + 1, q)
	}
	// span_clip in lanes.
	clip :: #force_inline proc(w: F, b, d: f64, s0, s1: ^F) {
		w := w + F(b)
		neg := simd.lanes_lt(w, F(0))
		switch {
		case d > 0:
			s0^ = simd.max(s0^, simd.select(neg, floor_div(-w + F(d - 1), d), F(0)))
		case d < 0:
			s1^ = simd.select(neg, F(-1), simd.min(s1^, floor_div(w, -d)))
		case:
			s1^ = simd.select(neg, F(-1), s1^)
		}
	}
	// The texels read at weights w0, w1, w2, as draw_triangle reads them.
	at :: #force_inline proc(v0, v1, v2: Vertex, area: i64, persp: bool, pw: Persp, w0, w1, w2: F) -> [2]F {
		if persp {
			a0, a1, a2 := transmute([4]f64)w0, transmute([4]f64)w1, transmute([4]f64)w2
			tu, tv: [4]f64
			for l in 0 ..< 4 {
				u, v, d := persp_sums(i64(a0[l]), i64(a1[l]), i64(a2[l]), v0, v1, v2, pw)
				tu[l] = f64(clamp((persp_coord(u, d) + 128) >> 8, min(v0.u, v1.u, v2.u), max(v0.u, v1.u, v2.u)))
				tv[l] = f64(clamp((persp_coord(v, d) + 128) >> 8, min(v0.v, v1.v, v2.v), max(v0.v, v1.v, v2.v)))
			}
			return {transmute(F)tu, transmute(F)tv}
		}
		// Covered weights are not negative, so the integer division's
		// rounding toward zero is rounding down.
		half, fa := f64(area / 2), f64(area)
		return {
			floor_div(w0 * F(f64(v0.u)) + w1 * F(f64(v1.u)) + w2 * F(f64(v2.u)) + F(half), fa),
			floor_div(w0 * F(f64(v0.v)) + w1 * F(f64(v1.v)) + w2 * F(f64(v2.v)) + F(half), fa),
		}
	}
	v0, v1, v2 := v[0], v[1], v[2]
	px, py := xs.x * SUB_PIXEL, ys.x * SUB_PIXEL
	// Each edge's weight at the box's first row and its change per row.
	e0, e1, e2 := f64(edge(v1, v2, px, py)), f64(edge(v2, v0, px, py)), f64(edge(v0, v1, px, py))
	r0, r1, r2 := f64((v2.sx - v1.sx) * SUB_PIXEL), f64((v0.sx - v2.sx) * SUB_PIXEL), f64((v1.sx - v0.sx) * SUB_PIXEL)
	b0, b1, b2 := f64(b[0]), f64(b[1]), f64(b[2])
	d0, d1, d2 := f64(d[0]), f64(d[1]), f64(d[2])
	rows, cols := f64(ys.y - ys.x), f64(xs.y - xs.x)
	BIG :: 1e18
	lo_u, hi_u, lo_v, hi_v := F(BIG), F(-BIG), F(BIG), F(-BIG)
	ok := false
	for y := f64(0); y <= rows; y += 4 {
		row := LANE + F(y)
		w0 := F(e0) + row * F(r0)
		w1 := F(e1) + row * F(r1)
		w2 := F(e2) + row * F(r2)
		s0, s1 := F(0), F(cols)
		clip(w0, b0, d0, &s0, &s1)
		clip(w1, b1, d1, &s0, &s1)
		clip(w2, b2, d2, &s0, &s1)
		live := simd.lanes_le(s0, s1) & simd.lanes_le(row, F(rows))
		if simd.reduce_or(live) == 0 {
			continue
		}
		ok = true
		// The row's two ends.
		t := at(v0, v1, v2, area, persp, pw, w0 + F(d0) * s0, w1 + F(d1) * s0, w2 + F(d2) * s0)
		e := at(v0, v1, v2, area, persp, pw, w0 + F(d0) * s1, w1 + F(d1) * s1, w2 + F(d2) * s1)
		lo_u = simd.select(live, simd.min(lo_u, simd.min(t[0], e[0])), lo_u)
		hi_u = simd.select(live, simd.max(hi_u, simd.max(t[0], e[0])), hi_u)
		lo_v = simd.select(live, simd.min(lo_v, simd.min(t[1], e[1])), lo_v)
		hi_v = simd.select(live, simd.max(hi_v, simd.max(t[1], e[1])), hi_v)
	}
	if !ok {
		return {u = {max(i32), min(i32)}, tv = {max(i32), min(i32)}}
	}
	return {
		ok = true,
		u = {i32(simd.reduce_min(lo_u)), i32(simd.reduce_max(hi_u))},
		tv = {i32(simd.reduce_min(lo_v)), i32(simd.reduce_max(hi_v))},
	}
}

// Narrow the steps s0 ..= s1 along a row to those where an edge weight w
// (bias included) growing by d per step stays non-negative.
@(private)
span_clip :: #force_inline proc(w, d: i64, s0, s1: ^i64) {
	switch {
	case d > 0:
		if w < 0 {
			s0^ = max(s0^, (-w + d - 1) / d)
		}
	case d < 0:
		if w < 0 {
			s1^ = -1
		} else {
			s1^ = min(s1^, w / -d)
		}
	case w < 0:
		s1^ = -1
	}
}

@(private)
draw_rect :: proc($P: typeid, ra: ^Raster, m: ^Prim_Mode, x0, y0, w, h: i32, r, g, b: i32, u0, v0: i32) #no_bounds_check {
	st := &ra.e.st
	k := ra.t.shift
	xs := max(x0, st.x1) << k
	xe := ((min(x0 + w - 1, st.x2) + 1) << k) - 1
	ys := max(y0, st.y1) << k
	ye := ((min(y0 + h - 1, st.y2) + 1) << k) - 1
	du: i32 = st.flip_x ? -1 : 1
	dv: i32 = st.flip_y ? -1 : 1
	for y := ys; y <= ye; y += 1 {
		if !raster_mine(ra, y) {
			continue
		}
		for x := xs; x <= xe; x += 1 {
			plot(P, ra, m, x, y, r, g, b, u0 + ((x >> k) - x0) * du, v0 + ((y >> k) - y0) * dv, 0)
		}
	}
}

// Plot VRAM pixel x, y as the block of target pixels covering it.
@(private)
plot_block :: proc($P: typeid, ra: ^Raster, m: ^Prim_Mode, x, y: i32, r, g, b: i32) {
	k := ra.t.shift
	n := i32(1) << k
	for dy in 0 ..< n {
		if !raster_mine(ra, y << k + dy) {
			continue
		}
		for dx in 0 ..< n {
			plot(P, ra, m, x << k + dx, y << k + dy, r, g, b, 0, 0, 0)
		}
	}
}

@(private)
draw_line :: proc($P: typeid, ra: ^Raster, m: ^Prim_Mode, a, b: Vertex) {
	st := &ra.e.st
	dx := b.x - a.x
	dy := b.y - a.y
	if abs(dx) >= 1024 || abs(dy) >= 512 {
		return
	}
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
			plot_block(P, ra, m, x, y, r, g, bl)
		}
	}
}

// Colours for a black fill_rect in the hi-res target, one per target row
// from the fill's top (rows[:h << shift]); false keeps the fill black. VRAM
// stays black either way. qol's sky behind the third-person field
// (backdrop.odin).
backdrop_hook: proc(x, y, w, h: i32, shift: u32, rows: []u32) -> bool

@(private)
backdrop_rows: [512 << 2]u32

// Fill a VRAM rectangle, ignoring draw area, offset and mask (GP0 02 / ClearImage).
fill_rect :: proc(x, y, w, h: i32, c: u16) {
	raster_sync()
	hi_cover(x, y, w, h)
	f := Fill{x = x, y = y, w = w, h = h, c = c}
	for &t in live_targets() {
		f.t = &t
		f.rows = nil
		if t.shift > 0 && c == 0 && backdrop_hook != nil && h <= 512 {
			rows := backdrop_rows[:h << t.shift]
			if backdrop_hook(x, y, w, h, t.shift, rows) {
				f.rows = rows
			}
		}
		if t.gl {
			gl_fill(x, y, w, h, c, f.rows)
		} else if t.shift > 0 {
			raster_parallel(proc(band, bands: i32, data: rawptr) {
					f := (^Fill)(data)
					y0, y1 := band_run(0, f.h << f.t.shift, band, bands)
					fill_rows(u32, f, y0, y1)
				}, &f)
		} else {
			fill_rows(u16, &f, 0, h)
		}
	}
}

@(private)
Fill :: struct {
	t:          ^Target,
	x, y, w, h: i32,
	c:          u16,
	// The hi-res target's colour per row instead of c (backdrop_hook).
	rows:       []u32,
}

// Fill rows y0 ..< y1 (target pixels from the top) of f in its target.
@(private)
fill_rows :: proc($P: typeid, f: ^Fill, y0, y1: i32) #no_bounds_check {
	t := f.t
	when P == u32 {
		c := hi_pixel(f.c)
	} else {
		c := f.c
	}
	k := t.shift
	// A row wraps at the target's right edge at most once: the part from
	// x to the edge, then the rest from column 0.
	n := min(f.w << k, t.w)
	if n <= 0 {
		return
	}
	x0 := (f.x << k) & (t.w - 1)
	first := min(n, t.w - x0)
	doors := depth_walk.on
	for yy in y0 ..< y1 {
		row := ((f.y << k + yy) & (t.h - 1)) * t.w
		when P == u32 {
			if f.rows != nil {
				c = f.rows[yy]
			}
		}
		fill_run(t, row + x0, first, c, doors)
		fill_run(t, row, n - first, c, doors)
	}
}

// Set n pixels of t from index i to c, and with doors their door tags to
// clear.
@(private)
fill_run :: #force_inline proc(t: ^Target, i, n: i32, c: $P, doors: bool) #no_bounds_check {
	if n <= 0 {
		return
	}
	slice.fill(target_pix(t, P)[i:][:n], c)
	if doors {
		slice.fill(t.door[i:][:n], DOOR_CLEAR)
		slice.fill(t.walk[i:][:n], depth_walk.now)
	}
}

rgb24_to_15 :: #force_inline proc(c: u32) -> u16 {
	return u16((c >> 3) & 31) | u16((c >> 11) & 31) << 5 | u16((c >> 19) & 31) << 10
}

@(private)
read_vertex :: proc(words: []u32, i: ^int, color: u32, textured: bool, m: ^Prim_Mode, first: bool) -> Vertex {
	v: Vertex
	v.r = i32(color & 0xff)
	v.g = i32((color >> 8) & 0xff)
	v.b = i32((color >> 16) & 0xff)
	xy := words[i^]
	i^ += 1
	v.x = sx11(xy) + gpu.off_x
	v.y = sx11(xy >> 16) + gpu.off_y
	v.sx = v.x * SUB_PIXEL
	v.sy = v.y * SUB_PIXEL
	if textured {
		uv := words[i^]
		i^ += 1
		v.u = i32(uv & 0xff)
		v.v = i32((uv >> 8) & 0xff)
		// First vertex's UV word carries the CLUT; the second carries the
		// texture page (applied by the caller).
		if first {
			hi := uv >> 16
			m.clut_x = i32(hi & 0x3f) * 16
			m.clut_y = i32((hi >> 6) & 0x1ff)
		}
	}
	return v
}

// Number of words a GP0 command occupies, or 0 for polylines (variable).
@(private)
cmd_len :: proc(op: u32) -> int {
	switch op >> 5 {
	case 1:
		verts := op & 0x08 != 0 ? 4 : 3
		per := op & 0x04 != 0 ? 2 : 1
		n := 1 + verts * per
		if op & 0x10 != 0 {
			n += verts - 1
		}
		return n
	case 2:
		if op & 0x08 != 0 {
			return 0
		}
		return op & 0x10 != 0 ? 4 : 3
	case 3:
		n := 2
		if op & 0x04 != 0 {
			n += 1
		}
		if op & 0x18 == 0 {
			n += 1
		}
		return n
	case 4:
		return 4
	case 5, 6:
		return 3
	}
	switch op {
	case 0x02:
		return 3
	}
	return 1
}

@(private)
exec_polygon :: proc(words: []u32) {
	op := words[0] >> 24
	m := Prim_Mode {
		textured = op & 0x04 != 0,
		raw      = op & 0x01 != 0,
		semi     = op & 0x02 != 0,
		gouraud  = op & 0x10 != 0,
	}
	if !m.textured {
		m.raw = false
	}
	m.dither = gpu.dither && (m.gouraud || m.textured && !m.raw)
	verts := op & 0x08 != 0 ? 4 : 3
	vs: [4]Vertex
	i := 1
	color := words[0] & 0xffffff
	for k in 0 ..< verts {
		if k > 0 && m.gouraud {
			color = words[i] & 0xffffff
			i += 1
		}
		vs[k] = read_vertex(words, &i, color, m.textured, &m, k == 0)
		if m.textured && k == 1 {
			set_tpage(words[i - 1] >> 16)
		}
	}
	// A world quad (world.odin) is drawn as its corners in view space cut
	// at the lens; the tests on the whole polygon take up to four of them.
	world: [WORLD_CORNERS]Vertex
	worlds := 0
	w: ^World_Quad
	in_world := false
	if verts == 4 {
		w, in_world = world_quad(packet_now)
	}
	screen := screens.n > 0 && on_screen(packet_now)
	if in_world {
		worlds, vs, verts = world_cut(w, vs, &world)
		if worlds == 0 {
			return
		}
		m.world = true
	} else if !screen {
		depth_fill(vs[:verts])
	}
	sprite_dump(vs[:verts], &m)
	if m.textured && m.raw {
		for &v in vs {
			v.r, v.g, v.b = 0x80, 0x80, 0x80
		}
	}
	if (blacks.n > 0 || blacks.all || cover_due()) && black_left_out(vs[:verts], &m) {
		return
	}
	// Corners the GTE did not project (cut by the game) take the depth of
	// those it did.
	known, sum: f32
	for v in vs[:verts] {
		if v.z > 0 {
			known += 1
			sum += v.z
		}
	}
	// Effects are drawn in 3D: menus, text and frames have no depth and
	// stay sharp.
	m.smooth = smooth_effects && m.textured && m.semi && known > 0
	if smooth_textures && m.textured && !m.smooth {
		m.sharp = polygon_sharp(vs[:verts])
	}
	m.glow = bloom_effects && m.textured && m.semi && known > 0
	// A sprite's corners take its anchor's sub-pixel part and where it
	// stands (see_flat_add).
	flat, front := false, false
	clear: f32
	if known == 0 && flats.n > 0 && !screen {
		if f, ok := see_flat(packet_now); ok {
			for &v in vs[:verts] {
				v.sx += i32(f.sub[0])
				v.sy += i32(f.sub[1])
			}
			if see.z_key != 0 && f.at.z > 0 {
				m.z_plane = z_sprite_plane(f.at)
				m.z_mode = m.z_plane == {} ? .Off : .Write
			}
			if see.active && f.z > 0 {
				for &v in vs[:verts] {
					v.z = f.z
				}
				known, sum, flat = f32(verts), f.z * f32(verts), true
				front, clear = f.front, f.clear
			}
		}
	}
	if m.sharp > 0 && known > 0 {
		m.smooth, m.smooth_all = true, true
	}
	if known > 0 {
		m.depth = true
		m.persp = known == f32(verts) && !flat
		if see.z_key != 0 && m.persp {
			m.z_mode = .Write
		}
		corners: [4][3]f32
		for &v, k in vs[:verts] {
			if v.z <= 0 {
				v.z = sum / known
			}
			corners[k] = {f32(v.x - gpu.off_x), f32(v.y - gpu.off_y), v.z}
		}
		// The party in front of a door's cover never fades (Flat.front),
		// but by its own Flat.clear.
		if see.active && !front {
			m.cover = see_cover(corners[:verts])
			if flat {
				m.cover = see_sprite_cover(vs[0].z)
				m.cover.clear = clear
				m.flat = true
			}
		} else if see.active && clear > 0 {
			m.cover = {sprite = true, clear = clear}
			m.flat = true
		}
		// A black face between the leader and the lens is the game's fill
		// for what its own camera never sees (a room's wall tops, the
		// curtain past its doorway): from behind the leader it hides the
		// floor he walks on, so it is left out. A thin one (a rope) is
		// drawn, and a town's are all drawn (its clotheslines are thin
		// strips seen edge on).
		if see.active && see.room && m.cover.weight > 0 && !m.cover.sprite && !m.semi && polygon_black(vs[:verts], &m) && !see_thin(corners[:verts]) {
			return
		}
		if cut.on && known == f32(verts) && !flat && cut_left_out(corners[:verts]) {
			return
		}
		if depth_walk.on && known == f32(verts) && !flat {
			if backs.n > 0 && back_left_out(corners[:verts]) {
				return
			}
			m.door = picture_back(corners[:verts])
		}
		// Sprites and the room's own doorway backs too: past the doorway
		// all of the room stands behind the town's wall. The party walking
		// in through it (Flat.front) stays in front.
		if depth_walk.on && m.door != DOOR_CLEAR && cover_due() && !front {
			m.door = DOOR_COVER
		}
	}
	e := plot_env()
	for &t in drawn_targets() {
		if in_world {
			// A fan over a convex polygon: its triangles cover distinct
			// pixels.
			gl_group(t.gl && worlds > 3)
			for k in 2 ..< worlds {
				draw_triangle(&t, &e, &m, world[0], world[k - 1], world[k])
			}
			gl_group(false)
			continue
		}
		// The halves of a proper quad cover distinct pixels: the GL queue
		// need not order them.
		group := t.gl && verts == 4 && quad_halves_apart(vs[0], vs[1], vs[2], vs[3])
		gl_group(group)
		draw_triangle(&t, &e, &m, vs[0], vs[1], vs[2])
		if verts == 4 {
			draw_triangle(&t, &e, &m, vs[1], vs[2], vs[3])
		}
		gl_group(false)
	}
}

@(private)
exec_rect :: proc(words: []u32) {
	op := words[0] >> 24
	m := Prim_Mode {
		textured = op & 0x04 != 0,
		raw      = op & 0x01 != 0,
		semi     = op & 0x02 != 0,
	}
	c := words[0]
	r, g, b := i32(c & 0xff), i32((c >> 8) & 0xff), i32((c >> 16) & 0xff)
	x := sx11(words[1]) + gpu.off_x
	y := sx11(words[1] >> 16) + gpu.off_y
	i := 2
	u, v: i32
	if m.textured {
		uv := words[i]
		i += 1
		u = i32(uv & 0xff)
		v = i32((uv >> 8) & 0xff)
		m.clut_x = i32((uv >> 16) & 0x3f) * 16
		m.clut_y = i32((uv >> 22) & 0x1ff)
		if m.raw {
			r, g, b = 0x80, 0x80, 0x80
		}
	}
	w, h: i32
	switch (op >> 3) & 3 {
	case 0:
		wh := words[i]
		w = i32(wh & 0x3ff)
		h = i32((wh >> 16) & 0x1ff)
	case 1:
		w, h = 1, 1
	case 2:
		w, h = 8, 8
	case 3:
		w, h = 16, 16
	}
	sprite_rect(u, v, w, h, &m)
	e := plot_env()
	for &t in drawn_targets() {
		rect_issue(&t, &e, &m, x, y, w, h, r, g, b, u, v)
	}
}

@(private)
exec_env :: proc(w: u32) {
	switch w >> 24 {
	case 0xe1:
		set_tpage(w & 0x9ff)
		gpu.dither = w & 0x200 != 0
		gpu.flip_x = w & 0x1000 != 0
		gpu.flip_y = w & 0x2000 != 0
	case 0xe2:
		gpu.tw_mask_x = w & 0x1f
		gpu.tw_mask_y = (w >> 5) & 0x1f
		gpu.tw_off_x = (w >> 10) & 0x1f
		gpu.tw_off_y = (w >> 15) & 0x1f
	case 0xe3:
		gpu.x1 = i32(w & 0x3ff)
		gpu.y1 = i32((w >> 10) & 0x1ff)
		hi_only.area_noted = false
	case 0xe4:
		gpu.x2 = i32(w & 0x3ff)
		gpu.y2 = i32((w >> 10) & 0x1ff)
		hi_only.area_noted = false
	case 0xe5:
		gpu.off_x = sx11(w)
		gpu.off_y = sx11(w >> 11)
	case 0xe6:
		gpu.set_mask = w & 1 != 0
		gpu.check_mask = w & 2 != 0
	}
}

// Execute a run of GP0 words (one OT packet body).
gp0_exec :: proc(words: []u32) {
	i := 0
	for i < len(words) {
		w := words[i]
		op := w >> 24
		n := cmd_len(op)
		if n == 0 {
			// Polyline: vertices until the 0x5xxx5xxx terminator.
			m := Prim_Mode {
				semi    = op & 0x02 != 0,
				gouraud = op & 0x10 != 0,
				dither  = gpu.dither && op & 0x10 != 0,
			}
			j := i + 1
			color := w & 0xffffff
			prev: Vertex
			have := false
			for j < len(words) && words[j] & 0xf000f000 != 0x50005000 {
				if m.gouraud && have {
					color = words[j] & 0xffffff
					j += 1
					if j >= len(words) {
						break
					}
				}
				k := j
				v := read_vertex(words, &k, color, false, &m, true)
				depth_fill(([^]Vertex)(&v)[:1])
				j = k
				if have {
					e := plot_env()
					for &t in drawn_targets() {
						line_issue(&t, &e, &m, prev, v)
					}
				}
				prev = v
				have = true
			}
			i = j + 1
			continue
		}
		if i + n > len(words) {
			return
		}
		cmd := words[i:][:n]
		switch op >> 5 {
		case 1:
			exec_polygon(cmd)
		case 2:
			m := Prim_Mode {
				semi    = op & 0x02 != 0,
				gouraud = op & 0x10 != 0,
				dither  = gpu.dither && op & 0x10 != 0,
			}
			k := 1
			a := read_vertex(cmd, &k, w & 0xffffff, false, &m, true)
			depth_fill(([^]Vertex)(&a)[:1])
			c2 := w & 0xffffff
			if m.gouraud {
				c2 = cmd[k] & 0xffffff
				k += 1
			}
			b := read_vertex(cmd, &k, c2, false, &m, true)
			depth_fill(([^]Vertex)(&b)[:1])
			e := plot_env()
			for &t in drawn_targets() {
				line_issue(&t, &e, &m, a, b)
			}
		case 3:
			exec_rect(cmd)
		case 4:
			sx, sy := i32(cmd[1] & 0x3ff), i32((cmd[1] >> 16) & 0x1ff)
			dx, dy := i32(cmd[2] & 0x3ff), i32((cmd[2] >> 16) & 0x1ff)
			cw, ch := i32(cmd[3] & 0x3ff), i32((cmd[3] >> 16) & 0x1ff)
			move_image(sx, sy, dx, dy, cw, ch)
		case 7:
			exec_env(w)
		case 0:
			if op == 0x02 {
				x := i32(cmd[1] & 0x3f0)
				y := i32((cmd[1] >> 16) & 0x1ff)
				fw := i32(((cmd[2] & 0x3ff) + 0xf) & ~u32(0xf))
				fh := i32((cmd[2] >> 16) & 0x1ff)
				fill_rect(x, y, fw, fh, rgb24_to_15(w))
			}
		}
		i += n
	}
}

move_image :: proc(sx, sy, dx, dy, w, h: i32) #no_bounds_check {
	// The game moves an area onto itself every frame: no pixel changes, and
	// on GL it would cost two reads back from the GPU.
	if sx == dx && sy == dy {
		return
	}
	raster_sync()
	hi_only_read(sx, sy, w, h)
	hi_touch(sx, sy, w, h)
	hi_touch(dx, dy, w, h)
	for &t in live_targets() {
		k := t.shift
		if t.gl && gl_move(sx << k, sy << k, dx << k, dy << k, w << k, h << k) {
			continue
		}
		if t.gl {
			gl_settle()
			gl_pull(sx << k, sy << k, w << k, h << k)
			gl_pull(dx << k, dy << k, w << k, h << k)
		}
		if k > 0 {
			move_pixels(&t, t.rgb, sx, sy, dx, dy, w, h)
		} else {
			move_pixels(&t, t.pix, sx, sy, dx, dy, w, h)
		}
		if t.gl {
			gl_push(dx << k, dy << k, w << k, h << k)
		}
	}
}

// move_image's copy in target t's pixels pix.
@(private = "file")
move_pixels :: proc(t: ^Target, pix: []$P, sx, sy, dx, dy, w, h: i32) #no_bounds_check {
	k := t.shift
	for y: i32 = 0; y < h << k; y += 1 {
		for x: i32 = 0; x < w << k; x += 1 {
			c := pix[target_index(t, sx << k + x, sy << k + y)]
			pix[target_index(t, dx << k + x, dy << k + y)] = c
			when P == u32 {
				if c & HI_GLOW != 0 {
					bloom_mark(t, dx << k + x, dy << k + y)
				}
			}
		}
	}
}

// Replace all of VRAM, as when switching to another map's machine kept
// whole: the hi-res target takes the new pixels too. VRAM area `keep` (x, y,
// w, h; none when empty) keeps what it holds, in both.
vram_replace :: proc(src: ^[VRAM_W * VRAM_H]u16, keep := [4]i32{}) #no_bounds_check {
	raster_sync()
	x0, y0 := clamp(keep.x, 0, VRAM_W), clamp(keep.y, 0, VRAM_H)
	x1, y1 := clamp(keep.x + keep.z, x0, VRAM_W), clamp(keep.y + keep.w, y0, VRAM_H)
	for y in i32(0) ..< VRAM_H {
		row := vram[y * VRAM_W:][:VRAM_W]
		from := src[y * VRAM_W:][:VRAM_W]
		if y < y0 || y >= y1 {
			copy(row, from)
		} else {
			copy(row[:x0], from[:x0])
			copy(row[x1:], from[x1:])
		}
	}
	if target_count == 2 {
		t := &targets[1]
		k := t.shift
		// The target's boxes outside the kept area, inclusive.
		boxes := [4][4]i32{
			{0, 0, t.w - 1, y0 << k - 1},
			{0, y1 << k, t.w - 1, t.h - 1},
			{0, y0 << k, x0 << k - 1, y1 << k - 1},
			{x1 << k, y0 << k, t.w - 1, y1 << k - 1},
		}
		if t.gl {
			gl_puts_apply()
			gl_vram_upload()
		}
		for b in boxes {
			if b.z < b.x || b.w < b.y {
				continue
			}
			if t.gl {
				gl_pass(1, b)
				continue
			}
			for y in b.y ..= b.w {
				for x in b.x ..= b.z {
					t.rgb[y * t.w + x] = hi_pixel(vram[(y >> k) * VRAM_W + (x >> k)])
				}
			}
		}
	}
	// Extra pictures drawn from the VRAM replaced are of another world.
	extra.ready = false
}

// Write VRAM pixel x, y as the CPU does (uploads, game code poking
// textures): the hi-res target takes it as a block.
vram_put :: proc(x, y: i32, c: u16) #no_bounds_check {
	raster_sync()
	hi_touch(x, y, 1, 1)
	vram_at(x, y)^ = c
	if target_count == 2 && targets[1].gl {
		gl_put(x, y, c)
	} else if target_count == 2 {
		t := &targets[1]
		n := i32(1) << t.shift
		for dy in 0 ..< n {
			for dx in 0 ..< n {
				t.rgb[target_index(t, x << t.shift + dx, y << t.shift + dy)] = hi_pixel(c)
			}
		}
	}
}
