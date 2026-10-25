// Portals: a run of packets drawn only inside, or only outside, the screen
// shape of an opening (not a PS1 feature).
//
// The field draws a neighbour section of the map around the loaded one
// (BoF4 qol/sections.odin). Sections are modelled alone, so a neighbour's rock can
// stand where the loaded section's rooms are, and the other way round: a cave
// drawn whole inside a canyon's cliffs is buried in them. Through a portal
// the neighbour shows only in the doorway between the two, as if seen through
// it, and the loaded section's rock that stands on the neighbour's rooms shows
// only outside it.
//
// portal_add takes the packets by their address range (the game writes a
// frame's packets one after another) and the opening as a quad in view
// space, cut at the near plane and projected with the GTE's projection as it
// stands. The ordering-table walk looks up each packet's portal (hooks.odin
// packet) and points render.mask_now at its mask. A walk spends the portals it met; ones never
// walked lapse after PORTAL_VBLANKS.
package scene

import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import render "ps:psx/render"

@(private)
MAX_PORTALS :: 32
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
	lo, hi:     u32,
	stamp:      u64,
	walked:     bool,
	// The opening on screen and which side of it draws.
	using mask: render.Mask,
}

portals: struct {
	list: [MAX_PORTALS]Portal,
	n:    int,
}

// Draw the packets at lo..<hi only inside (or, with inside false, only
// outside) the opening `quad`: its corners in view space, in order round it.
portal_add :: proc(lo, hi: u32, quad: [4][3]f32, inside: bool) {
	if hi <= lo {
		return
	}
	p := Portal{lo = lo & 0x1fffff, hi = hi & 0x1fffff, stamp = cpu.vblanks()}
	p.inside = inside
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
opening_project :: proc(quad: [4][3]f32) -> (corner: [render.MASK_CORNERS][2]f32, n: int, turn: f32) {
	cut: [render.MASK_CORNERS][3]f32
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
	h := f32(gte.state.h)
	of := [2]f32{f32(gte.state.ofx), f32(gte.state.ofy)} / 0x10000
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

// Point the walk at the portal of the packet at `a`, if any.
portal_find :: proc(a: u32) {
	render.mask_now = nil
	now := cpu.vblanks()
	for &p in portals.list[:portals.n] {
		if a >= p.lo && a < p.hi && now - p.stamp <= PORTAL_VBLANKS {
			p.walked = true
			render.mask_now = &p.mask
			return
		}
	}
}

// End a walk: the portals it met are spent, and lapsed ones go.
portal_walk_end :: proc() {
	render.mask_now = nil
	now := cpu.vblanks()
	kept := 0
	for p in portals.list[:portals.n] {
		if !p.walked && now - p.stamp <= PORTAL_VBLANKS {
			portals.list[kept] = p
			kept += 1
		}
	}
	portals.n = kept
}
