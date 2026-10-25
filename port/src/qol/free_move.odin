// Free movement of the party leader on field maps: the leader slides at any
// angle instead of stepping cell to cell.
//
// The field's collision is a grid of attribute bytes, one per cell, per
// layer. An object stands on a cell when its 16.16 position is that cell's
// integer coordinate; a step lerps to a neighbouring cell over a fixed number
// of game frames (8 walking, 4 running). PASSABLE(from, to, flags) decides
// whether a step between two neighbouring cells is allowed: it compares the
// two cells' attributes (walls, one-way ramp edges, blocked tiles), their
// ground heights (at most one unit apart) and, for diagonals, the two cells
// the step cuts across.
//
// The object's substates are run by FLD_MAIN through the table at 0x801e3160:
// 0 STAND (0x801d10e0), 1 CHOOSE_STEP (0x801d1298), 2 STEPPER (0x801d1b30).
// STAND handles talking, examining and menus, then, when a direction is held
// and the field allows control, turns toward it and enters substate 1.
// STEPPER advances the lerp and, once it arrives, runs everything bound to a
// cell: the followers' trail, events and exits under the leader, random
// encounters, then CHOOSE_STEP for the next step.
//
// Each game frame for the leader:
//   - STAND runs with the position rounded to the cell the leader is over, so
//     its checks look where they would on the grid. If it accepts a
//     direction, the step is cancelled and the leader moves continuously
//     toward the stick's exact angle (or the d-pad's) at the grid speed,
//     colliding a square of half-width RADIUS against cells PASSABLE rejects
//     and against NPCs, sliding along both, with the height taken from the
//     ground under it.
//   - Before moving, the exit check CHOOSE_STEP runs on a step's destination
//     (EXIT_CHECK) looks at the neighbours the leader is pushing toward, the
//     held direction and the two beside it, as CHOOSE_STEP tries them,
//     again only when the leader's cell or the held direction changes.
//     Some exits and events fire there, as the step starts, not on arrival
//     (Sarai 0201's door). When it finds one, the leader is put back on its
//     cell and CHOOSE_STEP runs as on the grid, so the engine takes over.
//   - When the leader crosses into another cell, the engine's arrival runs
//     on a one-frame step from the old cell to the new one, so events, exits,
//     encounters and the followers' trail behave as after a grid step. If the
//     arrival hands the leader to the engine (an exit, a scene), it keeps the
//     cell position; otherwise any step it starts is cancelled and the
//     continuous position comes back.
//   - An exit through a door whose room switches in at once (interiors.odin
//     door_exit_at) is left out of both: the leader walks onto its cells,
//     on the ground a cell back from the way through, and passing their
//     middle on the way through switches to the room there (door_through).
//
// NPCs live in their own array (NPC_COUNT entries of NPC_SIZE bytes at
// NPCS); the grid never marks them. CHOOSE_STEP asks the exe's OCCUPANT
// (0x80153690) for the NPC whose box overlaps the step's destination: each
// box is the object's step target (+156) with a half-width and a height in
// cells at +172 and +173, and bit 0 of +174 turns it off. Free mode collides
// the leader's square with each NPC's current position instead, so it stops
// flush against the NPC as it does at a wall, and counts the bump at +197 as
// CHOOSE_STEP does.
package qol

import "core:math"

import "ps:psx"

import "ps:core"

@(private = "file")
STEPPER :: 0x801d1b30
@(private = "file")
STEPPER_RET :: 0x801d1ea8 // after FLD_MAIN's substate dispatch
@(private = "file")
PASSABLE_RET :: 0x801d1584
@(private = "file")
NEXT_POS_RET :: 0x801d1574
@(private = "file")
GROUND_HEIGHT :: 0x8014a8a0 // (pos, layer) -> height under x/z
@(private = "file")
GROUND_HEIGHT_RET :: 0x801d1c50
@(private = "file")
STOP_MOTION :: 0x801541cc // (pos) clears the lerp's velocity
@(private = "file")
STOP_MOTION_RET :: 0x801d1d8c
@(private = "file")
EXIT_CHECK :: 0x801d5828 // (pos, direction, 0, out u8) -> out 0xff when nothing
@(private = "file")
EXIT_CHECK_RET :: 0x801d1458
@(private = "file")
STEP_TRIES :: 0x801e315c // u8 x3, direction offsets CHOOSE_STEP tries in turn
@(private = "file")
DASH_HELD :: 0x801d930c
@(private = "file")
DASH_HELD_RET :: 0x801d179c

