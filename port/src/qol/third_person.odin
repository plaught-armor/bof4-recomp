// Third-person field camera: while the player walks the field, the camera
// keeps the game's height and angle but turns freely round the leader and
// follows behind him, and zooms in and out.
//
// The exe's VIEW_BUILD (0x8014307c, once or twice per frame) turns the
// camera block's parameters into the GTE's view: SetGeomScreen(H), the
// rotation from pitch/yaw/roll into CAM_MATRIX, then the translation that
// puts the look-at target at `distance` straight ahead. The target is kept
// at 2x view units (256 per grid cell) and follows the leader's
// feet. Depth sorting drops anything nearer than CAM_NEAR, which the game
// sets for its own distance, so a closer camera needs it lowered by as much.
// The geometry's size on screen goes with H / distance, and that ratio is
// kept at the game's (the closer camera has a wider lens) down to H_MIN,
// past which the lens would stretch the picture's edges; nearer than that
// the leader grows. Sprites are drawn at
// a fixed size (scaled only when the sprite asks, by 0x140000 / depth, which
// ignores H), so while this camera is in, SPRITE_DRAW (0x8014193c) is given
// a scale that matches the geometry at the sprite's depth, relative to the
// game's framing: about 1 at the leader, larger nearer the camera.
//
// With `third_person`, the hook writes its own pitch (the arm's boom) and
// distance (zoom, arm) for the call and puts the game's values back after
// it, so nothing else sees them. H and the near limit are read while drawing, so they stay
// written; a value that differs from the one last written is the game's own
// (new) value. The change blends in over BLEND_S while the leader is under
// player control on the field and back out in events, dialog and menus, so
// scenes keep the game's framing.
//
// The camera hangs on a spring arm: the line from the leader out to the
// lens, and two fanning out to either side of the lens (ARM_FAN), are walked
// over the collision grid (minimap.odin's grid_of), and when one meets a
// wall cell the arm's reach over the ground is cut to stop ARM_MARGIN short
// of it, quickly (ARM_IN_S); it lets back out over ARM_OUT_S once the wall
// is gone. A doorway to a neighbour section drawn with this one
// (sections.odin) ends the walk clear: past it are the neighbour's rooms,
// and the camera keeps its yaw across into them. The arm keeps its length and swings up instead (up to
// BOOM_MAX), so the camera rises over what is behind the leader and he keeps
// his size on screen; past BOOM_MAX it rises no further and stays where it
// is, inside the building behind him if need be. What is
// still in the way, the GPU fades per
// pixel, by real depth (render.see_through, see psx/render/see_through.odin and scene/see.odin):
// set_see_through hands it the leader's middle for each view built. What the
// camera sits in is cut away near the lens; a face whose plane has the
// leader behind it as seen from the lens (a wall turned to the camera in
// front of him, a roof over him) is a ghost where it hides him, growing
// more opaque toward him; the ground and everything else are drawn as
// usual. Triangles too big for the PS1 GPU are drawn too, so floor running
// under the lens leaves no holes.
//
// While the leader walks, the camera swings round behind him (toward the way
// he moves, eased over FOLLOW_S) unless the player turned it within
// FOLLOW_PAUSE_S; walking toward the camera does not spin it. He faces the
// way he walks, so his sprite's animations stay as the game draws them.
//
// An in-between picture (smooth motion, inbetween.odin) blends the game's
// camera fields and the GTE's matrices between two game frames; this
// camera's own state (blend, arm, zoom) is noted with each game frame's
// pose and blended with them (third_person_state, inbetween_tp), or
// the pass would pair a blended rotation with this frame's arm and draw, and
// fade, from a camera that never was.
//
// L1/R1 (the mouse wheel) zoom instead of turning by 90 degrees, and turning
// is free on every map. The pitch stays the game's: the camera turns but
// does not tilt.
package qol

import "core:math"
import "core:math/linalg"
import "core:slice"

import cpu "ps:psx/cpu"
import gte "ps:psx/gte"
import host "ps:psx/host"
import io "ps:psx/io"
import render "ps:psx/render"
import scene "../scene"

// Maps of area M (1xxx) are towns; any other map is a room or a field.
@(private = "file")
TOWN_MAPS :: 0x1000
@(private = "file")
PARTY_OBJ_SIZE :: 0xfc
@(private = "file")
PARTY_COUNT :: 3
// SPRITE_DRAW's return address from the object sprite list; its other caller
// draws 52-byte copies of sprites (flag 8 effects), which have no object.
@(private = "file")
SPRITE_LIST_RA :: 0x80142224
@(private = "file")
ROTATE_TRIGGER :: 0x801d94e8 // FLD_MAIN: L1/R1 starts a camera turn; v0 = 1 if so
// a0 x, a1 y, a2 face code, a3 brightness: a message box's speaker portrait,
// a quad built at SPRITE_PACKETS (docs/text-and-ui.md, code 0x17).
@(private = "file")
FACE_DRAW :: 0x801516ec

// a0 = placed model: v0 = 0 hides it from the camera's octant. A model
// with byte +2 bit 2 hides from each octant ((CAMERA_YAW + 0x100) >> 9) whose
// bit is set in byte +0xb: Sarai's awnings, which would hide the stalls from
// the game's fixed views.
@(private = "file")
MODEL_SHOWN :: 0x80149ee0
// a0 x, a1 z of a placed model: v0 = 0 culls it as out of the fixed view's
// sight. The field draw sets the test in scratchpad per view: centre
// 0x1f800084/86 (+0x40), manhattan radius 0x1f800088, side limit 0x1f80008a,
// mode 0x1f80008d (from (CAMERA_YAW + 0x100) & 0x600). Facing one way, it culls
// what stands behind the fixed camera, e.g. Sarai's awnings from the north.
@(private = "file")
MODEL_IN_VIEW :: 0x80145c08
@(private = "file")
CAM_H :: 0x80138184 // s32, projection distance
@(private = "file")
CAM_NEAR :: 0x80138188 // s32, nearer depths are not drawn
@(private = "file")
CAM_PITCH :: 0x8013818c // u16, 0x800 level, larger looks further down
@(private = "file")
CAM_DISTANCE :: 0x8013819c // s32, view units from the target
// u16 x2: the half height and half width, in grid cells, of the window of
// map tiles drawn around a point ahead of the camera (tile window
// 0x8014330c, read while drawing). Its rows go into a list of 64 entries.
@(private = "file")
CAM_TILE_RADII :: 0x801381e4
// The radii while this camera is in: its low view reaches past the game's
// window, which leaves holes where the far ground and walls should be.
@(private = "file")
TP_TILE_RADIUS :: 31
@(private = "file")
CAM_ROLL :: 0x80138190 // u16
@(private = "file")
CAM_POS :: 0x80138194 // s32 x, y; the view's offset from straight ahead
@(private = "file")
CAM_SCALE :: 0x801381ac // s32 x3, the matrix's column scales (0x1000 = 1)

