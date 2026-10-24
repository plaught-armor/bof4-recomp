// The third-person field world drawn in 3D ([window] native_world; not a
// PS1 feature). The game's tile and model code (qol/map_geometry.odin) still
// builds its packets and orders them, but files each world quad's corners in
// view space here (world_quad_add), by the packet's address. When the walk
// reaches such a packet, exec_polygon draws it from those corners instead of
// the packet's screen positions: clipped at the lens (WORLD_NEAR), projected
// exactly, each corner at its own depth. The PS1 GPU's corners are whole
// pixels the GTE clamped to +-1024 and set to depth 0 behind the lens, so
// floors running under a close camera warped, tore and opened holes.
package psx

import "core:math"

// Set from the config.
native_world := false

// The view depth (view units; a cell is 128) a world polygon is cut at.
WORLD_NEAR :: f32(2)

@(private)
WORLD_SLOT_BITS :: 13
@(private)
WORLD_SLOTS :: 1 << WORLD_SLOT_BITS
// Slots a lookup probes past its own before giving up.
@(private)
WORLD_RUN :: 64
// Corners of a quad cut by the near plane (a twisted quad can have more
// than the five of a flat one).
@(private)
WORLD_CORNERS :: 8

// One world quad's packet: its address, the walk it is for (gen against
// world_quads.now), its corners in view space in packet order (0 1 / 2 3),
// and the GTE's H and screen offset it was projected with.
@(private)
World_Quad :: struct {
	key, gen: u32,
	p:        [4][3]f32,
	h:        f32,
	of:       [2]f32,
}

// Quads filed since the last ordering-table walk: open addressing, a slot
// counting only when its gen is `now`.
@(private)
world_quads: struct {
	slots: [WORLD_SLOTS]World_Quad,
	now:   u32,
}

// What a frozen-time pass changed in world_quads, to undo at restore (as
// Depth_Undo).
@(private)
World_Undo :: struct {
	kept: [WORLD_SLOTS / 64]u64,
	slot: [WORLD_SLOTS]u32,
	old:  [WORLD_SLOTS]World_Quad,
	n:    u32,
	now:  u32,
}

// Whether the world is drawn in 3D now: the third-person field.
world_on :: #force_inline proc() -> bool {
	return native_world && tiles_unculled
}

// The view-space point (view units) the GTE's rotation and translation put
// model point v at, by the exact view when on.
world_view :: proc(v: [3]i16) -> [3]f32 {
	g := &gte
	full: [3]f64
	for r in 0 ..< 3 {
		full[r] = f64(i64(g.tr[r]) << 12 + i64(g.rt[r][0]) * i64(v[0]) + i64(g.rt[r][1]) * i64(v[1]) + i64(g.rt[r][2]) * i64(v[2]))
	}
	if exact_on() {
		e := &exact_view
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
	o := gte_offset()
	return f32(gte.h), {f32(o[0]), f32(o[1])}
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
			e^ = {key, w.now, p, h, of}
			return
		}
		s = (s + 1) & (WORLD_SLOTS - 1)
	}
}

// The quad filed for the packet at addr this walk.
@(private)
world_quad :: proc(addr: u32) -> (^World_Quad, bool) #no_bounds_check {
	w := &world_quads
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
}

@(private)
world_undo_begin :: proc(u: ^World_Undo) {
	assert(u.n == 0, "world undo log not empty")
	u.now = world_quads.now
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
}

// Slot s is about to change: inside a pass, log it first.
@(private)
world_keep :: #force_inline proc(s: u32) #no_bounds_check {
	if pass_checkpoint == nil {
		return
	}
	u := &pass_checkpoint.worlds
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
world_cut :: proc(w: ^World_Quad, vs: [4]Vertex, out: ^[WORLD_CORNERS]Vertex) -> (n: int, few: [4]Vertex, nf: int) {
	corner :: proc(w: ^World_Quad, v: Vertex, k: int) -> World_Corner {
		return {p = w.p[k], c = {f32(v.r), f32(v.g), f32(v.b)}, t = {f32(v.u), f32(v.v)}}
	}
	mix :: proc(a, b: World_Corner, f: f32) -> World_Corner {
		return {p = a.p + (b.p - a.p) * f, c = a.c + (b.c - a.c) * f, t = a.t + (b.t - a.t) * f, cut = true}
	}
	edge := [4]int{0, 1, 3, 2}
	poly: [WORLD_CORNERS]World_Corner
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
ordered_remove_corner :: proc(a: ^[WORLD_CORNERS]World_Corner, n, k: int) {
	for i in k ..< n - 1 {
		a[i] = a[i + 1]
	}
}

// Corner c on screen. Drawn, it lands where the lens puts it, in
// sixteenths of a pixel. For the tests, it lands where the GTE would put
// it: they take screen corners back to view space (unproject), which holds
// the depth at H / 2 nearer than that, as the GTE's divide does.
@(private)
world_vertex :: proc(w: ^World_Quad, c: World_Corner, gte_like: bool) -> Vertex {
	LIMIT :: f32(1 << 26)
	z := gte_like ? max(c.p.z, w.h * DIVIDE_MAX) : c.p.z
	at := w.h / z
	sx := clamp((w.of.x + c.p.x * at + f32(gpu.off_x)) * SUB_PIXEL, -LIMIT, LIMIT)
	sy := clamp((w.of.y + c.p.y * at + f32(gpu.off_y)) * SUB_PIXEL, -LIMIT, LIMIT)
	v := Vertex {
		sx = i32(math.floor(sx + 0.5)),
		sy = i32(math.floor(sy + 0.5)),
		r  = i32(c.c.r + 0.5),
		g  = i32(c.c.g + 0.5),
		b  = i32(c.c.b + 0.5),
		u  = i32(math.floor(c.t.x + 0.5)),
		v  = i32(math.floor(c.t.y + 0.5)),
		z  = c.p.z,
	}
	v.x, v.y = i32(math.floor(sx / SUB_PIXEL)), i32(math.floor(sy / SUB_PIXEL))
	if gte_like {
		v.sx, v.sy = v.x * SUB_PIXEL, v.y * SUB_PIXEL
	}
	return v
}