@(private = "file")
DIRECTION_DELTA :: 0x80174944 // s8 (dz, dx) per world direction 0..7

@(private = "file")
NPC_BUMPS :: 0xc5 // u8, steps into this NPC CHOOSE_STEP turned away

@(private = "file")
OBJ_FLAGS_BYTE :: 0x2 // u8, PASSABLE's flags
@(private = "file")
OBJ_STATE :: 0x4 // u8, which program drives the object
@(private = "file")
OBJ_SUBSTATE :: 0x5 // u8
@(private = "file")
OBJ_TURN :: 0x8 // u8
@(private = "file")
OBJ_POS :: 0xc
@(private = "file")
OBJ_DIRECTION :: 0x4c // u8, world direction faced
@(private = "file")
OBJ_GAIT :: 0x4f // u8, index into the step frame table: 3 walk, 4 run
@(private = "file")
OBJ_TARGET :: 0x9c // pos the current step ends on
@(private = "file")
OBJ_BOX_WIDTH :: 0xac // u8, half-width in cells beyond the object's own
@(private = "file")
OBJ_BOX_HEIGHT :: 0xad // u8, height in cells beyond the object's own
@(private = "file")
OBJ_BOX_FLAGS :: 0xae // u8, bit 0: collides with nothing
@(private = "file")
OBJ_STEP_DIRECTION :: 0xd6 // u8
@(private = "file")
OBJ_PAD :: 0xe6 // u16, held pad bits
@(private = "file")
OBJ_GAIT_ANIM :: 0xfa // u8, 1 walk, 2 run, 3 stop (the next frame idles)

// Position: s32 16.16 x, y (height), z, then the layer byte; the lerp's
// velocity (s16 x, y, z) at +48 and frames left at +66.
@(private = "file")
POS_X :: 0x0
@(private = "file")
POS_Y :: 0x4
@(private = "file")
POS_Z :: 0x8
@(private = "file")
POS_LAYER :: 0xc
@(private = "file")
POS_SIZE :: 0x10
@(private = "file")
POS_FRAMES :: 0x42

@(private = "file")
SUBSTATE_STAND :: 0
@(private = "file")
SUBSTATE_CHOOSE :: 1
@(private = "file")
SUBSTATE_STEP :: 2
@(private = "file")
GAIT_WALK :: 3
@(private = "file")
GAIT_RUN :: 4
@(private = "file")
ANIM_WALK :: 1
@(private = "file")
ANIM_RUN :: 2
@(private = "file")
ANIM_STOP :: 3
@(private = "file")
DIRECTION_BITS :: 0xf000

@(private = "file")
CELL :: 0x10000
@(private = "file")
HALF_CELL :: 0x8000
// Half-width of the leader's collision square, and the smaller half-width
// used across the direction of travel so sliding along a wall does not catch
// on the cells beside it.
@(private = "file")
RADIUS :: 0x5000
@(private = "file")
RADIUS_SIDE :: 0x4000
// Half-width of an NPC's square (with no extra width).
@(private = "file")
NPC_RADIUS :: 0x4000
// Distance per game frame, as the grid steps cover it.
@(private = "file")
SPEED_WALK :: 0x2000
@(private = "file")
SPEED_RUN :: 0x4000
@(private = "file")
DEGREES_PER_YAW :: 360.0 / 4096

// Scratch frame on the emulated stack for the position structures the game
// functions take: the callee's argument save area, then two of them.
@(private = "file")
SCRATCH_FRAME :: 0x60
@(private = "file")
SCRATCH_A :: 0x10
@(private = "file")
SCRATCH_B :: 0x30
@(private = "file")
SCRATCH_OUT :: 0x50