// Sprite fields; the sprite is at +84 in its object.
@(private = "file")
SPRITE_OBJ :: 84
@(private = "file")
SPRITE_FLAGS :: 1 // u8
@(private = "file")
SPRITE_AT :: 4 // s16 x, y: the screen pixel the game projected the object to
@(private = "file")
SPRITE_SEMI :: 2 // in SPRITE_FLAGS: drawn see-through (additive)
@(private = "file")
SPRITE_SCALED :: 15 // u8, set: draw scaled by the two below
@(private = "file")
SPRITE_COLOR :: 24 // u32, r | g << 8 | b << 16, 0x80 = 1
@(private = "file")
SPRITE_SCALE_X :: 16 // s32, 0x10000 = 1
@(private = "file")
SPRITE_SCALE_Y :: 20
@(private = "file")
SCALE_ONE :: 0x10000
@(private = "file")
SCALE_MAX :: 4 * SCALE_ONE
// The shadows' 52-byte records (SHADOW_SET 0x801423f0 copies the sprite's
// position, scale and colour into one, drawn right after the sprite).
@(private = "file")
SHADOWS :: 0x80118bb0
@(private = "file")
SHADOWS_END :: SHADOWS + 35 * 52

// A sprite's parts go in its depth index's ordering-table bucket and up to
// How far the leader's middle, which the camera must see, is above his feet
// (view units, 128 a grid cell).
@(private = "file")
LEADER_MIDDLE :: 64
// The blend from which the camera sees through.
@(private = "file")
SEE_FROM :: 0.5

// The framing is the game's own pitch and distance; the zoom (L1/R1) scales
// the distance, between these shares of it.
@(private = "file")
ZOOM_MIN :: 0.05
@(private = "file")
ZOOM_MAX :: 1.5

// The widest lens (least H) this camera uses, so the edges of the picture do
// not stretch: about 70 degrees across the field's 320 pixels.
@(private = "file")
H_MIN :: 0xe0

// Follow: seconds to close most of the gap behind the leader; seconds a
// manual turn holds it off; the least move per tick (16.16 cells) that
// counts as walking; how far round (game units) the way he walks may be from
// the camera's facing and still be followed.
@(private = "file")
FOLLOW_S :: 0.8
@(private = "file")
FOLLOW_PAUSE_S :: 1.0
@(private = "file")
FOLLOW_MIN_STEP :: 0x1000
@(private = "file")
FOLLOW_REACH :: 0x600

// Spring arm: grid samples per cell walked, cells kept clear of a wall, the
// shortest share of the arm, seconds to pull in and to let back out. In
// eases too, fast: a wall swinging behind the leader (the camera turning, or
// him walking past a corner) cut the arm by half in one frame, a pop of the
// pitch, and what the lens passes through meanwhile is cut away
// (see_through).
@(private = "file")
ARM_SAMPLES :: 8
@(private = "file")
ARM_MARGIN :: 0.3
@(private = "file")
ARM_MIN :: 0.5
@(private = "file")
ARM_IN_S :: 0.1
@(private = "file")
ARM_OUT_S :: 0.4
// The arm's spring in through an instant door, per second: critically
// damped, so it sets off from rest and is all but in after 1.2 s.
@(private = "file")
DOOR_ARM_W :: 4.0
// The steepest the arm swings up to clear a wall behind the leader; how
// far either side of the lens (cells) the walk over the grid looks.
@(private = "file")
BOOM_MAX :: 0xa00
@(private = "file")
ARM_FAN :: 0.75
// While the camera turns, the walk also runs where the yaw will be over the
// next ARM_AHEAD_S at the speed it turns, at ARM_AHEAD_SAMPLES steps: a fast
// turn swings the lens a few cells a frame, into a building before the ease
// in could pull it out.
@(private = "file")
ARM_AHEAD_S :: 0.25
@(private = "file")
ARM_AHEAD_SAMPLES :: 4
@(private = "file")
VIEW_PER_CELL :: 128
@(private = "file")
ATTR_WALL :: 0x1 // high nibble of a wall cell's attribute

// Seconds to blend between the game's camera and this one; zoom factor per
// second of L1/R1 held.
@(private = "file")
BLEND_S :: 0.3
@(private = "file")
ZOOM_PER_S :: 3.0

@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
OBJ_POS :: 0xc // s32 x, y, z, 16.16
@(private = "file")
OBJ_PAD :: 0xe6 // u16, held pad bits
@(private = "file")
STATE_PLAYER_CONTROL :: 1
@(private = "file")
STATE_IDLE :: 8 // the stretch after standing still a while
@(private = "file")
STATE_SCRIPT :: 2 // a scene moves the leader (and the game's camera)
@(private = "file")
STATE_TALK :: 5 // turning to an NPC, before the event mode takes over
@(private = "file")
STATE_MENU :: 6 // the field menu is open
@(private = "file")
MODE_FIELD_ID :: 2
@(private = "file")
MODE_EVENT :: 4 // a talk or scene runs
@(private = "file")
MODE_SHOP :: 7
@(private = "file")
VBLANK_HZ :: 60
// Longest step the blend takes at once, in seconds.
@(private = "file")
MAX_DT :: 0.1

// A camera value the game keeps reading after the view is built.
@(private = "file")
Kept :: struct {
	game, wrote: u32,
}

