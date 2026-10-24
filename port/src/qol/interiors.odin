// Interiors seen through doors: a town's doorways show the rooms behind
// them, where the game draws a dark opening.
//
// A town's shops and houses are maps of their own (Sarai's are 0201 and
// 0204), which the PS1 loads in place of the town; nothing of them is in
// memory while the town is. So a map is kept as it stood while the party
// was in it: on a visit, once it has settled (WORLD_SETTLE field frames, no
// fade), a real frame's field draw notes RAM, the scratchpad, the GTE and
// VRAM as the drawing found them (a "world", as inbetween.odin notes a frame
// to draw again), and the registers of the main loop's draw that follows.
// Up to MAX_WORLDS are kept, the least lately used giving way.
//
// In the town, each exit to another map (not the world map) whose
// destination has a world is a door: its opening is the far side of the
// exit's cells (sections.odin's door), and the room lies where the exit pair
// says: arriving one cell past the exit, so the interior's cells sit at the
// town's less `shift` (exit cell + way in - arrival), at the height the
// grounds on both sides of the doorway agree on. Before the main loop sends
// a town frame, a frozen-time pass (psx.checkpoint_save) loads the world and
// draws its frame again (field draw, scene render, frame end, DrawOTagEnv),
// with the view the town frame used moved by the shift; the party is hidden
// so the leader is not seen inside. The picture is copied off and the
// machine put back, and psx/picture.odin lays it over the town's doorway
// pixels at or behind the door's plane. In-between frames (smooth motion)
// draw the rooms again the same way, inside their own pass, from the
// in-between's camera (doors_between_draw): a picture warped through the
// door's plane put whatever stands off it a few pixels off as the camera
// moved, which jittered against the doorway. Doors past MAX_DOOR_PASSES
// still reuse the real frame's picture, warped (door_warp).
//
// A room's door to the town it stands in (`around`) shows the town the
// same way, only through the doorway: round the room stays the game's
// black (a whole town picture laid wherever the room drew nothing showed
// the streets round the room and through its see-through walls).
//
// A room models a black curtain past its doorway for the town outside; the
// pass leaves it out (psx.blacks_all_begin). The exit cells on either side
// need not sit square on the doorway as the maps model it (Sarai 0204: the
// town's doorway sits 0.17 of the opening's width off its exit cells, the
// room's curtain not at all), so the room slides along the opening (`along`)
// until its curtain's middle meets the middle of the town's doorway back.
// That is measured only with the whole doorway on screen (door pictures
// only: with DOOR_PICTURES off no slide is measured, and a walked-through
// door shifts the party by its cells alone).
//
// The room's people live on (room_step): once per town frame a room is
// drawn, the game's NPC_UPDATE runs in the room's world, so their scripts,
// moves and animations go on, and the world keeps the outcome. The party is
// moved far off meanwhile, as sections.odin does for a neighbour's people,
// and the room draws its own random numbers, leaving the game's as they were.
//
// Rooms not visited yet load in the background (preload_step): a forked
// child goes through the door and hands the room's world back. Worlds are
// not kept across runs.
//
// Through a door whose world is ready (door_ready) the party walks with no
// stop: the game's exit on its cells is left out (free_move.odin), and
// passing their middle on the way through asks for the map as the exit
// would (door_through), the switch (door_enter, world_enter) putting the
// party and the camera's target where they stood, moved by the shift. A
// door pair has one shift both ways: the town door's settled slide also
// settles the room's door back by the opposite one.
package qol

import "core:math"
import "core:math/linalg"
import "core:mem"
import "core:time"

import "../psx"

// Whether doorways show the rooms behind them (pictures), and an instant door
// lays the town over the room while the camera comes in (door_cover,
// door_out). Off: a door is a plain cut, the switch alone (user, 2026-10-21:
// doors fast in and out, the portals not wanted).
@(private = "file")
DOOR_PICTURES :: false

@(private = "file")
MAX_WORLDS :: 8
// Real field frames into a visit before its world is noted.
@(private = "file")
WORLD_SETTLE :: 30
@(private = "file")
MAX_DOORS :: 8
// Share of the way to its settled place a room slides each pass.
@(private = "file")
SLIDE_RATE :: 0.5
// The back and curtain are measured from the polygons drawn, a unit or two
// off each frame, and a room may model more than one black polygon about
// its doorway (Sarai 0204.1: one as wide as the opening, one twice as wide,
// either seen as the view turns), each giving another place. A place is
// settled once SLIDE_READINGS readings in a row agree within SLIDE_AGREE
// view units; sliding on every reading shook the room by up to a tile from
// frame to frame.
@(private = "file")
SLIDE_READINGS :: 3
@(private = "file")
SLIDE_AGREE :: 8
// Rooms drawn per town frame, at most.
@(private = "file")
MAX_DOOR_PASSES :: 4
// Vblanks the town's picture with the building (door_cover) is laid in
// full after the party walks in through an instant door (the game's camera:
// its lens is past the doorway well before), then the vblanks it takes to
// give way. The third-person lens holds it instead until it is over the
// room's floor.
COVER_VBLANKS :: 30
COVER_TAIL :: 10
// Cells before the middle of a room's exit where the town with the
// building starts coming in over the room as the leader walks out
// (door_out). The floor's box is no help: the exit's way through the dark
// past the room's walls is floor too.
@(private = "file")
OUT_RAMP :: 3
// Picture size kept per door, pixels: a field frame's drawing area fits.
@(private = "file")
PICTURE_W :: 512
@(private = "file")
PICTURE_H :: 256
// Maps of area M (1xxx) are towns; a room of another area may stand in one.
@(private = "file")
TOWN_MAPS :: 0x1000
// Cells past a room's floor its building's walls may reach (AROUND_WALL).
@(private = "file")
AROUND_WALL :: 6
// How far over a room's floor its town's ground may rise, view units: more
// is its building.
@(private = "file")
AROUND_ABOVE :: 48
// Maps 08xx are the world map's nodes: no room behind those exits.
@(private)
WORLD_MAP_MASK :: 0xff00
@(private)
WORLD_MAP :: 0x0800
// Exits to 0000..0002 are special destinations (back where a camp was
// entered from, and the like), not maps on the disc.
@(private)
FIRST_MAP :: 0x0100

// What a pass's own DrawOTagEnv returns to: not the main loop's, so the
// hooks waiting for that one let it be.
@(private = "file")
PASS_DRAW_RET :: MAIN_DRAW_RET + 4
// The task fading the party's followers in from black as each steps off
// the leader (a0 = task): state +4 (0 blacks them all, FADE_WAIT for the next
// to step off, FADE_STEP raising its colour by 8 a frame, from the count
// at +78, up to GROUND_LIGHT / 2, then the full colour).
@(private = "file")
FOLLOWER_FADE :: 0x801cdbdc
@(private = "file")
FADE_STATE :: 4
@(private = "file")
FADE_COUNT :: 78
@(private = "file")
FADE_WAIT :: 1
@(private = "file")
FADE_STEP :: 2
// A count whose next step's colour (count + 1) * 8, as a byte, is past any
// GROUND_LIGHT / 2: the step ends the fade.
@(private = "file")
FADE_COUNT_LAST :: 30
@(private = "file")
MODEL_OBJS :: 0x801192cc // the other objects (models), MODEL_OBJ_COUNT of MODEL_OBJ_SIZE bytes; u8 +0 0 when free
@(private = "file")
MODEL_OBJ_SIZE :: 156
@(private = "file")
MODEL_OBJ_COUNT :: 32
@(private = "file")
OBJ_KIND :: 1
// The fade task is a model object of kind (+1) 4: the object loop runs that
// kind through 801cdf5c, whose call of FOLLOWER_FADE returns to FADE_RET.
@(private = "file")
KIND_FOLLOWER_FADE :: 4
@(private = "file")
FADE_RET :: 0x801cdfb8 // after 801cdf5c's call of FOLLOWER_FADE
@(private = "file")
OBJ_GAIT_ANIM :: 0xfa // u8, 1 walk, 2 run, 3 stop
@(private = "file")
GAIT_WALK :: 1
@(private = "file")
SET_ROT :: 0x80169e04 // a0 = matrix: GTE rotation
@(private = "file")
SET_TRANS :: 0x80169e34 // a0 = matrix: GTE translation from its +20
@(private = "file")
CAM_H :: 0x80138184
@(private = "file")
CAM_NEAR :: 0x80138188
@(private = "file")
DRAW_LAYER :: 0x1f80008c
// u16, the camera yaw an exit request keeps for the map it loads.
@(private = "file")
KEPT_YAW :: 0x8011c948
// The map request (MAP_REQUEST): the arrival cell x and z, 256 a cell, and
// the direction faced.
@(private = "file")
ARRIVE_X :: 0x80116bc6
@(private = "file")
ARRIVE_Z :: 0x80116bc8
@(private = "file")
ARRIVE_DIRECTION :: 0x80116bcb
// Where the map setup (0x801cf760) puts the arrival: s16 x, ground height,
// z, the vector GROUND_HEIGHT takes in a0 and gives the height of in v0.
@(private = "file")
ARRIVE_POS :: 0x8011c94c
@(private = "file")
GROUND_HEIGHT :: 0x8014a908
// Sound effects: SOUND_SLOTS slots of SOUND_SLOT_SIZE bytes (u8 flags, 0
// free; +2 first voice, +3 voice count; u16 sound at +4; u8 at +6; the
// object it follows at +0x10), and the voices they hold, 8 bytes each.
// Both mirror the sound chip, so they belong to no world. SOUND_PLAY: a0
// sound, a1 the +6 byte, a2 object; SOUND_STOP: a0 slot, keys its voices
// off.
@(private = "file")
SOUND_SLOT :: 0x8011ce10
@(private = "file")
SOUND_SLOTS :: 24
@(private = "file")
SOUND_SLOT_SIZE :: 0x14
@(private = "file")
SOUND_VOICES :: [2]u32{0x8011cd24, 0x8011cde4}
@(private = "file")
SOUND_PLAY :: 0x8013f268
@(private = "file")
SOUND_STOP :: 0x8013f2d4
// The record of the map left (written by the map setup): u16 map, u16 x,
// u16 z (the first party member's position / 256), u8 section | the
// member's +0x18 byte << 4.
@(private = "file")
LEFT_MAP :: 0x8011b718
// After it, the world map's: the return spot (u16 x, u16 z of the first
// party member / 256 at 0x8011b720, its direction at +5, a copy of
// 0x8011c948 at +6; field overlay 0x801cf758) and the world map's cursor
// (a byte at +4, a node pointer at +8; written at 0x801f18cc/0x801f19d8).
@(private = "file")
WORLD_RETURN_END :: 0x8011b72c
// The story: event flags, area and global flag words (the save's), less
// the left map and world map records and the resume position kept among
// them; and the party membership bits.
@(private = "file")
STORY_FLAGS :: [2]u32{0x8011b5c0, 0x8011b898}
@(private = "file")
STORY_SKIP :: [2][2]u32{{LEFT_MAP, WORLD_RETURN_END}, {0x8011b7c0, 0x8011b7c8}}
@(private = "file")
STORY_PARTY :: [2]u32{0x8011ad84, 0x8011ad8c}
@(private = "file")
OBJ_DIRECTION :: 0x4c
@(private = "file")
OBJ_TARGET :: 0x9c // pos the current step ends on (NPC boxes are counted from it)
@(private = "file")
EXIT_SIZE :: 12
@(private = "file")
EXIT_END :: 0xffff
@(private = "file")
VIEW_PER_CELL :: 128
// A room door's height above its ground, view units.
@(private = "file")
ROOM_DOOR_HEIGHT :: 2 * VIEW_PER_CELL
@(private = "file")
TARGET_PER_CELL :: 256
@(private = "file")
PARTY_OBJ_SIZE :: 0xfc
@(private = "file")
PARTY_COUNT :: 3
@(private = "file")
OBJ_SHOWN :: 0x2 // byte 0
// Each frame: the people's scripts, moves and animations (FLD_MAIN).
@(private = "file")
NPC_UPDATE :: 0x801da4b0
@(private = "file")
OBJ_POS :: 12 // s32 x, y, z, 16.16 a cell
// The party's x moved by this while a room's people run.
@(private = "file")
AWAY :: 0x40000000