@(private = "file")
free: struct {
	moving: bool,
	// The last exit check: cell origin x, z and held direction, and whether
	// a step there was bound. The check reruns only when these change.
	checked: bool,
	check:   [3]i32,
	bound:   bool,
	exit_check: psx.Func_Proc, // the game's EXIT_CHECK
}

@(private)
free_move_init :: proc() -> bool {
	free.exit_check = hook_field(EXIT_CHECK, exit_check) or_return
	return true
}

// a0 = destination pos, a3 = out. A door's exit cells (door_exit_at) hold
// nothing here, wherever the check runs (CHOOSE_STEP, a step's arrival):
// the leader walks onto them and door_through switches instead.
@(private = "file")
exit_check :: proc() {
	c := &psx.cpu
	pos := c.r[4]
	if _, _, through := door_exit_at(cell_of(i32(psx.lw(pos + POS_X))), cell_of(i32(psx.lw(pos + POS_Z)))); through {
		psx.sb(c.r[7], 0xff)
		c.r[2] = 0
		return
	}
	free.exit_check()
}

@(private = "file")
Cell :: [2]i32 // x, z

// Runs STAND for the leader in free mode; `stand` is the original.
@(private)
free_stand :: proc(obj: u32, stand: psx.Func_Proc) {
	pos := obj + OBJ_POS
	x, z := i32(psx.lw(pos + POS_X)), i32(psx.lw(pos + POS_Z))
	set_xz(pos, cell_origin(x), cell_origin(z))
	stand()
	set_xz(pos, x, z)
	if psx.lbu(obj + OBJ_SUBSTATE) != SUBSTATE_CHOOSE {
		free.checked = false
		if free.moving {
			free.moving = false
			psx.sb(obj + OBJ_GAIT_ANIM, ANIM_STOP)
		}
		return
	}
	degrees, ok := held_angle(obj)
	if !ok {
		free.checked = false
	}
	if ok && steps_bound_cached(obj, x, z, u32(i32(math.round(degrees / 45))) & 7) {
		// The engine takes the step from the cell, as on the grid.
		set_xz(pos, cell_origin(x), cell_origin(z))
		free.moving = false
		return
	}
	psx.sb(obj + OBJ_SUBSTATE, SUBSTATE_STAND)
	psx.sb(obj + OBJ_TURN, 0)
	if !ok {
		return
	}
	move(obj, degrees)
}

// World angle the leader is pushed toward, clockwise from the direction
// DIRECTION_DELTA calls 0 (-z), in degrees.
@(private = "file")
held_angle :: proc(obj: u32) -> (degrees: f64, ok: bool) {
	yaw := f64(psx.lhu(CAMERA_YAW)) * DEGREES_PER_YAW
	if stick := psx.sticks().left; config.move_stick && stick != {} {
		return psx.stick_angle(stick) + yaw, true
	}
	bits := u16(psx.lhu(obj + OBJ_PAD) & DIRECTION_BITS)
	for sector, i in psx.STICK_SECTORS {
		if sector == bits {
			return f64(i) * 45 + yaw, true
		}
	}
	return 0, false
}

@(private = "file")
move :: proc(obj: u32, degrees: f64) {
	c := &psx.cpu
	ra, sp := c.r[31], c.r[29]
	defer c.r[29], c.r[31] = sp, ra

	pos := obj + OBJ_POS
	c.r[4] = obj
	game_call(DASH_HELD, DASH_HELD_RET)
	run := c.r[2] & 0xff != 0
	speed := f64(run ? SPEED_RUN : SPEED_WALK)
	angle := math.to_radians(degrees)
	vx := i32(math.round(math.sin(angle) * speed))
	vz := i32(math.round(-math.cos(angle) * speed))

	x, z := i32(psx.lw(pos + POS_X)), i32(psx.lw(pos + POS_Z))
	from := Cell{cell_of(x), cell_of(z)}
	x, z = slide(obj, x, z, vx, true)
	z, x = slide(obj, z, x, vz, false)
	set_xz(pos, x, z)
	set_height(pos)

	direction := u32(i32(math.round(degrees / 45))) & 7
	psx.sb(obj + OBJ_DIRECTION, direction)
	psx.sb(obj + OBJ_STEP_DIRECTION, direction)
	psx.sb(obj + OBJ_GAIT, run ? GAIT_RUN : GAIT_WALK)
	psx.sb(obj + OBJ_GAIT_ANIM, run ? ANIM_RUN : ANIM_WALK)
	free.moving = true

	to := Cell{cell_of(x), cell_of(z)}
	p, way, through := door_exit_at(to.x, to.y)
	if to != from && !through {
		arrive(obj, from, to, x, z)
	}
	// Past the middle of a door's exit cells on the way through, the room
	// takes over with the party where it stands (interiors.odin).
	past := f32(x - to.x * CELL) * way.x + f32(z - to.y * CELL) * way.y
	if through && past > 0 && f32(vx) * way.x + f32(vz) * way.y > 0 {
		free.checked = false
		door_through(p)
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "free: %.0f deg, v %d,%d, pos %x,%x, cell %d,%d", degrees, vx, vz, x, z, to.x, to.y)
	}
}