@(private = "file")
tp: struct {
	view, trigger, sprite, model_shown, model_in_view, face: cpu.Func_Proc,
	// 0 the game's camera, 1 this one.
	t:             f64,
	last:          u64,
	// GAME_FRAME the state last stepped at (third_person_view).
	frame:         u32,
	zoom:          f64,
	h, near:       Kept,
	radii:         Kept,
	// The share of the arm in use, and the seconds the last real frame took.
	arm:           f64,
	dt:            f64,
	// The arm is coming in through an instant door (spring), and how fast
	// its pitch moves, units a second.
	door_in:       bool,
	lift_v:        f64,
	// The leader's x, z at the last follow tick; seconds since a manual turn.
	feet:          [2]i32,
	idle_s:        f64,
	// The view depth of the object the sprite list drew last (0 for none)
	// and whether it is the party's: its 52-byte copy, drawn next, stands
	// with it.
	copy_depth:    f32,
	copy_party:    bool,
	// Where that object stands in view space, for the depth buffer (always
	// filed under the close camera, the party too).
	copy_at:       [3]f32,
	// Its anchor's sub-pixel part (gte.anchor_sub), for the copy too.
	copy_sub:      [2]i8,
	// The share of that object faded out (fade_solid), or -1 for none, and
	// its sprite's flags and colour before: the copy's are the same (not
	// so the dust its feet kick up, drawn here too).
	copy_clear:    f32,
	copy_flags:    u32,
	copy_color:    u32,
	// The scale that object's sprite was drawn at (0 for none): its shadow
	// takes it, not the game's own (0x140000 / depth of the close camera,
	// many times the size).
	copy_scale:    [2]u32,
	// What the camera's yaw holds past the whole CAMERA_YAW, and the CAMERA_YAW it
	// goes with: under any other yaw (the game's own turns, a door room's
	// view) it holds nothing past.
	yaw_frac:      f64,
	yaw_wrote:     u32,
	// The exact yaw at the arm's last step, and how fast it turns (radians
	// a second; ARM_AHEAD_S).
	yaw_last:      f64,
	yaw_v:         f64,
	// The view depth of where the leader stands, in the view last built.
	leader_depth:  f32,
}

// This camera's own state, which in-between pictures blend with the game's
// (inbetween.odin's Pose).
@(private)
Tp_Blend :: struct {
	t, arm, zoom: f64,
	// tp.yaw_frac.
	yaw:          f64,
}

// The state the view was last built with.
@(private)
third_person_state :: proc() -> Tp_Blend {
	return {tp.t, tp.arm, tp.zoom, yaw_exact() - f64(cpu.lhu(CAMERA_YAW))}
}

// The camera's yaw, unrounded (0x1000 a turn).
@(private)
yaw_exact :: proc() -> f64 {
	y := u32(cpu.lhu(CAMERA_YAW))
	return f64(y) + (y == tp.yaw_wrote ? tp.yaw_frac : 0)
}

// Turn the camera's yaw by `by` units (0x1000 a turn), keeping the part past
// the whole unit for the exact view; returns the yaw written.
@(private)
yaw_turn :: proc(by: f64) -> u32 {
	f := yaw_exact() + by
	whole := math.round(f)
	y := u32(i32(whole)) & 0xfff
	cpu.sh(CAMERA_YAW, y)
	tp.yaw_frac, tp.yaw_wrote = f - whole, y
	return y
}

@(private)
third_person_init :: proc() -> bool {
	tp.zoom, tp.arm = 1, 1
	ok: bool
	tp.view, ok = cpu.hook(VIEW_BUILD, third_person_view)
	if !ok {
		return false
	}
	tp.trigger, ok = hook_field(ROTATE_TRIGGER, rotate_trigger)
	if !ok {
		return false
	}
	tp.sprite, ok = cpu.hook(SPRITE_DRAW, sprite_draw)
	if !ok {
		return false
	}
	tp.model_shown, ok = cpu.hook(MODEL_SHOWN, model_shown)
	if !ok {
		return false
	}
	tp.model_in_view, ok = cpu.hook(MODEL_IN_VIEW, model_in_view)
	if !ok {
		return false
	}
	tp.face, ok = cpu.hook(FACE_DRAW, face_draw)
	return ok
}

// A portrait is drawn flat on the screen: keep any depth off its quad
// (scene.screen_add), or it can take a sprite's from frames before and hide
// behind the scenery.
@(private = "file")
face_draw :: proc() {
	lo := cpu.lw(SPRITE_PACKETS)
	tp.face()
	scene.screen_add(lo, cpu.lw(SPRITE_PACKETS))
}

// This camera turns freely and looks through what stands before the leader
// (see_through), so no model hides by the way it looks and every placed model
// is in the fixed view's sight.
@(private)
models_all_shown :: proc() -> bool {
	return config.camera_third_person
}

@(private = "file")
model_shown :: proc() {
	if !models_all_shown() {
		tp.model_shown()
		return
	}
	cpu.state.r[2] = 1
}

// The same for the fixed view's sight test: every placed model is in view.
@(private = "file")
model_in_view :: proc() {
	if !models_all_shown() {
		tp.model_in_view()
		return
	}
	cpu.state.r[2] = 1
}

// Swing the camera's yaw toward the way the leader walks, `ticks` vblanks
// after the last field tick; `turned` when the player turned it this tick.
@(private)
third_person_follow :: proc(ticks: u64, turned: bool) {
	pos := u32(leader_obj() + OBJ_POS)
	feet := [2]i32{i32(cpu.lw(pos)), i32(cpu.lw(pos + 8))}
	step := feet - tp.feet
	tp.feet = feet
	// Through a doorway to a neighbour the leader's position jumps into the
	// neighbour's frame, and the exit walk keeps its way: the camera keeps
	// its yaw.
	if crossing_walk() {
		return
	}
	dt := min(f64(ticks) / VBLANK_HZ, MAX_DT)
	tp.idle_s = turned ? 0 : tp.idle_s + dt
	if tp.t < 1 || tp.idle_s < FOLLOW_PAUSE_S {
		return
	}
	dx, dz := f64(step.x), f64(step.y)
	if dx * dx + dz * dz < FOLLOW_MIN_STEP * FOLLOW_MIN_STEP {
		return
	}
	// Direction a points at (sin a, -cos a) in (x, z); screen-up is the yaw.
	want := math.atan2(dx, -dz) * 4096 / (2 * math.PI)
	gap := math.mod(want - yaw_exact() + 0x800 + 0x2000, 0x1000) - 0x800
	if abs(gap) > FOLLOW_REACH {
		return
	}
	yaw_turn(gap * (1 - math.exp(-dt / FOLLOW_S)))
}

// L1/R1 zoom on the field instead of turning while the option is on.
@(private = "file")
rotate_trigger :: proc() {
	if config.camera_third_person {
		cpu.state.r[2] = 0
		return
	}
	tp.trigger()
}