@(private = "file")
World :: struct {
	key:       [3]u32, // map, section, map data block
	used:      u64, // vblank last drawn or noted
	start:     ^psx.Draw_Start,
	vram:      ^[psx.VRAM_W * psx.VRAM_H]u16,
	// Registers at the field draw and at the main loop's DrawOTagEnv, and
	// the scene render's return address.
	regs:      psx.Cpu,
	main:      psx.Cpu,
	scene_ret: u32,
	ready:     bool,
	// The town's game frame its people were last stepped for, and the
	// rand() seed their scripts draw from.
	stepped:   u32,
	rand:      u32,
	// The end of the map data block the visit loaded (MAP_DATA up).
	map_end:   u32,
	// Sound RAM, of which the map's sound bank [bank[0], bank[1]) is kept.
	sound:     ^[psx.SPU_RAM_SIZE]u8,
	bank:      [2]u32,
	// The sound slots whose sounds loop (psx.voice_loops) when noted: the
	// lasting ones, which entering the world starts again.
	lasting:   bit_set[0 ..< SOUND_SLOTS; u32],
	// The story when noted (story_key): a later one may place its people
	// otherwise, so the world is then loaded afresh.
	story:     u64,
	// The GPU's draw state and display start when noted: the frame's draw
	// buffer and the one shown, which the game's double buffering goes on
	// from.
	gpu:       psx.Draw_State,
	disp:      [2]i32,
	// The game's own camera fields that the third-person camera keeps
	// written over (third_person_game_fields), as they stood when noted.
	camera:    [THIRD_PERSON_FIELDS]u32,
}

@(private = "file")
Door :: struct {
	world:   [2]u32, // map, section behind it
	exit:    u32, // its exit record
	// The opening, town view units, y up; and where the room's cells sit:
	// town cells less `cells`, its ground `dy` view units below the town's.
	quad:    [4][3]f32,
	// A point a tile out from the opening on the town's side: the picture
	// shows only to a lens on that side.
	front:   [3]f32,
	cells:   [2]f32,
	// The doorway's middle cell and the town's ground a cell in from it
	// (target units); the room's cell the party arrives on, its middle.
	here:    [2]f32,
	there:   [2]f32,
	ground:  f32,
	dy:      f32,
	dy_from: [3]u32, // the world key dy was found for
	// View units the room is slid along the opening, from its first corner
	// toward its second; the picture's index in the town frame, and how far
	// across the opening the town's doorway back reached in the frame before
	// (psx.picture_span).
	along:   f32,
	pic:     int,
	// Where the room slides to once settled; the last reading's place and
	// how many readings in a row agreed with it.
	goal:    f32,
	settled: bool,
	reading: f32,
	agreed:  int,
	// How far the picture's opening is moved out from `quad` toward the
	// front: onto the doorway's dark back when a frame found it standing
	// before the plane, and none on it (psx.picture_off). Sarai's tavern (0201.2) models
	// its back a tile before the far side of its exit cells.
	inset:   f32,
	// The inset the picture `pic` was added with.
	pic_inset: f32,
	back:    [2]f32,
	back_ok: bool,
	// A room's door to the town it stands in: its picture is drawn with
	// the room's building left out (psx.cut_begin), and the town with the
	// building is laid over the room as the party walks in (door_cover).
	around:  bool,
	box:     [2][2]f32, // the room's floor, lo and hi x, z (view units)
	pixels:  []u16,
	// The picture at the hi-res target's resolution (psx.picture_take).
	hi:      psx.Picture_Hi,
	w, h:    i32,
	drawn:   bool,
	// The view (CAM_MATRIX words) and projection the picture was drawn
	// with: an in-between picture's camera has moved on (door_warp).
	pic_view: [8]u32,
	pic_h:    f32,
	// The in-between picture's own drawing of the room (doors_between_draw)
	// and whether the in-between pass running shows it.
	between:    []u16,
	between_hi: psx.Picture_Hi,
	between_on: bool,
	// A room's door to its town, just walked in through: the town drawn
	// with the room's building (psx.cover_add), whether it was, and its
	// doorway on the picture (psx.curtain_hole).
	cover:       []u16,
	cover_hi:    psx.Picture_Hi,
	cover_drawn: bool,
	cover_hole:  psx.Cover_Hole,
}

// A pass draws another map: hooks that keep this map's state stand aside.
@(private)
interior_pass: bool
// The pass draws the town the party just left (door_cover) around the camera
// still outside: its view space is the frame's, so see-through stays on.
@(private = "file")
cover_pass: bool

@(private = "file")
interiors: struct {
	layer_draw, field_draw, draw_otag_env, view_build, follower_fade: psx.Func_Proc,
	checkpoint: ^psx.Checkpoint,
	worlds:     [MAX_WORLDS]World,
	// The visit being noted: its key, field frames seen, and the world
	// waiting for the main loop's draw registers.
	visit:      [3]u32,
	frames:     int,
	noted:      bool,
	noting:     ^World,
	// The town's doors, found for doors_key.
	doors_key:  [4]u32,
	doors:      [MAX_DOORS]Door,
	n_doors:    int,
	// The town frame's view (CAM_MATRIX block with translation, H), noted at
	// its first layer, and whether its doors wait for a pass.
	view:       [8]u32,
	h:          u32,
	want:       bool,
	// The same for the in-between pass running (smooth motion).
	between_view: [8]u32,
	between_want: bool,
	// During a pass: the door drawn.
	door:       ^Door,
	// The background loads (preload_step); the doors already tried for
	// doors_key; in a child, the load it is.
	loads:       [PRELOAD_LOADS]Preload,
	tried:       [MAX_DOORS]bool,
	tried_key:   [4]u32,
	load:        ^Preload,
	// The end of the map data block the disc last loaded, and the world a
	// door request switches to at the next field draw.
	load_end:    u32,
	entering:    ^World,
	// The request's arrival: x, z, direction.
	arrival:     [3]u32,
	// The vblank the party walked in through an instant door (door_cover),
	// 0 none, and the town door's shift (door_shift, target units); its
	// opening and front (door_inset, the town's view units), and whether
	// there was one: the cover's town marks its doorway there.
	cover_at:    u64,
	// The vblank a third-person lens came over the room's floor after
	// cover_at (door_cover), 0 not yet.
	cover_in:    f64,
	enter_shift: [3]f32,
	enter_quad:  [4][3]f32,
	enter_front: [3]f32,
	enter_ok:    bool,
	// Whether the request came from the party walking through the door's
	// exit cells (door_through): the party goes on where it stands, moved
	// by the shift, rather than onto the request's arrival cell.
	through:     bool,
	// Whether the switch waits for the screen faded to black: a script's
	// request (op 0x5b), made away from the door. The game's fade out runs;
	// the room comes in with no cover of the town.
	enter_dark:  bool,
	// Whether the fade out's end was held back a frame for it (door_dark_hold).
	dark_held:   bool,
	// The town's picture on screen as an instant door switched to its room
	// (world_enter), the cover of the room's first frame: the door's own
	// is drawn by the pass after it (doors_draw). Its size; whether the
	// room's doors are still to take it (doors_find). The town's view it
	// was drawn with, moved into the room by the door's shift, and its
	// projection: the frames after warp it on to the room's camera
	// (door_warp), which has moved on since.
	first_cover:    []u16,
	first_cover_hi: psx.Picture_Hi,
	first_cover_wh: [2]i32,
	first_cover_due: bool,
	first_cover_view: [8]u32,
	first_cover_h:    f32,
	// The sound RAM the map's sound bank was moved into since its data
	// block loaded, empty (0, 0) for none.
	bank:        [2]u32,
	// Where each door's far side settled, by the near map and the far
	// world: the slide along the opening (Door.goal times the opening's
	// direction), view units. Kept across visits, so a room is not measured
	// again each time the town is entered. A town door settling also settles
	// the room's door back by the opposite slide, so walking through and
	// back maps the party by one shift both ways.
	settled:     map[[3]u32][3]f32,
	// A door's pass ran in the last frame: the world drawn is noted again
	// at its next field draw (world_note).
	renote:      bool,
}

// A world as a background load hands it back.
@(private = "file")
// A background load: the child's pid, 0 none; the door it loads; the
// vblank it was forked at; and the memory the child hands the world back in.
Preload :: struct {
	pid:   i32,
	door:  [2]u32,
	since: u64,
	share: ^Preload_Share,
}

Preload_Share :: struct {
	done:      b32,
	key:       [3]u32,
	regs:      psx.Cpu,
	main:      psx.Cpu,
	scene_ret: u32,
	map_end:   u32,
	bank:      [2]u32,
	lasting:   bit_set[0 ..< SOUND_SLOTS; u32],
	story:     u64,
	gpu:       psx.Draw_State,
	disp:      [2]i32,
	camera:    [THIRD_PERSON_FIELDS]u32,
	start:     psx.Draw_Start,
	vram:      [psx.VRAM_W * psx.VRAM_H]u16,
	sound:     [psx.SPU_RAM_SIZE]u8,
}

