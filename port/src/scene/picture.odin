// Pictures: an opening in the scene filled with a picture drawn elsewhere
// (not a PS1 feature).
//
// A town's doors lead to other maps (shops, houses), which the PS1 loads in
// place of the town. qol/interiors.odin draws such a map off screen from the
// door's point of view and hands the picture here with the door's opening.
// The opening sits a tile in from the wall's face, at the doorway's dark
// back. The ordering-table walk notes which pixels that back drew
// (prim_classify, hooks.odin): polygons within the opening that lie on or behind its plane.
// Before the HUD the picture replaces those pixels only: the back gives way
// to the room beyond, while the doorway's sides, floor and lintel (in front
// of the plane) and anything drawn over the back later (people, posts, the
// leader) stay (doors_lay, render.lay_picture).
//
// A room inside a town building (qol/interiors.odin) shows the town only
// through its doorway, as a town's doorway shows the room; round the room
// stays the game's black. Just after the party walks in from the town (an
// instant door), the lens still stands where the town's camera put it,
// outside the room: a picture of the town with the building (cover_add) is
// laid over the room, except where the room's doorway opening is seen, and
// over the frame's clear (DOOR_CLEAR), mixed in less as the camera moves
// in, so the building gives way rather than vanishing.
//
// A section doorway (qol/sections.odin) leads to a neighbour section drawn
// in the same frame. Its back is left out instead (back_begin/back_end): the
// walk skips the back's polygons within the section's own packets, so the
// neighbour drawn past the doorway shows through.
package scene

import "core:math/linalg"
import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import render "ps:psx/render"

@(private)
MAX_PICTURES :: 8
@(private)
MAX_BACKS :: 8
// View units a back polygon's corners may stand before the opening's plane
// (depth error); a doorway side reaches a tile before it.
@(private)
BACK_ON :: 16
// View units before the opening's plane a doorway back off it may stand
// (back_off).
@(private)
BACK_BEFORE :: 256
// View units behind the opening's plane a back polygon may reach.
@(private)
BACK_DEEP :: 192
// Fraction of the opening's width and height a back polygon's corners may
// reach past it (Sarai 0204: the doorway sits 0.19 of its width off the exit
// cells).
@(private)
BACK_EDGE :: 0.25
// Fraction of the opening's height a section doorway's back may reach above
// it: cave mouths stand taller than the opening (0414 s2: 1.34). Their
// lintel, in front of the plane, covers the rest.
@(private)
BACK_ABOVE :: 1
// Fraction of the opening's width a door picture's back may reach past its
// sides: Sarai 0204's doorway is an alcove 0.5 of its width wider than its
// back, the wall at its left on the back's plane, drawn dark.
@(private)
PICTURE_SIDE :: 0.6

// A doorway's opening, a tile in from the wall's face, as a frame's view
// sees it.
@(private)
Opening :: struct {
	// The opening in view space, and its plane: dot(normal, p) == dist,
	// normal of unit length, pointing to the lens's side.
	quad:   [4][3]f32,
	normal: [3]f32,
	dist:   f32,
	// Projection the opening was projected with.
	h:      f32,
	of:     [2]f32,
	// Fraction of the opening's height a back may reach above it, and of
	// its width past its sides.
	above:  f32,
	side:   f32,
}

Picture :: struct {
	// The picture and how it is laid; a cover's (cover_add) hole and alpha.
	using lay:     render.Lay,
	using opening: Opening,
	owner:         rawptr, // picture_add's
	stamp:         u64,
	// How far across the opening (0 one side, 1 the other) the corners of
	// the back polygons the walk found reach, and how far before its plane
	// (view units) the nearest back standing off it was (back_off).
	span:          [2]f32,
	off:           f32,
}

// A doorway whose back the packets lo..<hi leave out: what is drawn past it
// (a neighbour section) shows there instead.
@(private)
Back :: struct {
	using opening: Opening,
	lo, hi: u32,
	stamp:  u64,
}

pictures: struct {
	list:  [MAX_PICTURES]Picture,
	n:     int,
	// The spans and offs of the last walk's pictures, by index, and how
	// many.
	spans: [MAX_PICTURES][2]f32,
	offs:  [MAX_PICTURES]f32,
	spent: int,
}

// A quad's cover outline is clipped HOLE_NEAR view units before the lens.
@(private)
HOLE_NEAR :: 8
// View units from the opening's plane a cover's lens is laid in full.
@(private)
COVER_FADE :: 96