@(private = "file")
third_person_view :: proc() {
	// An in-between picture (smooth motion) redraws the frame from RAM as it
	// was when the frame began drawing, and then puts RAM back as the frame
	// left it: the blend and the kept values only follow real frames, and
	// the picture's view uses the state the pass blended (inbetween_tp).
	// A door's room (interiors.odin) is drawn for the real frame: its view
	// uses the frame's state as it stands.
	target := crossing_view_begin()
	defer crossing_view_end(target)
	// The game builds the view several times a frame, some of them while the
	// frame is still drawing (a frame's drawing can span vblanks): the state
	// steps once a game frame, so all of a frame's drawing has one view, the
	// one its in-between pictures blend.
	if !io.events_frozen {
		frame := cpu.lw(GAME_FRAME)
		step := frame != tp.frame
		if step {
			tp.frame = frame
			blend(cpu.lw(SLOT_ENGINE) == FLD_MAIN_ID)
		}
		build_view(third_person_state().yaw, {}, step)
		return
	}
	if !inbetween_replaying {
		build_view(third_person_state().yaw, {}, false)
		return
	}
	now := third_person_state()
	tp.t, tp.arm, tp.zoom = inbetween_tp.t, inbetween_tp.arm, inbetween_tp.zoom
	build_view(inbetween_tp.yaw, inbetween_frac, false)
	tp.t, tp.arm, tp.zoom = now.t, now.arm, now.zoom
}

// Build the view; `yaw_frac` and `frac` are what the camera's yaw and fields hold
// past their whole values in RAM (third_person_state, inbetween_frac). `step`:
// the game frame's first build, which moves the arm on.
@(private = "file")
build_view :: proc(yaw_frac: f64, frac: [VIEW_FIELD_COUNT]f64, step: bool) {
	h := kept_game(&tp.h, CAM_H)
	near := kept_game(&tp.near, CAM_NEAR)
	radii := kept_game(&tp.radii, CAM_TILE_RADII)
	if tp.t == 0 {
		kept_write(&tp.h, CAM_H, h)
		kept_write(&tp.near, CAM_NEAR, near)
		kept_write(&tp.radii, CAM_TILE_RADII, radii)
		cpu.world_3d = false
		tp.view()
		render.see_through.on = false
		gte.exact_view.stamp = 0
		return
	}
	pitch, distance := cpu.lhu(CAM_PITCH), cpu.lw(CAM_DISTANCE)
	height := cpu.lhu(CAM_TARGET + 2)
	yaw := f64(cpu.lhu(CAMERA_YAW)) * (2 * math.PI / 4096)
	reach := f64(i32(distance)) * zoom()
	tilt := u32(pitch)
	if !io.events_frozen {
		want := 1.0
		if step {
			// The yaw's turn since the last step, per second.
			now := yaw_exact()
			turned := math.mod(now - tp.yaw_last + 0x800 + 0x2000, 0x1000) - 0x800
			tp.yaw_v = tp.dt > 0 ? turned / tp.dt * (2 * math.PI / 4096) : 0
			tp.yaw_last = now
			ahead := tp.yaw_v * ARM_AHEAD_S
			for k in 0 ..= ARM_AHEAD_SAMPLES {
				// Not turning, every sample is the first.
				if k > 0 && ahead == 0 {
					break
				}
				want = min(want, arm_reach(reach, yaw + ahead * f64(k) / ARM_AHEAD_SAMPLES, f64(tilt)))
			}
		}
		spring(want, tilt, step)
	}
	cpu.sh(CAM_PITCH, boom(tilt))
	cpu.sh(CAM_TARGET + 2, height)
	kept_write(&tp.radii, CAM_TILE_RADII, max(radii & 0xffff, TP_TILE_RADIUS) | max(radii >> 16, TP_TILE_RADIUS) << 16)
	cpu.world_3d = true
	a0 := cpu.state.r[4]
	view_at(u32(i32(math.round(reach))), distance, h, near)
	exact_set(a0, yaw_frac, frac, h, pitch, distance, height)
	cpu.sh(CAM_PITCH, pitch)
	cpu.sw(CAM_DISTANCE, distance)
	cpu.sh(CAM_TARGET + 2, height)
	set_see_through()
}

// Hand the GTE the way from the view just built to the one unrounded values
// give (gte.exact_view). `yaw_frac` and `frac` are what the yaw and the camera
// fields hold past their whole values (build_view); pitch, distance and
// height the game's, h its lens; a0 VIEW_BUILD's offset vector. The rest of
// what build_view rounds (boom, view_at) is taken here unrounded;
// CAM_MATRIX and CAM_TR hold the view built.
@(private = "file")
exact_set :: proc(a0: u32, yaw_frac: f64, frac: [VIEW_FIELD_COUNT]f64, h, pitch, distance, height: u32) {
	e := &gte.exact_view
	e.stamp = 0
	if cpu.lhu(CAM_ROLL) != 0 {
		return
	}
	for i in u32(0) ..< 3 {
		if cpu.lw(CAM_SCALE + i * 4) != 0x1000 {
			return
		}
	}
	// frac's fields, in VIEW_FIELDS order.
	PITCH, YAW, POS, DISTANCE, TARGET :: 0, 1, 3, 5, 6
	game_pitch := f64(i16(pitch)) + frac[PITCH]
	tilt := game_pitch
	turn := 2 * math.PI / 4096
	game_d := f64(i32(distance)) + frac[DISTANCE]
	reach := game_d * zoom()
	scale := f64(i32(h)) / max(f64(i32(distance)), 1)
	lens := max(scale * reach, f64(min(H_MIN, i32(h))), 1)
	k := lens / f64(i32(cpu.lw(CAM_H)))
	target := [3]f64 {
		f64(i16(cpu.lhu(CAM_TARGET))) + frac[TARGET],
		f64(i16(height)) + frac[TARGET + 1],
		f64(i16(cpu.lhu(CAM_TARGET + 4))) + frac[TARGET + 2],
	}
	for i in u32(0) ..< 3 {
		target[i] = target[i] / 2 - f64(i16(cpu.lhu(a0 + i * 2)))
	}
	pos := [3]f64{f64(i32(cpu.lw(CAM_POS))) + frac[POS], f64(i32(cpu.lw(CAM_POS + 4))) + frac[POS + 1], reach}
	// RotMatrix: the x turn (pitch) of the y turn (yaw); roll is 0.
	sp, cp := math.sincos(lift(tp.arm, tilt) * turn)
	sy, cy := math.sincos((f64(cpu.lhu(CAMERA_YAW)) + frac[YAW] + yaw_frac) * turn)
	rx := matrix[3, 3]f64{1, 0, 0, 0, cp, -sp, 0, sp, cp}
	ry := matrix[3, 3]f64{cy, 0, sy, 0, 1, 0, -sy, 0, cy}
	r := rx * ry
	q: matrix[3, 3]f64
	tq: [3]f64
	for i in u32(0) ..< 3 {
		for j in u32(0) ..< 3 {
			q[i, j] = f64(i16(cpu.lhu(CAM_MATRIX + (i * 3 + j) * 2))) / 0x1000
		}
		tq[i] = f64(i32(cpu.lw(CAM_TR + i * 4)))
	}
	lens_k := matrix[3, 3]f64{k, 0, 0, 0, k, 0, 0, 0, 1}
	m := lens_k * r * linalg.inverse(q)
	t := lens_k * (pos - r * target) - m * tq
	for i in 0 ..< 3 {
		for j in 0 ..< 3 {
			e.m[i][j] = m[i, j]
		}
		e.t[i] = t[i]
	}
	e.stamp = cpu.vblanks()
}

