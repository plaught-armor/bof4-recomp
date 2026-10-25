// Seamless sections, step one: a map file holds several sections (rooms,
// corridors), each in its own coordinate frame, and the game draws only the
// one the leader is in; the others are behind a load zone (an exit to the
// same map, another section). All of them are in RAM, so the neighbours are
// drawn too, placed where their doorways meet this section's.
//
// SCENE_DRAW (0x801420a4) draws the current section's layers from the last
// down to the first: LAYER_VIEW sets the view for the layer (its origin
// against the camera target), LAYER_SETUP points the drawing at the layer
// held at DRAW_LAYER, LAYER_DRAW puts its geometry into the ordering table
// and, with DRAW_FLAGS bit 3, MODELS_DRAW its placed models. The hook on
// LAYER_DRAW runs the game's drawing, and after the section's first layer
// it draws each neighbour's layers the same way, with the GTE translation
// moved by the neighbour's offset, then puts the section's back.
//
// A neighbour is a section this one has an exit to whose exit list leads
// back here. The two exits are the floor cells either side of the wall
// between the sections: the offset puts the other exit's middle past this
// one's, across that wall, and makes up the difference in the ground's
// height there (each section has its own floor level).
//
// The people of a neighbour are the game's own, spawned for it: once per
// section, SPAWN runs again as if the neighbour were loaded, its new objects
// are kept and all of RAM is put back. Those are people (NPC pool) and model
// objects (pool2 at 0x801192cc: furniture, doors and the like, drawn by
// MODEL_OBJECTS_DRAW). Each frame the kept objects are drawn, moved into this
// section's frame, through their doorway only: sprites with the sprite pass,
// models right after the game's own model objects. People live
// on in their own section's frame: after the people's NPC_UPDATE, it runs
// again per neighbour with only that neighbour's people in the slots they
// were spawned in and MAP_SECTION set to the neighbour, so their scripts walk
// them on its grid.
package qol

import "core:math"

import "../psx"

import "ps:core"

@(private = "file")
LAYER_SETUP :: 0x80143304 // per-layer drawing pointers for DRAW_LAYER
@(private = "file")
SET_TRANS :: 0x80169e34 // a0 = matrix; GTE translation from its +20
@(private = "file")
DRAW_LAYER :: 0x1f80008c // u8
@(private = "file")
DRAW_FLAGS :: 0x80116fac // u8, bit 3: draw placed models
@(private = "file")
FLAG_MODELS :: 0x8

@(private = "file")
TILE_RUNS :: 0x8017c618 // LAYER_SETUP's runs of tiles to draw, 8 bytes each
@(private = "file")
TILE_RUN_COUNT :: 0x1f800090 // u16
@(private = "file")
// u16 kind: bit 0 set, a heightfield quad and a shared model; clear, the rest
// counts the tile's own polygons. Then corner heights and the polygons.
TILE_SIZE :: 16
@(private = "file")
TILE_SPAN :: 256 // view units, two cells
@(private = "file")
TILE_CORNER :: -64 // a tile's low corner against its block's
@(private = "file")
MAX_HIDDEN :: 128
@(private = "file")
MAX_TILES :: 1024 // tiles LAYER_SETUP picks, at most
@(private = "file")
MAX_MODELS :: 255 // placed models in a layer, at most (u8 count)
// A layer's placed models, from its descriptor: u8 count at +2, then
// MODEL_SIZE entries from +4.
@(private = "file")
MODEL_COUNT :: 2
@(private = "file")
MODEL_FIRST :: 4
@(private = "file")
MODEL_SIZE :: 12
@(private = "file")
MODEL_FLAGS :: 2 // u8, bit 5: drawn
@(private = "file")
MODEL_DRAWN :: 0x20
@(private = "file")
MODEL_X :: 4 // u16 x, z at +4, +8: MODEL_UNIT view units each
@(private = "file")
MODEL_UNIT :: 16
@(private = "file")
MODEL_Z :: 8
@(private = "file")
MAX_CELLS :: 256 * 256 // attr_at reads cells past 255 as outside

@(private = "file")
LAYER_ORIGIN :: 0x80138208 // 8 bytes a layer: u8 x, pad, s16 y, u8 z
@(private = "file")
EXITS :: 0x80116be8 // u32 -> u32 -> per-section exit lists
@(private = "file")
EXIT_SIZE :: 12
@(private = "file")
EXIT_END :: 0xffff

@(private = "file")
VIEW_PER_CELL :: 128
@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
OBJ_POS :: 0xc // s32 x, y, z, 16.16
@(private = "file")
OBJ_LAYER :: 0x18 // u8, the layer of its section it walks on, counted from the first
@(private = "file")
STATE_EXIT_WALK :: 2 // walked through an exit, out and in
@(private = "file")
TARGET_PER_CELL :: 256
@(private = "file")
MAX_NEIGHBOURS :: 8
@(private = "file")
MAX_WALL :: 4 // the thickest wall between two doorways
@(private = "file")
DOOR_HEIGHT :: 3 * VIEW_PER_CELL // a doorway's opening above its ground, view units
@(private = "file")
DOOR_MARGIN :: 0.25 // cells the opening reaches past each side of the exit
@(private = "file")
DOOR_EDGE :: 0.5 // cells from an exit's middle to its far edge
@(private = "file")
UPPER_RISE :: VIEW_PER_CELL / 2 // climb through a doorway that makes its neighbour an upper floor, view units
@(private = "file")
PACKETS :: 0x1f80006c // u32, where the next GPU packet goes
@(private = "file")
ATTR_WALL_KIND :: 0x1 // high nibble of a wall cell's attribute
@(private = "file")
ATTR_EXIT_KIND :: 0xa // high nibble of an exit cell's attribute
GROUND :: 0x8014a8a0 // a0 = position (s32 16.16 x, y, z), a1 = layer - section: v0 ground y, 16.16
@(private = "file")
LEADER_Y :: 0x80116fc0 // s32 16.16, the leader's height
@(private = "file")
POS_AT :: 0x40 // a position below the caller's stack pointer
@(private = "file")
CELL :: 0x10000

