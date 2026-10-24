// Portals: a run of packets drawn only inside, or only outside, the screen
// shape of an opening (not a PS1 feature).
//
// The field draws a neighbour section of the map around the loaded one
// (qol/sections.odin). Sections are modelled alone, so a neighbour's rock can
// stand where the loaded section's rooms are, and the other way round: a cave
// drawn whole inside a canyon's cliffs is buried in them. Through a portal
// the neighbour shows only in the doorway between the two, as if seen through
// it, and the loaded section's rock that stands on the neighbour's rooms shows
// only outside it.
//
// portal_add takes the packets by their address range (the game writes a
// frame's packets one after another) and the opening as a quad in view
// space, cut at the near plane and projected with the GTE's projection as it
// stands. The ordering-table walk looks up each packet's portal and plot
// tests each pixel against it. A walk spends the portals it met; ones never
// walked lapse after PORTAL_VBLANKS.
package psx

@(private)
MAX_PORTALS :: 32
// Corners of an opening cut at the near plane: four plus one per cut.
@(private)
PORTAL_CORNERS :: 8
// View depth (view units) the opening is cut at, in front of the lens.
@(private)
PORTAL_NEAR :: 16
// Vblanks a portal waits for its walk: a frame is drawn within a few after
// its packets are built.
@(private)
PORTAL_VBLANKS :: 10

@(private)
Portal :: struct {
	// Packet addresses, lo inclusive, hi exclusive.
	lo, hi:  u32,
	inside:  bool,
	stamp:   u64,
	// The opening on screen, as packets hold positions: convex, n corners,
	// turning the way `turn` says (+1 or -1).
	corner:  [PORTAL_CORNERS][2]f32,
	n:       int,
	turn:    f32,
	walked:  bool,
}

@(private)
portals: struct {
	list: [MAX_PORTALS]Portal,
	n:    int,
}

// The portal of the packet being drawn, during a walk.
@(private)
portal_now: ^Portal

// Draw the packets at lo..<hi only inside (or, with inside false, only
// outside) the opening `quad`: its corners in view space, in order round it.
portal_add :: proc(lo, hi: u32, quad: [4][3]f32, inside: bool) {
	if hi <= lo {
		return
	}
	p := Portal{lo = lo & 0x1fffff, hi = hi & 0x1fffff, inside = inside, stamp = vblanks()}
	p.corner, p.n, p.turn = opening_project(quad)
	// A run of packets has one portal: the latest, for the frame drawn next.
	kept := 0
	for q in portals.list[:portals.n] {
		if q.hi <= p.lo || q.lo >= p.hi {
			portals.list[kept] = q
			kept += 1
		}
	}
	portals.n = kept
	if portals.n == MAX_PORTALS {
		copy(portals.list[:], portals.list[1:])
		portals.n -= 1
	}
	portals.list[portals.n] = p
	portals.n += 1
}

// The screen shape of an opening `quad` (view space, corners in order round
// it) cut at the near plane, as packets hold positions: n corners turning
// the way `turn` says (+1 or -1); n is 0 when nothing of it shows.
@(private)
opening_project :: proc(quad: [4][3]f32) -> (corner: [PORTAL_CORNERS][2]f32, n: int, turn: f32) {
	cut: [PORTAL_CORNERS][3]f32
	for a, i in quad {
		b := quad[(i + 1) % len(quad)]
		if a.z >= PORTAL_NEAR {
			cut[n] = a
			n += 1
		}
		if (a.z >= PORTAL_NEAR) != (b.z >= PORTAL_NEAR) {
			t := (PORTAL_NEAR - a.z) / (b.z - a.z)
			cut[n] = a + (b - a) * t
			n += 1
		}
	}
	h := f32(gte.h)
	of := [2]f32{f32(gte.ofx), f32(gte.ofy)} / 0x10000
	area: f32
	for i in 0 ..< n {
		c := cut[i]
		corner[i] = of + [2]f32{c.x, c.y} * h / c.z
	}
	for i in 0 ..< n {
		a, b := corner[i], corner[(i + 1) % n]
		area += a.x * b.y - b.x * a.y
	}
	if area == 0 {
		n = 0
	}
	turn = area > 0 ? 1 : -1
	return
}

// Whether screen point `at` lies inside the convex shape of n corners
// turning `turn`; false when n < 3.
@(private)
opening_holds :: proc(corner: [PORTAL_CORNERS][2]f32, n: int, turn: f32, at: [2]f32) -> bool {
	if n < 3 {
		return false
	}
	for i in 0 ..< n {
		a, b := corner[i], corner[(i + 1) % n]
		if ((b.x - a.x) * (at.y - a.y) - (b.y - a.y) * (at.x - a.x)) * turn < 0 {
			return false
		}
	}
	return true
}

// Point the walk at the portal of the packet at `a`, if any.
@(private)
portal_find :: proc(a: u32) {
	portal_now = nil
	now := vblanks()
	for &p in portals.list[:portals.n] {
		if a >= p.lo && a < p.hi && now - p.stamp <= PORTAL_VBLANKS {
			p.walked = true
			portal_now = &p
			return
		}
	}
}

// End a walk: the portals it met are spent, and lapsed ones go.
@(private)
portal_walk_end :: proc() {
	portal_now = nil
	now := vblanks()
	kept := 0
	for p in portals.list[:portals.n] {
		if !p.walked && now - p.stamp <= PORTAL_VBLANKS {
			portals.list[kept] = p
			kept += 1
		}
	}
	portals.n = kept
}

// Whether portal p (the walk's when the pixel was drawn) lets a pixel whose
// middle is at screen x, y (as packets hold positions) be drawn.
@(private)
portal_lets :: proc(p: ^Portal, x, y: f32) -> bool {
	return opening_holds(p.corner, p.n, p.turn, {x, y}) == p.inside
}