@(private)
interiors_init :: proc() -> bool {
	ok: bool
	interiors.layer_draw, ok = psx.hook(LAYER_DRAW, interiors_layer_draw)
	if !ok {
		return false
	}
	interiors.draw_otag_env, ok = psx.hook(DRAW_OTAG_ENV, interiors_draw_otag_env)
	if !ok {
		return false
	}
	interiors.view_build, ok = psx.hook(VIEW_BUILD, interiors_view_build)
	if !ok {
		return false
	}
	interiors.field_draw = hook_field(FIELD_DRAW, interiors_field_draw) or_return
	interiors.follower_fade = hook_field(FOLLOWER_FADE, interiors_follower_fade) or_return
	psx.dma_cdrom_hook = interiors_dma_cdrom
	psx.dma_spu_hook = interiors_dma_spu
	interiors.checkpoint = new(psx.Checkpoint)
	for &l in interiors.loads {
		l.share = (^Preload_Share)(psx.preload_shared(size_of(Preload_Share)))
		if l.share == nil {
			return false
		}
	}
	return true
}

@(private = "file")
map_key :: proc() -> [3]u32 {
	return {psx.lhu(MAP_ID), psx.lhu(MAP_SECTION), psx.lw(MAP_BLOCK)}
}

// What the doors are found for: the map, and its exit list, which a map's
// first frames may still find left over from the map before.
@(private = "file")
doors_key :: proc() -> [4]u32 {
	k := map_key()
	return {k[0], k[1], k[2], exit_list(k[1])}
}

// The field draw of a real frame: note the map's world once it settled.
@(private = "file")
interiors_field_draw :: proc() {
	if !psx.events_frozen && psx.lw(psx.cpu.r[31]) == JAL_SCENE_DRAW {
		if w := interiors.entering; w != nil && (!interiors.enter_dark || screen_fade() >= 1) {
			interiors.entering = nil
			world_enter(w)
		}
		world_note()
		preload_step()
	}
	interiors.field_draw()
}

@(private = "file")
world_note :: proc() {
	key := map_key()
	if key != interiors.visit {
		interiors.visit, interiors.frames, interiors.noted = key, 0, false
	}
	if interiors.noted {
		// Near a door the world is kept as it goes on, so a door walked
		// through leaves it as it was a frame before: the room's cover draws
		// its people where they stood, and the way back goes on from there.
		// The world stays ready: its own passes run only from other worlds.
		w := world_slot(key)
		if interiors.renote && interiors.noting == nil && !psx.preload_child && w.key == key && w.ready {
			world_take(w, key)
			interiors.noting = w
		}
		interiors.renote = false
		return
	}
	if key[0] & WORLD_MAP_MASK == WORLD_MAP {
		return
	}
	if psx.hold_picture > 0 || screen_fade() > 0 {
		interiors.frames = 0
		return
	}
	interiors.frames += 1
	if interiors.frames < WORLD_SETTLE {
		return
	}
	interiors.noted = true
	w := world_slot(key)
	world_alloc(w)
	w.ready = false
	w.stepped, w.rand = 0, key[0] ~ 0x9e3779b9
	world_take(w, key)
	interiors.noting = w
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: noting world %04x.%d (sound bank %x..%x)", key[0], key[1], w.bank[0], w.bank[1])
	}
}

// Keep the machine as it is at the field draw as world w's, all but its
// registers at the main loop's DrawOTagEnv (World.main).
@(private = "file")
world_take :: proc(w: ^World, key: [3]u32) {
	w.key, w.used = key, psx.vblanks()
	w.map_end = interiors.load_end
	w.bank = interiors.bank
	w.story = story_key()
	w.lasting = {}
	for i in 0 ..< SOUND_SLOTS {
		at := SOUND_SLOT + SOUND_SLOT_SIZE * u32(i)
		if psx.lbu(at) != 0 && psx.voice_loops(int(psx.lbu(at + 2))) {
			w.lasting += {i}
		}
	}
	copy(w.sound[w.bank[0]:w.bank[1]], psx.sound_ram()[w.bank[0]:w.bank[1]])
	psx.draw_start_save(w.start)
	w.vram^ = psx.vram
	w.regs = psx.cpu
	w.gpu, w.disp = psx.gpu, {psx.display.x, psx.display.y}
	w.scene_ret = psx.cpu.r[31] + 8
	w.camera = third_person_game_fields()
}

@(private = "file")
world_alloc :: proc(w: ^World) {
	if w.start == nil {
		w.start = new(psx.Draw_Start)
		w.vram = new([psx.VRAM_W * psx.VRAM_H]u16)
		w.sound = new([psx.SPU_RAM_SIZE]u8)
	}
}

// The world kept for `key`, or the slot to keep it in.
@(private = "file")
world_slot :: proc(key: [3]u32) -> ^World {
	oldest := &interiors.worlds[0]
	for &w in interiors.worlds {
		if w.key == key {
			return &w
		}
		if w.used < oldest.used {
			oldest = &w
		}
	}
	return oldest
}

// The ready world for map `m` section `section`, any data block, or nil.
@(private = "file")
world_find :: proc(m, section: u32) -> ^World {
	for &w in interiors.worlds {
		if w.ready && w.key[0] == m && w.key[1] == section {
			return &w
		}
	}
	return nil
}

// The town's first layer: note the frame's view and hand its doors'
// pictures to the GPU.
@(private = "file")
interiors_layer_draw :: proc() {
	section := psx.lhu(MAP_SECTION)
	if interior_pass || psx.lbu(DRAW_LAYER) != section || psx.lw(SLOT_ENGINE) != FLD_MAIN_ID {
		interiors.layer_draw()
		return
	}
	key := doors_key()
	if key != interiors.doors_key {
		interiors.doors_key = key
		doors_find(section)
	}
	if !psx.events_frozen {
		for i in u32(0) ..< 8 {
			interiors.view[i] = psx.lw(CAM_MATRIX + 4 * i)
		}
		interiors.h, _ = psx.gte_projection()
		interiors.want = DOOR_PICTURES && interiors.n_doors > 0
	} else if inbetween_replaying {
		for i in u32(0) ..< 8 {
			interiors.between_view[i] = psx.lw(CAM_MATRIX + 4 * i)
		}
	}
	if !DOOR_PICTURES {
		interiors.layer_draw()
		return
	}
	redrawn := 0
	tr: [3]u32
	for i in u32(0) ..< 3 {
		tr[i] = psx.lw(CAM_TR + 4 * i)
	}
	for &d in interiors.doors[:interiors.n_doors] {
		// An in-between picture (smooth motion) shows the doors the real
		// frame showed, its rooms drawn again from its own camera before its
		// walk (doors_between_draw): its walk measures nothing, and its
		// pictures are gone with the pass, so their indices are not kept.
		if psx.events_frozen {
			if a, out := door_cover(), door_out(); max(a, out) > 0 && d.around && d.cover_drawn {
				quad, front := door_inset(&d)
				n := linalg.normalize0(linalg.cross(quad[1] - quad[0], quad[3] - quad[0]))
				warp := door_warp(&d, tr, n, linalg.dot(n, quad[0]))
				psx.cover_add(d.cover, &d.cover_hi, d.w, d.h, door_view(quad, tr), view_point(front, tr), &d.cover_hole, max(a, out), warp, out <= a)
			}
			d.between_on = inbetween_replaying && d.drawn && d.pic >= 0 && redrawn < MAX_DOOR_PASSES
			if d.between_on {
				redrawn += 1
				interiors.between_want = true
				quad, front := door_inset(&d)
				psx.picture_add(&d, door_view(quad, tr), view_point(front, tr), d.between, &d.between_hi, d.w, d.h)
			} else if d.drawn && d.pic >= 0 {
				quad, front := door_inset(&d)
				n := linalg.normalize0(linalg.cross(quad[1] - quad[0], quad[3] - quad[0]))
				warp := door_warp(&d, tr, n, linalg.dot(n, quad[0]))
				psx.picture_add(&d, door_view(quad, tr), view_point(front, tr), d.pixels, &d.hi, d.w, d.h, warp)
			}
			continue
		}
		// The town may draw its layer more than once a frame: keep the
		// last back seen until a pass measures against it.
		back, on := psx.picture_span(d.pic)
		if on {
			d.back, d.back_ok = back, true
		}
		// Moved only when no back stood on the plane: a wall before it
		// beside a back on it (Sarai 0204.2) is not one.
		if off, ok := psx.picture_off(d.pic); ok && !on && d.pic_inset == 0 && d.inset == 0 {
			d.inset = off
			if .Qol in psx.trace.active {
				psx.tracef(.Qol, "interiors: %04x.%d inset %v", d.world[0], d.world[1], d.inset)
			}
		}
		d.pic = -1
		if a, out := door_cover(), door_out(); max(a, out) > 0 && d.around && d.cover_drawn && world_find(d.world[0], d.world[1]) != nil {
			quad, front := door_inset(&d)
			psx.cover_add(d.cover, &d.cover_hi, d.w, d.h, door_view(quad, tr), view_point(front, tr), &d.cover_hole, max(a, out), sided = out <= a)
		}
		if d.drawn && world_find(d.world[0], d.world[1]) != nil {
			d.pic_inset = d.inset
			quad, front := door_inset(&d)
			d.pic = psx.picture_add(&d, door_view(quad, tr), view_point(front, tr), d.pixels, &d.hi, d.w, d.h)
		}
	}
	interiors.layer_draw()
}

// Whether a door of the map drawn leads to world m section `section`: the
// change to it goes without fades (sections.odin map_request), showing the
// room in the doorway's picture once it is noted.
door_to :: proc(m, section: u32) -> bool {
	if interiors.doors_key != doors_key() {
		return false
	}
	for d in interiors.doors[:interiors.n_doors] {
		if d.world == {m, section} {
			return true
		}
	}
	return false
}

// For an in-between picture: the frame's screen point (x, y, 1) to door d's
// picture's, through the plane dot(n, p) == dist (world view units, y up).
// The picture's view is the real frame's; the frame's camera (CAM_MATRIX,
// translation `tr`) is part of the way back toward the frame before, so the
// picture is moved as that plane moves. Things off the plane are a little
// off, as far as the camera moved in a vblank or two.
@(private = "file")
door_warp :: proc(d: ^Door, tr: [3]u32, n: [3]f32, dist: f32) -> matrix[3, 3]f32 {
	h, of := psx.gte_projection()
	ra, rb: matrix[3, 3]f32
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {
			k := i * 3 + j
			ra[i, j] = f32(i16(d.pic_view[k / 2] >> (16 * u32(k % 2)))) / 4096
			rb[i, j] = f32(i16(psx.lhu(CAM_MATRIX + u32(2 * k)))) / 4096
		}
	}
	ta := [3]f32{f32(i32(d.pic_view[5])), f32(i32(d.pic_view[6])), f32(i32(d.pic_view[7]))}
	tb := [3]f32{f32(i32(tr[0])), f32(i32(tr[1])), f32(i32(tr[2]))}
	// Picture view = m * frame view + c; on the plane, c = c * dot(nb, v) / db.
	// The view rotations need not be orthonormal (the in-between one is
	// blended), so they are inverted outright.
	rb_inv := linalg.inverse(rb)
	m := ra * rb_inv
	c := ta - m * tb
	nb := linalg.transpose(rb_inv) * n
	db := dist + linalg.dot(nb, tb)
	if abs(db) < 1 || h == 0 || d.pic_h == 0 {
		return 1
	}
	a := m + linalg.outer_product(c, nb / db)
	hb := f32(h)
	to_pic := matrix[3, 3]f32{d.pic_h, 0, of.x, 0, d.pic_h, of.y, 0, 0, 1}
	from_frame := matrix[3, 3]f32{1 / hb, 0, -of.x / hb, 0, 1 / hb, -of.y / hb, 0, 0, 1}
	return to_pic * a * from_frame
}