// The share of an arm of `reach` view units (the camera looking along `yaw`
// radians, tilted `pitch`) that is clear of walls on the leader's layer of the
// grid. The lens takes in more than the line it hangs on: the walk runs on a
// fan of lines from the leader, out to ARM_FAN cells either side at the lens,
// so a wall beside the lens counts as well as one behind it. A wall cell
// stops the arm only where its polygons rise to the arm's height over it: a
// pond or a low fence is a wall to walking, not to the lens passing above.
@(private = "file")
arm_reach :: proc(reach, yaw, pitch: f64) -> f64 {
	pos := u32(leader_obj() + OBJ_POS)
	g, ok := grid_of(cpu.lbu(pos + 12))
	if !ok {
		return 1
	}
	x := f64(i32(cpu.lw(pos))) / 0x10000
	z := f64(i32(cpu.lw(pos + 8))) / 0x10000
	// In cells, back along the ground: direction a points at (sin a, -cos a)
	// in (x, z), and back is yaw + 180.
	length := reach * math.cos((pitch - 0x800) * (2 * math.PI / 4096)) / VIEW_PER_CELL
	ex, ez := -math.sin(yaw) * length, math.cos(yaw) * length
	// Square to the arm, ARM_FAN cells long.
	sx, sz := math.cos(yaw) * ARM_FAN, math.sin(yaw) * ARM_FAN
	steps := max(int(math.ceil(length * ARM_SAMPLES)), 1)
	// Map y is up.
	elevation := (pitch - 0x800) * (2 * math.PI / 4096)
	from := [3]f32{f32(x * VIEW_PER_CELL), f32(f64(i32(cpu.lw(pos + 4))) / 0x10000 * VIEW_PER_CELL + LEADER_MIDDLE), f32(z * VIEW_PER_CELL)}
	rise := f32(reach * math.sin(elevation))
	section := u32(cpu.lbu(MAP_SECTION))
	// The layer's polygons round the arm, gathered once for both walks: out
	// to ARM_FAN cells past it and a cell more, for the cells the fan's
	// samples land in.
	lens := from + {f32(ex * VIEW_PER_CELL), rise, f32(ez * VIEW_PER_CELL)}
	fan_v := f32(ARM_FAN * VIEW_PER_CELL)
	side_v := [3]f32{f32(sx * VIEW_PER_CELL), 0, f32(sz * VIEW_PER_CELL)}
	lo := [2]f32{min(from.x, lens.x), min(from.z, lens.z)} - fan_v - VIEW_PER_CELL
	hi := [2]f32{max(from.x, lens.x), max(from.z, lens.z)} + fan_v + VIEW_PER_CELL
	n := 0
	for l in section ..< section + section_layers(section) {
		n += layer_tris(l, origin(l) - origin(section), lo, hi, arm_tris[n:])
	}
	tris := arm_tris[:n]
	tops := cell_tops(tris, lo, hi)
	share := 1.0
	fan: for side in ([3]f64{0, -1, 1}) {
		for i in 1 ..= steps {
			f := f64(i) / f64(steps)
			px, pz := x + (ex + sx * side) * f, z + (ez + sz * side) * f
			cx, cz := i32(math.floor(px + 0.5)), i32(math.floor(pz + 0.5))
			// Through a doorway the arm hangs over the neighbour's rooms.
			if doorway_cell(cx, cz) {
				if side == 0 {
					return 1
				}
				continue fan
			}
			if attr_at(g, cx, cz) >> 4 == ATTR_WALL && tops_at(tops, tris, cx, cz) > from.y + rise * f32(f) {
				clear := f64(i - 1) / f64(steps) * length - ARM_MARGIN
				share = min(share, max(clear / max(length, 1e-6), ARM_MIN))
				continue fan
			}
		}
	}
	// The grid knows walls only at their foot: a roof or an awning over cells
	// it calls floor stands in the way too. The same walk over the layer's
	// polygons, on lines out to ARM_FAN cells round the lens: either side, and
	// above and below it.
	for off in ([5][3]f32{{}, side_v, -side_v, {0, fan_v, 0}, {0, -fan_v, 0}}) {
		f := f64(segment_hit(from, lens + off, tris))
		if f < 1 {
			share = min(share, max((f * length - ARM_MARGIN) / max(length, 1e-6), ARM_MIN))
		}
	}
	return share
}

// Room for the polygons arm_reach walks over.
@(private = "file")
arm_tris: [8192]Map_Tri

// Cells a side of the grid of heights arm_reach looks wall tops up in: the
// longest arm (CAM_DISTANCE at ZOOM_MAX, some 60 cells) and its fan fit.
@(private = "file")
TOPS_SIDE :: 128

// The highest corner among a set of polygons over each cell of a square of
// cells from `cell` (cell_tops).
@(private = "file")
Cell_Tops :: struct {
	cell: [2]i32,
	side: [2]i32,
	top:  [TOPS_SIDE * TOPS_SIDE]f32,
}

@(private = "file")
arm_tops: Cell_Tops

