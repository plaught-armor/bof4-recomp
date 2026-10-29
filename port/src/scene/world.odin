// The third-person field world drawn in 3D (not a PS1 feature). The game's
// tile and model code (qol/map_geometry.odin) still
// builds its packets and orders them, but files each world quad's corners in
// view space here (world_quad_add), by the packet's address. When the walk
// reaches such a packet, prim_shape (hooks.odin) has the renderer draw it
// from those corners instead of
// the packet's screen positions: clipped at the lens (WORLD_NEAR), projected
// exactly, each corner at its own depth. The PS1 GPU's corners are whole
// pixels the GTE clamped to +-1024 and set to depth 0 behind the lens, so
// floors running under a close camera warped, tore and opened holes.
package scene

import "core:math"
import "core:math/linalg"
import "core:slice"
import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import render "ps:psx/render"

// The view depth (view units; a cell is 128) a world polygon is cut at.
WORLD_NEAR :: f32(2)

@(private)
WORLD_SLOT_BITS :: 13
@(private)
WORLD_SLOTS :: 1 << WORLD_SLOT_BITS
// Slots a lookup probes past its own before giving up.
@(private)
WORLD_RUN :: 64

// One world quad's packet: its address, the walk it is for (gen against
// world_quads.now), its corners in view space in packet order (0 1 / 2 3),
// the GTE's H and screen offset it was projected with, and whether it is a
// decal (world_decals_mark).
@(private)
World_Quad :: struct {
	key, gen: u32,
	p:        [4][3]f32,
	h:        f32,
	of:       [2]f32,
	decal:    bool,
}

// Quads filed since the last ordering-table walk: open addressing, a slot
// counting only when its gen is `now`; whether the walk's decals are
// marked.
@(private)
world_quads: struct {
	slots:  [WORLD_SLOTS]World_Quad,
	now:    u32,
	marked: bool,
}

// What a frozen-time pass changed in world_quads, to undo at restore (as
// render.Depth_Undo).
@(private)
World_Undo :: struct {
	kept:   [WORLD_SLOTS / 64]u64,
	slot:   [WORLD_SLOTS]u32,
	old:    [WORLD_SLOTS]World_Quad,
	n:      u32,
	now:    u32,
	marked: bool,
}

// Whether the world is drawn in 3D now: the third-person field.
world_on :: #force_inline proc() -> bool {
	return cpu.host_camera
}

// The view-space point (view units) the GTE's rotation and translation put
// model point v at, by the exact view when on.
world_view :: proc(v: [3]i16) -> [3]f32 {
	g := &gte.state
	full: [3]f64
	for r in 0 ..< 3 {
		full[r] = f64(i64(g.tr[r]) << 12 + i64(g.rt[r][0]) * i64(v[0]) + i64(g.rt[r][1]) * i64(v[1]) + i64(g.rt[r][2]) * i64(v[2]))
	}
	if gte.exact_on() {
		e := &gte.exact_view
		x: [3]f64
		for r in 0 ..< 3 {
			x[r] = e.m[r][0] * full[0] + e.m[r][1] * full[1] + e.m[r][2] * full[2] + e.t[r] * 0x1000
		}
		full = x
	}
	return {f32(full[0] / 0x1000), f32(full[1] / 0x1000), f32(full[2] / 0x1000)}
}

// The GTE's H and screen offset, in pixels.
world_lens :: proc() -> (h: f32, of: [2]f32) {
	o := gte.gte_offset()
	return f32(gte.state.h), {f32(o[0]), f32(o[1])}
}

@(private)
world_slot :: #force_inline proc(key: u32) -> u32 {
	return (key * 2654435761) >> (32 - WORLD_SLOT_BITS)
}

// File the quad packet at addr with view-space corners p (packet order),
// projected with the GTE's lens as it stands.
world_quad_add :: proc(addr: u32, p: [4][3]f32) #no_bounds_check {
	w := &world_quads
	key := addr & 0x1ffffc | 1 << 31
	h, of := world_lens()
	s := world_slot(key)
	for _ in 0 ..< WORLD_RUN {
		e := &w.slots[s]
		if e.gen != w.now || e.key == 0 || e.key == key {
			world_keep(s)
			e^ = {key, w.now, p, h, of, false}
			return
		}
		s = (s + 1) & (WORLD_SLOTS - 1)
	}
}

// The quad filed for the packet at addr this walk.
@(private)
world_quad :: proc(addr: u32) -> (^World_Quad, bool) #no_bounds_check {
	w := &world_quads
	if !w.marked {
		world_decals_mark()
	}
	key := addr & 0x1ffffc | 1 << 31
	s := world_slot(key)
	for _ in 0 ..< WORLD_RUN {
		e := &w.slots[s]
		if e.gen != w.now || e.key == 0 {
			return nil, false
		}
		if e.key == key {
			return e, true
		}
		s = (s + 1) & (WORLD_SLOTS - 1)
	}
	return nil, false
}

