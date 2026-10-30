// See-through, the game's part (not a PS1 feature): which packets are
// sprites standing at a depth of their own or pictures flat on the screen,
// and how each polygon covers the leader. The renderer fades the pixels
// (render see_through.odin) by the cover prim_classify (hooks.odin) gives
// a polygon, with the margins and opacities set here (render.see_fade).
//
// - Sprites (people) have no projected corners. The field camera files each
//   person's packets with the depth of where they stand (see_flat_add), so a
//   person standing nearer the lens than the leader (feet to feet,
//   see_sprite_cover) fades like a wall before him, only further
//   (see_fade.sprite_ghost).
// - A filed sprite may carry a share faded out regardless (Flat.clear,
//   See_Cover.clear): a follower fading in at map start is drawn solid and
//   ghosted by that share, instead of the game's additive glow.
package scene

import "core:math/linalg"
import cpu "ps:psx/cpu"
import render "ps:psx/render"

// View units (128 a grid cell): how far behind a face's plane the leader
// must be for it to cover him.
@(private)
SEE_BEHIND :: 8
// View units over which a face's cover fades in as its plane moves away from
// the leader or the lens.
@(private)
SEE_FADE :: 48

// Runs of sprite packets kept at once.
@(private)
MAX_FLATS :: 128
// Runs of screen packets kept at once (screen_add).
@(private)
MAX_SCREENS :: 4

// The packets lo..<hi draw a sprite standing at view depth z (0 for none
// filed: the party, which see-through never fades) and at view-space point
// `at` (its depth 0 for none), whose plane the depth buffer takes; a front
// one (the party walking in through an instant door) a waiting door cover
// does not lay over; `clear` is the share of it faded out regardless; `sub`
// its anchor's sub-pixel part (gte.state anchor_sub), which its corners take.
@(private)
Flat :: struct {
	lo, hi: u32,
	z:      f32,
	at:     [3]f32,
	stamp:  u64,
	front:  bool,
	clear:  f32,
	sub:    [2]i8,
}

flats: struct {
	list: [MAX_FLATS]Flat,
	n:    int,
}


// The renderer's fade margins and opacities: the cut before the lens, the
// ghosted cone round the leader and the floor under him, and the ghosts'
// opacity at the camera's and at the leader's end (a person is small, and
// one right before the leader must not hide him).
@(init, private)
see_fade_init :: proc "contextless" () {
	render.see_fade = {
		near         = {64, 160},
		radius       = 160,
		soft         = 64,
		cone_min     = 0.05,
		gap          = 64,
		floor        = {8, 40},
		ghost        = {0.3, 0.45},
		sprite_ghost = {0.25, 0.4},
	}
}

// Set with see_through: the view depth of where the leader stands, against
// which a sprite's (where it stands) is judged, and whether the map is a
// room (not a town), where black fill between the leader and the lens is
// left out.
feet: f32
room: bool

// Turn see-through on for the view just built: the GTE's projection, the
// leader's middle `target` and world `up` in view space, the view depth
// `feet_z` of where he stands and how far his middle `rise`s above that;
// `in_room` when the map is not a town.
see_through_set :: proc(target, up: [3]f32, feet_z, rise: f32, in_room: bool) {
	render.see_through_set(target, up, rise)
	feet, room = feet_z, in_room
}

// File the packets lo..<hi as a sprite standing at view depth z (0 for
// none) and view-space point `at`, for the frame drawn next (Flat).
see_flat_add :: proc(lo, hi: u32, z: f32, at: [3]f32, sub: [2]i8, front := false, clear: f32 = 0) {
	if hi <= lo || (z <= 0 && at.z <= 0 && sub == {}) {
		return
	}
	f := Flat {
		lo    = lo & 0x1fffff,
		hi    = hi & 0x1fffff,
		z     = max(z, 0),
		at    = at,
		stamp = cpu.vblanks(),
		front = front,
		clear = clear,
		sub   = sub,
	}
	now := f.stamp
	kept := 0
	for q in flats.list[:flats.n] {
		if now - q.stamp <= PORTAL_VBLANKS && (q.hi <= f.lo || q.lo >= f.hi) {
			flats.list[kept] = q
			kept += 1
		}
	}
	flats.n = kept
	if flats.n == MAX_FLATS {
		return
	}
	flats.list[flats.n] = f
	flats.n += 1
}

// Packets drawn flat on the screen (a speaker's portrait), filed by
// screen_add.
@(private)
screens: struct {
	list: [MAX_SCREENS]struct {
		lo, hi: u32,
		stamp:  u64,
	},
	n:    int,
}