// The heights of the highest corners among `tris` over the cells round the
// view-unit box lo..hi, binned in one pass over the polygons rather than one
// per wall cell asked about: a town's models give thousands. A corner on the
// edge between cells counts for both, as cell_top counts it.
@(private = "file")
cell_tops :: proc(tris: []Map_Tri, lo, hi: [2]f32) -> ^Cell_Tops {
	t := &arm_tops
	t.cell = {i32(math.floor(lo.x / VIEW_PER_CELL)), i32(math.floor(lo.y / VIEW_PER_CELL))}
	far := [2]i32{i32(math.ceil(hi.x / VIEW_PER_CELL)), i32(math.ceil(hi.y / VIEW_PER_CELL))}
	t.side = {min(far.x - t.cell.x + 1, TOPS_SIDE), min(far.y - t.cell.y + 1, TOPS_SIDE)}
	slice.fill(t.top[:t.side.x * t.side.y], min(f32))
	for tri in tris {
		for v in tri {
			// The cell v rounds into and its neighbours: a corner on an
			// edge between cells belongs to both.
			cx := i32(math.floor(v.x / VIEW_PER_CELL + 0.5))
			cz := i32(math.floor(v.z / VIEW_PER_CELL + 0.5))
			for gz in cz - 1 ..= cz + 1 {
				for gx in cx - 1 ..= cx + 1 {
					i := [2]i32{gx, gz} - t.cell
					if i.x < 0 || i.y < 0 || i.x >= t.side.x || i.y >= t.side.y {
						continue
					}
					c_lo := [2]f32{f32(gx) - 0.5, f32(gz) - 0.5} * VIEW_PER_CELL
					c_hi := c_lo + VIEW_PER_CELL
					if v.x >= c_lo.x && v.x <= c_hi.x && v.z >= c_lo.y && v.z <= c_hi.y {
						k := i.y * t.side.x + i.x
						t.top[k] = max(t.top[k], v.y)
					}
				}
			}
		}
	}
	return t
}

// The height cell_top gives cell cx, cz, from `tops` where it covers the
// cell, else from `tris`.
@(private = "file")
tops_at :: proc(tops: ^Cell_Tops, tris: []Map_Tri, cx, cz: i32) -> f32 {
	i := [2]i32{cx, cz} - tops.cell
	if i.x < 0 || i.y < 0 || i.x >= tops.side.x || i.y >= tops.side.y {
		return cell_top(tris, cx, cz)
	}
	return tops.top[i.y * tops.side.x + i.x]
}

// The height (view units, map y up) of the highest corner among `tris` over
// cell cx, cz; the lowest f32 over a cell with none.
@(private = "file")
cell_top :: proc(tris: []Map_Tri, cx, cz: i32) -> f32 {
	lo := [2]f32{f32(cx) - 0.5, f32(cz) - 0.5} * VIEW_PER_CELL
	hi := lo + VIEW_PER_CELL
	top := min(f32)
	for t in tris {
		for v in t {
			if v.x >= lo.x && v.x <= hi.x && v.z >= lo.y && v.z <= hi.y {
				top = max(top, v.y)
			}
		}
	}
	return top
}

// The pitch that brings the lens in over the ground to tp.arm of its reach at
// `tilt`, keeping the arm's length: the arm swings up, at most to BOOM_MAX.
@(private = "file")
boom :: proc(tilt: u32) -> u32 {
	return u32(math.round(lift(tp.arm, f64(tilt))))
}

// The pitch, unrounded, that brings the lens in to `arm` of its reach at
// `tilt` (boom).
@(private = "file")
lift :: proc(arm, tilt: f64) -> f64 {
	if arm >= 1 {
		return tilt
	}
	angle := (tilt - 0x800) * (2 * math.PI / 4096)
	up := math.acos(clamp(math.cos(angle) * arm, 0, 1)) * (4096 / (2 * math.PI)) + 0x800
	return clamp(up, tilt, max(tilt, BOOM_MAX))
}

// The least arm that lift brings the lens in to: the arm at BOOM_MAX (1 when
// `tilt` is steeper already). The arm stops there (spring): the lens never
// comes in along it, since view_at keeps the leader's size on screen and a
// lens that came in would only widen the view round him, the world swelling
// and shrinking about a leader who stays the same size.
@(private = "file")
boom_top :: proc(tilt: f64) -> f64 {
	turn := 2 * math.PI / 4096
	return math.cos((max(tilt, BOOM_MAX) - 0x800) * turn) / math.cos((tilt - 0x800) * turn)
}

// The arm lift gives the pitch `e` for.
@(private = "file")
arm_of :: proc(e, tilt: f64) -> f64 {
	turn := 2 * math.PI / 4096
	return math.cos((e - 0x800) * turn) / math.cos((tilt - 0x800) * turn)
}

// Move the arm in use toward `want`: in over ARM_IN_S, out over ARM_OUT_S. Just
// after an instant door it comes from the town's arm (door_cover) on a
// spring that starts at rest (DOOR_ARM_W), until it is in: the camera
// stood still at the door, and an ease at its fastest from the first frame
// jolts the picture. The ease runs on the pitch the arm gives (lift), not
// on the arm: a little less arm tips the pitch a lot when the arm is near
// full. The arm stops at BOOM_MAX's (boom_top). It moves only at a game
// frame's first build (`step`), in as well as out: a later build of the
// frame (after the leader moved) that pulled it in would draw the real frame with an arm its in-between pictures never
// blend toward (the pose notes the arm before the drawing), a pitch jump
// every game frame against a wall.
@(private = "file")
spring :: proc(want: f64, tilt: u32, step: bool) {
	top := boom_top(f64(tilt))
	want := max(want, top)
	if door_cover() > 0 && !tp.door_in {
		tp.door_in, tp.lift_v = true, 0
	}
	if !step {
		return
	}
	from, to := lift(max(tp.arm, top), f64(tilt)), lift(want, f64(tilt))
	if math.abs(to - from) < 0.5 {
		tp.arm = want
		tp.door_in, tp.lift_v = false, 0
		return
	}
	e: f64
	if tp.door_in {
		tp.lift_v += (DOOR_ARM_W * DOOR_ARM_W * (to - from) - 2 * DOOR_ARM_W * tp.lift_v) * tp.dt
		e = from + tp.lift_v * tp.dt
	} else {
		// The ease grows as the arm comes in.
		e = from + (to - from) * (1 - math.exp(-tp.dt / (to > from ? ARM_IN_S : ARM_OUT_S)))
	}
	tp.arm = arm_of(e, f64(tilt))
}

// Build the view at distance `d`, keeping the screen scale (H per unit of
// distance) the game's and moving the near limit with the camera.
@(private = "file")
view_at :: proc(d, game_distance, h, near: u32) {
	scale := f64(i32(h)) / max(f64(i32(game_distance)), 1)
	cpu.sw(CAM_DISTANCE, d)
	lens := max(i32(math.round(scale * f64(d))), min(H_MIN, i32(h)), 1)
	kept_write(&tp.h, CAM_H, u32(lens))
	kept_write(&tp.near, CAM_NEAR, u32(max(0, i32(near) + i32(d) - i32(game_distance))))
	tp.view()
}