// End a walk: the quads filed for it are spent.
@(private)
world_walk_end :: proc() {
	world_quads.now += 1
	world_quads.marked = false
}

// Units a quad's corners may stray from another's plane and bounds and still
// lie in them (view-space rounding), and the most of the other's area it may
// cover.
@(private = "file")
DECAL_SLACK :: f32(0.5)
@(private = "file")
DECAL_SHARE :: f32(0.9)

// A filed quad's view-space bounds, by slot.
@(private = "file")
Decal_Box :: struct {
	lo, hi: [3]f32,
	slot:   u32,
}

@(private = "file")
decal_boxes: [WORLD_SLOTS]Decal_Box

// Mark the walk's decals: quads lying in another's plane, inside its bounds
// and smaller, as the scalloped valance of an awning painted over a wall
// top. The table orders the two by their farthest corners, which trade
// places as the camera moves, so the depth buffer takes a decal nearer
// (render Z_LIFT) to keep it over the surface it lies on.
@(private = "file")
world_decals_mark :: proc() #no_bounds_check {
	w := &world_quads
	w.marked = true
	n := 0
	for &e, s in w.slots {
		if e.gen != w.now || e.key == 0 {
			continue
		}
		b := &decal_boxes[n]
		b.lo, b.hi, b.slot = e.p[0], e.p[0], u32(s)
		for c in e.p[1:] {
			for k in 0 ..< 3 {
				b.lo[k] = min(b.lo[k], c[k])
				b.hi[k] = max(b.hi[k], c[k])
			}
		}
		n += 1
	}
	boxes := decal_boxes[:n]
	slice.sort_by(boxes, proc(a, b: Decal_Box) -> bool {return a.lo.x < b.lo.x})
	for &a, i in boxes {
		for &b in boxes[i + 1:] {
			if b.lo.x > a.hi.x + DECAL_SLACK {
				break
			}
			if decal_in(b, a) {
				world_keep(b.slot)
				w.slots[b.slot].decal = true
			} else if decal_in(a, b) {
				world_keep(a.slot)
				w.slots[a.slot].decal = true
			}
		}
	}
}

// Whether quad q lies in quad p's plane and bounds, covering less of it
// than DECAL_SHARE.
@(private = "file")
decal_in :: proc(q, p: Decal_Box) -> bool #no_bounds_check {
	for k in 0 ..< 3 {
		if q.lo[k] < p.lo[k] - DECAL_SLACK || q.hi[k] > p.hi[k] + DECAL_SLACK {
			return false
		}
	}
	pc, qc := &world_quads.slots[p.slot].p, &world_quads.slots[q.slot].p
	// Twice the area along the normal, from the diagonals (0 1 / 2 3).
	nrm := linalg.cross(pc[3] - pc[0], pc[2] - pc[1])
	l := linalg.length(nrm)
	if l < 1 || linalg.length(linalg.cross(qc[3] - qc[0], qc[2] - qc[1])) >= l * DECAL_SHARE {
		return false
	}
	for c in qc {
		if abs(linalg.dot(nrm, c - pc[0])) > DECAL_SLACK * l {
			return false
		}
	}
	return true
}

@(private)
world_undo_begin :: proc(u: ^World_Undo) {
	assert(u.n == 0, "world undo log not empty")
	u.now = world_quads.now
	u.marked = world_quads.marked
	// The pass files its quads under a walk of its own: the frame drawn
	// since (whose walk is still to come) filed its quads under `now`, and
	// a packet of the pass at one of their addresses that is no world quad
	// (a model's polygon) took that quad's corners, a stray slab over the
	// field.
	world_quads.now += 1
	world_quads.marked = false
}

@(private)
world_undo_end :: proc(u: ^World_Undo) #no_bounds_check {
	w := &world_quads
	for i in 0 ..< u.n {
		s := u.slot[i]
		w.slots[s] = u.old[i]
		u.kept[s >> 6] &~= 1 << (s & 63)
	}
	u.n = 0
	w.now = u.now
	w.marked = u.marked
}

// Slot s is about to change: inside a pass, log it first.
@(private)
world_keep :: #force_inline proc(s: u32) #no_bounds_check {
	if pass_n == 0 {
		return
	}
	u := &passes[pass_n - 1].worlds
	bit := u64(1) << (s & 63)
	if u.kept[s >> 6] & bit != 0 {
		return
	}
	u.kept[s >> 6] |= bit
	u.slot[u.n] = s
	u.old[u.n] = world_quads.slots[s]
	u.n += 1
}

