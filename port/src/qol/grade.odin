// Colour grade of the third-person field ([window] color_grade, render.grade):
// each map's look, as a saturation, a warmth (red up and blue down by as
// much) and a contrast about the middle grey, made into the 3x3 mix and
// offset the conversion applies (psx/post.odin). Set with every view the
// field camera builds, so it lapses with the camera.
package qol

import "core:math"
import cpu "ps:psx/cpu"
import render "ps:psx/render"


@(private = "file")
Look :: struct {
	saturation, warmth, contrast: f32,
}

// Any map not listed.
@(private = "file")
LOOK_DEFAULT :: Look{1.06, 0, 1.04}

@(private = "file")
LOOKS := [?]struct {
	map_id: u16,
	look:   Look,
} {
	{0x1000, {1.05, 0.01, 1.05}}, // Sarai, the desert at noon
	{0x0414, {1.05, 0.01, 1.06}}, // the canyon
}

// Luma weights the saturation keeps.
@(private = "file")
LUMA :: [3]f32{0.299, 0.587, 0.114}

// Set render.grade for the map loaded, or turn it off.
@(private)
grade_update :: proc() {
	if !config.window_color_grade {
		render.grade.on = false
		return
	}
	look := LOOK_DEFAULT
	id := u16(cpu.lhu(MAP_ID))
	for l in LOOKS {
		if l.map_id == id {
			look = l.look
		}
	}
	g := render.Grade {
		on    = true,
		stamp = cpu.vblanks(),
	}
	gain := [3]f32{1 + look.warmth, 1, 1 - look.warmth} * look.contrast
	s := look.saturation
	luma := LUMA
	for r in 0 ..< 3 {
		for c in 0 ..< 3 {
			v := (1 - s) * luma[c] + (r == c ? s : f32(0))
			g.m[r][c] = i32(math.round(v * gain[r] * 256))
		}
		g.add[r] = i32(math.round(128 * (1 - look.contrast) * 256))
	}
	render.grade = g
}