// Door d's opening and front moved d.inset out toward the front: the
// front stays before the opening.
@(private = "file")
door_inset :: proc(d: ^Door) -> (quad: [4][3]f32, front: [3]f32) {
	mid := (d.quad[0] + d.quad[1]) / 2
	out := linalg.normalize0([3]f32{d.front.x - mid.x, 0, d.front.z - mid.z}) * d.inset
	for c, k in d.quad {
		quad[k] = c + out
	}
	return quad, d.front + out
}

// The loaded section's exits to rooms of other maps.
@(private = "file")
doors_find :: proc(section: u32) {
	interiors.n_doors = 0
	defer interiors.first_cover_due = false
	m := psx.lhu(MAP_ID)
	p := exit_list(section)
	for ; p != 0 && psx.lhu(p) != EXIT_END && interiors.n_doors < MAX_DOORS; p += EXIT_SIZE {
		to := psx.lhu(p)
		if to == m || to < FIRST_MAP || to & WORLD_MAP_MASK == WORLD_MAP {
			continue
		}
		d := &interiors.doors[interiors.n_doors]
		cell := [2]f32{f32(psx.lbu(p + 4)), f32(psx.lbu(p + 5))}
		arrive := [2]f32{f32(i16(psx.lhu(p + 6))), f32(i16(psx.lhu(p + 8)))} / TARGET_PER_CELL
		here := exit_middle(p)
		// The ground a cell in from the exit, where the party walks up to
		// it: a room's exit cells may lie past its floor.
		g := ground(section, here - exit_way(p), section)
		pixels, hi, between, between_hi := d.pixels, d.hi, d.between, d.between_hi
		cover, cover_hi := d.cover, d.cover_hi
		if pixels == nil {
			pixels = make([]u16, PICTURE_W * PICTURE_H)
			between = make([]u16, PICTURE_W * PICTURE_H)
			cover = make([]u16, PICTURE_W * PICTURE_H)
		}
		psx.picture_hi_clear(&hi)
		psx.picture_hi_clear(&between_hi)
		psx.picture_hi_clear(&cover_hi)
		// The picture's opening is the far side of the exit cells, a tile
		// in from the wall's face, a room door tall: the doorway's dark back
		// gives way to the room, while its sides and the wall above stay.
		quad := door(p, here, g * VIEW_PER_CELL / TARGET_PER_CELL)
		quad[2].y = quad[1].y + ROOM_DOOR_HEIGHT
		quad[3].y = quad[0].y + ROOM_DOOR_HEIGHT
		d^ = {
			around = m & TOWN_MAPS == 0 && to & TOWN_MAPS != 0 && !door_around(),
			world  = {to, psx.lbu(p + 2)},
			exit   = p,
			quad   = quad,
			front  = door_front(p, quad),
			cells  = cell + exit_way(p) - arrive,
			here   = here,
			there  = arrive + here - cell,
			ground = g,
			pixels = pixels,
			hi     = hi,
			between    = between,
			between_hi = between_hi,
			cover      = cover,
			cover_hi   = cover_hi,
			pic    = -1,
		}
		if slide, ok := interiors.settled[{u32(m), u32(to), u32(psx.lbu(p + 2))}]; ok {
			d.goal, d.settled = linalg.dot(slide, linalg.normalize0(quad[1] - quad[0])), true
		}
		d.along = d.goal
		if d.around {
			// A wall's thickness round the floor: the building's own.
			lo, hi, ok := floor_open_box(section)
			if !ok {
				d.around = false
			}
			d.box = {(linalg.to_f32(lo) - AROUND_WALL) * VIEW_PER_CELL, (linalg.to_f32(hi) + AROUND_WALL) * VIEW_PER_CELL}
		}
		if d.around && interiors.first_cover_due {
			copy(d.cover, interiors.first_cover)
			psx.picture_hi_copy(&d.cover_hi, &interiors.first_cover_hi)
			d.w, d.h = interiors.first_cover_wh[0], interiors.first_cover_wh[1]
			d.pic_view, d.pic_h = interiors.first_cover_view, interiors.first_cover_h
			d.cover_drawn = true
		}
		interiors.n_doors += 1
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: %d doors in %04x.%d", interiors.n_doors, m, section)
		for d in interiors.doors[:interiors.n_doors] {
			psx.tracef(.Qol, "interiors:   to %04x.%d cells %v quad %v", d.world[0], d.world[1], d.cells, d.quad)
		}
	}
}

// A town door as autoplay's `doors` walks up to it: the room, the
// doorway's middle cell and the way through it (exit_way), the world angle
// toward the doorway (degrees, 0 = -z, clockwise), and the slide once
// settled.
@(private)
Door_Spot :: struct {
	world:   [2]u32,
	here:    [2]f32,
	way:     [2]f32,
	angle:   f64,
	settled: bool,
	slide:   [3]f32,
}

// The loaded section's doors to rooms, none until they are found for it.
@(private)
interiors_door_spots :: proc(out: []Door_Spot) -> int {
	if interiors.doors_key != doors_key() {
		return 0
	}
	n := 0
	for d in interiors.doors[:interiors.n_doors] {
		if d.around || n == len(out) {
			continue
		}
		way := exit_way(d.exit)
		out[n] = {
			world   = d.world,
			here    = d.here,
			way     = way,
			angle   = math.to_degrees(math.atan2(f64(way.x), -f64(way.y))),
			settled = d.settled,
			slide   = linalg.normalize0(d.quad[1] - d.quad[0]) * d.goal,
		}
		n += 1
	}
	return n
}

// Whether a door found so far is the room's door to its town.
@(private = "file")
door_around :: proc() -> bool {
	for d in interiors.doors[:interiors.n_doors] {
		if d.around {
			return true
		}
	}
	return false
}

// How much of the town with the room's building is laid over the room
// (psx.cover_add): all of it as the party walks in through an instant door,
// then easing out over COVER_TAIL. The game's camera holds it for
// COVER_VBLANKS; the third-person lens, trailing the leader, until it comes
// over the room's floor (door_lens_in): out there it sees the building, and
// the room alone would show its walls' backs over the void. An in-between
// picture fades by its pose's time, between the real frames round it.
door_cover :: proc() -> f32 {
	if !DOOR_PICTURES || interiors.cover_at == 0 {
		return 0
	}
	now := inbetween_replaying ? inbetween_vblank : f64(psx.vblanks())
	from := f64(interiors.cover_at) + COVER_VBLANKS
	if config.camera_third_person && third_person_keeps() {
		if interiors.cover_in == 0 && door_lens_in() {
			interiors.cover_in = now
			if .Qol in psx.trace.active {
				psx.tracef(.Qol, "interiors: lens over the room's floor %.0f vblanks after walking in", now - f64(interiors.cover_at))
			}
		}
		from = interiors.cover_in != 0 ? interiors.cover_in : max(f64)
	}
	t := max(f32(now - from), 0) / COVER_TAIL
	if t >= 1 {
		interiors.cover_at, interiors.cover_in = 0, 0
		return 0
	}
	return 1 - t * t * (3 - 2 * t)
}

// How much of the town with the room's building is laid over the room as
// the leader walks out through its door to its town: none OUT_RAMP cells
// before the middle of the exit's cells, all of it there, where
// door_through switches, so the room's last frame is the town's first.
// Only in line with the exit's cells.
door_out :: proc() -> f32 {
	if !DOOR_PICTURES || interiors.doors_key != doors_key() {
		return 0
	}
	for d in interiors.doors[:interiors.n_doors] {
		if !d.around {
			continue
		}
		way := exit_way(d.exit)
		at := [2]f32{f32(i32(psx.lw(leader_obj() + OBJ_POS))), f32(i32(psx.lw(leader_obj() + OBJ_POS + 8)))} / 0x10000
		off := at - (d.here + 0.5)
		past := linalg.dot(off, way)
		across := abs(linalg.dot(off, [2]f32{-way.y, way.x}))
		if across > f32(psx.lbu(d.exit + 10)) / 2 + 0.5 {
			return 0
		}
		t := clamp(past / OUT_RAMP + 1, 0, 1)
		return t * t * (3 - 2 * t)
	}
	return 0
}

// Whether the frame's lens stands over the floor of the room whose door to
// its town has a cover (its box without the walls round it); true with no
// such door, so nothing holds the cover; false while the doors found are
// still the last map's.
@(private = "file")
door_lens_in :: proc() -> bool {
	if interiors.doors_key != doors_key() {
		return false
	}
	for d in interiors.doors[:interiors.n_doors] {
		if !d.around {
			continue
		}
		// The lens in world space: the view's translation turned back.
		eye: [3]f32
		for j in 0 ..< 3 {
			for i in 0 ..< 3 {
				eye[j] -= f32(town_matrix(i, j)) * f32(i32(interiors.view[5 + i]))
			}
		}
		eye /= 4096
		wall := f32(AROUND_WALL * VIEW_PER_CELL)
		return eye.x >= d.box[0].x + wall && eye.x <= d.box[1].x - wall && eye.z >= d.box[0].y + wall && eye.z <= d.box[1].y - wall
	}
	return true
}

// Before the main loop sends a town frame, draw the rooms behind the doors
// in sight; while it sends a room's frame, finish noting that world.
@(private = "file")
interiors_draw_otag_env :: proc() {
	if psx.cpu.r[31] == MAIN_DRAW_RET && !psx.events_frozen {
		if w := interiors.noting; w != nil {
			interiors.noting = nil
			if w.key == map_key() {
				w.main = psx.cpu
				w.ready = true
				if psx.preload_child {
					preload_hand_back(w)
				}
			}
		}
		// The doors' passes still run: the next frame shows their pictures.
		if interiors.want && !psx.preload_child {
			interiors.want = false
			doors_draw()
		}
	}
	interiors.draw_otag_env()
}

