// Field camera rotation.
//
// L1/R1 on a field map (FLD_MAIN 0x801d94e8) stores a direction in
// ROTATE_SIGN and requests game mode 6, whose handler (GAME.EMI 0x8018ec24,
// once per game tick) runs three phases kept in MODE_PHASE:
//
//   0  turn : while ROTATE_LEFT counts down from ROTATE_TICKS, add
//             sign * ROTATE_CURVE[ROTATE_TICKS - left] to CAMERA_YAW; the
//             curve eases out and sums to 90 degrees. Maps whose rotation
//             flags forbid the turn clear ROTATE_LEFT first.
//   1  hold : while the button stays held, d-pad left/right peeks up to
//             +-0x180 off the turn in PEEK_OFFSET.
//   2  back : the peek returns to zero, then the game goes back to mode 2.
//
// `rotate_speed` lets the turn consume several curve steps per tick, using
// the same curve, so the turn keeps its shape and its 90 degree total.
// `hold_to_spin` starts another turn after the button has been held in the
// hold phase for SPIN_DELAY ticks without peeking. Both count game ticks
// only, so they behave the same at any presentation rate.
//
// `stick` turns the camera with the right stick's x axis while the field runs
// (mode 2, handler 0x8018e068), on maps whose rotation flags allow any angle
// (MAP_FREE_ROTATION), or on every map with `stick_all_maps`; maps limited to
// fixed angles may show unfinished scenery from other sides, and an L1/R1
// turn there starts from wherever the stick left the camera. With
// `third_person` every map turns freely (third_person.odin); the camera
// only turns, it does not tilt. The turn rate is in
// degrees per second of emulated time, measured in vblanks, so it does not
// depend on the tick or frame rate.
//
// `mouse` turns it by dragging with the right mouse button: freely, at
// mouse_speed degrees per window pixel, where the stick may turn, and
// elsewhere by tapping L1/R1 once per DRAG_TURN_PX of drag, so every map
// turns with the mouse. Drag taken outside the field is dropped.
//
// The field's top-left compass and rotate icon are not drawn: their task
// (FLD_MAIN 0x801ce370) slides them in and out and draws them only while
// HUD_SHOWN is set, so it runs with the flag cleared.
package qol

import "core:fmt"
import "core:math"

import "../psx"

import "ps:core"

@(private = "file")
GAME_ID :: 0x0e
@(private = "file")
MODE_ROTATE :: 0x8018ec24
@(private)
MODE_FIELD :: 0x8018e068 // GAME.EMI handler of the field game modes
@(private = "file")
COMPASS_TASK :: 0x801ce370 // FLD_MAIN
@(private = "file")
HUD_SHOWN :: 0x80116fac // u8

// Rotation flags of the current map: byte MAP_SECTION * 3 into the table at
// [[MAP_HEADER] + 0x30]. 0xff allows any angle; other values pick fixed ones.
@(private = "file")
MAP_HEADER :: 0x80116be8 // u32 pointer
@(private = "file")
MAP_FREE_ROTATION :: 0xff

// Emulated vblanks per second (NTSC) and the longest gap between field ticks
// still treated as continuous turning.
@(private = "file")
VBLANK_HZ :: 60
@(private = "file")
MAX_STICK_GAP :: 4

// Mouse drag, in window pixels, that turns a fixed-angle map by one step.
@(private = "file")
DRAG_TURN_PX :: 80

@(private = "file")
MODE_PHASE :: 0x80114852 // u16
@(private = "file")
PEEK_OFFSET :: 0x80114860 // s16
@(private = "file")
ROTATE_LEFT :: 0x80114871 // u8, curve steps left in the turn
@(private = "file")
ROTATE_SIGN :: 0x80114872 // s8, +1 or -1
@(private = "file")
YAW_PER_DEGREE :: 4096.0 / 360
@(private = "file")
MODE_FIELD_ID :: 2
@(private = "file")
ROTATE_CURVE :: 0x80199c48 // u16[ROTATE_TICKS]
@(private = "file")
ROTATE_TICKS :: 0x19

@(private = "file")
PAD_ROTATE_HELD :: 0x80116d36 // u16, the pad word the hold phase reads
@(private = "file")
ROTATE_MASK_A :: 0x80116d8e // u16
@(private = "file")
ROTATE_MASK_B :: 0x80116d90 // u16
@(private = "file")
PEEK_BUTTONS :: psx.PAD_LEFT | psx.PAD_RIGHT

@(private = "file")
SPIN_DELAY :: 12

@(private = "file")
Phase :: enum u16 {
	Turn = 0,
	Hold = 1,
	Back = 2,
}

@(private = "file")
camera: struct {
	original:  psx.Func_Proc,
	// Fractional curve steps carried between ticks.
	carry:     f64,
	// Ticks spent in the hold phase without peeking.
	held_for:  int,
	field:     psx.Func_Proc,
	compass:   psx.Func_Proc,
	// Vblank of the last field tick.
	last_tick: u64,
	// Mouse drag (window pixels) toward the next fixed-angle turn.
	drag_px:   f64,
}

@(private)
camera_init :: proc() -> bool {
	camera.original = hook_game_mode(MODE_ROTATE, camera_tick) or_return
	camera.field = hook_game_mode(MODE_FIELD, field_tick) or_return
	camera.compass = hook_field(COMPASS_TASK, compass_task) or_return
	backdrop_init()
	return third_person_init()
}

