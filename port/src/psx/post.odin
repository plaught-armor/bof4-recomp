// Picture effects in the style of HD-2D (not a PS1 feature), worked into
// the shown area as it is converted for the window, on the hi-res target
// only and while the third-person field camera is up (see_through):
//
// - Depth of field: each pixel mixes toward a blurred copy of the picture
//   by how far its depth (HI_DEPTH) stands from the leader's, so the leader
//   and what is round him stay sharp while the far end of the town and what
//   passes close by the lens go soft. Pixels without depth (menus, text, the
//   party's sprites, the sky) stay sharp. The blur is the glow's (bloom.odin):
//   the area averaged down to the PS1's resolution, blurred across then down
//   and stretched back bilinearly.
// - Colour grading: each channel out a mix of the three in, plus an offset,
//   as the field's map asks (Grade, set by the port's field code).
// - Vignette: the picture darkens toward its corners.
//
// They go on in that order, the glow added after the depth of field. The
// target itself is left as drawn. Integer arithmetic throughout, the same as
// the GPU's (gl_target.odin, BLOOM_CS and CONV_CS), so both give the same
// pixels. Set from the config ([window] depth_of_field, vignette; the grade's
// own switch is the field code's).
package psx

import "core:simd"

depth_of_field := false
vignette := false

// Each channel out (r, g, b) in 256ths of each channel in, plus an offset
// in 256ths of a step; on while set again within GRADE_VBLANKS.
Grade :: struct {
	on:    bool,
	m:     [3][3]i32,
	add:   [3]i32,
	stamp: u64,
}
grade: Grade
@(private)
GRADE_VBLANKS :: 8

// Depth steps (HI_DEPTH, 64 view units) either side of the leader kept
// sharp, the steps past those over which the blur comes in in full, and
// how long the field camera's view (see_through) holds the focus.
@(private)
DOF_BAND :: 2
@(private)
DOF_RAMP :: 8
@(private)
DOF_VBLANKS :: 8

// How far from the middle (256ths of the half diagonal, squared) the
// vignette starts, and how dark it gets at the corners (256ths).
@(private)
VIGNETTE_FROM :: 128
@(private)
VIGNETTE_MOST :: 80

// The effects for one conversion: the focus's depth step (0 no depth of
// field), whether to darken the corners, the grade (off when not on).
@(private)
Post :: struct {
	focus:    i32,
	vignette: bool,
	grade:    Grade,
}

// The effects due now: only under the third-person field camera.
@(private)
post_now :: proc() -> Post {
	s := &see_through
	if !s.on || vblanks() - s.stamp > DOF_VBLANKS || s.target.z <= 0 {
		return {}
	}
	p := Post {
		vignette = vignette,
	}
	if depth_of_field {
		p.focus = i32(depth_bits(s.target.z) >> HI_DEPTH_SHIFT)
	}
	if grade.on && vblanks() - grade.stamp <= GRADE_VBLANKS {
		p.grade = grade
	}
	return p
}

// The blurred picture of the area being converted at the PS1's resolution,
// w x h, packed as hi-res pixels: averaged (avg), blurred across (across)
// and down (down). x, y is the area's corner in target pixels, k the
// target's shift.
@(private)
dof: struct {
	avg, across, down: [dynamic]u32,
	w, h, x, y, k:     i32,
}

// Blur the shown target's area x, y, w x h (VRAM pixels).
@(private)
dof_prepare :: proc(x, y, w, h: i32) {
	d := &dof
	k := i32(shown_target().shift)
	d.w, d.h, d.x, d.y, d.k = w, h, x << u32(k), y << u32(k), k
	n := int(w * h)
	resize(&d.avg, n)
	resize(&d.across, n)
	resize(&d.down, n)
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, dof.h, band, bands)
			dof_average(y0, y1)
		}, nil)
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, dof.h, band, bands)
			bloom_blur(dof.avg[:], dof.across[:], dof.w, dof.h, y0, y1, 1, 0)
		}, nil)
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, dof.h, band, bands)
			bloom_blur(dof.across[:], dof.down[:], dof.w, dof.h, y0, y1, 0, 1)
		}, nil)
}