@(private)
cut: struct {
	on:     bool,
	rot:    [3][3]f32,
	tr:     [3]f32,
	lo, hi: [2]f32,
	top:    f32,
	h:      f32,
	of:     [2]f32,
}

// The picture laid over the scene (cover_add): no opening, only pixels.
cover: Picture

backs: struct {
	list: [MAX_BACKS]Back,
	n:    int,
}

// Fill the opening `quad` (view space, corners in order round it) of the
// frame drawn next with `pixels`, w x h, as packets hold positions, and
// `hi`, the same at the hi-res target's resolution (picture_take). The
// picture shows only to a lens on the side of the opening `front` (view
// space) lies on: from behind, the doorway's back faces the other way. The
// pixels must outlive the frame's walk. Returns the picture's index for
// picture_span, -1 when there is none. A picture added for `owner` (a
// doorway) takes the place of the one added for it before.
picture_add :: proc(owner: rawptr, quad: [4][3]f32, front: [3]f32, pixels: []u16, hi: ^render.Picture_Hi, w, h: i32, warp: Maybe(matrix[3, 3]f32) = nil) -> int {
	if i64(len(pixels)) < i64(w) * i64(h) {
		return -1
	}
	o, ok := opening_make(quad, front)
	if !ok {
		return -1
	}
	now := cpu.vblanks()
	kept := 0
	for q in pictures.list[:pictures.n] {
		// The same doorway's picture added again (an in-between picture of
		// the frame's door, drawn into its own pixels) takes the place of the
		// earlier one.
		if now - q.stamp <= PORTAL_VBLANKS && q.owner != owner {
			pictures.list[kept] = q
			kept += 1
		}
	}
	pictures.n = kept
	if pictures.n == MAX_PICTURES {
		return -1
	}
	o.above, o.side = BACK_EDGE, PICTURE_SIDE
	pictures.list[pictures.n] = {lay = {pixels = pixels, hi = hi, w = w, ht = h}, opening = o, owner = owner, stamp = now, span = {max(f32), min(f32)}, off = max(f32)}
	pictures.list[pictures.n].warp, pictures.list[pictures.n].warped = warp.?
	pictures.n += 1
	return pictures.n - 1
}

// Black pixels for picture_blank_add.
@(private)
blank_pixels: []u16

// A picture of nothing for the opening `quad` (view space, as picture_add's):
// its doorway's back is drawn black, the corners of its polygons noted as
// the curtain (curtain_hole). The town drawn for a room's cover marks its
// doorway so.
picture_blank_add :: proc(quad: [4][3]f32, front: [3]f32, w, h: i32) {
	if i64(len(blank_pixels)) < i64(w) * i64(h) {
		delete(blank_pixels)
		blank_pixels = make([]u16, w * h)
	}
	if k := picture_add(&blank_pixels, quad, front, blank_pixels, nil, w, h); k >= 0 {
		pictures.list[k].blank = true
	}
}

// Lay `pixels`, w x h, and `hi` (picture_take) over the frame drawn next,
// mixed in by `alpha`: over its clear, and over what its polygons with
// depths drew, except where the picture shows its opening `hole`
// (curtain_hole) black, its doorway's curtain left out; nothing with the
// lens on the side `front` lies on (the room's) of the opening `quad` (view
// space, corners in order round it). A room's town with its building, the
// lens outside the room: the room, its people too, shows only through its
// doorway. Less is mixed in as the lens nears the opening's plane, none on
// it: the lens goes on into the room through the building's roof or walls.
// Not `sided`, neither: walking out, `alpha` alone says how much is laid.
// The room's own curtain at the opening (its black polygons about it), seen
// from outside, would hide the room there: the frame leaves it out
// (black_left_out). The pixels and the hole must outlive the frame's walk,
// which reads them as it lays the cover: a pass may draw them again before
// it. `warp` as for picture_add.
cover_add :: proc(pixels: []u16, hi: ^render.Picture_Hi, w, h: i32, quad: [4][3]f32, front: [3]f32, hole: ^render.Cover_Hole, alpha: f32, warp: Maybe(matrix[3, 3]f32) = nil, sided := true) {
	if i64(len(pixels)) < i64(w) * i64(h) || alpha <= 0 {
		return
	}
	normal := linalg.normalize0(linalg.cross(quad[1] - quad[0], quad[2] - quad[0]))
	dist := linalg.dot(normal, quad[0])
	// The lens (the origin) and `front` on either side.
	if sided && (normal == {} || -dist * (linalg.dot(normal, front) - dist) >= 0) {
		return
	}
	cover = {lay = {pixels = pixels, hi = hi, w = w, ht = h, alpha = sided ? min(alpha, abs(dist) / COVER_FADE, 1) : min(alpha, 1)}, stamp = cpu.vblanks()}
	cover_hole = hole
	cover.warp, cover.warped = warp.?
	ok: bool
	if cover_door, ok = opening_make(quad, front); !ok {
		cover_door = {}
	}
}