// Draw a sprite at the geometry's scale for its depth, blended in with the
// camera; its own fields are put back after.
@(private = "file")
sprite_draw :: proc() {
	sprite := cpu.state.r[4]
	if tp.t == 0 || cpu.state.r[31] != SPRITE_LIST_RA {
		lo := cpu.lw(SPRITE_PACKETS)
		flags, color := cpu.lbu(sprite + SPRITE_FLAGS), cpu.lw(sprite + SPRITE_COLOR)
		same := flags == tp.copy_flags && color == tp.copy_color
		clear := tp.copy_depth > 0 && same && tp.copy_clear >= 0 ? fade_solid(sprite) : -1
		scaled := cpu.lbu(sprite + SPRITE_SCALED)
		sx, sy := cpu.lw(sprite + SPRITE_SCALE_X), cpu.lw(sprite + SPRITE_SCALE_Y)
		shadow := tp.t > 0 && tp.copy_scale.x != 0 && sprite >= SHADOWS && sprite < SHADOWS_END
		if shadow {
			cpu.sb(sprite + SPRITE_SCALED, 1)
			cpu.sw(sprite + SPRITE_SCALE_X, tp.copy_scale.x)
			cpu.sw(sprite + SPRITE_SCALE_Y, tp.copy_scale.y)
		}
		tp.sprite()
		cpu.sb(sprite + SPRITE_FLAGS, flags)
		cpu.sw(sprite + SPRITE_COLOR, color)
		if shadow {
			cpu.sb(sprite + SPRITE_SCALED, scaled)
			cpu.sw(sprite + SPRITE_SCALE_X, sx)
			cpu.sw(sprite + SPRITE_SCALE_Y, sy)
		}
		scene.see_flat_add(lo, cpu.lw(SPRITE_PACKETS), tp.copy_depth, tp.copy_at, tp.copy_sub, tp.copy_party, max(clear, 0))
		tp.copy_depth, tp.copy_at, tp.copy_sub, tp.copy_clear, tp.copy_scale = 0, {}, {}, -1, {}
		return
	}
	full := view_full(sprite - SPRITE_OBJ + OBJ_POS)
	depth := full[2] >> 12
	scaled := cpu.lbu(sprite + SPRITE_SCALED)
	sx, sy := cpu.lw(sprite + SPRITE_SCALE_X), cpu.lw(sprite + SPRITE_SCALE_Y)
	base := [2]f64{SCALE_ONE, SCALE_ONE}
	if scaled != 0 {
		base = {f64(i32(sx)), f64(i32(sy))}
	}
	// On screen size per unit, against the game's framing at its distance.
	h_game, d_game := f64(i32(tp.h.game)), f64(i32(cpu.lw(CAM_DISTANCE)))
	target := SCALE_ONE * f64(i32(cpu.lw(CAM_H))) * d_game / max(f64(depth) * h_game, 1)
	cpu.sb(sprite + SPRITE_SCALED, 1)
	for b, i in base {
		v := clamp(b + (target - b) * tp.t, 0, SCALE_MAX)
		tp.copy_scale[i] = u32(i32(math.round(v)))
		cpu.sw(sprite + SPRITE_SCALE_X + 4 * u32(i), tp.copy_scale[i])
	}
	obj := sprite - SPRITE_OBJ
	party := obj >= PARTY_OBJ && obj < PARTY_OBJ + PARTY_OBJ_SIZE * PARTY_COUNT
	flags, color := cpu.lbu(sprite + SPRITE_FLAGS), cpu.lw(sprite + SPRITE_COLOR)
	clear := party && obj != leader_obj() ? fade_solid(sprite) : -1
	lo := cpu.lw(SPRITE_PACKETS)
	tp.sprite()
	cpu.sb(sprite + SPRITE_FLAGS, flags)
	cpu.sw(sprite + SPRITE_COLOR, color)
	// People between the lens and the leader fade (render.see_through); the
	// party never does, but a follower fading in (fade_solid). While a
	// door's cover is laid over the room, walking in (the lens still over
	// the town's roof) or out (door_out), the party stays over it, seen
	// through the town's walls. Every sprite takes its anchor's sub-pixel
	// part: the geometry has the exact view's, and a sprite snapped to
	// whole pixels would swim against it.
	anchor := [2]i32{i32(i16(cpu.lhu(sprite + SPRITE_AT))), i32(i16(cpu.lhu(sprite + SPRITE_AT + 2)))}
	tp.copy_depth, tp.copy_party, tp.copy_clear = 0, false, clear
	tp.copy_sub = gte.anchor_sub({f64(full[0]), f64(full[1]), f64(full[2])}, anchor)
	tp.copy_at = {f32(full[0]), f32(full[1]), f32(full[2])} / 4096
	tp.copy_flags, tp.copy_color = flags, color
	if !party || clear >= 0 || door_out() > 0 || door_cover() > 0 {
		tp.copy_depth, tp.copy_party = f32(depth), party
	}
	scene.see_flat_add(lo, cpu.lw(SPRITE_PACKETS), tp.copy_depth, tp.copy_at, tp.copy_sub, tp.copy_party, max(clear, 0))
	cpu.sb(sprite + SPRITE_SCALED, scaled)
	cpu.sw(sprite + SPRITE_SCALE_X, sx)
	cpu.sw(sprite + SPRITE_SCALE_Y, sy)
}

// The game fades a follower in as it steps off the leader (interiors.odin's
// FOLLOWER_FADE): see-through (additive), its colour rising to half the
// ground's light, then solid at the full colour. Before the close camera it
// stands over bright ground, where that glows white and then pops. While
// see-through is on, the sprite is drawn solid at the leader's colour
// instead, faded out by the share its colour has yet to rise; returns that
// share, or -1 for a sprite not fading. The caller puts the sprite's flags
// and colour back after the draw.
@(private = "file")
fade_solid :: proc(sprite: u32) -> f32 {
	flags := cpu.lbu(sprite + SPRITE_FLAGS)
	full := cpu.lw(leader_obj() + SPRITE_OBJ + SPRITE_COLOR)
	half := f32(full & 0xff) / 2
	if !render.see_through.on || flags & SPRITE_SEMI == 0 || half <= 0 {
		return -1
	}
	risen := min(f32(cpu.lbu(sprite + SPRITE_COLOR)) / half, 1)
	cpu.sb(sprite + SPRITE_FLAGS, flags &~ SPRITE_SEMI)
	cpu.sw(sprite + SPRITE_COLOR, full)
	return 1 - risen
}