@(private = "file")
NPC_POS :: 12 // s32 x, y, z, 16.16 a cell
@(private = "file")
NPC_SPRITE :: 84 // the sprite record within an object
@(private = "file")
NPC_PREV :: 28 // NPC_POS as the frame's NPC_UPDATE found it
@(private = "file")
MAX_BLEND :: 2 * CELL // a move per frame past this is a jump, not blended
@(private = "file")
NPC_UPDATE :: 0x801da4b0 // each frame: the people's scripts, moves and animations
@(private = "file")
PARTY_SIZE :: 0xfc
@(private = "file")
PARTY_COUNT :: 3
@(private = "file")
AWAY :: 0x40000000 // the party's x moved by this while a neighbour's people run
@(private = "file")
MODEL_OBJS :: 0x801192cc // the other objects (models), MODEL_OBJ_COUNT of MODEL_OBJ_SIZE bytes; u8 +0 0 when free
@(private = "file")
MODEL_OBJ_SIZE :: 156
@(private = "file")
MODEL_OBJ_COUNT :: 32
@(private = "file")
OBJ_SHOWN :: 0x2 // u8 +0 of an object: COLLECT lists it
@(private = "file")
OBJ_MODEL :: 0x4 // listed as a model, drawn by MODEL_OBJECTS_DRAW (else a sprite)
@(private = "file")
Pool :: struct {
	base, size, count: u32,
}
// The object pools a spawn script fills.
@(private = "file")
POOLS := [?]Pool{{NPCS, NPC_SIZE, NPC_COUNT}, {MODEL_OBJS, MODEL_OBJ_SIZE, MODEL_OBJ_COUNT}}
@(private = "file")
MAX_ACTORS :: 32
@(private = "file")
// After the objects' sprites go into the scene, before its models and map:
// the sprites of the neighbours' people go in here.
MODELS_LIST_DRAW :: 0x8014316c
@(private = "file")
// After the map: the objects COLLECT listed as models, from MODEL_LIST.
MODEL_OBJECTS_DRAW :: 0x80145958
@(private = "file")
MODEL_OBJECTS_RA :: 0x80142370
@(private = "file")
MODEL_LIST :: SPRITE_LIST + 268 // u32 object pointers, MODEL_LIST_COUNT of them
@(private = "file")
MODEL_LIST_COUNT :: SPRITE_LIST + 528
@(private = "file")
COLLECT :: 0x80141f1c // a0 = object, a1 = SPRITE_LIST: project it and list its sprite
@(private = "file")
COLLECT_RA :: 0x80142124
@(private = "file")
SPRITE_LIST :: 0x80116d98 // the scene's sprites to draw, u32 count at +524
@(private = "file")
SPRITE_LIST_COUNT :: SPRITE_LIST + 524
@(private = "file")
SHADOW_NEXT :: SPRITE_LIST + 534 // u8, the next of MAX_SHADOWS
@(private = "file")
SPRITE_LIST_RA :: 0x80142224 // SPRITE_DRAW's return address in the sprite list
@(private = "file")
SHADOW_SET :: 0x801423f0 // a0 = sprite, a1 = shadow record: the shadow under it
@(private = "file")
SHADOW_SET_RA :: 0x80142278
@(private = "file")
SHADOW_RA :: 0x8014229c // SPRITE_DRAW's, for a shadow
@(private = "file")
ACTOR_FRAME :: 0x200 // stack room left above a call made from a hook
@(private = "file")
SHADOWS :: 0x80118bb0
@(private = "file")
SHADOW_SIZE :: 52
@(private = "file")
MAX_SHADOWS :: 35
@(private = "file")
SPRITE_FLAGS :: 1 // u8 of a sprite record, bit 3: has a shadow
@(private = "file")
FLAG_SHADOW :: 0x8

@(private)
MAP_REQUEST :: 0x801cf598 // a0 map, a1 section, a2/a3 x/z, stack facing: field mode 4
@(private = "file")
FIELD_ENTER :: 0x8018de00 // the field's set-up after a map or section change
@(private = "file")
// u8 each, beside MAP_ID: the fades in and out of a change, 0xff none.
FADE_IN :: 0x80116bcc
@(private = "file")
FADE_OUT :: 0x80116bcd
@(private = "file")
NO_FADE :: 0xff
@(private = "file")
// Presents the window keeps the last picture through a crossing: at most
// CROSS_HOLD from the request, ENTER_HOLD once the field is set up again,
// which covers the first frame after it, drawn while the camera settles.
CROSS_HOLD :: 60
// The same through a door to another map, which loads from the disc: cut
// to ENTER_HOLD once the field is set up.
@(private = "file")
DOOR_HOLD :: 600
@(private = "file")
ENTER_HOLD :: 6
@(private = "file")
OBJ_DIRECTION :: 0x4c // u8, world direction faced, 45 degrees each
@(private = "file")
EASE_KEEP :: 0.85 // the share of the crossing's camera offset kept each frame
// After an instant door the camera glides in from the town's spot as the
// building gives way (interiors.odin door_cover), on a critically damped
// spring of this rate a frame: it sets off from rest, where an ease at its
// fastest from the first frame jolts the picture, and is all but in after
// 48 frames.
@(private = "file")
DOOR_EASE_W :: 0.1

@(private = "file")
Neighbour :: struct {
	section: u32,
	// Where the neighbour's origin sits in this section's frame: x and z in
	// cells, y (height) in view units.
	offset:  [3]f32,
	// The opening of the doorway to it, in this section: corners round it,
	// in world view units (128 a cell, y up); and a point on this section's
	// side of it.
	door:    [4][3]f32,
	front:   [3]f32,
	// How far the ground climbs from this side of the doorway to the
	// neighbour's arrival point, view units: a stair to another floor.
	rise:    f32,
	// The layer of this section, counted from its first, holding the
	// doorway.
	layer:   u32,
}

@(private = "file")
sections: struct {
	draw: psx.Func_Proc,
	// The neighbours of the section drawn last, found for
	// neighbours_key.
	key:  [4]u32,
	list: [MAX_NEIGHBOURS]Neighbour,
	n:    int,
	request: psx.Func_Proc,
	enter:   psx.Func_Proc,
	// The fades a crossing to a neighbour replaced, put back once the field
	// is set up again.
	fades:   [2]u32,
	crossing: bool,
	// The camera target before the crossing, in the new section's frame,
	// until the first view after it takes it up.
	from:    [3]f32,
	pending: bool,
	// Whether `from` holds the target to ease from: a neighbour's crossing,
	// not a door.
	from_on: bool,
	// A crossing's walk is under way: from the request until the leader's
	// walk in ends.
	walking: bool,
	// The camera's yaw before the crossing: the third-person camera keeps
	// it, where the game would face the new section's way. Through a door
	// to another map, whose frame may be turned, it turns with the leader:
	// `dir` is the way the leader faced (OBJ_DIRECTION) as it went.
	yaw:     u32,
	dir:     u32,
	door:    bool,
	// What the view adds to the camera target, easing to nothing, so the
	// picture pans from where it was instead of cutting: target units; and
	// whether it eases in through an instant door (DOOR_EASE_W), and how
	// fast, target units a frame.
	ease:    [3]f32,
	door_ease: bool,
	ease_v:  [3]f32,
	// The vblank of the frame the ease was last stepped for, and whether
	// the window shows that frame's picture.
	eased_at: u64,
	shown:    bool,
	// The rooms of the section drawn last, then of each neighbour in list.
	floors:  [MAX_NEIGHBOURS + 1]Floor,
	// floor_fill's cells to visit, grid indices.
	queue:   [MAX_CELLS]u16,
	models_draw: psx.Func_Proc,
	model_objects_draw: psx.Func_Proc,
	layer_models: psx.Func_Proc,
	npc_update:  psx.Func_Proc,
	// The neighbours' people, as spawned in their own sections' frames.
	actors:  [MAX_ACTORS]Actor,
	n_actors: int,
	// The people and the ease as the frame whose in-between pictures are
	// queued drew them: inbetween.odin draws those pictures in the next
	// vblanks, after the next frame's update has moved both on.
	queued: struct {
		actors:   [MAX_ACTORS]Actor,
		n_actors: int,
		ease:     [3]f32,
	},
	// The rand() seed of the neighbours' scripts, kept apart from the
	// game's so they leave its random numbers (encounters, battles) as
	// they would be without them.
	rand:    u32,
}

@(private = "file")
Actor :: struct {
	neighbour: int, // in sections.list
	pool:      int, // in POOLS
	slot:      u32, // the slot it was spawned in
	object:    [NPC_SIZE]u8,
}

// All of RAM and the scratchpad, kept over a spawn run for a neighbour.
@(private = "file")
spawn_saved: struct {
	ram:     [psx.RAM_SIZE]u8,
	scratch: [psx.SCRATCH_SIZE]u8,
}

// The cells of a section's grid its rooms take: floor and the walls round
// it, a bit each.
@(private = "file")
Floor :: struct {
	grid: Grid,
	bits: [MAX_CELLS / 8]u8,
	// The cells walked on, without the walls round them.
	walk: [MAX_CELLS / 8]u8,
}