// File the packets lo..<hi as drawn flat on the screen, for the frame drawn
// next: they take no depth. Such a quad would otherwise take one from a
// sprite run (Flat) filed a few frames before at the same packet addresses
// (the packet pool is reused every other frame), or from the depth cache,
// which files projections by pixel, when a world corner projected onto one
// of its corners; the depth buffer or see-through then hid it.
screen_add :: proc(lo, hi: u32) {
	if hi <= lo {
		return
	}
	low, high := lo & 0x1fffff, hi & 0x1fffff
	now := cpu.vblanks()
	kept := 0
	for q in screens.list[:screens.n] {
		if now - q.stamp <= PORTAL_VBLANKS && (q.hi <= low || q.lo >= high) {
			screens.list[kept] = q
			kept += 1
		}
	}
	screens.n = kept
	// Full: the oldest gives way. A portrait is filed every frame and good
	// for PORTAL_VBLANKS, and its packets move on as its text grows, so the
	// runs still good need not overlap the new one; refusing it left the
	// quad drawn next to a stale sprite run, hidden for a frame.
	if screens.n == MAX_SCREENS {
		copy(screens.list[:], screens.list[1:])
		screens.n -= 1
	}
	screens.list[screens.n] = {low, high, now}
	screens.n += 1
}

// Whether the packet at address a was filed by screen_add.
@(private)
on_screen :: proc(a: u32) -> bool {
	now := cpu.vblanks()
	for q in screens.list[:screens.n] {
		if a >= q.lo && a < q.hi && now - q.stamp <= PORTAL_VBLANKS {
			return true
		}
	}
	return false
}

// The sprite the packet at address a draws, if filed.
@(private)
see_flat :: proc(a: u32) -> (Flat, bool) {
	now := cpu.vblanks()
	for f in flats.list[:flats.n] {
		if a >= f.lo && a < f.hi && now - f.stamp <= PORTAL_VBLANKS {
			return f, true
		}
	}
	return {}, false
}

// How the polygon through `corners` (packet screen x, y and view depth z, 3
// or 4 in GPU order) covers the leader: its plane has him behind it, the lens
// before.
@(private)
see_cover :: proc(corners: [][3]f32) -> render.See_Cover {
	p: [4][3]f32
	mid: [3]f32
	for c, i in corners {
		p[i] = render.see_point(c.x, c.y, c.z)
		mid += p[i]
	}
	mid /= f32(len(corners))
	// A quad's corners run 0 1 / 2 3: its normal is across the diagonals.
	n := len(corners) == 4 ? linalg.cross(p[3] - p[0], p[2] - p[1]) : linalg.cross(p[1] - p[0], p[2] - p[0])
	n = linalg.normalize0(n)
	lens := -linalg.dot(n, mid)
	leader := linalg.dot(n, render.see_through.target - mid)
	if lens * leader >= 0 {
		return {}
	}
	return {weight = render.smooth(SEE_BEHIND, SEE_BEHIND + SEE_FADE, abs(leader)) * render.smooth(0, SEE_FADE, abs(lens))}
}

// A black face narrower than this (view units; a cell is 128) between the
// leader and the lens is kept: a rope or a rail, not a wall's fill (Sarai's
// clotheslines are 24..39 across, room 0204's wall tops 43 and up).
@(private)
SEE_BLACK_THIN :: 40

// Whether the polygon through `corners` (as see_cover's) has a side shorter
// than SEE_BLACK_THIN.
@(private)
see_thin :: proc(corners: [][3]f32) -> bool {
	side := max(f32)
	p: [4][3]f32
	for c, i in corners {
		p[i] = render.see_point(c.x, c.y, c.z)
	}
	// A quad's corners run 0 1 / 2 3, round its edge 0 1 3 2.
	order := len(corners) == 4 ? [4]int{0, 1, 3, 2} : [4]int{0, 1, 2, 0}
	n := len(corners)
	for k in 0 ..< n {
		side = min(side, linalg.length(p[order[(k + 1) % n]] - p[order[k]]))
	}
	return side < SEE_BLACK_THIN
}

// How a sprite standing at view depth z covers the leader: like a wall
// before him when it stands nearer the lens than he does. Ground to ground:
// against his middle, raised toward a lens looking down, a person just
// behind him would count as in front.
@(private)
see_sprite_cover :: proc(z: f32) -> render.See_Cover {
	leader := feet - z
	if leader <= 0 {
		return {sprite = true}
	}
	return {weight = render.smooth(SEE_BEHIND, SEE_BEHIND + SEE_FADE, leader) * render.smooth(0, SEE_FADE, z), sprite = true}
}