// The view space position of a position (s32 x, y, z, 16.16), as the GTE
// gives it for the view last built: its MAC (view units << 12).
@(private = "file")
view_full :: proc(pos: u32) -> (v: [3]i64) {
	for r in u32(0) ..< 3 {
		dot: i64
		for i in u32(0) ..< 3 {
			p := i64(i32(cpu.lw(pos + 4 * i)) >> 9)
			dot += i64(i16(cpu.lhu(CAM_MATRIX + 6 * r + 2 * i))) * p
		}
		v[r] = dot + i64(i32(cpu.lw(CAM_TR + 4 * r))) << 12
	}
	return
}

// view_full in view units.
@(private = "file")
view_pos :: proc(pos: u32) -> [3]i64 {
	v := view_full(pos)
	return {v[0] >> 12, v[1] >> 12, v[2] >> 12}
}

@(private = "file")
view_depth :: proc(pos: u32) -> i64 {
	return view_pos(pos)[2]
}

// See through what stands between the camera and the leader
// (render.see_through) for the view just built, once the camera has mostly
// blended in.
@(private = "file")
set_see_through :: proc() {
	feet := view_pos(leader_obj() + OBJ_POS)
	tp.leader_depth = f32(feet.z)
	if tp.t < SEE_FROM {
		render.see_through.on = false
		return
	}
	// World down in view space: the matrix's column 1 (world y) comes out
	// pointing up the screen and toward the lens under the field's camera.
	down: [3]f32
	for r in u32(0) ..< 3 {
		down[r] = -f32(i16(cpu.lhu(CAM_MATRIX + 6 * r + 2))) / 4096
	}
	down = linalg.normalize0(down)
	f := [3]f32{f32(feet.x), f32(feet.y), f32(feet.z)}
	scene.see_through_set(f - down * LEADER_MIDDLE, -down, f.z, LEADER_MIDDLE, cpu.lhu(MAP_ID) & TOWN_MAPS == 0)
	grade_update()
}

// Whether this camera stays: while the player has the leader, and through a
// talk, the field menu and a shop, which leave the leader standing (talk:
// leader state 5, then the event mode with the leader back at 1; the menu:
// state 6). A scene that moves the leader (state 2) hands the view back to
// the game's camera, which it moves.
@(private)
third_person_keeps :: proc() -> bool {
	switch cpu.lhu(GAME_MODE) {
	case MODE_FIELD_ID, MODE_EVENT, MODE_SHOP:
	case:
		return false
	}
	switch cpu.lbu(leader_obj() + OBJ_STATE) {
	case STATE_PLAYER_CONTROL, STATE_IDLE, STATE_TALK, STATE_MENU:
		return true
	}
	return false
}

// Move the blend toward this camera while it stays (third_person_keeps), and
// zoom with L1/R1 while the player has the leader.
@(private = "file")
blend :: proc(field: bool) {
	now := cpu.vblanks()
	dt := min(f64(now - tp.last) / VBLANK_HZ, MAX_DT)
	tp.last = now
	tp.dt = dt
	if !field {
		tp.t = 0
		return
	}
	state := cpu.lbu(leader_obj() + OBJ_STATE)
	active := config.camera_third_person && third_person_keeps()
	control :=
		active && cpu.lhu(GAME_MODE) == MODE_FIELD_ID && (state == STATE_PLAYER_CONTROL || state == STATE_IDLE)
	// Through a doorway to a neighbour section the camera stays as it is.
	held := config.camera_third_person && crossing_walk()
	step := dt / BLEND_S
	tp.t = active || held ? min(tp.t + step, 1) : max(tp.t - step, 0)
	if tp.t == 0 {
		tp.arm = 1
	}
	if control {
		pad := cpu.lhu(leader_obj() + OBJ_PAD)
		if pad & host.PAD_L1 != 0 {
			tp.zoom /= math.pow(ZOOM_PER_S, dt)
		}
		if pad & host.PAD_R1 != 0 {
			tp.zoom *= math.pow(ZOOM_PER_S, dt)
		}
		tp.zoom = clamp(tp.zoom, ZOOM_MIN, ZOOM_MAX)
	}
}

// The share of the game's distance the camera is at: from 1 toward the
// zoom by the blend.
@(private = "file")
zoom :: proc() -> f64 {
	return 1 + (tp.zoom - 1) * tp.t
}

// The camera fields the game reads after the view is built, which this
// camera keeps written over while it is in (Kept).
@(private)
THIRD_PERSON_FIELDS :: 3
@(private = "file")
KEPT_FIELDS :: [THIRD_PERSON_FIELDS]u32{CAM_H, CAM_NEAR, CAM_TILE_RADII}

// The view depth of where the leader stands, in the view last built.
@(private)
third_person_leader_depth :: proc() -> f32 {
	return tp.leader_depth
}

// The game's own values of the kept fields, for a machine noted to go on
// from later (interiors.odin's worlds): RAM holds this camera's while it
// is in, and a world entered with those would hand them to the game as its
// own.
@(private)
third_person_game_fields :: proc() -> (v: [THIRD_PERSON_FIELDS]u32) {
	kept := [THIRD_PERSON_FIELDS]^Kept{&tp.h, &tp.near, &tp.radii}
	for addr, i in KEPT_FIELDS {
		ram := cpu.lw(addr)
		v[i] = ram != kept[i].wrote ? ram : kept[i].game
	}
	return
}

// Put back the game's values of the kept fields (third_person_game_fields).
@(private)
third_person_game_fields_put :: proc(v: [THIRD_PERSON_FIELDS]u32) {
	for addr, i in KEPT_FIELDS {
		cpu.sw(addr, v[i])
	}
}

// The game's current value of a kept field.
@(private = "file")
kept_game :: proc(k: ^Kept, addr: u32) -> u32 {
	if v := cpu.lw(addr); v != k.wrote && !io.events_frozen {
		k.game = v
	}
	return k.game
}

@(private = "file")
kept_write :: proc(k: ^Kept, addr, v: u32) {
	if !io.events_frozen {
		k.wrote = v
	}
	cpu.sw(addr, v)
}

