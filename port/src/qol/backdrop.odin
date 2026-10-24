// Sky behind the third-person field: the game clears each frame to black
// (a GP0 02 fill of the draw buffer) and, from its high camera, never shows
// past the map's edge. The low third-person camera does, and there the
// black shows as a void. For outdoor maps the clear is instead, in the
// hi-res target only (psx.backdrop_hook), a sky above the horizon and the
// map's ground fading into haze below it.
//
// Each target row's colour goes with its ray's elevation: the ray through
// the row's centre at the screen's middle column is (0, y - ofy, H) in view
// space, and column 1 of the view rotation (CAM_MATRIX, s16 4.12) takes it
// to world y, which points up. The rotation in RAM at the clear is the
// frame's own: the real frame's, or an in-between pass's. Roll is taken to
// be none.
//
// Such a map also gets distance fog (psx.fog): what stands far off mixes
// toward the horizon haze, up to `fog_most` (256ths) at `fog_far` past the
// leader's view depth, about where the game stops drawing the map round
// him, so its edge melts into the backdrop instead of cutting off.
package qol

import "core:math"
import "../psx"

@(private = "file")
MODE_EVENT :: 4
@(private = "file")
MODE_SHOP :: 7
// Elevation sines over which the sky reaches its zenith colour, and the
// ground its own colour out of the haze.
@(private = "file")
SKY_SPAN :: 0.6
@(private = "file")
HAZE_SPAN :: 0.12

@(private = "file")
Sky :: struct {
	zenith, horizon, ground: [3]f32,
	// View depths past the leader's the fog runs over, and how far it goes
	// (256ths).
	fog_near, fog_far:       f32,
	fog_most:                i32,
}

@(private = "file")
DESERT :: Sky {
	zenith  = {90, 140, 210},
	horizon = {222, 226, 228},
	ground  = {206, 190, 136},
	fog_near = 380,
	fog_far  = 2680,
	fog_most = 256,
}

@(private = "file")
CANYON :: Sky {
	zenith  = DESERT.zenith,
	horizon = DESERT.horizon,
	ground  = {150, 134, 95},
	// The cliffs close in; only what nears the draw edge hazes.
	fog_near = 1280,
	fog_far  = DESERT.fog_far,
	fog_most = DESERT.fog_most,
}

// Maps that get a sky; any other keeps the black.
@(private = "file")
SKIES := [?]struct {
	map_id: u16,
	sky:    Sky,
} {
	{0x1000, DESERT}, // Sarai
	{0x0414, CANYON}, // the canyon
}

@(private)
backdrop_init :: proc() {
	psx.backdrop_hook = backdrop
}

@(private = "file")
backdrop :: proc(x, y, w, h: i32, shift: u32, rows: []u32) -> bool {
	if interior_pass || w < 256 || third_person_state().t == 0 {
		return false
	}
	psx.fog.on = false
	switch psx.lhu(GAME_MODE) {
	case GAME_MODE_FIELD, MODE_EVENT, MODE_SHOP:
	case:
		return false
	}
	sky: ^Sky
	id := u16(psx.lhu(MAP_ID))
	for &s in SKIES {
		if s.map_id == id {
			sky = &s.sky
		}
	}
	if sky == nil {
		return false
	}
	lens, of := psx.gte_projection()
	m1 := f32(i16(psx.lhu(CAM_MATRIX + 2 * 4))) / 4096 // row 1, column 1
	m2 := f32(i16(psx.lhu(CAM_MATRIX + 2 * 7))) / 4096 // row 2, column 1
	hz := f32(lens)
	step := 1 / f32(i32(1) << shift)
	for &c, r in rows {
		ys := (f32(r) + 0.5) * step - of.y
		e := (m1 * ys + m2 * hz) / math.sqrt(ys * ys + hz * hz)
		col: [3]f32
		if e >= 0 {
			t := math.pow(min(e / SKY_SPAN, 1), 0.6)
			col = sky.horizon + (sky.zenith - sky.horizon) * t
		} else {
			t := math.sqrt(min(-e / HAZE_SPAN, 1))
			col = sky.horizon + (sky.ground - sky.horizon) * t
		}
		c = u32(col.r) << 16 | u32(col.g) << 8 | u32(col.b)
	}
	h := sky.horizon
	psx.fog = {
		on    = true,
		near  = third_person_leader_depth() + sky.fog_near,
		inv   = 1 / (sky.fog_far - sky.fog_near),
		most  = sky.fog_most,
		color = u32(h.r) << 16 | u32(h.g) << 8 | u32(h.b),
		stamp = psx.vblanks(),
	}
	return true
}