@(private)
sections_init :: proc() -> bool {
	ok: bool
	sections.draw, ok = psx.hook(LAYER_DRAW, layer_draw)
	if !ok {
		return false
	}
	sections.models_draw, ok = psx.hook(MODELS_LIST_DRAW, models_draw)
	if !ok {
		return false
	}
	sections.model_objects_draw, ok = psx.hook(MODEL_OBJECTS_DRAW, model_objects_draw)
	if !ok {
		return false
	}
	sections.layer_models, ok = psx.hook(MODELS_DRAW, layer_models)
	if !ok {
		return false
	}
	sections.request = hook_field(MAP_REQUEST, map_request) or_return
	sections.npc_update = hook_field(NPC_UPDATE, npc_update) or_return
	sections.enter = hook_game_mode(FIELD_ENTER, field_enter) or_return
	return true
}

// A change to a neighbour section of the same map goes without the fades:
// the section is already on screen, drawn as a neighbour. So does one
// through a town door showing the room behind it (interiors.odin): the
// picture from before it is held through the load and fades out over the
// room.
@(private = "file")
map_request :: proc() {
	m, section := psx.cpu.r[4] & 0xffff, psx.cpu.r[5] & 0xff
	near := m == psx.lhu(MAP_ID) && sections.key == neighbours_key(psx.lhu(MAP_SECTION)) && listed(sections.list[:sections.n], section)
	// A script's request (op 0x5b) is made wherever the party stands: the
	// room comes in at the black of the game's fade out instead, and the
	// game then sets it up as after a load (interiors.odin world_enter).
	scripted := psx.cpu.r[31] == SCRIPT_REQUEST_RET && !door_walked_through()
	// An arrival of cell 0, 0 leaves the party to the map's setup scripts
	// (script op 0x5b requests mostly, some exits): a room switched to at
	// once has them run already, so it would set the party down on that
	// corner. Such a request loads as the game's, unless walked through or
	// a script's, which the setup after the black places.
	placed := psx.cpu.r[6] & 0xffff != 0 || psx.cpu.r[7] & 0xffff != 0 || door_walked_through() || scripted
	door := !near && placed && door_to(m, section)
	sections.request()
	if door && door_enter(m, section, scripted) {
		// No load to hold the picture through: the room's world is on
		// screen at the next field draw. The room was drawn in the doorway
		// moved by the door's shift, not turned, so the camera keeps its yaw
		// and eases in from where it stood, moved by the shift: the room's
		// first frame is the town's last, the town with the building laid
		// over the room but for its doorway, giving way as the camera moves
		// in (interiors.odin door_cover). The walk in keeps its framing as a
		// neighbour's does (crossing_walk).
		// Walked through (interiors.odin door_through), the party and the
		// camera's target go on moved by the shift: the camera has nothing
		// to ease in from. A script's switch is set up by the game after
		// the black, the camera with it.
		sections.door = false
		sections.yaw = psx.lhu(CAMERA_YAW)
		sections.pending = !scripted
		sections.from_on = false
		if !door_walked_through() && !scripted {
			sections.walking = true
			sections.from = target_now() - door_enter_shift() + sections.ease
			sections.from_on = true
			sections.door_ease = true
			sections.ease_v = {}
		}
		if .Game in core.trace.active {
			core.tracef(.Game, "sections: door to %04x.%d at once%s", m, section, scripted ? " at black" : "")
		}
		return
	}
	if !near && !door || sections.crossing {
		return
	}
	sections.fades = {psx.lbu(FADE_IN), psx.lbu(FADE_OUT)}
	sections.crossing = true
	sections.walking = true
	psx.hold_picture = near ? CROSS_HOLD : DOOR_HOLD
	sections.door = door
	sections.from_on = false
	sections.door_ease = false
	sections.ease_v = {}
	if door {
		sections.yaw = psx.lhu(CAMERA_YAW)
		sections.dir = psx.lbu(leader_obj() + OBJ_DIRECTION) & 7
		sections.pending = true
	}
	if .Game in core.trace.active && door {
		core.tracef(.Game, "sections: door to %04x.%d without fades", m, section)
	}
	for nb in sections.list[:sections.n] {
		if nb.section == section {
			sections.from = target_now() - layer_shift(section, psx.lhu(MAP_SECTION), nb.offset) * (TARGET_PER_CELL / VIEW_PER_CELL) + sections.ease
			sections.yaw = psx.lhu(CAMERA_YAW)
			sections.from_on = true
			sections.pending = true
		}
	}
	psx.sb(FADE_IN, NO_FADE)
	psx.sb(FADE_OUT, NO_FADE)
}

@(private = "file")
field_enter :: proc() {
	sections.enter()
	if sections.crossing {
		sections.crossing = false
		psx.sb(FADE_IN, sections.fades[0])
		psx.sb(FADE_OUT, sections.fades[1])
		psx.hold_picture = min(psx.hold_picture, ENTER_HOLD)
	}
}

// After a crossing: the camera turned as the party did through a door, and
// the target eased from where it was (a neighbour, an instant door).
@(private)
crossing_turn :: proc() {
	if !sections.pending {
		return
	}
	sections.pending = false
	yaw := sections.yaw
	if sections.door {
		turn := (psx.lbu(leader_obj() + OBJ_DIRECTION) & 7) - sections.dir
		yaw = (yaw + turn * 0x200) & 0xfff
	}
	if sections.from_on {
		sections.ease = sections.from - target_now()
	}
	if config.camera_third_person {
		psx.sh(CAMERA_YAW, yaw)
	}
}

// Around the game's view build: the camera target moved by what is left of
// the last crossing's offset. Returns the target to put back. The view is
// built more than once a frame, so the offset eases once a frame, after a
// frame the window showed: the first picture after the hold is the one from
// before the crossing.
@(private)
crossing_view_begin :: proc() -> [3]u32 {
	t := [3]u32{psx.lhu(CAM_TARGET), psx.lhu(CAM_TARGET + 2), psx.lhu(CAM_TARGET + 4)}
	now := psx.vblanks()
	if !psx.events_frozen && now != sections.eased_at {
		sections.eased_at = now
		if sections.shown {
			if sections.door_ease {
				sections.ease_v += -DOOR_EASE_W * DOOR_EASE_W * sections.ease - 2 * DOOR_EASE_W * sections.ease_v
				sections.ease += sections.ease_v
			} else {
				sections.ease *= EASE_KEEP
			}
			v := sections.ease_v
			if abs(sections.ease.x) < 1 && abs(sections.ease.y) < 1 && abs(sections.ease.z) < 1 && abs(v.x) < 1 && abs(v.y) < 1 && abs(v.z) < 1 {
				sections.ease = {}
				sections.ease_v = {}
				sections.door_ease = false
			}
		}
		if !sections.crossing {
			crossing_turn()
		}
		sections.shown = psx.hold_picture == 0
	}
	ease := inbetween_replaying ? sections.queued.ease : sections.ease
	if ease != {} {
		for i in u32(0) ..< 3 {
			psx.sh(CAM_TARGET + 2 * i, u32(i32(i16(t[i])) + i32(math.round(ease[i]))))
		}
	}
	return t
}

// Keep the people and the ease of the frame whose in-between pictures were
// just queued, for those pictures.
@(private)
sections_pass_note :: proc() {
	q := &sections.queued
	q.n_actors = sections.n_actors
	copy(q.actors[:q.n_actors], sections.actors[:q.n_actors])
	q.ease = sections.ease
}

@(private)
crossing_view_end :: proc(t: [3]u32) {
	for i in u32(0) ..< 3 {
		psx.sh(CAM_TARGET + 2 * i, t[i])
	}
}

@(private = "file")
target_now :: proc() -> [3]f32 {
	return {f32(i16(psx.lhu(CAM_TARGET))), f32(i16(psx.lhu(CAM_TARGET + 2))), f32(i16(psx.lhu(CAM_TARGET + 4)))}
}