// Average each PS1 pixel's block of target pixels, rows y0 ..< y1.
@(private)
dof_average :: proc(y0, y1: i32) #no_bounds_check {
	d := &dof
	t := shown_target()
	k := u32(d.k)
	s := i32(1) << k
	half := Lanes(u32(1) << (2 * k) >> 1)
	for cy in y0 ..< y1 {
		for cx in 0 ..< d.w {
			sum: Lanes
			for dy in 0 ..< s {
				line := t.rgb[((d.y + cy << k + dy) & (t.h - 1)) * t.w:][:t.w]
				for dx in 0 ..< s {
					sum += lanes(line[(d.x + cx << k + dx) & (t.w - 1)])
				}
			}
			d.avg[cy * d.w + cx] = pack(simd.shr(sum + half, Lanes(2 * k)))
		}
	}
}

// Target pixel c (with its depth) of the area's column px, row row, mixed
// toward the blurred picture by how far it stands from depth step `focus`.
@(private)
dof_mix :: #force_inline proc(c: u32, focus, px, row: i32) -> u32 {
	z := i32(c >> HI_DEPTH_SHIFT & 63)
	if z == 0 {
		return c
	}
	w := clamp((abs(z - focus) - DOF_BAND) * 256 / DOF_RAMP, 0, 256)
	if w == 0 {
		return c
	}
	b := bloom_sample(dof.down[:], dof.w, dof.h, dof.k, px, row)
	return pack(simd.shr(lanes(c) * Lanes(u32(256 - w)) + b * Lanes(u32(w)) + 128, Lanes(8)))
}

@(private)
Signed :: #simd[4]i32

// Pixel c graded by g.
@(private)
grade_apply :: #force_inline proc(c: u32, g: ^Grade) -> u32 {
	r, gr, b := i32(c >> 16 & 255), i32(c >> 8 & 255), i32(c & 255)
	m := &g.m
	v := Signed{m[0][0], m[1][0], m[2][0], 0} * r + Signed{m[0][1], m[1][1], m[2][1], 0} * gr
	v += Signed{m[0][2], m[1][2], m[2][2], 0} * b + Signed{g.add[0], g.add[1], g.add[2], 0} + 128
	v = simd.clamp(v, Signed(0), Signed(255 * 256 + 255))
	return pack(simd.shr(transmute(Lanes)v, Lanes(8)))
}

// Pixel c at the area's column px, row row (fw x fh pixels) darkened
// toward the corners.
@(private)
vignette_apply :: #force_inline proc(c: u32, px, row, fw, fh: i32) -> u32 {
	nx := abs(2 * px + 1 - fw) * 256 / fw
	ny := abs(2 * row + 1 - fh) * 256 / fh
	r2 := (nx * nx + ny * ny) >> 8
	dark := clamp((r2 - VIGNETTE_FROM) * VIGNETTE_MOST / (512 - VIGNETTE_FROM), 0, VIGNETTE_MOST)
	if dark == 0 {
		return c
	}
	return pack(simd.shr(lanes(c) * Lanes(u32(256 - dark)) + 128, Lanes(8)))
}

// Target pixel c of the area's column px, row row (fw x fh pixels) with the
// effects of p and, with `bloom`, the glow worked in, as XRGB8888.
@(private)
post_pixel :: #force_inline proc(c: u32, p: ^Post, bloom: bool, px, row, fw, fh: i32) -> u32 {
	out := c
	if p.focus > 0 {
		out = dof_mix(out, p.focus, px, row)
	}
	if bloom {
		out = bloom_add(out, px, row)
	}
	if p.grade.on {
		out = grade_apply(out, &p.grade)
	}
	if p.vignette {
		out = vignette_apply(out, px, row, fw, fh)
	}
	return out & 0xffffff
}
