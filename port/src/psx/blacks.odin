// Black-out drops: a run of packets drawn without its black polygons (not a
// PS1 feature).
//
// Around a stairwell a section models solid black blocks, in the same placed
// model as the stair's top steps: the game shows the floor below as black.
// When qol/sections.odin draws that floor whole, the blocks would cover its
// stair, so the model's packets are drawn with their black polygons left out
// and its steps kept. Runs lapse after PORTAL_VBLANKS, as portals do.
package psx

import "core:math/linalg"
import "core:slice"

@(private)
MAX_BLACKS :: 32
// An untextured polygon whose corners' colours are all at most this
// (0..255 each) is black.
@(private)
BLACK_MAX :: 8
// The same for a texel's 5-bit channels (0..31).
@(private)
BLACK_TEXEL :: 1

@(private)
Black_Run :: struct {
	lo, hi: u32,
	stamp:  u64,
}

@(private)
blacks: struct {
	list: [MAX_BLACKS]Black_Run,
	n:    int,
	// Every packet's black polygons left out, not just the runs', and how
	// far across `door` those about it reach; their corners on screen
	// (packet positions), as many as fit.
	all:  bool,
	door: Opening,
	span: [2]f32,
	pts:  [MAX_CURTAIN][2]f32,
	n_pts: int,
}

// Corners of a curtain's polygons kept for its outline (curtain_hole).
@(private)
MAX_CURTAIN :: 64

// How far before and behind a door's opening, view units, and past its
// sides and top (fractions), a black polygon counts as its curtain.
@(private)
CURTAIN_BEFORE :: 256
@(private)
CURTAIN_BEHIND :: 96
@(private)
CURTAIN_EDGE :: 1

// Leave the black polygons out of every packet drawn until blacks_all_end:
// a room drawn for a door picture models black past its doorway, a curtain
// standing for the town outside, which would hide the room. The curtain is
// measured against the door's opening `quad` (view space, as picture_add's,
// seen from the side `front` lies on).
blacks_all_begin :: proc(quad: [4][3]f32, front: [3]f32) {
	blacks.all = true
	blacks.span = {max(f32), min(f32)}
	blacks.n_pts = 0
	ok: bool
	blacks.door, ok = opening_make(quad, front)
	if !ok {
		blacks.door = {}
	}
}

// End blacks_all_begin: how far across its opening (as picture_span) the
// curtain left out reached, false when none was seen.
blacks_all_end :: proc() -> (span: [2]f32, ok: bool) {
	blacks.all = false
	return blacks.span, blacks.span[0] <= blacks.span[1]
}

// Note a black polygon left out, its corners `vs`, as the curtain if it
// stands about the door's opening.
@(private)
curtain_note :: proc(vs: []Vertex) {
	if !blacks.all || blacks.door.h == 0 {
		return
	}
	lo, hi, ok := curtain_at(&blacks.door, vs)
	if !ok {
		return
	}
	blacks.span = {min(blacks.span[0], lo), max(blacks.span[1], hi)}
	corners: [4][3]f32
	for v, k in vs[:min(len(vs), 4)] {
		corners[k] = {f32(v.x - gpu.off_x), f32(v.y - gpu.off_y), v.z}
	}
	curtain_corners(corners[:min(len(vs), 4)])
}

// Whether the polygon with corners `vs` stands about opening o, as its
// curtain would, and how far across it it reaches.
@(private)
curtain_at :: proc(o: ^Opening, vs: []Vertex) -> (lo, hi: f32, ok: bool) {
	lo, hi = max(f32), min(f32)
	for v in vs {
		if v.z <= 0 {
			return
		}
		at := opening_at(o, {f32(v.x - gpu.off_x), f32(v.y - gpu.off_y), v.z})
		if at.x < -CURTAIN_EDGE || at.x > 1 + CURTAIN_EDGE || at.y < -0.25 || at.y > 1 + CURTAIN_EDGE || at.z > CURTAIN_BEFORE || at.z < -CURTAIN_BEHIND {
			return
		}
		lo, hi = min(lo, at.x), max(hi, at.x)
	}
	return lo, hi, true
}

// Note a curtain polygon's corners (packet positions) for curtain_hole, as
// many as fit.
@(private)
curtain_corners :: proc(corners: [][3]f32) {
	if !blacks.all {
		return
	}
	for c in corners {
		if blacks.n_pts == MAX_CURTAIN {
			return
		}
		blacks.pts[blacks.n_pts] = c.xy
		blacks.n_pts += 1
	}
}