@(private = "file")
layer_draw :: proc() {
	section := psx.lhu(MAP_SECTION)
	if psx.lbu(DRAW_LAYER) != section || psx.lw(SLOT_ENGINE) != FLD_MAIN_ID || interior_pass {
		lo := psx.lw(PACKETS)
		sections.draw()
		layer := u32(psx.lbu(DRAW_LAYER))
		if layer > u32(section) && layer < u32(section) + section_layers(u32(section)) && sections.key == neighbours_key(section) && open_any() {
			psx.blacks_add(lo, psx.lw(PACKETS))
		}
		return
	}
	key := neighbours_key(section)
	if key != sections.key {
		sections.key = key
		sections.n = neighbours(section, &sections.list)
		for nb in sections.list[:sections.n] {
			core.tracef(.Game, "sections: %x.%d neighbour %d at %v door %v rise %v", key[0], section, nb.section, nb.offset, nb.door, nb.rise)
		}
		floor_fill(&sections.floors[0], section)
		for nb, i in sections.list[:sections.n] {
			floor_fill(&sections.floors[i + 1], nb.section)
		}
		spawn_actors(section)
	}
	list, n := sections.list, sections.n
	tr: [3]u32
	for i in u32(0) ..< 3 {
		tr[i] = psx.lw(CAM_TR + 4 * i)
	}
	// The section's own tiles give way where a neighbour has floor and this
	// section has none: the wall tops around its rooms would cover the
	// neighbour's.
	hidden: [MAX_HIDDEN][2]u32
	from: [MAX_NEIGHBOURS + 1]int
	h := 0
	for nb, i in list[:n] {
		from[i] = h
		open := drawn_open(nb)
		if open && nb.rise > 0 {
			continue // an upper floor stands over them
		}
		// Over a floor below, drawn open, only the tiles of the floor walked
		// on stay: the walls round a stairwell would cover the stair, which
		// both sections model.
		h = hide_tiles({&sections.floors[i + 1], -layer_shift(nb.section, section, nb.offset), false}, {&sections.floors[0], {}, open}, &hidden, h)
	}
	from[n] = h
	// Each doorway's back gives way to the neighbour drawn past it; its
	// sides and lintel stay.
	backs: [MAX_NEIGHBOURS]int
	lo := psx.lw(PACKETS)
	for nb, i in list[:n] {
		backs[i] = psx.back_begin(lo, door_view(nb.door, tr), view_point(nb.front, tr))
	}
	sections.draw()
	for k in backs[:n] {
		psx.back_end(k, psx.lw(PACKETS))
	}
	if open_any() {
		psx.blacks_add(lo, psx.lw(PACKETS))
	}
	unhide_tiles(hidden[:h])
	if n == 0 {
		return
	}
	// Seen through its doorway only, a neighbour gives way to this section
	// everywhere else: the tiles hidden over its rooms show again outside
	// the doorway.
	for nb, i in list[:n] {
		if from[i + 1] == from[i] || drawn_open(nb) {
			continue
		}
		others: [MAX_TILES][2]u32
		k := hide_others(hidden[from[i]:from[i + 1]], &others)
		lo := psx.lw(PACKETS)
		sections.draw()
		psx.portal_add(lo, psx.lw(PACKETS), door_view(nb.door, tr), false)
		unhide_tiles(others[:k])
	}
	for nb, i in list[:n] {
		lo := psx.lw(PACKETS)
		for layer := nb.section + section_layers(nb.section) - 1; layer + 1 > nb.section; layer -= 1 {
			draw_layer_at(layer, section, nb, tr, &sections.floors[i + 1])
		}
		through_door(nb, lo, psx.lw(PACKETS), tr)
	}
	for i in u32(0) ..< 3 {
		psx.sw(CAM_TR + 4 * i, tr[i])
	}
	psx.cpu.r[4] = CAM_MATRIX
	psx.call(SET_TRANS)
	psx.sb(DRAW_LAYER, section)
	psx.call(LAYER_SETUP)
}

// Run the spawn script for each neighbour as if it were the section loaded
// and keep the objects it puts in free slots; then put all of RAM back, so
// nothing else of the run stays.
@(private = "file")
spawn_actors :: proc(section: u32) {
	sections.n_actors = 0
	if sections.n == 0 {
		return
	}
	spawn_saved.ram = psx.ram
	spawn_saved.scratch = psx.scratch
	seed := psx.rand_seed()
	sections.rand = seed ~ 0x9e3779b9
	for nb, i in sections.list[:sections.n] {
		free: [len(POOLS)][NPC_COUNT]bool
		for pool, p in POOLS {
			for k in u32(0) ..< pool.count {
				free[p][k] = psx.lbu(pool.base + pool.size * k) == 0
			}
		}
		psx.sh(MAP_SECTION, nb.section)
		game_routine(SPAWN, {})
		for pool, p in POOLS {
			for k in u32(0) ..< pool.count {
				at := pool.base + pool.size * k
				if !free[p][k] || psx.lbu(at) == 0 || sections.n_actors == MAX_ACTORS {
					continue
				}
				a := &sections.actors[sections.n_actors]
				a.neighbour = i
				a.pool = p
				a.slot = at
				a.object = slot_take(at, pool.size)
				sections.n_actors += 1
			}
		}
		psx.ram_touch(0, psx.RAM_SIZE)
		psx.ram = spawn_saved.ram
		psx.scratch = spawn_saved.scratch
	}
	psx.set_rand_seed(seed)
	models: int
	for a in sections.actors[:sections.n_actors] {
		models += int(a.object[0] & OBJ_MODEL != 0)
	}
	core.tracef(.Game, "sections: %d neighbour objects, %d models", sections.n_actors, models)
}

@(private = "file")
actors_shown :: proc() -> bool {
	return sections.n_actors > 0 && psx.lw(SLOT_ENGINE) == FLD_MAIN_ID && sections.key == neighbours_key(psx.lhu(MAP_SECTION))
}

// Draw the sprites of the neighbours' objects into the scene, each in a free
// slot for the while, moved into this section's frame and seen through its
// doorway only.
@(private = "file")
models_draw :: proc() {
	if actors_shown() {
		draw_actors(false)
	}
	sections.models_draw()
}

// MODELS_DRAW for the section's own layers (SCENE_DRAW calls it after
// LAYER_DRAW): over a floor below drawn open, the placed models off the
// section's grid lose their black polygons: blocks round the stairwell,
// which would cover the stair below. Their stair steps stay, meeting the
// stair of the floor below.
@(private = "file")
layer_models :: proc() {
	section := u32(psx.lhu(MAP_SECTION))
	layer := u32(psx.lbu(DRAW_LAYER))
	if layer < section || layer >= section + section_layers(section) || psx.lw(SLOT_ENGINE) != FLD_MAIN_ID || interior_pass || sections.key != neighbours_key(section) {
		sections.layer_models()
		return
	}
	if open_below() {
		draw_models(layer, {}, {&sections.floors[0], origin(layer) - origin(section), false})
		return
	}
	sections.layer_models()
}

// Whether a floor below the section is drawn open: the section's blocks
// round its stairwell, black, would cover the stair down.
@(private = "file")
open_below :: proc() -> bool {
	for nb in sections.list[:sections.n] {
		if nb.rise < 0 && drawn_open(nb) {
			return true
		}
	}
	return false
}

// The same for the neighbours' model objects, after the section's.
@(private = "file")
model_objects_draw :: proc() {
	sections.model_objects_draw()
	if actors_shown() {
		draw_actors(true)
	}
}

