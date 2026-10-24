// A depth buffer for the hi-res target under the third-person field camera
// (not a PS1 feature). The PS1 draws in ordering-table order, the painter's
// way, and the game's table was sorted for its own camera: from the close
// camera a floor polygon filed after a person cuts a line through his legs,
// an awning's back edge draws over the vendor under it. Each hi-res pixel
// keeps the depth of the nearest solid pixel drawn there this walk, and a
// pixel standing behind it by more than a bias is not drawn.
//
// - Only polygons whose corners all carry projected depths (see_through)
//   and filed sprites take part; menus, text, fills, copies and polygons
//   with corners filled in stay painted in table order. VRAM itself stays as
//   the PS1 has it.
// - A sprite stands upright where its feet are, facing the lens across:
//   its depth is that plane's (Flat.at), 1 / depth running straight down
//   the screen (Prim_Mode.z_plane), but never past its feet: the art below
//   where it stands (the soles, a stride's back foot) would lie under the
//   ground there, and the floor before it cut its legs off in a ragged
//   line.
// - Every taking part is tested; only a solid pixel drawn in full writes
//   (not see-through texels, ghosts or faded pixels), keeping the nearer of
//   its depth and the one there.
// - A pixel passes when no more than a bias behind (Z_BIAS: a few units and
//   a share of the depth, more for sprites, whose feet run onto the ground
//   before them); among those the later one wins, as the table had it.
//
// A pixel's word is the walk's key (0xffff less its count) << 16 and its
// depth in quarter view units, so a word left by an earlier walk is larger
// than any of this one's and counts as empty: no clear between walks, and
// keeping the nearer is one min (the GPU's atomic min, gl_target.odin, whose
// levels each lay down their depths before they draw).
package psx

import "core:slice"

// The count of the walk drawing with depth (see_begin), 1 ..= 0xffff.
@(private)
z_walk: u32

@(private)
Z_Mode :: enum u8 {
	Off,
	Test,
	Write,
}

// Quarter view units a depth step; the buffer's empty word.
@(private)
Z_SCALE :: 4
@(private)
Z_EMPTY :: max(u32)

// Depth steps a pixel may stand behind the one there and still be drawn:
// a fixed part for a polygon and for a sprite, and the depth's share past
// it as a shift. GL_DRAW_FS has them too.
@(private)
Z_BIAS :: 2 * Z_SCALE
@(private)
Z_BIAS_SPRITE :: 48 * Z_SCALE
@(private)
Z_BIAS_SHIFT :: 7

// Start a walk drawing with depth: its key for Plot_Env.z_key.
@(private)
z_walk_begin :: proc() -> u32 {
	z_walk += 1
	if z_walk > 0xffff {
		z_walk = 1
		for &t in live_targets() {
			if t.gl {
				gl_zbuf_clear()
			}
			slice.fill(t.zbuf, Z_EMPTY)
		}
	}
	return (0xffff - z_walk) << 16
}

// View depth z as a depth step, 1 ..= 0xffff.
@(private)
z_step :: #force_inline proc(z: f32) -> u32 {
	return u32(clamp(z * Z_SCALE + 0.5, 1, 0xffff))
}

// The depth a sprite's pixel at packet row y stands at on its plane, no
// farther than its feet, or 0.
@(private)
z_on_plane :: #force_inline proc(plane: [3]f32, y: f32) -> f32 {
	iz := max(plane.x * y + plane.y, plane.z)
	return iz > 0 ? 1 / iz : 0
}

// The plane of a sprite standing at view-space point `at`, upright (world
// up, see_through.up) and facing the lens across (holding the view's x
// axis): 1 / depth = plane.x * y + plane.y for packet row y, at least
// plane.z (its feet's). Zero when it runs through the lens.
@(private)
z_sprite_plane :: proc(at: [3]f32) -> [3]f32 {
	s := &see_through
	// The normal, cross((1, 0, 0), up), has no x.
	ny, nz := -s.up.z, s.up.y
	d := ny * at.y + nz * at.z
	if abs(d) < 1e-3 || s.h <= 0 {
		return {}
	}
	return {ny / (s.h * d), (nz - ny * s.of.y / s.h) / d, at.z > 0 ? 1 / at.z : 0}
}

// Whether a pixel at depth z passes the depth at target index i: walk key
// `key`, a sprite's bias when sprite.
@(private)
z_test :: #force_inline proc(t: ^Target, i: i32, key: u32, z: f32, sprite: bool) -> bool #no_bounds_check {
	s := t.zbuf[i]
	if s >> 16 != key >> 16 {
		return true
	}
	q, d := z_step(z), s & 0xffff
	return q <= d + (sprite ? Z_BIAS_SPRITE : Z_BIAS) + (d >> Z_BIAS_SHIFT)
}

// Keep depth z at target index i when nearer than the one there.
@(private)
z_write :: #force_inline proc(t: ^Target, i: i32, key: u32, z: f32) #no_bounds_check {
	t.zbuf[i] = min(t.zbuf[i], key | z_step(z))
}