// Moves one axis by v (x when `along_x`, else z), stopping flush against
// the first cell PASSABLE rejects on the leading edge of the square. `along`
// is the coordinate on that axis, `across` the other one; the second result
// is `across` again, or nudged toward its cell's middle when only the corner
// of a wall beside the way ahead stops the square (an off-centre walk into a
// doorway), so the leader slips past the corner as on the grid.
@(private = "file")
slide :: proc(obj: u32, along, across, v: i32, along_x: bool) -> (i32, i32) {
	if v == 0 {
		return along, across
	}
	sign := v > 0 ? i32(1) : -1
	here := cell_of(along)
	center := cell_of(across)
	to := along + v
	to = npc_clamp(obj, along, across, to, along_x)
	edge := cell_of(to + sign * RADIUS)
	if edge == here {
		return to, across
	}
	from := along_x ? Cell{here, center} : Cell{center, here}
	for offset in ([2]i32{-RADIUS_SIDE, RADIUS_SIDE}) {
		side := cell_of(across + offset)
		dest := along_x ? Cell{edge, side} : Cell{side, edge}
		if !passable(obj, from, dest) {
			// Stop with the leading edge just inside the current cell.
			limit := cell_origin(along) + sign * (HALF_CELL - RADIUS - 1)
			stop := sign > 0 ? max(along, min(to, limit)) : min(along, max(to, limit))
			ahead := along_x ? Cell{edge, center} : Cell{center, edge}
			if side == center || !passable(obj, from, ahead) {
				return stop, across
			}
			middle := cell_origin(across)
			return stop, across + clamp(middle - across, -abs(v), abs(v))
		}
	}
	return to, across
}

// Shortens a move along one axis from `along` to `to` so the leader's square
// stops flush against the first NPC square in the way. A move away from an
// NPC the leader already overlaps is left alone, so it can always get free.
@(private = "file")
npc_clamp :: proc(obj: u32, along, across, to: i32, along_x: bool) -> i32 {
	if psx.lbu(obj + OBJ_BOX_FLAGS) & 1 != 0 {
		return to
	}
	pos := obj + OBJ_POS
	y := i32(psx.lw(pos + POS_Y))
	width := i32(psx.lbu(obj + OBJ_BOX_WIDTH))
	height := i32(psx.lbu(obj + OBJ_BOX_HEIGHT))
	along_at, across_at := u32(POS_Z), u32(POS_X)
	if along_x {
		along_at, across_at = POS_X, POS_Z
	}
	result := to
	for i in u32(0) ..< NPC_COUNT {
		npc := NPCS + i * NPC_SIZE
		if psx.lbu(npc) == 0 || psx.lbu(npc + OBJ_BOX_FLAGS) & 1 != 0 {
			continue
		}
		npc_pos := npc + OBJ_POS
		reach := (height + i32(psx.lbu(npc + OBJ_BOX_HEIGHT)) + 1) * CELL
		if abs(i32(psx.lw(npc_pos + POS_Y)) - y) > reach {
			continue
		}
		extent := RADIUS + NPC_RADIUS + (width + i32(psx.lbu(npc + OBJ_BOX_WIDTH))) * CELL
		if abs(i32(psx.lw(npc_pos + across_at)) - across) >= extent {
			continue
		}
		at := i32(psx.lw(npc_pos + along_at))
		clamped := result
		if to > along && along < at {
			clamped = min(result, max(along, at - extent))
		} else if to < along && along > at {
			clamped = max(result, min(along, at + extent))
		}
		if clamped != result {
			result = clamped
			psx.sb(npc + NPC_BUMPS, psx.lbu(npc + NPC_BUMPS) + 1)
		}
	}
	return result
}