// Run the neighbours' people the way NPC_UPDATE runs the section's: per
// neighbour, the slots hold only its people, MAP_SECTION is the neighbour and
// the party is moved far off, so scripts, moves and collisions keep to the
// neighbour's frame. The slots, MAP_SECTION and the party are put back after.
@(private = "file")
npc_update :: proc() {
	sections.npc_update()
	if interior_pass || sections.n_actors == 0 || sections.key != neighbours_key(psx.lhu(MAP_SECTION)) {
		return
	}
	@(static) kept: [NPC_COUNT * NPC_SIZE]u8
	for &b, j in kept {
		b = u8(psx.lbu(NPCS + u32(j)))
	}
	section := psx.lhu(MAP_SECTION)
	seed := psx.rand_seed()
	psx.set_rand_seed(sections.rand)
	for k in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_SIZE * k + NPC_POS
		psx.sw(at, psx.lw(at) + AWAY)
	}
	for nb, i in sections.list[:sections.n] {
		any: bool
		for k in u32(0) ..< NPC_COUNT {
			psx.sb(NPCS + NPC_SIZE * k, 0)
		}
		for a in sections.actors[:sections.n_actors] {
			if a.neighbour == i && a.pool == 0 {
				slot_put(a.slot, a.object, NPC_SIZE)
				any = true
			}
		}
		if !any {
			continue
		}
		psx.sh(MAP_SECTION, nb.section)
		sections.npc_update()
		for &a in sections.actors[:sections.n_actors] {
			if a.neighbour == i && a.pool == 0 {
				a.object = slot_take(a.slot, NPC_SIZE)
			}
		}
	}
	psx.sh(MAP_SECTION, section)
	sections.rand = psx.rand_seed()
	psx.set_rand_seed(seed)
	for k in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_SIZE * k + NPC_POS
		psx.sw(at, psx.lw(at) - AWAY)
	}
	for b, j in kept {
		psx.sb(NPCS + u32(j), u32(b))
	}
}

// A free slot of a pool, 0 when none is.
@(private = "file")
free_slot :: proc(pool: Pool) -> u32 {
	for k in u32(0) ..< pool.count {
		if psx.lbu(pool.base + pool.size * k) == 0 {
			return pool.base + pool.size * k
		}
	}
	return 0
}

@(private = "file")
slot_take :: proc(slot, size: u32) -> (object: [NPC_SIZE]u8) {
	for &b, j in object[:size] {
		b = u8(psx.lbu(slot + u32(j)))
	}
	return
}

@(private = "file")
slot_put :: proc(slot: u32, object: [NPC_SIZE]u8, size: u32) {
	for j in 0 ..< size {
		psx.sb(slot + j, u32(object[j]))
	}
}

// Draw the neighbours' sprite objects (from MODELS_LIST_DRAW's hook) or
// model objects (from MODEL_OBJECTS_DRAW's), each put in a free slot of its
// pool for the while.
@(private = "file")
draw_actors :: proc(models: bool) {
	slots: [len(POOLS)]u32
	kept: [len(POOLS)][NPC_SIZE]u8
	for pool, p in POOLS {
		slots[p] = free_slot(pool)
		if slots[p] != 0 {
			kept[p] = slot_take(slots[p], pool.size)
		}
	}
	tr: [3]u32
	for i in u32(0) ..< 3 {
		tr[i] = psx.lw(CAM_TR + 4 * i)
	}
	section := psx.lhu(MAP_SECTION)
	count := psx.lw(SPRITE_LIST_COUNT)
	model_count, model_first := psx.lw(MODEL_LIST_COUNT), psx.lw(MODEL_LIST)
	actors := inbetween_replaying ? sections.queued.actors[:sections.queued.n_actors] : sections.actors[:sections.n_actors]
	for a in actors {
		flags := a.object[0]
		if flags & OBJ_SHOWN == 0 || (flags & OBJ_MODEL != 0) != models {
			continue // hidden or gone, by its script; or drawn by the other hook
		}
		slot := slots[a.pool]
		if slot == 0 {
			continue
		}
		nb := sections.list[a.neighbour]
		slot_put(slot, a.object, POOLS[a.pool].size)
		shift := layer_shift(nb.section, section, nb.offset)
		for i in u32(0) ..< 3 {
			at := slot + NPC_POS + 4 * i
			pos := i32(psx.lw(at))
			if psx.events_frozen && a.pool == 0 {
				// An in-between picture: part of the way back to where the
				// frame's update found it.
				d := pos - i32(psx.lw(slot + NPC_PREV + 4 * i))
				if abs(d) <= MAX_BLEND {
					pos -= i32(math.round(f64(d) * inbetween_back))
				}
			}
			psx.sw(at, u32(pos + i32(math.round(shift[i] * CELL / VIEW_PER_CELL))))
		}
		if models {
			psx.sw(MODEL_LIST, slot)
			psx.sw(MODEL_LIST_COUNT, 1)
			lo := psx.lw(PACKETS)
			actor_draw_models()
			through_door(nb, lo, psx.lw(PACKETS), tr)
			continue
		}
		psx.sw(SPRITE_LIST_COUNT, count)
		actor_call(COLLECT, slot, SPRITE_LIST, COLLECT_RA)
		if psx.lw(SPRITE_LIST_COUNT) == count {
			continue // off screen
		}
		sprite := slot + NPC_SPRITE
		lo := psx.lw(SPRITE_PACKETS)
		actor_call(SPRITE_DRAW, sprite, 0, SPRITE_LIST_RA)
		if shadow := psx.lbu(SHADOW_NEXT); psx.lbu(sprite + SPRITE_FLAGS) & FLAG_SHADOW != 0 && shadow < MAX_SHADOWS {
			record := SHADOWS + SHADOW_SIZE * shadow
			actor_call(SHADOW_SET, sprite, record, SHADOW_SET_RA)
			actor_call(SPRITE_DRAW, record, 0, SHADOW_RA)
			psx.sb(SHADOW_NEXT, shadow + 1)
		}
		through_door(nb, lo, psx.lw(SPRITE_PACKETS), tr)
	}
	psx.sw(SPRITE_LIST_COUNT, count)
	psx.sw(MODEL_LIST_COUNT, model_count)
	psx.sw(MODEL_LIST, model_first)
	for pool, p in POOLS {
		if slots[p] != 0 {
			slot_put(slots[p], kept[p], pool.size)
		}
	}
}

// MODEL_OBJECTS_DRAW once more, for the list as set, keeping the caller's
// registers.
@(private = "file")
actor_draw_models :: proc() {
	c := &psx.cpu
	regs, hi, lo := c.r, c.hi, c.lo
	c.r[29] = (c.r[29] - ACTOR_FRAME) &~ 7
	c.r[31] = MODEL_OBJECTS_RA
	sections.model_objects_draw()
	c.r, c.hi, c.lo = regs, hi, lo
}

// Call a game function with two arguments as if from return address `ra`,
// keeping the caller's registers.
@(private = "file")
actor_call :: proc(target, a0, a1, ra: u32) {
	c := &psx.cpu
	regs, hi, lo := c.r, c.hi, c.lo
	c.r[29] = (c.r[29] - ACTOR_FRAME) &~ 7
	c.r[4], c.r[5], c.r[31] = a0, a1, ra
	psx.call(target)
	c.r, c.hi, c.lo = regs, hi, lo
}