@(private = "file")
doors_draw :: proc() {
	if interiors.doors_key != doors_key() {
		return
	}
	passes := 0
	for &d in interiors.doors[:interiors.n_doors] {
		if passes == MAX_DOOR_PASSES {
			return
		}
		w := world_find(d.world[0], d.world[1])
		if w == nil || !door_seen(&d) {
			continue
		}
		interiors.renote = true
		if !door_pass(&d, w) {
			return
		}
		passes += 1
	}
	// The town once more with the building, round the room walked in.
	for &d in interiors.doors[:interiors.n_doors] {
		w := world_find(d.world[0], d.world[1])
		if d.around && w != nil && max(door_cover(), door_out()) > 0 {
			door_pass(&d, w, cover = true)
		}
	}
}

// Before an in-between pass (inbetween_pass) walks its frame: draw the rooms
// its layer draw showed, each in a pass nested in it, from its camera. A
// room that cannot be drawn shows the real frame's picture, unwarped.
doors_between_draw :: proc() {
	if !interiors.between_want {
		return
	}
	interiors.between_want = false
	view := interiors.view
	interiors.view = interiors.between_view
	defer interiors.view = view
	for &d in interiors.doors[:interiors.n_doors] {
		if !d.between_on {
			continue
		}
		d.between_on = false
		w := world_find(d.world[0], d.world[1])
		if w == nil || !door_pass(&d, w, true) {
			copy(d.between, d.pixels)
			psx.picture_hi_copy(&d.between_hi, &d.hi)
		}
	}
}

// Whether the door's opening, in the town frame's view, is in front of the
// lens and on screen.
@(private = "file")
door_seen :: proc(d: ^Door) -> bool {
	tr := [3]u32{interiors.view[5], interiors.view[6], interiors.view[7]}
	_, of := psx.gte_projection()
	h := f32(interiors.h)
	lo, hi := [2]f32{max(f32), max(f32)}, [2]f32{min(f32), min(f32)}
	for c in d.quad {
		v := town_view_point(c, tr)
		if v.z < 16 {
			return true // reaches the lens: on screen in part, at least
		}
		at := of + [2]f32{v.x, v.y} * h / v.z
		lo = {min(lo.x, at.x), min(lo.y, at.y)}
		hi = {max(hi.x, at.x), max(hi.y, at.y)}
	}
	return hi.x >= 0 && hi.y >= 0 && lo.x < 2 * of.x && lo.y < 2 * of.y
}

// Whether the door's opening, view space corners `quad`, stands whole on
// screen in front of the lens.
@(private = "file")
door_whole :: proc(quad: [4][3]f32) -> bool {
	_, of := psx.gte_projection()
	h := f32(interiors.h)
	for v in quad {
		if v.z < 16 {
			return false
		}
		at := of + [2]f32{v.x, v.y} * h / v.z
		if at.x < 0 || at.y < 0 || at.x >= 2 * of.x || at.y >= 2 * of.y {
			return false
		}
	}
	return true
}

// World point `c` (view units) in the noted town view.
@(private = "file")
town_view_point :: proc(c: [3]f32, tr: [3]u32) -> (v: [3]f32) {
	for i in 0 ..< 3 {
		sum: f32
		for j in 0 ..< 3 {
			sum += f32(town_matrix(i, j)) * c[j]
		}
		v[i] = sum / 4096 + f32(i32(tr[i]))
	}
	return
}

@(private = "file")
town_matrix :: proc(i, j: int) -> i16 {
	k := 3 * i + j
	return i16(interiors.view[k / 2] >> (16 * u32(k % 2)))
}

// Draw world `w` as seen through door `d` into the door's picture, or for
// an in-between pass (`between`) into its own, where the room's people do
// not move and nothing is measured. False when the GPU is busy. A room's
// door to its town draws the town without the building, or with it into
// its own picture (`cover`, door_cover).
@(private = "file")
door_pass :: proc(d: ^Door, w: ^World, between := false, cover := false) -> bool {
	main := psx.cpu
	frame := psx.lw(GAME_FRAME)
	town := [2]u32{u32(psx.lhu(MAP_ID)), u32(psx.lhu(MAP_SECTION))}
	target := [3]i32{i32(i16(psx.lhu(CAM_TARGET))), i32(i16(psx.lhu(CAM_TARGET + 2))), i32(i16(psx.lhu(CAM_TARGET + 4)))}
	if !psx.checkpoint_save(interiors.checkpoint) {
		return false
	}
	defer psx.checkpoint_restore(interiors.checkpoint)
	psx.pictures_clear()
	psx.draw_start_load(w.start)
	psx.vram = w.vram^
	psx.vram_world(u32(mem.ptr_sub(w, &interiors.worlds[0])) + 1)
	w.used = psx.vblanks()
	interior_pass, cover_pass = true, cover
	defer interior_pass, cover_pass = false, false
	// A room seen through a door is not fogged.
	fog := psx.fog
	psx.fog.on = false
	defer psx.fog = fog
	interiors.door = d
	psx.cpu = w.regs
	if d.dy_from != w.key {
		section := w.key[1]
		g := ground(section, d.there, section)
		d.dy = (d.ground - g) * VIEW_PER_CELL / TARGET_PER_CELL
		d.dy_from = w.key
	}
	// The town's frame count; then its projection, and the room's blocks
	// are picked around the town's target moved into its frame.
	psx.sw(GAME_FRAME, frame)
	if w.stepped != frame && !between {
		w.stepped = frame
		room_step(w)
	}
	psx.sw(CAM_H, interiors.h)
	shift := door_shift(d) * TARGET_PER_CELL / VIEW_PER_CELL
	psx.sh(CAM_TARGET, u32(target.x - i32(shift.x)))
	psx.sh(CAM_TARGET + 2, u32(target.y - i32(shift.y)))
	psx.sh(CAM_TARGET + 4, u32(target.z - i32(shift.z)))
	for i in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_OBJ_SIZE * i
		psx.sb(at, psx.lbu(at) &~ OBJ_SHOWN)
	}
	psx.call(FIELD_DRAW)
	psx.cpu.r[29] = w.regs.r[29]
	game_call(SCENE_DRAW, w.scene_ret)
	psx.cpu = w.main
	game_call(FRAME_END, FRAME_END_RET)
	psx.cpu = w.main
	psx.cpu.r[31] = PASS_DRAW_RET
	tr := [3]u32{interiors.view[5], interiors.view[6], interiors.view[7]}
	quad: [4][3]f32
	for c, k in d.quad {
		quad[k] = town_view_point(c, tr)
	}
	psx.blacks_all_begin(quad, town_view_point(d.front, tr))
	// The town's doorway the party walked in through, where the pass draws
	// it: the cover's opening (psx.curtain_hole).
	if cover && interiors.enter_ok {
		shift := door_shift(d)
		at: [4][3]f32
		for c, k in interiors.enter_quad {
			at[k] = town_view_point(c + shift, tr)
		}
		psx.picture_blank_add(at, town_view_point(interiors.enter_front + shift, tr), PICTURE_W, PICTURE_H)
	}
	if d.around && !cover {
		rot: [3][3]f32
		for i in 0 ..< 3 {
			for j in 0 ..< 3 {
				rot[i][j] = f32(town_matrix(i, j)) / 4096
			}
		}
		psx.cut_begin(rot, {f32(i32(tr[0])), f32(i32(tr[1])), f32(i32(tr[2]))}, d.box[0], d.box[1], d.ground * VIEW_PER_CELL / TARGET_PER_CELL + AROUND_ABOVE)
	}
	interiors.draw_otag_env()
	psx.cut_end()
	// The back and the curtain are measured only with the whole opening on
	// screen: one cut by the screen's edge or the lens (the camera at the
	// doorway) measures part of either, which slid the room by more than a
	// tile from one frame to the next.
	curtain, seen := psx.blacks_all_end()
	hole := psx.curtain_hole(quad)
	env := w.main.r[5]
	x, y := i32(i16(psx.lh(env))), i32(i16(psx.lh(env + 2)))
	d.w = min(i32(i16(psx.lh(env + 4))), PICTURE_W)
	d.h = min(i32(i16(psx.lh(env + 6))), PICTURE_H)
	if between {
		psx.picture_take(x, y, d.w, d.h, d.between, &d.between_hi)
		psx.cpu = main
		return true
	}
	if cover {
		psx.picture_take(x, y, d.w, d.h, d.cover, &d.cover_hi)
		d.cover_drawn, d.cover_hole = true, hole
		d.pic_view, d.pic_h = interiors.view, f32(interiors.h)
		psx.cpu = main
		return true
	}
	if seen && d.back_ok && !d.settled && door_whole(quad) {
		width := linalg.length(d.quad[1] - d.quad[0])
		miss := ((d.back[0] + d.back[1]) - (curtain[0] + curtain[1])) / 2 * width
		place := clamp(d.along + miss, -width, width)
		d.agreed = d.agreed > 0 && abs(place - d.reading) <= SLIDE_AGREE ? d.agreed + 1 : 1
		d.reading = place
		if d.agreed == SLIDE_READINGS {
			d.goal, d.settled = place, true
			slide := linalg.normalize0(d.quad[1] - d.quad[0]) * place
			interiors.settled[{town[0], d.world[0], d.world[1]}] = slide
			interiors.settled[{d.world[0], town[0], town[1]}] = -slide
			if .Qol in psx.trace.active {
				psx.tracef(.Qol, "interiors: %04x.%d settled at %.0f (back %v, curtain %v)", d.world[0], d.world[1], place, d.back, curtain)
			}
		}
	}
	d.back_ok = false
	d.along += (d.goal - d.along) * SLIDE_RATE
	if abs(d.goal - d.along) < 1 {
		d.along = d.goal
	}
	psx.picture_take(x, y, d.w, d.h, d.pixels, &d.hi)
	d.drawn = true
	d.pic_view, d.pic_h = interiors.view, f32(interiors.h)
	psx.cpu = main
	return true
}

// One game frame of the room's people: NPC_UPDATE in the room's world, with
// the party far off and the room's own rand() seed. The world keeps the RAM
// it leaves; the scratchpad and GTE go back to the field draw's, which the
// pass draws from.
@(private = "file")
room_step :: proc(w: ^World) {
	regs := psx.cpu.r
	seed := psx.rand_seed()
	psx.set_rand_seed(w.rand)
	for i in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_OBJ_SIZE * i + OBJ_POS
		psx.sw(at, psx.lw(at) + AWAY)
	}
	psx.call(NPC_UPDATE)
	for i in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_OBJ_SIZE * i + OBJ_POS
		psx.sw(at, psx.lw(at) - AWAY)
	}
	w.rand = psx.rand_seed()
	psx.set_rand_seed(seed)
	psx.cpu.r = regs
	psx.draw_start_take_ram(w.start)
	psx.draw_start_load(w.start)
}

