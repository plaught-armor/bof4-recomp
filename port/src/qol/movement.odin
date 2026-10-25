// Analog movement of the party leader on field maps.
//
// The field walks on a tile grid in eight world directions. Each movement
// step, FLD_MAIN calls SCREEN_DIRECTION(pad, obj), which turns the held d-pad
// bits into a screen direction 0..7 (clockwise from up; stairs may bend it by
// one), and the caller adds the camera's yaw rounded to 45 degrees,
// ((CAMERA_YAW + 0x100) >> 9), to get the world direction. Then
// DASH_HELD(obj) decides the step speed: it returns pad byte obj+0xe6 masked
// with the dash button (DASH_MASK, Circle by default), or 0 where the map
// forbids running.
//
// With `stick`, while the left stick is tilted:
//   - the world direction is the one nearest to the stick's exact angle plus
//     the exact camera yaw, so pushing the stick toward a screen direction
//     walks the nearest grid direction even when the free camera sits between
//     45 degree steps;
//   - tilting at least `run_tilt` runs as if the dash button were held; a
//     lighter tilt walks unless the button is held.
// The d-pad and buttons work as before when the stick is centered.
//
// A standing object waits before its first step: when a direction is held,
// STAND (801d10e0) turns it, sets substate obj+5 = 1 and the turn counter
// obj+8 = 2, and the step handler (801d1298) counts obj+8 down once per game
// frame before it moves. The first step thus starts three game frames after
// the press, so a quick tap only turns in place. Steps that follow while the
// direction stays held do not wait. With `instant_start` the leader's counter
// is cleared, so the step starts on the next game frame.
//
// With the stick walk, the stick's tilt picks walking or running for the
// leader: a full tilt runs, and a lighter one runs only while the dash button
// is held, whatever the game's Dash option (its pad read has already turned
// the button over for Auto, so it is turned back). Maps that forbid running
// still walk.
package qol

import "core:math"

import cpu "ps:psx/cpu"
import host "ps:psx/host"

import "ps:core"

@(private = "file")
SCREEN_DIRECTION :: 0x801d9948
@(private = "file")
STAND :: 0x801d10e0
@(private = "file")
DASH_HELD :: 0x801d930c

@(private = "file")
LEADER_ID :: 0x801172af // u8, id of the controlled object
@(private = "file")
FIELD_OBJ :: 0x80116fb0 // the field objects, FIELD_OBJ_SIZE bytes each
@(private = "file")
FIELD_OBJ_SIZE :: 0xfc
@(private = "file")
DASH_MASK :: 0x80116d8c // u8, pad bits of the dash button
@(private = "file")
OBJ_ID :: 0x1 // u8
@(private = "file")
OBJ_PAD :: 0xe6 // u8, low byte of the object's held pad word
@(private = "file")
OBJ_SUBSTATE :: 0x5 // u8, 0 standing, 1 turning, 2 stepping
@(private = "file")
OBJ_TURN :: 0x8 // u8, game frames left before the first step
@(private = "file")
SUBSTATE_TURNING :: 1
@(private = "file")
DIRECTION_BITS :: 0xf000

@(private = "file")
YAW_PER_DIRECTION :: 0x200 // one of the eight directions, 45 degrees
@(private = "file")
DEGREES_PER_DIRECTION :: 45.0

@(private = "file")
movement: struct {
	screen_direction: cpu.Func_Proc,
	dash_held:        cpu.Func_Proc,
	stand:            cpu.Func_Proc,
}

@(private)
movement_init :: proc() -> bool {
	movement.screen_direction = hook_field(SCREEN_DIRECTION, screen_direction) or_return
	movement.dash_held = hook_field(DASH_HELD, dash_held) or_return
	movement.stand = hook_field(STAND, stand) or_return
	return free_move_init()
}

// The object the player controls, as the field code finds it: the field
// object LEADER_ID counts (object 0 may stand idle).
@(private)
leader_obj :: proc() -> u32 {
	return FIELD_OBJ + u32(cpu.lbu(LEADER_ID)) * FIELD_OBJ_SIZE
}

@(private = "file")
is_leader :: proc(obj: u32) -> bool {
	return cpu.lbu(obj + OBJ_ID) == cpu.lbu(LEADER_ID)
}

// a0 = held pad bits, a1 = object.
@(private = "file")
screen_direction :: proc() {
	c := &cpu.state
	stick := host.sticks().left
	if config.move_stick && stick != {} && c.r[4] & DIRECTION_BITS != 0 && is_leader(c.r[5]) {
		yaw := f64(cpu.lhu(CAMERA_YAW))
		world := int(math.round(host.stick_angle(stick) / DEGREES_PER_DIRECTION + yaw / YAW_PER_DIRECTION))
		screen := (world - int((cpu.lhu(CAMERA_YAW) + 0x100) >> 9)) & 7
		c.r[4] = c.r[4] & ~u32(DIRECTION_BITS) | u32(host.STICK_SECTORS[screen])
		if .Game in core.trace.active {
			core.tracef(.Game, "move: stick %.0f deg, yaw %03x, world %d", host.stick_angle(stick), u32(yaw), world & 7)
		}
	}
	movement.screen_direction()
}

// a0 = object.
@(private = "file")
stand :: proc() {
	obj := cpu.state.r[4]
	if is_leader(obj) {
		free_stand(obj, movement.stand)
		return
	}
	movement.stand()
	if config.move_instant_start && cpu.lbu(obj + OBJ_SUBSTATE) == SUBSTATE_TURNING && cpu.lbu(obj + OBJ_TURN) != 0 && is_leader(obj) {
		cpu.sb(obj + OBJ_TURN, 0)
		if .Game in core.trace.active {
			core.tracef(.Game, "move: instant start")
		}
	}
}

// a0 = object; v0 = nonzero to run.
@(private = "file")
dash_held :: proc() {
	c := &cpu.state
	obj := c.r[4]
	if !is_leader(obj) {
		movement.dash_held()
		return
	}
	stick := host.sticks().left
	tilt := math.sqrt(stick.x * stick.x + stick.y * stick.y)
	pad := cpu.lbu(obj + OBJ_PAD)
	dash := cpu.lbu(DASH_MASK)
	if config.move_stick && tilt != 0 {
		switch {
		case f64(tilt) >= config.move_run_tilt:
			cpu.sb(obj + OBJ_PAD, pad | dash)
		case cpu.lbu(OPTION_DASH_AUTO) != 0:
			// Undo Auto: a light tilt walks unless the button is held.
			cpu.sb(obj + OBJ_PAD, pad ~ dash)
		}
	}
	movement.dash_held()
	cpu.sb(obj + OBJ_PAD, pad)
	if .Game in core.trace.active {
		core.tracef(.Game, "move: tilt %.2f, run %v", tilt, c.r[2] != 0)
	}
}