// Draw `layer` of section `of`, whose floor is `floor`, as if its origin sat
// at `offset` cells in the frame of `section`, whose view translation is
// `tr`.
@(private = "file")
draw_layer_at :: proc(layer, section: u32, nb: Neighbour, tr: [3]u32, floor: ^Floor) {
	offset := nb.offset
	shift := layer_shift(layer, section, offset)
	for i in u32(0) ..< 3 {
		sum: f32
		for j in u32(0) ..< 3 {
			sum += f32(i16(psx.lhu(CAM_MATRIX + 6 * i + 2 * j))) * shift[j]
		}
		psx.sw(CAM_TR + 4 * i, u32(i32(tr[i]) + i32(sum / 4096)))
	}
	psx.cpu.r[4] = CAM_MATRIX
	psx.call(SET_TRANS)
	// LAYER_SETUP picks the blocks of geometry around the target, in the
	// layer's own frame.
	tx, tz := psx.lhu(CAM_TARGET), psx.lhu(CAM_TARGET + 4)
	psx.sh(CAM_TARGET, u32(i32(i16(tx)) - i32(offset.x * TARGET_PER_CELL)))
	psx.sh(CAM_TARGET + 4, u32(i32(i16(tz)) - i32(offset.z * TARGET_PER_CELL)))
	psx.sb(DRAW_LAYER, layer)
	psx.call(LAYER_SETUP)
	// Its rock gives way over this section's floor, but not its own floor:
	// an upper storey stands over the rooms below it. An open floor above
	// shows only its rooms: its rock and the black around them would cover
	// this section's walls.
	open := drawn_open(nb)
	over := Cover{&sections.floors[0], shift, false}
	if open && nb.rise > 0 {
		over = {}
	}
	keep := Cover{floor, origin(layer) - origin(nb.section), false}
	hidden: [MAX_HIDDEN][2]u32
	n := hide_tiles(over, keep, &hidden, 0)
	lo := psx.lw(PACKETS)
	sections.draw()
	if psx.lbu(DRAW_FLAGS) & FLAG_MODELS != 0 {
		if open {
			draw_models(layer, {&sections.floors[0], shift, false}, {floor, keep.shift, true})
		} else {
			sections.layer_models()
		}
	}
	if open {
		psx.blacks_add(lo, psx.lw(PACKETS))
	}
	unhide_tiles(hidden[:n])
	psx.sh(CAM_TARGET, tx)
	psx.sh(CAM_TARGET + 4, tz)
}

// Where `layer` is drawn in the frame of `section` when its section's origin
// sits at `offset` cells there: view units.
@(private = "file")
layer_shift :: proc(layer, section: u32, offset: [3]f32) -> [3]f32 {
	return [3]f32{offset.x * VIEW_PER_CELL, offset.y, offset.z * VIEW_PER_CELL} + origin(layer) - origin(section)
}

// A section's floor, and the move (view units) from the frame of the tiles
// being drawn into its grid's.
@(private = "file")
Cover :: struct {
	floor: ^Floor,
	shift: [3]f32,
	walk:  bool, // only the cells walked on count
}

// Sections are modelled alone, so each one's solid ground and wall tops run
// on where its neighbours' rooms are. Of the tiles LAYER_SETUP picked, hide
// the ones over floor of `over` (no floor: everywhere) and over none of
// `keep` (no floor has none): kind 0 has no polygons. Their addresses and kinds go in `hidden`
// from `n` on, to be put back; the count is returned.
@(private = "file")
hide_tiles :: proc(over, keep: Cover, hidden: ^[MAX_HIDDEN][2]u32, n: int) -> int {
	n := n
	run := u32(TILE_RUNS)
	for _ in 0 ..< psx.lhu(TILE_RUN_COUNT) {
		tile := psx.lw(run)
		count := i32(i16(psx.lhu(run + 4)))
		at := [3]f32{f32(i32(i8(psx.lbu(run + 6))) * TILE_SPAN + TILE_CORNER), 0, f32(i32(i8(psx.lbu(run + 7))) * TILE_SPAN + TILE_CORNER)}
		for _ in 0 ..< count {
			kind := psx.lhu(tile)
			if kind != 0 && n < MAX_HIDDEN && (over.floor == nil || floor_under(over, at)) && !floor_under(keep, at) {
				hidden[n] = {tile, kind}
				psx.sh(tile, 0)
				n += 1
			}
			tile += TILE_SIZE
			at.x += TILE_SPAN
		}
		run += 8
	}
	return n
}

// Draw the placed models of `layer` but the ones over floor of `over` and
// not of `keep`: walls round rooms, where another floor's rooms are. The
// ones off the grid of `keep`'s floor hold a stairwell's black blocks along
// with the stair's top steps: they are drawn without their black polygons.
@(private = "file")
draw_models :: proc(layer: u32, over, keep: Cover) {
	models: [MAX_MODELS]u32
	lo := psx.lw(PACKETS)
	k := hide_models(layer, over, keep, false, &models)
	sections.layer_models()
	show_models(models[:k])
	k = hide_models(layer, over, keep, true, &models)
	sections.layer_models()
	psx.blacks_add(lo, psx.lw(PACKETS))
	show_models(models[:k])
}

// Hide the placed models of `layer` that draw_models leaves out of a pass:
// with `off_pass` false the ones off the grid of `keep`'s floor or over
// floor of `over` and not of `keep`, with it true all but the ones off the
// grid. Their flag bytes go in `hidden`; the count is returned.
@(private = "file")
hide_models :: proc(layer: u32, over, keep: Cover, off_pass: bool, hidden: ^[MAX_MODELS]u32) -> int {
	desc := layer_desc(layer)
	if desc == 0 {
		return 0
	}
	n := 0
	for i in u32(0) ..< psx.lbu(desc + MODEL_COUNT) {
		m := desc + MODEL_FIRST + MODEL_SIZE * i
		flags := m + MODEL_FLAGS
		at := [3]f32{f32(psx.lhu(m + MODEL_X)), 0, f32(psx.lhu(m + MODEL_Z))} * MODEL_UNIT
		g := keep.floor.grid
		x := i32(math.floor((at.x + keep.shift.x) / VIEW_PER_CELL))
		z := i32(math.floor((at.z + keep.shift.z) / VIEW_PER_CELL))
		off := x < 0 || z < 0 || x >= g.w || z >= g.h
		// floor_under looks at a tile's span: the cells round the model.
		round := at - TILE_SPAN / 2
		hide := off_pass ? !off : off || floor_under(over, round) && !floor_under(keep, round)
		if psx.lbu(flags) & MODEL_DRAWN != 0 && n < MAX_MODELS && hide {
			psx.sb(flags, psx.lbu(flags) &~ MODEL_DRAWN)
			hidden[n] = flags
			n += 1
		}
	}
	return n
}

@(private = "file")
show_models :: proc(hidden: []u32) {
	for m in hidden {
		psx.sb(m, psx.lbu(m) | MODEL_DRAWN)
	}
}

// Hide every tile LAYER_SETUP picked but the ones in `keep`, into `hidden`;
// returns the count.
@(private = "file")
hide_others :: proc(keep: [][2]u32, hidden: ^[MAX_TILES][2]u32) -> int {
	n := 0
	run := u32(TILE_RUNS)
	for _ in 0 ..< psx.lhu(TILE_RUN_COUNT) {
		tile := psx.lw(run)
		for _ in 0 ..< i32(i16(psx.lhu(run + 4))) {
			kind := psx.lhu(tile)
			if kind != 0 && n < MAX_TILES && !kept(keep, tile) {
				hidden[n] = {tile, kind}
				psx.sh(tile, 0)
				n += 1
			}
			tile += TILE_SIZE
		}
		run += 8
	}
	return n
}

@(private = "file")
kept :: proc(keep: [][2]u32, tile: u32) -> bool {
	for t in keep {
		if t[0] == tile {
			return true
		}
	}
	return false
}

// A doorway's opening in view space, under the view rotation and the
// translation `tr`.
@(private)
door_view :: proc(door: [4][3]f32, tr: [3]u32) -> (v: [4][3]f32) {
	for c, k in door {
		v[k] = view_point(c, tr)
	}
	return
}

// World point `c` (view units) in view space.
@(private)
view_point :: proc(c: [3]f32, tr: [3]u32) -> (v: [3]f32) {
	for i in u32(0) ..< 3 {
		sum: f32
		for j in u32(0) ..< 3 {
			sum += f32(i16(psx.lhu(CAM_MATRIX + 6 * i + 2 * j))) * c[j]
		}
		v[i] = sum / 4096 + f32(i32(tr[i]))
	}
	return
}