// The outline on screen of `quad` (view space), clipped HOLE_NEAR before
// the lens and projected with the GTE's projection; none when less than a
// polygon is left.
@(private)
hole_make :: proc(quad: [4][3]f32) -> render.Cover_Hole {
	h := f32(gte.state.h)
	of := [2]f32{f32(gte.state.ofx), f32(gte.state.ofy)} / 0x10000
	pts: [render.MAX_HOLE][2]f32
	n := 0
	for a, k in quad {
		b := quad[(k + 1) % 4]
		if a.z >= HOLE_NEAR {
			pts[n] = of + h * a.xy / a.z
			n += 1
		}
		if (a.z >= HOLE_NEAR) != (b.z >= HOLE_NEAR) {
			c := a + (b - a) * (HOLE_NEAR - a.z) / (b.z - a.z)
			pts[n] = of + h * c.xy / c.z
			n += 1
		}
	}
	return hole_edges(pts[:n])
}

// The edges of the convex outline `pts` (corners in order round it, either
// way); none when less than a polygon.
@(private)
hole_edges :: proc(pts: [][2]f32) -> (hole: render.Cover_Hole) {
	n := len(pts)
	if n < 3 || n > render.MAX_HOLE {
		return
	}
	area: f32
	for k in 0 ..< n {
		p, q := pts[k], pts[(k + 1) % n]
		area += p.x * q.y - q.x * p.y
	}
	if area == 0 {
		return
	}
	s := area > 0 ? f32(1) : -1
	for k in 0 ..< n {
		p, q := pts[k], pts[(k + 1) % n]
		a, b := -(q.y - p.y) * s, (q.x - p.x) * s
		hole.edges[k] = {a, b, -(a * p.x + b * p.y)}
	}
	hole.n = n
	return
}

// The opening of the cover waiting for the walk (cover_add), and its hole.
@(private)
cover_door: Opening
@(private)
cover_hole: ^render.Cover_Hole

@(private)
cover_due :: #force_inline proc() -> bool {
	return cover.pixels != nil && cpu.vblanks() - cover.stamp <= PORTAL_VBLANKS
}

// A box of the world left out of the frame drawn until cut_end: a room's
// town seen through its doorway leaves out the room's own building, whose
// roof and walls would hide the streets. `rot` and `tr` are the view
// the box is in (view = rot * world + tr, rot orthonormal), lo..hi its x and
// z, `top` its floor's height and a margin (y grows up): a polygon goes
// when it reaches over the box and above `top`. The ground round the
// building stays.
cut_begin :: proc(rot: [3][3]f32, tr: [3]f32, lo, hi: [2]f32, top: f32) {
	h, of := render.gte_projection()
	cut = {on = true, rot = rot, tr = tr, lo = lo, hi = hi, top = top, h = f32(h), of = of}
}

cut_end :: proc() {
	cut.on = false
}

@(private)
cut_left_out :: proc(corners: [][3]f32) -> bool {
	if cut.h == 0 {
		return false
	}
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	above := false
	for c in corners {
		v := render.unproject(c.x, c.y, c.z, cut.h, cut.of) - cut.tr
		// The transpose undoes the rotation.
		w := [3]f32 {
			cut.rot[0][0] * v.x + cut.rot[1][0] * v.y + cut.rot[2][0] * v.z,
			cut.rot[0][1] * v.x + cut.rot[1][1] * v.y + cut.rot[2][1] * v.z,
			cut.rot[0][2] * v.x + cut.rot[1][2] * v.y + cut.rot[2][2] * v.z,
		}
		lo, hi = {min(lo.x, w.x), min(lo.y, w.z)}, {max(hi.x, w.x), max(hi.y, w.z)}
		above ||= w.y > cut.top
	}
	return above && hi.x > cut.lo.x && lo.x < cut.hi.x && hi.y > cut.lo.y && lo.y < cut.hi.y
}