@(private)
hook_game_mode :: proc(addr: u32, fn: psx.Func_Proc) -> (psx.Func_Proc, bool) {
	original, ok := psx.hook_overlay(addr, SLOT_GAME, GAME_ID, fn)
	if !ok {
		fmt.eprintf("qol: game mode handler %08x not found\n", addr)
	}
	return original, ok
}

@(private = "file")
compass_task :: proc() {
	shown := psx.lbu(HUD_SHOWN)
	psx.sb(HUD_SHOWN, 0)
	camera.compass()
	psx.sb(HUD_SHOWN, shown)
}

@(private = "file")
field_tick :: proc() {
	camera.field()
	now := psx.vblanks()
	gap := now - camera.last_tick
	camera.last_tick = now
	mouse := psx.mouse_drag_take()
	degrees, drag := 0.0, f64(mouse.x)
	if config.camera_stick {
		degrees = f64(psx.sticks().right.x) * config.camera_stick_speed * f64(gap) / VBLANK_HZ
	}
	if psx.lbu(OPTION_CAMERA_REVERSE) != 0 {
		degrees, drag = -degrees, -drag
	}
	turning := psx.lhu(GAME_MODE) == MODE_FIELD_ID || config.camera_third_person && third_person_keeps()
	if gap > MAX_STICK_GAP || !turning {
		camera.drag_px = 0
		return
	}
	free := config.camera_stick_all_maps || config.camera_third_person
	if rotation := map_rotation(); rotation != MAP_FREE_ROTATION && !free {
		if degrees != 0 && .Game in core.trace.active {
			core.tracef(.Game, "camera: map rotation %02x, stick ignored", rotation)
		}
		drag_turn(drag)
		return
	}
	degrees += drag * config.camera_mouse_speed
	if degrees == 0 {
		third_person_follow(gap, false)
		return
	}
	third_person_follow(gap, true)
	yaw := yaw_turn(degrees * YAW_PER_DEGREE)
	if .Game in core.trace.active {
		core.tracef(.Game, "camera: free turn %.2f degrees, yaw %03x", degrees, yaw)
	}
}

// On a map limited to fixed angles, a drag of DRAG_TURN_PX taps L1 (right,
// turning the same way as free yaw) or R1 for one of the game's own turns.
@(private = "file")
drag_turn :: proc(drag: f64) {
	camera.drag_px += drag
	if abs(camera.drag_px) < DRAG_TURN_PX {
		return
	}
	button := u16(camera.drag_px > 0 ? psx.PAD_L1 : psx.PAD_R1)
	psx.press_for(button, psx.TAP_HOLD)
	camera.drag_px = 0
	if .Game in core.trace.active {
		core.tracef(.Game, "camera: drag turn %s", button == psx.PAD_L1 ? "L1" : "R1")
	}
}

@(private = "file")
map_rotation :: proc() -> u32 {
	table := psx.lw(psx.lw(MAP_HEADER) + 0x30)
	return psx.lbu(table + psx.lhu(MAP_SECTION) * 3)
}

@(private = "file")
camera_tick :: proc() {
	phase := Phase(psx.lhu(MODE_PHASE))
	if phase == .Hold && config.camera_hold_to_spin && spin_due() {
		psx.sb(ROTATE_LEFT, ROTATE_TICKS)
		psx.sh(MODE_PHASE, u32(Phase.Turn))
		phase = .Turn
		if .Game in core.trace.active {
			core.tracef(.Game, "camera: spin again, sign %d", i8(psx.lbu(ROTATE_SIGN)))
		}
	}
	camera.original()
	if phase == .Turn {
		turn_extra_steps()
		if .Game in core.trace.active {
			core.tracef(.Game, "camera: yaw %03x, %d steps left", psx.lhu(CAMERA_YAW), psx.lbu(ROTATE_LEFT))
		}
	}
}

// True once the rotate button has been held in the hold phase, without a
// peek, for SPIN_DELAY ticks.
@(private = "file")
spin_due :: proc() -> bool {
	held := psx.lhu(PAD_ROTATE_HELD)
	rotate_held := held & (psx.lhu(ROTATE_MASK_A) | psx.lhu(ROTATE_MASK_B)) != 0
	if !rotate_held || held & PEEK_BUTTONS != 0 || psx.lhu(PEEK_OFFSET) != 0 {
		camera.held_for = 0
		return false
	}
	camera.held_for += 1
	if camera.held_for < SPIN_DELAY {
		return false
	}
	camera.held_for = 0
	return true
}

// The original tick consumed one curve step; consume the rest of this tick's
// share at the configured speed.
@(private = "file")
turn_extra_steps :: proc() {
	camera.carry += config.camera_rotate_speed - 1
	extra := int(math.floor(camera.carry))
	camera.carry -= f64(extra)
	sign := u32(i32(i8(psx.lbu(ROTATE_SIGN))))
	for _ in 0 ..< extra {
		left := psx.lbu(ROTATE_LEFT)
		if left == 0 {
			camera.carry = 0
			return
		}
		step := psx.lhu(ROTATE_CURVE + (ROTATE_TICKS - left) * 2)
		yaw := psx.lhu(CAMERA_YAW) + sign * step
		psx.sh(CAMERA_YAW, yaw & 0xfff)
		psx.sb(ROTATE_LEFT, left - 1)
	}
}