// A corner of a world polygon: view-space point, shade and texel, and
// whether the near plane made it.
@(private)
World_Corner :: struct {
	p:   [3]f32,
	c:   [3]f32,
	t:   [2]f32,
	cut: bool,
}

// The polygon of quad w, its packet corners vs, cut at WORLD_NEAR: its
// corners round its edge (out), and at most four of them (in GPU order,
// as a quad's run 0 1 / 2 3) standing for it in the tests made on whole
// polygons (see_cover, cut_left_out, the blacks): where the cut made five
// or more, a pair the cut made merges into their middle.
@(private)
world_cut :: proc(w: ^World_Quad, vs: [4]render.Vertex, out: ^[render.FAN_CORNERS]render.Vertex) -> (n: int, few: [4]render.Vertex, nf: int) {
	corner :: proc(w: ^World_Quad, v: render.Vertex, k: int) -> World_Corner {
		return {p = w.p[k], c = {f32(v.r), f32(v.g), f32(v.b)}, t = {f32(v.u), f32(v.v)}}
	}
	mix :: proc(a, b: World_Corner, f: f32) -> World_Corner {
		return {p = a.p + (b.p - a.p) * f, c = a.c + (b.c - a.c) * f, t = a.t + (b.t - a.t) * f, cut = true}
	}
	edge := [4]int{0, 1, 3, 2}
	poly: [render.FAN_CORNERS]World_Corner
	for k in 0 ..< 4 {
		a, b := corner(w, vs[edge[k]], edge[k]), corner(w, vs[edge[(k + 1) % 4]], edge[(k + 1) % 4])
		front_a, front_b := a.p.z >= WORLD_NEAR, b.p.z >= WORLD_NEAR
		if front_a {
			poly[n] = a
			n += 1
		}
		if front_a != front_b {
			poly[n] = mix(a, b, (WORLD_NEAR - a.p.z) / (b.p.z - a.p.z))
			n += 1
		}
	}
	if n < 3 {
		return 0, {}, 0
	}
	for c, k in poly[:n] {
		out[k] = world_vertex(w, c, false)
	}
	// The tests: no more than four corners, merging pairs the cut made.
	keep := poly
	nk := n
	for nk > 4 {
		merged := false
		for k in 0 ..< nk {
			j := (k + 1) % nk
			if keep[k].cut && keep[j].cut {
				keep[k] = mix(keep[k], keep[j], 0.5)
				ordered_remove_corner(&keep, nk, j)
				nk -= 1
				merged = true
				break
			}
		}
		if !merged {
			nk = 4
		}
	}
	// Round the edge to GPU order: 0 1 3 2 for four.
	order := [4]int{0, 1, 3, 2}
	for k in 0 ..< nk {
		few[nk == 4 ? order[k] : k] = world_vertex(w, keep[k], true)
	}
	return n, few, nk
}

@(private = "file")
ordered_remove_corner :: proc(a: ^[render.FAN_CORNERS]World_Corner, n, k: int) {
	for i in k ..< n - 1 {
		a[i] = a[i + 1]
	}
}

// Corner c on screen. Drawn, it lands where the lens puts it, in
// sixteenths of a pixel. For the tests, it lands where the GTE would put
// it: they take screen corners back to view space (unproject), which holds
// the depth at H / 2 nearer than that, as the GTE's divide does.
@(private)
world_vertex :: proc(w: ^World_Quad, c: World_Corner, gte_like: bool) -> render.Vertex {
	LIMIT :: f32(1 << 26)
	z := gte_like ? max(c.p.z, w.h * render.DIVIDE_MAX) : c.p.z
	at := w.h / z
	sx := clamp((w.of.x + c.p.x * at + f32(render.gpu.off_x)) * gte.SUB_PIXEL, -LIMIT, LIMIT)
	sy := clamp((w.of.y + c.p.y * at + f32(render.gpu.off_y)) * gte.SUB_PIXEL, -LIMIT, LIMIT)
	v := render.Vertex {
		sx = i32(math.floor(sx + 0.5)),
		sy = i32(math.floor(sy + 0.5)),
		r  = i32(c.c.r + 0.5),
		g  = i32(c.c.g + 0.5),
		b  = i32(c.c.b + 0.5),
		u  = i32(math.floor(c.t.x + 0.5)),
		v  = i32(math.floor(c.t.y + 0.5)),
		z  = c.p.z,
	}
	v.x, v.y = i32(math.floor(sx / gte.SUB_PIXEL)), i32(math.floor(sy / gte.SUB_PIXEL))
	if gte_like {
		v.sx, v.sy = v.x * gte.SUB_PIXEL, v.y * gte.SUB_PIXEL
	}
	return v
}