// Where door d's room sits: its point p is the town's p + the shift (view
// units).
@(private = "file")
door_shift :: proc(d: ^Door) -> [3]f32 {
	way := linalg.normalize0(d.quad[1] - d.quad[0]) * d.along
	return {d.cells.x * VIEW_PER_CELL, d.dy, d.cells.y * VIEW_PER_CELL} + way
}

// During a pass, every view the room builds is the town frame's, moved by
// the door's shift: the room's point p is drawn where the town's p + shift
// would be. VIEW_BUILD takes a center (a0: s16 x, y, z, view units; a
// layer's origin, or none) its view's points are counted from, which moves
// the translation by the rotated center.
@(private = "file")
interiors_follower_fade :: proc() {
	if interiors.cover_at == 0 {
		interiors.follower_fade()
		return
	}
	// A room noted ahead holds its followers mid-fade (FOLLOWER_FADE):
	// drawn see-through and dark, over the cover's town they show black.
	// Walked in through an instant door, they were in sight all along: the
	// fade runs out now, each follower in a step. One still on the leader
	// waits there; the wait that finds none left ends the task.
	task, ra, sp := psx.cpu.r[4], psx.cpu.r[31], psx.cpu.r[29]
	for _ in 0 ..< 2 * PARTY_COUNT + 2 {
		before := psx.lbu(task + FADE_STATE)
		if before == FADE_STEP {
			psx.sb(task + FADE_COUNT, FADE_COUNT_LAST)
		}
		psx.cpu.r[4], psx.cpu.r[29], psx.cpu.r[31] = task, sp, ra
		interiors.follower_fade()
			if before == FADE_WAIT && psx.lbu(task + FADE_STATE) != FADE_STEP {
			return
		}
	}
}

// Run out the room's follower fade now, before its first frame is drawn:
// the task's own turn comes after the draw. It steps followers off only
// while the member it looks from walks (OBJ_GAIT_ANIM), which the party
// set down may not yet.
@(private = "file")
followers_shown :: proc() {
	regs, hi, lo := psx.cpu.r, psx.cpu.hi, psx.cpu.lo
	gaits: [PARTY_COUNT]u32
	for &g, i in gaits {
		at := PARTY_OBJ + PARTY_OBJ_SIZE * u32(i)
		g = psx.lbu(at + OBJ_GAIT_ANIM)
		psx.sb(at + OBJ_GAIT_ANIM, GAIT_WALK)
	}
	defer {
		psx.cpu.r, psx.cpu.hi, psx.cpu.lo = regs, hi, lo
		for g, i in gaits {
			psx.sb(PARTY_OBJ + PARTY_OBJ_SIZE * u32(i) + OBJ_GAIT_ANIM, g)
		}
	}
	for i in u32(0) ..< MODEL_OBJ_COUNT {
		task := MODEL_OBJS + MODEL_OBJ_SIZE * i
		state := psx.lbu(task + FADE_STATE)
		if psx.lbu(task) == 0 || psx.lbu(task + OBJ_KIND) != KIND_FOLLOWER_FADE || (state != FADE_WAIT && state != FADE_STEP) {
			continue
		}
		psx.cpu.r[4], psx.cpu.r[31] = task, FADE_RET
		interiors_follower_fade()
	}
}

@(private = "file")
interiors_view_build :: proc() {
	a0 := psx.cpu.r[4]
	center := [3]f32{f32(i16(psx.lhu(a0))), f32(i16(psx.lhu(a0 + 2))), f32(i16(psx.lhu(a0 + 4)))}
	interiors.view_build()
	if !interior_pass || interiors.door == nil {
		return
	}
	shift := door_shift(interiors.door) + center
	tr := [3]u32{interiors.view[5], interiors.view[6], interiors.view[7]}
	moved := town_view_point(shift, tr)
	for i in u32(0) ..< 5 {
		psx.sw(CAM_MATRIX + 4 * i, interiors.view[i])
	}
	for i in u32(0) ..< 3 {
		psx.sw(CAM_TR + 4 * i, u32(i32(moved[i])))
	}
	regs := psx.cpu.r
	psx.cpu.r[4] = CAM_MATRIX
	psx.call(SET_ROT)
	psx.cpu.r[4] = CAM_MATRIX
	psx.call(SET_TRANS)
	psx.cpu.r = regs
	psx.gte_set_h(interiors.h)
	if !cover_pass {
		psx.see_through.on = false
	}
}

// Vblanks a background load may take before the parent gives up on it.
@(private = "file")
PRELOAD_LIMIT :: 1200
// Background loads run at once, each in its own child: a door the party
// walks straight to need not wait for loads of doors nearer it.
@(private = "file")
PRELOAD_LOADS :: 4
// The longest door_enter waits for the load of the room it goes to.
@(private = "file")
PRELOAD_WAIT :: 2 * time.Second
@(private = "file")
MAP_REQUEST_RET :: 0x801d5c38 // where the field's exit check requests a map
// (a0 map, a1 section): what the field's exit check calls before it
// requests a map, and where that returns.
@(private = "file")
AREA_SET :: 0x801cfe5c
@(private = "file")
AREA_SET_RET :: 0x801d5c04

// Background loads of rooms not yet visited: once the town has settled, a
// forked child (psx/preload.odin) walks through one of its doors whose room
// has no world, unseen and unpaced, and hands the room's world back once it
// is noted; the parent, playing on, keeps it as if the party had been in.
// Up to PRELOAD_LOADS doors at a time, nearest the leader first, each tried
// once per town visit.
@(private = "file")
preload_step :: proc() {
	if psx.preload_child {
		return
	}
	free: ^Preload
	for &l in interiors.loads {
		if l.pid != 0 {
			preload_poll(&l)
		}
		if l.pid == 0 && free == nil {
			free = &l
		}
	}
	if free == nil {
		return
	}
	key := doors_key()
	if !interiors.noted || interiors.doors_key != key || interior_pass || psx.hold_picture > 0 {
		return
	}
	if interiors.tried_key != key {
		interiors.tried_key, interiors.tried = key, {}
	}
	// The untried door without a room nearest the leader goes first: the
	// one the party is most likely to walk into next.
	lead := leader_obj() + OBJ_POS
	at := [2]f32{f32(i32(psx.lw(lead)) >> 16), f32(i32(psx.lw(lead + 8)) >> 16)}
	pick, best := -1, max(f32)
	for d, i in interiors.doors[:interiors.n_doors] {
		if interiors.tried[i] || world_find(d.world[0], d.world[1]) != nil || preload_of(d.world) != nil {
			continue
		}
		if dist := linalg.length2(d.here - at); dist < best {
			pick, best = i, dist
		}
	}
	if pick >= 0 {
		i := pick
		d := &interiors.doors[i]
		interiors.tried[i] = true
		free.share.done = false
		free.door = d.world
		pid, ok := psx.preload_fork()
		if !ok {
			return
		}
		if pid == 0 {
			interiors.load = free
			preload_enter(d)
			return
		}
		free.pid, free.since = pid, psx.vblanks()
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "interiors: loading %04x.%d in the background", d.world[0], d.world[1])
		}
		return
	}
}

// In the child: request the door's map as its exit would, then let the
// field draw go on; the game loads the room on the frames that follow.
@(private = "file")
preload_enter :: proc(d: ^Door) {
	c := &psx.cpu
	saved := c^
	c.r[29] -= 0x18
	c.r[4] = d.world[0]
	c.r[5] = d.world[1]
	c.r[6] = psx.lhu(d.exit + 6)
	c.r[7] = psx.lhu(d.exit + 8)
	psx.sw(c.r[29] + 16, psx.lbu(d.exit + 11))
	game_call(MAP_REQUEST, MAP_REQUEST_RET)
	cycles := c.cycles
	c^ = saved
	c.cycles = cycles
}

// In the child: a world was noted; hand it back if it is the room loaded.
@(private = "file")
preload_hand_back :: proc(w: ^World) {
	l := interiors.load
	if l == nil || w.key[0] != l.door[0] || w.key[1] != l.door[1] {
		return
	}
	sh := l.share
	sh.key, sh.regs, sh.main, sh.scene_ret = w.key, w.regs, w.main, w.scene_ret
	sh.map_end, sh.bank, sh.lasting, sh.story = w.map_end, w.bank, w.lasting, w.story
	sh.gpu, sh.disp, sh.camera = w.gpu, w.disp, w.camera
	sh.sound = w.sound^
	sh.start = w.start^
	sh.vram = w.vram^
	sh.done = true
	psx.preload_exit()
}

// The background load running for the room `key`, nil none.
@(private = "file")
preload_of :: proc(key: [2]u32) -> ^Preload {
	for &l in interiors.loads {
		if l.pid != 0 && l.door == key {
			return &l
		}
	}
	return nil
}

// In the parent: take the child's world once it handed one back, or end
// it past PRELOAD_LIMIT.
@(private = "file")
preload_poll :: proc(l: ^Preload) {
	sh := l.share
	ended := psx.preload_ended(l.pid)
	if !ended && !sh.done && psx.vblanks() - l.since < PRELOAD_LIMIT {
		return
	}
	if !ended {
		psx.preload_kill(l.pid)
	}
	l.pid = 0
	if !sh.done {
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "interiors: background load of %04x.%d failed", l.door[0], l.door[1])
		}
		return
	}
	w := world_slot(sh.key)
	world_alloc(w)
	w.key, w.used, w.stepped, w.rand = sh.key, psx.vblanks(), 0, sh.key[0] ~ 0x9e3779b9
	w.regs, w.main, w.scene_ret = sh.regs, sh.main, sh.scene_ret
	w.map_end, w.bank, w.lasting, w.story = sh.map_end, sh.bank, sh.lasting, sh.story
	w.gpu, w.disp, w.camera = sh.gpu, sh.disp, sh.camera
	w.sound^ = sh.sound
	w.start^ = sh.start
	psx.draw_start_adopt(w.start)
	w.vram^ = sh.vram
	w.ready = true
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: background load of %04x.%d done in %d vblanks", sh.key[0], sh.key[1], psx.vblanks() - l.since)
	}
}


// The party took the door the background load is on: wait for the child
// (a frozen frame of up to PRELOAD_WAIT) rather than load the room from the
// disc again, which takes longer than what the child has left.
@(private = "file")
preload_wait :: proc(l: ^Preload) -> ^World {
	start := time.tick_now()
	for !l.share.done && !psx.preload_ended(l.pid) && time.tick_since(start) < PRELOAD_WAIT {
		time.sleep(time.Millisecond)
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: waited %v for the background load of %04x.%d", time.tick_since(start), l.door[0], l.door[1])
	}
	key := l.door
	preload_poll(l)
	return world_find(key[0], key[1])
}