// How far across its opening (0 its first corner's side, 1 its second's)
// the doorway back of picture k, added for the last walk, reached; false
// when the walk drew none of it. The back is the doorway as the scene
// models it, which may sit off the opening.
picture_span :: proc(k: int) -> (span: [2]f32, ok: bool) {
	if k < 0 || k >= pictures.spent {
		return
	}
	span = pictures.spans[k]
	return span, span[0] <= span[1]
}

// How far before its opening's plane (view units) the doorway back of
// picture k, added for the last walk, stood when the walk found it off the
// plane (back_off); false when it found none. Sarai's tavern (0201.2)
// models its back a tile before the far side of its exit cells.
picture_off :: proc(k: int) -> (off: f32, ok: bool) {
	if k < 0 || k >= pictures.spent {
		return
	}
	return pictures.offs[k], pictures.offs[k] < max(f32)
}

// Leave out of the packets from `lo` on the back of the doorway `quad`
// (view space, corners in order round it), seen from the side `front` lies
// on; back_end closes the run. Returns the back's index, -1 when there is
// none. Packets drawn past the doorway then show through it, while its
// sides and lintel stay.
back_begin :: proc(lo: u32, quad: [4][3]f32, front: [3]f32) -> int {
	o, ok := opening_make(quad, front)
	if !ok {
		return -1
	}
	now := cpu.vblanks()
	kept := 0
	for b in backs.list[:backs.n] {
		if now - b.stamp <= PORTAL_VBLANKS {
			backs.list[kept] = b
			kept += 1
		}
	}
	backs.n = kept
	if backs.n == MAX_BACKS {
		return -1
	}
	o.above, o.side = BACK_ABOVE, BACK_EDGE
	backs.list[backs.n] = {opening = o, lo = lo & 0x1fffff, hi = 0x200000, stamp = now}
	backs.n += 1
	return backs.n - 1
}

// Close back k's run of packets at `hi`.
back_end :: proc(k: int, hi: u32) {
	if k >= 0 && k < backs.n {
		backs.list[k].hi = hi & 0x1fffff
	}
}

// The opening `quad` (view space) as the GTE's projection stands, seen from
// the side `front` lies on; false when wholly behind the lens or seen from
// the other side.
@(private)
opening_make :: proc(quad: [4][3]f32, front: [3]f32) -> (o: Opening, ok: bool) {
	if _, n, _ := opening_project(quad); n < 3 {
		return
	}
	o.quad = quad
	o.h = f32(gte.state.h)
	o.of = [2]f32{f32(gte.state.ofx), f32(gte.state.ofy)} / 0x10000
	o.normal = linalg.normalize0(linalg.cross(quad[1] - quad[0], quad[2] - quad[0]))
	o.dist = linalg.dot(o.normal, quad[0])
	if o.normal == {} {
		return
	}
	// The lens (the origin) and `front` on the same side.
	if -o.dist * (linalg.dot(o.normal, front) - o.dist) <= 0 {
		return
	}
	if o.dist > 0 {
		o.normal, o.dist = -o.normal, -o.dist
	}
	return o, true
}

// Drop the pictures and backs waiting for a walk (a pass drawing another
// map).
pictures_clear :: proc() {
	pictures.n = 0
	backs.n = 0
	cover.pixels = nil
}

// Whether the frame's GTE projections must keep their depths: pictures or
// backs wait for the walk.
@(private)
depths_wanted :: proc() -> bool {
	return pictures.n > 0 || backs.n > 0 || cover_due()
}

// Whether the polygon with these corners (packet positions, view depth),
// drawn from the packet at render.packet_now, is a back left out.
@(private)
back_left_out :: proc(corners: [][3]f32) -> bool {
	now := cpu.vblanks()
	for &b in backs.list[:backs.n] {
		if render.packet_now >= b.lo && render.packet_now < b.hi && now - b.stamp <= PORTAL_VBLANKS && in_back(&b, corners) {
			return true
		}
	}
	return false
}

// The picture (index + 1) whose doorway back the polygon with these
// corners (packet positions, view depth) is part of, or 0.
@(private)
picture_back :: proc(corners: [][3]f32) -> u8 {
	for &p, k in pictures.list[:pictures.n] {
		if ats, ok := back_at(&p.opening, corners); ok {
			// The span is the doorway's back proper: walls beside it on its
			// plane (PICTURE_SIDE) are left out of it.
			lo, hi := max(f32), min(f32)
			for at in ats[:len(corners)] {
				lo, hi = min(lo, at.x), max(hi, at.x)
			}
			if lo >= -BACK_EDGE && hi <= 1 + BACK_EDGE {
				p.span = {min(p.span[0], lo), max(p.span[1], hi)}
			}
			if p.blank {
				curtain_corners(corners)
			}
			return u8(k + 1)
		}
		if off, ok := back_off(&p.opening, corners); ok {
			p.off = min(p.off, off)
		}
	}
	return 0
}