// The opening on the picture drawn between blacks_all_begin and _end, as
// cover_add takes it: the outline round the curtain left out and a blank
// picture's back (picture_blank_add), its doorway's dark back, or without
// either the opening `quad` (view space) as the lens sees it. An outline of more corners than a hole has is boxed.
curtain_hole :: proc(quad: [4][3]f32) -> Cover_Hole {
	n := blacks.n_pts
	if n < 3 {
		return hole_make(quad)
	}
	// The convex hull (Andrew's monotone chain), lower then upper.
	pts := blacks.pts
	slice.sort_by(pts[:n], proc(a, b: [2]f32) -> bool {
		return a.x < b.x || a.x == b.x && a.y < b.y
	})
	cross :: proc(o, a, b: [2]f32) -> f32 {
		return (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x)
	}
	hull: [2 * MAX_CURTAIN][2]f32
	m := 0
	for p in pts[:n] {
		for m >= 2 && cross(hull[m - 2], hull[m - 1], p) <= 0 {
			m -= 1
		}
		hull[m] = p
		m += 1
	}
	lower := m + 1
	for k := n - 2; k >= 0; k -= 1 {
		for m >= lower && cross(hull[m - 2], hull[m - 1], pts[k]) <= 0 {
			m -= 1
		}
		hull[m] = pts[k]
		m += 1
	}
	m -= 1
	if m <= MAX_HOLE {
		return hole_edges(hull[:m])
	}
	lo, hi := hull[0], hull[0]
	for p in hull[1:m] {
		lo, hi = linalg.min(lo, p), linalg.max(hi, p)
	}
	box := [4][2]f32{lo, {hi.x, lo.y}, hi, {lo.x, hi.y}}
	return hole_edges(box[:])
}

// Leave the black polygons out of the packets at lo..<hi in the frame drawn
// next.
blacks_add :: proc(lo, hi: u32) {
	if hi <= lo {
		return
	}
	now := vblanks()
	kept := 0
	for b in blacks.list[:blacks.n] {
		if now - b.stamp <= PORTAL_VBLANKS {
			blacks.list[kept] = b
			kept += 1
		}
	}
	blacks.n = kept
	if blacks.n == MAX_BLACKS {
		return
	}
	blacks.list[blacks.n] = {lo & 0x1fffff, hi & 0x1fffff, now}
	blacks.n += 1
}

// Whether the polygon of the packet being drawn, its corners `vs` and mode
// `m`, is a black one left out: its colour, or for a textured one its
// texels at the middle and toward each corner, black. With a cover waiting
// (cover_add), those about its opening are too.
@(private)
black_left_out :: proc(vs: []Vertex, m: ^Prim_Mode) -> bool {
	in_run := blacks.all
	for b in blacks.list[:blacks.n] {
		if packet_now >= b.lo && packet_now < b.hi {
			in_run = true
			break
		}
	}
	if !in_run {
		if !cover_due() || cover_door.h == 0 {
			return false
		}
		if _, _, ok := curtain_at(&cover_door, vs); !ok {
			return false
		}
	}
	if !polygon_black(vs, m) {
		return false
	}
	curtain_note(vs)
	return true
}

// Whether the polygon with corners `vs` and mode `m` draws black: its
// colour, or for a textured one its texels at the middle and toward each
// corner.
@(private)
polygon_black :: proc(vs: []Vertex, m: ^Prim_Mode) -> bool {
	if !m.textured {
		for v in vs {
			if v.r > BLACK_MAX || v.g > BLACK_MAX || v.b > BLACK_MAX {
				return false
			}
		}
		return true
	}
	mid: [2]i32
	for v in vs {
		mid += {v.u, v.v}
	}
	mid /= i32(len(vs))
	if !black_texel(m, mid) {
		return false
	}
	for v in vs {
		if !black_texel(m, mid + ([2]i32{v.u, v.v} - mid) * 3 / 4) {
			return false
		}
	}
	return true
}

// Whether the texel at `uv` of the texture `m` draws with is black: its
// 5-bit channels all at most BLACK_TEXEL (0 is see-through, nothing drawn).
@(private)
black_texel :: proc(m: ^Prim_Mode, uv: [2]i32) -> bool {
	t := texel(&gpu, m, uv.x, uv.y)
	return t & 0x1f <= BLACK_TEXEL && (t >> 5) & 0x1f <= BLACK_TEXEL && (t >> 10) & 0x1f <= BLACK_TEXEL
}