// Instant doors: a door request whose room has a world switches the machine
// to that world at the next field draw instead of loading the room from the
// disc. The world's map-local memory (MAP_LOCAL, its map data block), its
// scratchpad, GTE, VRAM and the field draw's registers come in; the rest of
// RAM (the save game, sound, disc and timer state) stays the town's.

// Where the disc loads a map's data block, and the most it may take.
@(private = "file")
MAP_DATA :: 0x80069800
@(private = "file")
MAP_DATA_MAX :: 0x80101000
// The field's mode byte (MAP_REQUEST sets 4, a map change) and its state
// index (the handler f_801be694 runs).
@(private = "file")
FIELD_MODE :: 0x80114870
@(private = "file")
FIELD_STATE :: 0x80114852
@(private = "file")
RAM_BASE :: 0x80000000
// RAM a map owns besides its data block: what differs between a town's and
// a room's machine at the same point of a frame, less the save game.
@(private = "file")
MAP_LOCAL := [?][2]u32 {
	{0x80010000, 0x80013000}, // a map file
	{0x80024000, 0x80025000},
	{0x8002d000, 0x8002e000},
	{0x80036000, 0x8005b000}, // CLUT and texture staging, the map heap
	{0x8010ff80, 0x80111000},
	{0x80114a04, 0x80116b00}, // which frame buffer is drawn, both buffers' draw and display environments and ordering tables
	{0x80116b00, 0x80119a00}, // the map record, objects, NPCs, models
	{0x8011c940, 0x8011ce40}, // map state
	{0x8011d2f0, 0x8011d340},
	// (From 0x8011d77c: libsnd's sequence table, SsSetTableSize(0x8011d77c,
	// 1, 6), 6 * 0xb0 bytes of each sequence's read position, tempo and
	// timing. Taken with the world, every switch put the music back where it
	// was when the world was noted, and notes came late or were lost.)
	{0x8011d770, 0x8011d77c},
	{0x8011e000, 0x80138300}, // packets, ordering tables, camera
	// Library state and draw lists; the sound library's state between
	// (0x8017c6a0..0x8017db00: its sound chip register copies, voice
	// attributes and sequencer) follows the sound chip, so it stays the
	// town's like the voices (world_enter): taking a world's old copy
	// made the music skip and notes hang at every door.
	{0x8017c000, 0x8017c6a0},
	{0x8017db00, 0x80182000},
	{0x801e3480, 0x801e34c0},
	{0x801f0800, 0x80200000}, // the map's code overlay, the stack
}

// The disc's data moved into RAM: follow the map data block's end.
@(private = "file")
interiors_dma_cdrom :: proc(addr, size: u32) {
	if addr == MAP_DATA {
		interiors.load_end = addr + size
		interiors.bank = {}
	} else if addr > MAP_DATA && addr < MAP_DATA_MAX && addr <= interiors.load_end + 0x800 {
		interiors.load_end = max(interiors.load_end, min(addr + size, MAP_DATA_MAX))
	}
}

// Sound data moved into sound RAM: follow the map's sound bank, which a
// map load moves in after its data block.
@(private = "file")
interiors_dma_spu :: proc(addr, size: u32) {
	b := &interiors.bank
	if b[0] == b[1] {
		b^ = {addr, addr + size}
	} else {
		b^ = {min(b[0], addr), max(b[1], addr + size)}
	}
}

// A door request to map m section `section` (sections.odin map_request,
// after the game's): true when its room's world will be switched to; once
// the screen is faded to black when `dark`.
@(private)
door_enter :: proc(m, section: u32, dark: bool) -> bool {
	if !config.field_instant_doors || psx.preload_child {
		return false
	}
	w := world_find(m, section)
	if l := preload_of({m, section}); w == nil && l != nil {
		w = preload_wait(l)
	}
	if w == nil || w.map_end <= MAP_DATA {
		return false
	}
	if w.story != story_key() {
		w.ready = false
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "interiors: world %04x.%d is from before the story moved on", m, section)
		}
		return false
	}
	interiors.entering = w
	interiors.enter_dark, interiors.dark_held = dark, false
	interiors.arrival = {u32(psx.lhu(ARRIVE_X)), u32(psx.lhu(ARRIVE_Z)), u32(psx.lbu(ARRIVE_DIRECTION))}
	interiors.enter_shift, interiors.enter_ok = {}, false
	for &d in interiors.doors[:interiors.n_doors] {
		if d.world == {m, section} {
			interiors.enter_shift = door_shift(&d) * TARGET_PER_CELL / VIEW_PER_CELL
			interiors.enter_quad, interiors.enter_front = door_inset(&d)
			interiors.enter_ok = true
		}
	}
	return true
}

// A fade just ended: whether to report it still running, once, so the field
// draws a frame more, at black, for a switch waiting on it (enter_dark). The
// field ends with the fade out of a map request: without that frame the game
// would go on to load the room from the disc.
@(private)
door_dark_hold :: proc() -> bool {
	if interiors.entering == nil || !interiors.enter_dark || interiors.dark_held {
		return false
	}
	interiors.dark_held = true
	return true
}

// Whether the door request being made is door_through's.
door_walked_through :: proc() -> bool {
	return interiors.through
}

// Whether a request to map m section `section` would switch to its room's
// world at once (door_enter): a door of the map drawn, its world kept from
// the story as it stands, or still loading.
@(private = "file")
door_ready :: proc(m, section: u32) -> bool {
	if !config.field_instant_doors || psx.preload_child || !door_to(m, section) {
		return false
	}
	if w := world_find(m, section); w != nil {
		return w.map_end > MAP_DATA && w.story == story_key()
	}
	return preload_of({m, section}) != nil
}

// The exit of the loaded section whose cells hold cell x, z and lead
// through a door ready to switch at once (door_ready), and the way through
// it (sections.odin exit_way). The party walks onto such cells: the game's
// exit there is left out (free_move.odin), and door_through switches as the
// leader passes their middle.
@(private)
door_exit_at :: proc(x, z: i32) -> (p: u32, way: [2]f32, ok: bool) {
	if interiors.doors_key != doors_key() {
		return
	}
	for e := exit_list(u32(psx.lhu(MAP_SECTION))); e != 0 && psx.lhu(e) != EXIT_END; e += EXIT_SIZE {
		at := [2]i32{i32(psx.lbu(e + 4)), i32(psx.lbu(e + 5))}
		n := i32(psx.lbu(e + 10))
		along := psx.lbu(e + 3) & 1 != 0 ? z - at.y : x - at.x
		beside := psx.lbu(e + 3) & 1 != 0 ? x - at.x : z - at.y
		if beside != 0 || along < 0 || along >= n {
			continue
		}
		if door_ready(u32(psx.lhu(e)), u32(psx.lbu(e + 2))) {
			return e, exit_way(e), true
		}
	}
	return
}

// The leader passed the middle of exit p's cells on the way through: ask
// for its map as the field's exit check does (KEPT_YAW, AREA_SET, then
// MAP_REQUEST with the exit's arrival), marked as walked through, so the
// switch (door_enter, world_enter) keeps the party where it stands. Should
// the room not be switched to after all, the request loads it as the game
// would.
@(private)
door_through :: proc(p: u32) {
	c := &psx.cpu
	ra, sp := c.r[31], c.r[29]
	defer c.r[29], c.r[31] = sp, ra
	m, section := u32(psx.lhu(p)), u32(psx.lbu(p + 2))
	psx.sh(KEPT_YAW, u32(psx.lhu(CAMERA_YAW)))
	c.r[4], c.r[5] = m, section
	game_call(AREA_SET, AREA_SET_RET)
	c.r[29] = sp - 0x18
	psx.sw(c.r[29] + 16, u32(psx.lbu(p + 11)))
	c.r[4], c.r[5], c.r[6], c.r[7] = m, section, u32(i32(i16(psx.lhu(p + 6)))), u32(i32(i16(psx.lhu(p + 8))))
	interiors.through = true
	game_call(MAP_REQUEST, MAP_REQUEST_RET)
	interiors.through = interiors.entering != nil
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: walked through the door to %04x.%d", m, section)
	}
}

// Script op 0x5b's map request (handler 0x801ddfc0): AREA_SET, the camera
// yaw kept, then MAP_REQUEST, returning where the op does. The autopilot's
// `request` stands in with it for scenes not reached yet; it runs between
// the game's instructions, so every register is put back.
@(private = "file")
SCRIPT_AREA_SET_RET :: 0x801ddfe0
@(private)
SCRIPT_REQUEST_RET :: 0x801de044

script_request :: proc(m, section: u32, x, z: i32, facing: u32) {
	c := &psx.cpu
	regs := c.r
	defer c.r = regs
	c.r[4], c.r[5] = m, section
	game_call(AREA_SET, SCRIPT_AREA_SET_RET)
	psx.sh(KEPT_YAW, u32(psx.lhu(CAMERA_YAW)))
	c.r[29] = regs[29] - 0x18
	psx.sw(c.r[29] + 16, facing)
	c.r[4], c.r[5], c.r[6], c.r[7] = m, section, u32(x), u32(z)
	game_call(MAP_REQUEST, SCRIPT_REQUEST_RET)
}

// The town door just walked through: its room's point p is the town's p
// less this (target units).
door_enter_shift :: proc() -> [3]f32 {
	return interiors.enter_shift
}

// A hash of the story flags (STORY_*).
@(private = "file")
story_key :: proc() -> u64 {
	h: u64 = 0xcbf29ce484222325
	add :: proc(h: ^u64, r: [2]u32) {
		for a in r[0] ..< r[1] {
			skip := false
			for s in STORY_SKIP {
				skip ||= a >= s[0] && a < s[1]
			}
			if !skip {
				h^ = (h^ ~ u64(psx.ram[a - RAM_BASE])) * 0x100000001b3
			}
		}
	}
	add(&h, STORY_FLAGS)
	add(&h, STORY_PARTY)
	return h
}