// True when PASSABLE allows a step between two cells, the second one either
// the same or a neighbour of the first.
@(private = "file")
passable :: proc(obj: u32, from, to: Cell) -> bool {
	if from == to {
		return true
	}
	c := &psx.cpu
	c.r[29] -= SCRATCH_FRAME
	defer c.r[29] += SCRATCH_FRAME
	a := c.r[29] + SCRATCH_A
	b := c.r[29] + SCRATCH_B
	pos := obj + OBJ_POS
	copy_pos(a, pos)
	set_xz(a, from.x * CELL, from.y * CELL)
	c.r[4], c.r[5], c.r[6], c.r[7] = a, b, direction_of(to - from), 0
	game_call(NEXT_POS, NEXT_POS_RET)
	c.r[4], c.r[5], c.r[6] = a, b, psx.lbu(obj + OBJ_FLAGS_BYTE)
	game_call(PASSABLE, PASSABLE_RET)
	return c.r[2] & 0xff != 0
}

// steps_bound, rerun only when the leader's cell or the held direction
// changes (or after letting go or leaving CHOOSE), not every frame.
@(private = "file")
steps_bound_cached :: proc(obj: u32, x, z: i32, direction: u32) -> bool {
	key := [3]i32{cell_origin(x), cell_origin(z), i32(direction)}
	if !free.checked || free.check != key {
		free.checked, free.check = true, key
		free.bound = steps_bound(obj, direction)
	}
	return free.bound
}

// True when a step CHOOSE_STEP would try for the held `direction` runs into
// an exit or event that fires as the step starts.
@(private = "file")
steps_bound :: proc(obj, direction: u32) -> bool {
	for i in u32(0) ..< 3 {
		if step_bound(obj, (direction + psx.lbu(STEP_TRIES + i)) & 7) {
			return true
		}
	}
	return false
}

// True when CHOOSE_STEP's exit check finds an exit or event that fires as a
// step from the leader's cell toward `direction` starts. Results 2, 3 and 4
// CHOOSE_STEP passes over like an empty cell.
@(private = "file")
step_bound :: proc(obj, direction: u32) -> bool {
	c := &psx.cpu
	ra := c.r[31]
	c.r[29] -= SCRATCH_FRAME
	defer c.r[29], c.r[31] = c.r[29] + SCRATCH_FRAME, ra
	a := c.r[29] + SCRATCH_A
	b := c.r[29] + SCRATCH_B
	out := c.r[29] + SCRATCH_OUT
	pos := obj + OBJ_POS
	copy_pos(a, pos)
	set_xz(a, cell_origin(i32(psx.lw(pos + POS_X))), cell_origin(i32(psx.lw(pos + POS_Z))))
	c.r[4], c.r[5], c.r[6], c.r[7] = a, b, direction, 0
	game_call(NEXT_POS, NEXT_POS_RET)
	psx.sb(out, 0xff)
	c.r[4], c.r[5], c.r[6], c.r[7] = b, direction, 0, out
	game_call(EXIT_CHECK, EXIT_CHECK_RET)
	switch psx.lbu(out) {
	case 0xff, 2, 3, 4:
		return false
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "free: step %d bound (result %d)", direction, psx.lbu(out))
	}
	return true
}