@(private = "file")
unhide_tiles :: proc(hidden: [][2]u32) {
	for t in hidden {
		psx.sh(t[0], t[1])
	}
}

// Whether a tile at `at` (its low corner, view units, in the tiles' frame)
// reaches over any of the cover's rooms. Tiles sit half a cell off the
// cells, so one reaches over three a side.
@(private = "file")
floor_under :: proc(c: Cover, at: [3]f32) -> bool {
	if c.floor == nil {
		return false
	}
	g := c.floor.grid
	lo := [2]i32{i32(math.floor((at.x + c.shift.x) / VIEW_PER_CELL)), i32(math.floor((at.z + c.shift.z) / VIEW_PER_CELL))}
	hi := [2]i32{i32(math.ceil((at.x + c.shift.x + TILE_SPAN) / VIEW_PER_CELL)), i32(math.ceil((at.z + c.shift.z + TILE_SPAN) / VIEW_PER_CELL))}
	for z in lo.y ..< hi.y {
		for x in lo.x ..< hi.x {
			bits := c.walk ? &c.floor.walk : &c.floor.bits
			if x >= 0 && z >= 0 && x < g.w && z < g.h && bits[(z * g.w + x) >> 3] & (1 << u32((z * g.w + x) & 7)) != 0 {
				return true
			}
		}
	}
	return false
}