// Put the party where the request arrives, as the map setup does: on the
// cell, at the ground's height, facing the request's way; and the camera's
// target on it, which the world kept from when it was noted (the game's
// camera takes it up a frame or two later). Walked through (door_through),
// the party and the camera's target go on from where they stood in the
// town, `at`, moved by the door's shift: the room's first frame is the
// town's last.
@(private = "file")
arrive :: proc(at: Party_At) {
	x, z, direction := interiors.arrival[0], interiors.arrival[1], interiors.arrival[2]
	psx.sh(ARRIVE_X, x)
	psx.sh(ARRIVE_Z, z)
	psx.sb(ARRIVE_DIRECTION, direction)
	psx.sh(ARRIVE_POS, x)
	psx.sh(ARRIVE_POS + 4, z)
	psx.cpu.r[4] = ARRIVE_POS
	psx.call(GROUND_HEIGHT)
	height := psx.cpu.r[2]
	psx.sh(ARRIVE_POS + 2, height & 0xffff)
	if interiors.through {
		interiors.through = false
		shift := interiors.enter_shift
		for i in u32(0) ..< PARTY_COUNT {
			obj := PARTY_OBJ + PARTY_OBJ_SIZE * i
			for k in u32(0) ..< 3 {
				v := u32(at.pos[i][k] - i32(math.round(shift[k] * 256)))
				psx.sw(obj + OBJ_POS + 4 * k, v)
				psx.sw(obj + OBJ_TARGET + 4 * k, v)
			}
			psx.sb(obj + OBJ_DIRECTION, at.direction[i])
		}
		through_clamp()
		for k in u32(0) ..< 3 {
			psx.sh(CAM_TARGET + 2 * k, u32(i32(at.target[k]) - i32(math.round(shift[k]))) & 0xffff)
		}
		return
	}
	for i in u32(0) ..< PARTY_COUNT {
		at := PARTY_OBJ + PARTY_OBJ_SIZE * i
		psx.sw(at + OBJ_POS, x << 8)
		psx.sw(at + OBJ_POS + 4, u32(i32(i16(height))) << 8)
		psx.sw(at + OBJ_POS + 8, z << 8)
		psx.sb(at + OBJ_DIRECTION, direction)
	}
	psx.sh(CAM_TARGET, x)
	psx.sh(CAM_TARGET + 2, height & 0xffff)
	psx.sh(CAM_TARGET + 4, z)
}

// Keep the party, walked through, inside the run of cells of the exit it
// came out of: the door's shift lines up the doorway's picture, which can be
// wider than the exit's cells, and a leader set down on the wall beside them
// could not step off it. The whole party moves by the leader's correction,
// across the exit's way only.
@(private = "file")
THROUGH_CELL :: 0x10000
// How far inside the exit's end cells the leader is kept: free_move's
// RADIUS, the half-width it steps with.
@(private = "file")
THROUGH_MARGIN :: 0x5000
@(private = "file")
through_clamp :: proc() {
	left_section := u32(psx.lbu(LEFT_MAP + 6)) & 0xf
	p := exit_to(u32(psx.lhu(MAP_SECTION)), u32(psx.lhu(LEFT_MAP)), left_section)
	if p == 0 {
		return
	}
	k := psx.lbu(p + 3) & 1 != 0 ? u32(2) : 0
	first := i32(psx.lbu(p + (k == 0 ? 4 : 5))) * THROUGH_CELL
	last := first + i32(psx.lbu(p + 10)) * THROUGH_CELL
	v := i32(psx.lw(PARTY_OBJ + OBJ_POS + 4 * k))
	d := clamp(v, first + THROUGH_MARGIN, last - THROUGH_MARGIN) - v
	if d == 0 || last - first <= 2 * THROUGH_MARGIN {
		return
	}
	for i in u32(0) ..< PARTY_COUNT {
		obj := PARTY_OBJ + PARTY_OBJ_SIZE * i
		v := u32(i32(psx.lw(obj + OBJ_POS + 4 * k)) + d)
		psx.sw(obj + OBJ_POS + 4 * k, v)
		psx.sw(obj + OBJ_TARGET + 4 * k, v)
	}
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: walked-through party moved %.2f cells into the exit", f32(d) / THROUGH_CELL)
	}
}

// Where the party and the camera's target stood in the town, as a door
// was walked through.
@(private = "file")
Party_At :: struct {
	pos:       [PARTY_COUNT][3]i32,
	direction: [PARTY_COUNT]u32,
	target:    [3]i16,
}

@(private = "file")
party_at :: proc() -> (at: Party_At) {
	for i in u32(0) ..< PARTY_COUNT {
		obj := PARTY_OBJ + PARTY_OBJ_SIZE * i
		for k in u32(0) ..< 3 {
			at.pos[i][k] = i32(psx.lw(obj + OBJ_POS + 4 * k))
		}
		at.direction[i] = u32(psx.lbu(obj + OBJ_DIRECTION))
	}
	for k in u32(0) ..< 3 {
		at.target[k] = i16(psx.lhu(CAM_TARGET + 2 * k))
	}
	return
}

// Note the map left, as the map setup does before it places the party.
@(private = "file")
left :: proc() {
	psx.sh(LEFT_MAP, u32(psx.lhu(FIELD_MAP)))
	psx.sh(LEFT_MAP + 2, u32(i32(psx.lw(PARTY_OBJ + OBJ_POS)) >> 8))
	psx.sh(LEFT_MAP + 4, u32(i32(psx.lw(PARTY_OBJ + OBJ_POS + 8)) >> 8))
	psx.sb(LEFT_MAP + 6, u32(psx.lbu(MAP_SECTION)) | u32(psx.lbu(PARTY_OBJ + 0x18)) << 4)
}

// Stop the sounds playing, as a map load does.
@(private = "file")
sounds_stop :: proc() {
	for i in u32(0) ..< SOUND_SLOTS {
		if psx.lbu(SOUND_SLOT + SOUND_SLOT_SIZE * i) != 0 {
			psx.cpu.r[4] = i
			psx.call(SOUND_STOP)
		}
	}
}

// Start again the lasting sounds world w had playing (its map scripts
// start them, such as a fountain's, once, as the map loads). One-shots
// still sounding when the world was noted, such as a step or a bird's
// call, are left: replaying them sounded at every door.
@(private = "file")
sounds_resume :: proc(w: ^World) {
	for i in u32(0) ..< SOUND_SLOTS {
		at := SOUND_SLOT + SOUND_SLOT_SIZE * i - RAM_BASE
		if int(i) not_in w.lasting || w.start.ram[at] == 0 {
			continue
		}
		psx.cpu.r[4] = u32((^u16le)(&w.start.ram[at + 4])^)
		psx.cpu.r[5] = u32(w.start.ram[at + 6])
		psx.cpu.r[6] = u32((^u32le)(&w.start.ram[at + 0x10])^)
		psx.call(SOUND_PLAY)
	}
}

// Switch the machine to world w, at the town's field draw: the world was
// noted at its own.
@(private = "file")
world_enter :: proc(w: ^World) {
	take :: proc(w: ^World, from, to: u32) {
		copy(psx.mem_slice(from, to - from), w.start.ram[from - RAM_BASE:to - RAM_BASE])
	}
	at := party_at()
	left()
	sounds_stop()
	voices: [SOUND_VOICES[1] - SOUND_VOICES[0]]u8
	slots: [SOUND_SLOTS * SOUND_SLOT_SIZE]u8
	copy(voices[:], psx.ram[SOUND_VOICES[0] - RAM_BASE:])
	copy(slots[:], psx.ram[SOUND_SLOT - RAM_BASE:])
	yaw := u32(psx.lhu(KEPT_YAW))
	// At the black of a script's request (enter_dark), the game's fade out
	// still waits for its end, on the stack the world's replaces: its frame
	// is kept, so it ends there, and the game goes on to set the map up as
	// it would after loading it, finding it in already, and fades it in.
	fading: [FADE_FRAME]u8
	fade_sp := fade_frame()
	keep := interiors.enter_dark && fade_sp != 0
	if keep {
		copy(fading[:], psx.mem_slice(fade_sp, FADE_FRAME))
	}
	for r in MAP_LOCAL {
		take(w, r[0], r[1])
	}
	if keep {
		copy(psx.mem_slice(fade_sp, FADE_FRAME), fading[:])
	}
	take(w, MAP_DATA, w.map_end)
	third_person_game_fields_put(w.camera)
	copy(psx.mem_slice(SOUND_VOICES[0], u32(len(voices))), voices[:])
	copy(psx.mem_slice(SOUND_SLOT, u32(len(slots))), slots[:])
	psx.sh(KEPT_YAW, yaw)
	copy(psx.sound_ram()[w.bank[0]:w.bank[1]], w.sound[w.bank[0]:w.bank[1]])
	interiors.bank = w.bank
	take(w, FIELD_STATE, FIELD_STATE + 2)
	take(w, FIELD_MODE, FIELD_MODE + 1)
	psx.draw_start_enter(w.start)
	sounds_resume(w)
	arrive(at)
	crossing_turn()
	psx.cpu.r = w.regs.r
	psx.cpu.hi, psx.cpu.lo = w.regs.hi, w.regs.lo
	// The GPU goes on from where the world was noted: drawing into its
	// frame's buffer, showing the other. Both take the picture shown now,
	// which stays until the noted frame is up: the rest of it runs from
	// the world's field draw, into the world's own ordering table and
	// buffer (MAP_LOCAL), with no hold. The camera goes on through the door
	// (sections.odin map_request), so the room's frames carry it on.
	shown := psx.display
	if interiors.first_cover == nil {
		interiors.first_cover = make([]u16, PICTURE_W * PICTURE_H)
	}
	interiors.first_cover_wh = {min(shown.w, PICTURE_W), min(shown.h, PICTURE_H)}
	psx.picture_take(shown.x, shown.y, interiors.first_cover_wh[0], interiors.first_cover_wh[1], interiors.first_cover, &interiors.first_cover_hi)
	interiors.first_cover_due = !interiors.enter_dark
	interiors.first_cover_view = interiors.view
	moved := town_view_point(interiors.enter_shift * VIEW_PER_CELL / TARGET_PER_CELL, {interiors.view[5], interiors.view[6], interiors.view[7]})
	for i in 0 ..< 3 {
		interiors.first_cover_view[5 + i] = u32(i32(moved[i]))
	}
	interiors.first_cover_h = f32(interiors.h)
	psx.move_image(shown.x, shown.y, w.disp.x, w.disp.y, shown.w, shown.h)
	psx.vram_replace(w.vram, {w.disp.x, w.disp.y, shown.w, shown.h})
	psx.move_image(w.disp.x, w.disp.y, w.gpu.x1, w.gpu.y1, shown.w, shown.h)
	psx.gpu = w.gpu
	psx.display_start(w.disp.x, w.disp.y)
	interiors.cover_at, interiors.cover_in = interiors.enter_dark ? 0 : psx.vblanks(), 0
	followers_shown()
	for &d in interiors.doors[:interiors.n_doors] {
		d.cover_drawn = false
	}
	w.used = psx.vblanks()
	interiors.load_end = w.map_end
	inbetween_world_switch()
	if .Qol in psx.trace.active {
		psx.tracef(.Qol, "interiors: entered world %04x.%d at once (map data to %08x, sound bank %x..%x)", w.key[0], w.key[1], w.map_end, w.bank[0], w.bank[1])
	}
}