// Runs the engine's arrival on a one-frame step from `from` to `to`, then
// returns to the continuous position x, z unless the engine took the leader.
@(private = "file")
arrive :: proc(obj: u32, from, to: Cell, x, z: i32) {
	c := &psx.cpu
	pos := obj + OBJ_POS
	direction := direction_of(to - from)
	set_xz(pos, from.x * CELL, from.y * CELL)
	c.r[4], c.r[5], c.r[6], c.r[7] = pos, obj + OBJ_TARGET, direction, 0
	game_call(NEXT_POS, NEXT_POS_RET)
	for i in u32(0) ..< 3 {
		psx.sw(pos + 4 * i, psx.lw(obj + OBJ_TARGET + 4 * i))
	}
	c.r[4] = pos
	game_call(STOP_MOTION, STOP_MOTION_RET)
	psx.sb(pos + POS_FRAMES, 1)
	psx.sb(obj + OBJ_STEP_DIRECTION, direction)
	psx.sb(obj + OBJ_SUBSTATE, SUBSTATE_STEP)

	state := psx.lbu(obj + OBJ_STATE)
	c.r[4] = obj
	game_call(STEPPER, STEPPER_RET)
	substate := psx.lbu(obj + OBJ_SUBSTATE)
	if psx.lbu(obj + OBJ_STATE) != state || substate > SUBSTATE_STEP {
		free.moving = false
		if .Game in core.trace.active {
			core.tracef(.Game, "free: arrival at %d,%d handed over (state %x, substate %d)", to.x, to.y, psx.lbu(obj + OBJ_STATE), substate)
		}
		return
	}
	c.r[4] = pos
	game_call(STOP_MOTION, STOP_MOTION_RET)
	psx.sb(pos + POS_FRAMES, 0)
	psx.sb(obj + OBJ_SUBSTATE, SUBSTATE_STAND)
	set_xz(pos, x, z)
	set_height(pos)
}

// The ground's height under pos. On a door's exit cells (door_exit_at),
// the cell's own may lie past the floor (a room's reads a wall's top): then
// the height is the one a cell back from the way through. A cell's own
// within a step (STEP_RISE) of that one is kept: 0204.1's stairs climb a
// whole step on the exit cell, and the cell back is the floor at their
// foot, which stood the leader at the top of the stairs sunk into them.
@(private = "file")
set_height :: proc(pos: u32) {
	x, z := i32(psx.lw(pos + POS_X)), i32(psx.lw(pos + POS_Z))
	y := ground_height(pos)
	if _, way, through := door_exit_at(cell_of(x), cell_of(z)); through {
		set_xz(pos, x - i32(way.x) * CELL, z - i32(way.y) * CELL)
		back := ground_height(pos)
		set_xz(pos, x, z)
		if abs(y - back) > STEP_RISE {
			y = back
		}
	}
	psx.sw(pos + POS_Y, u32(y))
}

// The most two neighbouring cells' ground may differ by for a step between
// them (PASSABLE), 16.16.
@(private = "file")
STEP_RISE :: 0x10000

@(private = "file")
ground_height :: proc(pos: u32) -> i32 {
	c := &psx.cpu
	c.r[4], c.r[5] = pos, psx.lbu(pos + POS_LAYER)
	game_call(GROUND_HEIGHT, GROUND_HEIGHT_RET)
	return i32(c.r[2])
}

// World direction 0..7 of a neighbour offset, from DIRECTION_DELTA.
@(private = "file")
direction_of :: proc(d: Cell) -> u32 {
	for i in u32(0) ..< 8 {
		dz := i32(i8(psx.lbu(DIRECTION_DELTA + 2 * i)))
		dx := i32(i8(psx.lbu(DIRECTION_DELTA + 2 * i + 1)))
		if dx == d.x && dz == d.y {
			return i
		}
	}
	return 0
}

@(private = "file")
cell_of :: proc(v: i32) -> i32 {
	return (v + HALF_CELL) >> 16
}

@(private = "file")
cell_origin :: proc(v: i32) -> i32 {
	return cell_of(v) * CELL
}

@(private = "file")
set_xz :: proc(pos: u32, x, z: i32) {
	psx.sw(pos + POS_X, u32(x))
	psx.sw(pos + POS_Z, u32(z))
}

@(private = "file")
copy_pos :: proc(dst, src: u32) {
	for i: u32 = 0; i < POS_SIZE; i += 4 {
		psx.sw(dst + i, psx.lw(src + i))
	}
}