// A section's floor is what its exits lead into: the cells reached from
// them without crossing a wall. Its grid also holds open cells around the
// rooms, closed off from them. The walls next to the floor, diagonals too,
// are the rooms' as well.
@(private = "file")
floor_fill :: proc(f: ^Floor, section: u32) {
	f.bits = {}
	g, ok := map_grid(section)
	if !ok || g.w * g.h > MAX_CELLS {
		f.grid = {}
		return
	}
	f.grid = g
	n := 0
	for p := exit_list(section); p != 0 && psx.lhu(p) != EXIT_END; p += EXIT_SIZE {
		at := [2]i32{i32(psx.lbu(p + 4)), i32(psx.lbu(p + 5))}
		step := psx.lbu(p + 3) & 1 != 0 ? [2]i32{0, 1} : [2]i32{1, 0}
		for _ in 0 ..< psx.lbu(p + 10) {
			n = floor_add(f, at, n)
			at += step
		}
	}
	ways := [4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
	// Each cell joins the queue once, so it ends within the grid's count.
	for i := 0; i < n; i += 1 {
		c := i32(sections.queue[i])
		for d in ways {
			n = floor_add(f, {c % g.w, c / g.w} + d, n)
		}
	}
	f.walk = f.bits
	for i in 0 ..< n {
		c := i32(sections.queue[i])
		for dz in i32(-1) ..= 1 {
			for dx in i32(-1) ..= 1 {
				x, z := c % g.w + dx, c / g.w + dz
				if x >= 0 && z >= 0 && x < g.w && z < g.h {
					f.bits[(z * g.w + x) >> 3] |= u8(1) << u32((z * g.w + x) & 7)
				}
			}
		}
	}
}

@(private = "file")
floor_add :: proc(f: ^Floor, at: [2]i32, n: int) -> int {
	g := f.grid
	if at.x < 0 || at.y < 0 || at.x >= g.w || at.y >= g.h || is_wall(g, at.x, at.y) {
		return n
	}
	i := at.y * g.w + at.x
	bit := u8(1) << u32(i & 7)
	if f.bits[i >> 3] & bit != 0 {
		return n
	}
	f.bits[i >> 3] |= bit
	sections.queue[n] = u16(i)
	return n + 1
}

@(private = "file")
is_wall :: proc(g: Grid, x, z: i32) -> bool {
	return attr_at(g, x, z) >> 4 == ATTR_WALL_KIND
}

// Where `layer`'s frame sits (view units): a section's layers are drawn
// shifted by the difference from its first layer's.
@(private)
origin :: proc(layer: u32) -> [3]f32 {
	at := LAYER_ORIGIN + 8 * layer
	return {f32(psx.lbu(at)), f32(i16(psx.lhu(at + 2))), f32(psx.lbu(at + 4))}
}

// The sections `section` has a doorway pair with, up to len(list).
@(private = "file")
neighbours :: proc(section: u32, list: ^[MAX_NEIGHBOURS]Neighbour) -> int {
	m := psx.lhu(MAP_ID)
	n := 0
	p := exit_list(section)
	for ; p != 0 && psx.lhu(p) != EXIT_END && n < MAX_NEIGHBOURS; p += EXIT_SIZE {
		other := psx.lbu(p + 2)
		if psx.lhu(p) != m || other == section || listed(list[:n], other) {
			continue
		}
		back := exit_to(other, m, section)
		if back == 0 {
			continue
		}
		here, there := exit_middle(p), exit_middle(back)
		// An exit can lie on a section's upper layer (the top of a stair),
		// so heights and walls are read on the layer holding its cells.
		lp, lb := exit_layer(section, p), exit_layer(other, back)
		y := ground(section, here, section, lp) * VIEW_PER_CELL / TARGET_PER_CELL
		// The doorways face each other across the wall between the sections.
		d := exit_way(p)
		// The sections meet at the doorways' far edges: on a stair the
		// ground still climbs through the exit cells.
		edge, edge_back := door_edge(section, here, d, section, lp), door_edge(other, there, -d, section, lb)
		dy := (edge - edge_back) * VIEW_PER_CELL / TARGET_PER_CELL
		// A stair runs on through the edges, where both sections model it:
		// no wall stands between them there.
		gap: f32 = 1
		if edge == ground(section, here, section, lp) && edge_back == ground(other, there, section, lb) {
			gap += f32(max(wall_beyond(section + lp, p, d), wall_beyond(other + lb, back, -d)))
		}
		at := here + gap * d - there
		quad := door(p, here, y)
		// The arrival point in the neighbour, 256 a cell.
		arrive := [2]f32{f32(i16(psx.lhu(p + 6))), f32(i16(psx.lhu(p + 8)))} / TARGET_PER_CELL
		top := ground(other, {math.floor(arrive.x), math.floor(arrive.y)}, section, lb) * VIEW_PER_CELL / TARGET_PER_CELL
		list[n] = {other, {at.x, dy, at.y}, quad, door_front(p, quad), top + dy - y, lp}
		n += 1
	}
	return n
}

// Whether neighbour `nb` is another floor, reached by a stair through the
// doorway, and drawn whole rather than through the doorway: a floor below
// shows down the stairwell; a floor above, seen over its walls, shows once
// the leader is on the stair's layer, not from the floor under it.
@(private = "file")
drawn_open :: proc(nb: Neighbour) -> bool {
	if nb.rise <= -UPPER_RISE {
		return true
	}
	return nb.rise >= UPPER_RISE && u32(psx.lbu(leader_obj() + OBJ_LAYER)) == nb.layer
}

// Show neighbour `nb`'s packets lo..<hi only through its doorway, unless it
// is drawn open.
@(private = "file")
through_door :: proc(nb: Neighbour, lo, hi: u32, tr: [3]u32) {
	if !drawn_open(nb) {
		psx.portal_add(lo, hi, door_view(nb.door, tr), true)
	}
}

// A point a tile out from exit `p`'s opening `quad`, on the side the exit
// is walked into from.
@(private)
door_front :: proc(p: u32, quad: [4][3]f32) -> [3]f32 {
	way := exit_way(p) * VIEW_PER_CELL
	return (quad[0] + quad[2]) / 2 - {way.x, 0, way.y}
}

// The opening of exit `p` (middle `here`, ground `y` in view units): the
// far side of its cells, DOOR_HEIGHT tall.
@(private)
door :: proc(p: u32, here: [2]f32, y: f32) -> [4][3]f32 {
	d := exit_way(p)
	along := psx.lbu(p + 3) & 1 != 0 ? [2]f32{0, 1} : [2]f32{1, 0}
	half := f32(psx.lbu(p + 10)) / 2 + DOOR_MARGIN
	mid := here + 0.5 + d * 0.5
	a, b := (mid - along * half) * VIEW_PER_CELL, (mid + along * half) * VIEW_PER_CELL
	return {{a.x, y, a.y}, {b.x, y, b.y}, {b.x, y + DOOR_HEIGHT, b.y}, {a.x, y + DOOR_HEIGHT, a.y}}
}

@(private = "file")
listed :: proc(list: []Neighbour, section: u32) -> bool {
	for nb in list {
		if nb.section == section {
			return true
		}
	}
	return false
}

@(private)
exit_list :: proc(section: u32) -> u32 {
	base := psx.lw(EXITS)
	if !in_ram(base) || !in_ram(psx.lw(base)) {
		return 0
	}
	p := psx.lw(psx.lw(base) + 4 * section)
	return in_ram(p) ? p : 0
}

// What a section's neighbours are found for: the map, the section, the map's
// data block and the section's exit list, which a map's first frames may
// still find left over from the map before.
@(private = "file")
neighbours_key :: proc(section: u32) -> [4]u32 {
	return {psx.lhu(MAP_ID), section, psx.lw(MAP_BLOCK), exit_list(section)}
}

// The first exit of `section` to section `to` of map `m`, or 0.
@(private)
exit_to :: proc(section, m, to: u32) -> u32 {
	for p := exit_list(section); p != 0 && psx.lhu(p) != EXIT_END; p += EXIT_SIZE {
		if psx.lhu(p) == m && psx.lbu(p + 2) == to {
			return p
		}
	}
	return 0
}

// The ground's height at the far edge, toward `way`, of the exit cells
// around `middle` in section `of`'s `layer`: carried on from halfway there,
// as the edge itself can read a wall top. 256 a cell.
@(private = "file")
door_edge :: proc(of: u32, middle, way: [2]f32, section, layer: u32) -> f32 {
	mid := ground(of, middle, section, layer)
	return mid + 2 * (ground(of, middle + way * DOOR_EDGE / 2, section, layer) - mid)
}

// The ground's height in the middle of `cell` of section `of`'s `layer`
// (counted from `of`), at about the leader's height, while `section` is the
// one loaded; 256 a cell.
@(private)
ground :: proc(of: u32, cell: [2]f32, section: u32, layer: u32 = 0) -> f32 {
	// GROUND works in the scratchpad through 0x1f8000d3, past the drawing's
	// fog (0x1f8000ac..0x1f8000b6): called from a layer's draw, it left the
	// room's first frame fogged through and its tiles culled.
	saved := psx.scratch
	pos := (psx.cpu.r[29] - POS_AT) &~ 7
	psx.sw(pos, u32(i32((cell.x + 0.5) * CELL)))
	psx.sw(pos + 4, psx.lw(LEADER_Y))
	psx.sw(pos + 8, u32(i32((cell.y + 0.5) * CELL)))
	// GROUND takes the layer counted from MAP_SECTION, so `of` is made the
	// section for the call.
	psx.sh(MAP_SECTION, of)
	y := f32(i32(game_routine(GROUND, {pos, layer, 0, 0, 0}))) * TARGET_PER_CELL / CELL
	psx.sh(MAP_SECTION, section)
	psx.scratch = saved
	return y
}

// The way through an exit, in cells: its direction byte counts eighths of a
// turn from -z towards +x.
@(private)
exit_way :: proc(p: u32) -> [2]f32 {
	a := f32(psx.lbu(p + 11) & 7) * math.PI / 4
	return {math.round(math.sin(a)), math.round(-math.cos(a))}
}

// Whether cell x, z of the loaded section's grid is a doorway to a
// neighbour drawn with it: what lies past it is the neighbour's.
@(private)
doorway_cell :: proc(x, z: i32) -> bool {
	section := psx.lhu(MAP_SECTION)
	if sections.key != neighbours_key(section) {
		return false
	}
	for p := exit_list(section); p != 0 && psx.lhu(p) != EXIT_END; p += EXIT_SIZE {
		if psx.lhu(p) != psx.lhu(MAP_ID) || !listed(sections.list[:sections.n], psx.lbu(p + 2)) {
			continue
		}
		if exit_cell(p, x, z) {
			return true
		}
	}
	return false
}

// Whether cell x, z is one of exit p's cells.
@(private)
exit_cell :: proc(p: u32, x, z: i32) -> bool {
	at := [2]i32{i32(psx.lbu(p + 4)), i32(psx.lbu(p + 5))}
	run := i32(psx.lbu(p + 10))
	if psx.lbu(p + 3) & 1 != 0 {
		return x == at.x && z >= at.y && z < at.y + run
	}
	return z == at.y && x >= at.x && x < at.x + run
}

// Whether the leader walks through a doorway to a neighbour: out to it
// (beside it, in the exit walk) or in on the other side after the crossing.
// The camera keeps its framing through it, as if no change took place.
@(private)
crossing_walk :: proc() -> bool {
	walk := psx.lbu(leader_obj() + OBJ_STATE) == STATE_EXIT_WALK
	if sections.crossing || sections.walking && walk {
		return true
	}
	sections.walking = false
	if !walk {
		return false
	}
	x := i32(psx.lw(leader_obj() + OBJ_POS) + 0x8000) >> 16
	z := i32(psx.lw(leader_obj() + OBJ_POS + 8) + 0x8000) >> 16
	for dz in i32(-1) ..= 1 {
		for dx in i32(-1) ..= 1 {
			if doorway_cell(x + dx, z + dz) {
				return true
			}
		}
	}
	return false
}

// How many wall cells of `layer`'s grid lie past exit `p` along `d`, up to
// MAX_WALL; the grid's edge ends the count.
@(private = "file")
wall_beyond :: proc(layer, p: u32, d: [2]f32) -> int {
	g, ok := map_grid(layer)
	if !ok {
		return 0
	}
	x, z := i32(psx.lbu(p + 4)), i32(psx.lbu(p + 5))
	n := 0
	for n < MAX_WALL {
		x += i32(d.x)
		z += i32(d.y)
		if x < 0 || z < 0 || x >= g.w || z >= g.h || !is_wall(g, x, z) {
			break
		}
		n += 1
	}
	return n
}

// Which of section `of`'s layers (counted from `of`) holds exit `p`'s first
// cell as an exit; 0 when none does.
@(private = "file")
exit_layer :: proc(of, p: u32) -> u32 {
	x, z := i32(psx.lbu(p + 4)), i32(psx.lbu(p + 5))
	for l in u32(0) ..< section_layers(of) {
		g, ok := map_grid(of + l)
		if ok && attr_at(g, x, z) >> 4 == ATTR_EXIT_KIND {
			return l
		}
	}
	return 0
}

// The middle of an exit's run of cells: flags bit 0 runs it along z, else
// along x.
@(private)
exit_middle :: proc(p: u32) -> [2]f32 {
	at := [2]f32{f32(psx.lbu(p + 4)), f32(psx.lbu(p + 5))}
	half := (f32(psx.lbu(p + 10)) - 1) / 2
	if psx.lbu(p + 3) & 1 != 0 {
		return at + {0, half}
	}
	return at + {half, 0}
}

// Whether any neighbour of this walk is drawn open: its floor shown whole,
// so the stairwell's black blocks in the current section's own packets must
// be left out too.
open_any :: proc() -> bool {
	for nb in sections.list[:sections.n] {
		if drawn_open(nb) {
			return true
		}
	}
	return false
}