// How far before p's opening (view units) a polygon stands that could be
// its doorway's back off the plane: upright and parallel to it, spanning
// the opening's height and no more (the wall beside the doorway reaches
// above it), within its sides, at most BACK_BEFORE before it.
// The nearest such polygon is the back; the wall's face, farther, is not.
@(private)
back_off :: proc(p: ^Opening, corners: [][3]f32) -> (off: f32, ok: bool) {
	if p.quad[1] == p.quad[0] || p.quad[3] == p.quad[0] {
		return
	}
	lo, hi := [3]f32{max(f32), max(f32), max(f32)}, [3]f32{min(f32), min(f32), min(f32)}
	for c in corners {
		at := opening_at(p, c)
		lo, hi = linalg.min(lo, at), linalg.max(hi, at)
	}
	if lo.z <= BACK_ON || hi.z > BACK_BEFORE || hi.z - lo.z > BACK_ON {
		return
	}
	if lo.x < -BACK_EDGE || hi.x > 1 + BACK_EDGE || hi.x - lo.x < BACK_EDGE || lo.y > BACK_EDGE || hi.y < 1 - BACK_EDGE || hi.y > 1 + BACK_EDGE {
		return
	}
	return (lo.z + hi.z) / 2, true
}

// Corner `c` (packet position, view depth) against opening p: how far
// across it and up it (fractions, from its first corner), and how far from
// its plane toward the lens (view units).
@(private)
opening_at :: proc(p: ^Opening, c: [3]f32) -> [3]f32 {
	e1 := p.quad[1] - p.quad[0]
	e2 := p.quad[3] - p.quad[0]
	at := render.unproject(c.x, c.y, c.z, p.h, p.of)
	return {linalg.dot(at - p.quad[0], e1) / linalg.dot(e1, e1), linalg.dot(at - p.quad[0], e2) / linalg.dot(e2, e2), linalg.dot(p.normal, at) - p.dist}
}

// The polygon lies within p's opening, on or behind its plane.
@(private)
in_back :: proc(p: ^Opening, corners: [][3]f32) -> bool {
	_, ok := back_at(p, corners)
	return ok
}

// The corners of a polygon lying within p's opening, on or behind its
// plane, against it (as opening_at); false when it does not. Depths come
// from the projections filed by screen position, and a vertex hidden behind
// the back at the same pixel (Sarai 0204: the house floor, 450 deep) can
// give one corner its depth: that corner, too deep, is put back on the
// plane along its ray from the lens. One before the plane is no stray: a
// doorway side reaches toward the lens from it.
@(private)
back_at :: proc(p: ^Opening, corners: [][3]f32) -> (ats: [4][3]f32, ok: bool) {
	if p.quad[1] == p.quad[0] || p.quad[3] == p.quad[0] {
		return
	}
	strays := 0
	for c, k in corners {
		at := opening_at(p, c)
		if at.z > BACK_ON {
			return
		}
		if at.z < -BACK_DEEP {
			ray := [3]f32{(c.x - p.of.x) / p.h, (c.y - p.of.y) / p.h, 1}
			n := linalg.dot(p.normal, ray)
			strays += 1
			if strays > 1 || n == 0 || p.dist / n <= 0 {
				return
			}
			at = opening_at(p, {c.x, c.y, p.dist / n})
		}
		if at.x < -p.side || at.x > 1 + p.side || at.y < -BACK_EDGE || at.y > 1 + p.above {
			return
		}
		ats[k] = at
	}
	return ats, true
}

// Lay the waiting pictures over the walk's scene and spend them
// (render.picture_flush): before the HUD (bucket 0) and, failing that, at
// the walk's end.
@(private)
doors_lay :: proc() {
	backs.n = 0
	now := cpu.vblanks()
	for &p, k in pictures.list[:pictures.n] {
		if now - p.stamp <= PORTAL_VBLANKS {
			render.lay_picture(&p.lay, u8(k + 1))
		}
		pictures.spans[k] = p.span
		pictures.offs[k] = p.off
	}
	if cover_due() {
		cover.hole = cover_hole^
		render.lay_picture(&cover.lay, render.DOOR_CLEAR, render.DOOR_COVER)
		cover.pixels = nil
	}
	pictures.spent = pictures.n
	pictures.n = 0
}
