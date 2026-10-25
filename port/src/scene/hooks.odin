// The game's answers to the renderer's scene hooks (render scene_hooks.odin):
// which packets are world quads, sprites and screen pictures, which are left
// out, how a polygon covers the leader and whose doorway back it is, and the
// state a frozen-time pass keeps.
package scene

import render "ps:psx/render"

@(init, private)
hooks_init :: proc "contextless" () {
	render.scene = {
		walk_doors    = depths_wanted,
		walk_end      = walk_end,
		packet        = packet,
		prim_shape    = prim_shape,
		prim_drop     = prim_drop,
		prim_classify = prim_classify,
		doors_lay     = doors_lay,
		pass_save     = pass_save,
		pass_restore  = pass_restore,
	}
}

// End a walk: the portals it met and the quads filed for it are spent.
@(private)
walk_end :: proc() {
	portal_walk_end()
	world_walk_end()
}

@(private)
packet :: proc(a: u32) {
	if portals.n > 0 {
		portal_find(a)
	}
}

// A world quad (world.odin) is drawn as its corners in view space cut at
// the lens; the tests on the whole polygon take up to four of them. A
// sprite's corners take where it stands (see_flat_add), never the depth
// cache's: a corner of the ground projected onto one of its corners gave
// the sprite that depth, and see-through then ghosted it as part of the
// scene.
@(private)
prim_shape :: proc(vs: ^[4]render.Vertex, verts: ^int, shape: ^render.Prim_Shape) {
	w: ^World_Quad
	in_world := false
	if verts^ == 4 {
		w, in_world = world_quad(render.packet_now)
	}
	screen := screens.n > 0 && on_screen(render.packet_now)
	f: Flat
	filed := false
	if !in_world && !screen && flats.n > 0 {
		f, filed = see_flat(render.packet_now)
	}
	switch {
	case in_world:
		shape.n, vs^, verts^ = world_cut(w, vs^, &shape.fan)
		if shape.n == 0 {
			shape.kind = .Drop
			return
		}
		shape.kind, shape.decal = .World, w.decal
	case screen:
		shape.kind = .Screen
	case filed:
		shape.kind = .Sprite
		shape.z, shape.at, shape.sub, shape.front, shape.clear = f.z, f.at, f.sub, f.front, f.clear
	}
}

@(private)
prim_drop :: proc(vs: []render.Vertex, m: ^render.Prim_Mode) -> bool {
	return (blacks.n > 0 || blacks.all || cover_due()) && black_left_out(vs, m)
}

@(private)
prim_classify :: proc(vs: []render.Vertex, corners: [][3]f32, m: ^render.Prim_Mode, flat, front: bool, clear: f32, whole: bool) -> bool {
	see := &render.see
	// The party in front of a door's cover never fades (Flat.front), but
	// by its own Flat.clear.
	if see.active && !front {
		m.cover = see_cover(corners)
		if flat {
			m.cover = see_sprite_cover(vs[0].z)
			m.cover.clear = clear
			m.flat = true
		}
	} else if see.active && clear > 0 {
		m.cover = {sprite = true, clear = clear}
		m.flat = true
	}
	// A black face between the leader and the lens is the game's fill for
	// what its own camera never sees (a room's wall tops, the curtain past
	// its doorway): from behind the leader it hides the floor he walks on,
	// so it is left out. A thin one (a rope) is drawn, and a town's are all
	// drawn (its clotheslines are thin strips seen edge on).
	if see.active && room && m.cover.weight > 0 && !m.cover.sprite && !m.semi && polygon_black(vs, m) && !see_thin(corners) {
		return false
	}
	if cut.on && whole && !flat && cut_left_out(corners) {
		return false
	}
	if render.depth_walk.on && whole && !flat {
		if backs.n > 0 && back_left_out(corners) {
			return false
		}
		m.door = picture_back(corners)
	}
	// Sprites and the room's own doorway backs too: past the doorway all
	// of the room stands behind the town's wall. The party walking in
	// through it (Flat.front) stays in front.
	if render.depth_walk.on && m.door != render.DOOR_CLEAR && cover_due() && !front {
		m.door = render.DOOR_COVER
	}
	return true
}

// Passes nest at most twice (checkpoint.odin).
@(private)
MAX_PASSES :: 2

// What a frozen-time pass keeps of the scene, to put back at its end.
@(private)
Scene_Pass :: struct {
	worlds:     World_Undo,
	flats:      type_of(flats),
	portals:    type_of(portals),
	pictures:   type_of(pictures),
	backs:      type_of(backs),
	cover:      Picture,
	blacks:     type_of(blacks),
	feet:       f32,
	room:       bool,
}

// The passes running, innermost last (World_Undo is too big for the stack).
@(private)
passes: [MAX_PASSES]Scene_Pass
@(private)
pass_n: int

@(private)
pass_save :: proc() {
	assert(pass_n < MAX_PASSES, "scene passes nested too deep")
	p := &passes[pass_n]
	pass_n += 1
	world_undo_begin(&p.worlds)
	p.flats = flats
	p.portals = portals
	p.pictures = pictures
	p.backs = backs
	p.cover = cover
	p.blacks = blacks
	p.feet, p.room = feet, room
}

@(private)
pass_restore :: proc() {
	assert(pass_n > 0, "scene pass restored without a save")
	p := &passes[pass_n - 1]
	world_undo_end(&p.worlds)
	pass_n -= 1
	flats = p.flats
	portals = p.portals
	pictures = p.pictures
	backs = p.backs
	cover = p.cover
	blacks = p.blacks
	feet, room = p.feet, p.room
}
