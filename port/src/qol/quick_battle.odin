// Quick battle turns and quick idle: fewer game frames between actions.
//
// Both cut the dead time of a battle by running fewer game frames, never by
// speeding up the clock, so every animation on screen keeps its pace.
//
// Quick turns: the bookkeeping steps the battle runs between one actor's
// action and the next each take a game frame or a few, during which nothing
// moves on screen but idle sprites. The battle's per-frame entry dispatches
// the current phase handler once per game frame; the hooks below run the
// handler again in the same frame while it only stepped through bookkeeping
// (its state changed and is not an actor's action), so a chain of one-frame
// steps passes in one frame. A step that holds (a message on screen, a
// status effect playing, an actor's action) leaves the state unchanged and
// stops the chain there, so it plays out in full. The fixed countdown after
// the last command is chosen runs out in one frame the same way.
//
// Quick idle: once every combatant is back in its resting loop, no
// transient effect is running, the camera holds still and no window has
// opened since the commands were chosen, the round only waits for the last
// damage number to finish settling (the popup pool tick holds a battle flag
// while any popup lives). popup.odin then finishes the number's animation at
// once instead of drawing the rest of its settle. A number's first bounce,
// where it is read, is never cut.
package qol

import "core:fmt"

import "../psx"

@(private = "file")
ROUND_ID :: 0x34

// Phase handlers, from the battle's phase table at 0x801c5e30.
@(private = "file")
PREP_PHASE :: 0x801ab298 // phase 2: countdown, then the round's data loads
@(private = "file")
ROUND_PHASE :: 0x801ccbe0 // phase 3: the round


// Phase 2 sub-phase 0 (0x801ab2d8): a fixed 8-frame countdown after the last
// command is chosen, with the menu already gone, before the round's data
// loads.
@(private = "file")
PHASE_COUNTDOWN :: 2

// Phase 3 (overlay at 0x801cc800, sub-phase table 0x801e4dcc): the round.
// Sub-phase 3 runs an actor's action script; the others are bookkeeping
// between actions (queue messages, pick the next actor, apply results,
// counters, status effects, round end).
@(private = "file")
PHASE_ROUND :: 3
@(private = "file")
SUB_ACTION :: 3

// Most handler runs in one game frame. The countdown needs 8; the longest
// bookkeeping chain seen is 7 steps.
@(private = "file")
MAX_RUNS :: 16

// Combatants, effects, number popups and windows, as the battle overlay
// keeps them. An actor rests when its action state is idle and its animation
// mode is the resting loop; the round waits on exactly these two (the per-
// frame masks at 0x8011df34/0x8011df36).
@(private = "file")
Pool :: struct {
	base, stride, count: u32,
}
@(private = "file")
ACTORS :: [?]Pool {
	{PARTY_COMBATANTS, PARTY_COMBATANT_SIZE, 6}, // party
	{ENEMY_COMBATANTS, ENEMY_COMBATANT_SIZE, 6}, // enemies
}
@(private = "file")
ACTOR_ACTIVE :: 0x01 // flags, byte 0
@(private = "file")
ACTOR_ANIM_MODE :: 0x4 // u8
@(private = "file")
ACTOR_ACTION :: 0x8 // u8
@(private = "file")
ANIM_RESTING :: 1
@(private = "file")
ACTION_IDLE :: 3

// Effect pool (run by 0x801ba12c; entries flagged persistent, such as the
// shadows, by 0x801ba1f0 instead).
@(private = "file")
EFFECTS :: Pool{0x801c83a8, 0x9c, 64}
@(private = "file")
EFFECT_ACTIVE :: 0x01
@(private = "file")
EFFECT_PERSISTENT :: 0x20

// Popup pool, ticked by 0x801af948 (see popup.odin). A number rises in
// step 1 and settles in a smaller bounce in step 2 before it is freed.
@(private = "file")
POPUPS :: Pool{0x801caab0, 0x10, 24}
@(private)
POPUP_ACTIVE :: 0x01
@(private = "file")
POPUP_SETTLING :: 2

// Window slots (0x80150018): flag bit 0 per slot is on while it shows.
@(private = "file")
WINDOWS :: Pool{0x8011db9c, 0x18, 27}

// Battle camera state (RAM offset of 0x80138170), compared from one game
// frame to the next.
@(private = "file")
CAMERA :: 0x138170
@(private = "file")
CAMERA_SIZE :: 0x80

// What a bookkeeping step must leave alone: the combatants, effects and
// popups, which only advance in the per-frame update after the phase handler.
@(private = "file")
WATCHED :: [?]Pool {
	{PARTY_COMBATANTS, PARTY_COMBATANT_SIZE, 6},
	{ENEMY_COMBATANTS, ENEMY_COMBATANT_SIZE, 6},
	EFFECTS,
	POPUPS,
}
@(private = "file")
SNAPSHOT_SIZE :: 0x4000 // >= the WATCHED pools' total, 0x3d08

@(private = "file")
quick: struct {
	prep:     psx.Func_Proc,
	round:    psx.Func_Proc,
	snapshot: [SNAPSHOT_SIZE]u8,
	camera:   [CAMERA_SIZE]u8,
	moved:   bool, // the camera changed since the previous game frame
	windows: u32, // windows showing during the countdown
}

@(private)
quick_battle_init :: proc() -> bool {
	ok: [2]bool
	quick.prep, ok[0] = psx.hook_overlay(PREP_PHASE, SLOT_MENU, BATTLE_ID, prep_phase)
	quick.round, ok[1] = psx.hook_overlay(ROUND_PHASE, SLOT_ENGINE, ROUND_ID, round_phase)
	if ok != {true, true} {
		fmt.eprintf("qol: battle phase handlers not found %v\n", ok)
		return false
	}
	return true
}

@(private = "file")
prep_phase :: proc() {
	if u8(psx.lw(BATTLE_STATE)) == PHASE_COUNTDOWN && u8(psx.lw(BATTLE_STATE) >> 8) == 0 {
		quick.windows = window_mask()
	}
	phase_run(quick.prep)
}

@(private = "file")
round_phase :: proc() {
	camera := (^[CAMERA_SIZE]u8)(&psx.ram[CAMERA])^
	quick.moved = camera != quick.camera
	quick.camera = camera
	phase_run(quick.round)
}

// Run a phase handler, then again from the same registers while it only
// stepped through bookkeeping.
@(private = "file")
phase_run :: proc(handler: psx.Func_Proc) {
	if !config.battle_quick_turns {
		handler()
		return
	}
	regs := psx.cpu.r
	before := psx.lw(BATTLE_STATE)
	snapshot_take()
	handler()
	for _ in 1 ..< MAX_RUNS {
		after := psx.lw(BATTLE_STATE)
		if !step_passed(before, after) || !snapshot_same() {
			return
		}
		if .Qol in psx.trace.active {
			psx.tracef(.Qol, "quick turns: %08x -> %08x in the same frame", before, after)
		}
		before = after
		psx.cpu.r = regs
		handler()
	}
}

@(private = "file")
snapshot_take :: proc() {
	pools := WATCHED
	n: u32
	for pool in pools {
		size := pool.stride * pool.count
		copy(quick.snapshot[n:][:size], psx.mem_slice(pool.base, size))
		n += size
	}
}

// Whether the last handler run left the WATCHED pools as snapshot_take saw
// them; takes a new snapshot for the next run.
@(private = "file")
snapshot_same :: proc() -> bool {
	pools := WATCHED
	n: u32
	same := true
	for pool in pools {
		size := pool.stride * pool.count
		ram := psx.mem_slice(pool.base, size)
		if same && string(ram) != string(quick.snapshot[n:][:size]) {
			same = false
		}
		copy(quick.snapshot[n:][:size], ram)
		n += size
	}
	return same
}

// Whether a handler run that moved the state from `before` to `after` was
// pure bookkeeping, so the next run can follow in the same frame. The caller
// also requires that the run wrote no combatant, effect or popup: waits such
// as the round end's read masks (0x8011df34/0x8011df36, the 0x100 bit of
// 0x8011deec) that the per-frame update fills in from those, so once a step
// has queued work for any of them, the next step must see a game frame
// first. Run in the same frame it reads the old mask, ends the round under a
// running actor script, and the next phase loads over that script's code.
// Work already in flight (a combatant out of its resting loop, an effect)
// stops the chain as well.
@(private = "file")
step_passed :: proc(before, after: u32) -> bool {
	phase, sub := u8(after), u8(after >> 8)
	switch phase {
	case PHASE_COUNTDOWN:
		return sub == 0
	case PHASE_ROUND:
		return sub != SUB_ACTION && after != before && actors_resting() && !effects_running()
	}
	return false
}

// Whether the round is running with nothing on screen but resting combatants
// and settling numbers, with quick idle on.
@(private)
quick_idle :: proc() -> bool {
	return config.battle_quick_idle && u8(psx.lw(BATTLE_STATE)) == PHASE_ROUND && !quick.moved &&
		window_mask() == quick.windows && actors_resting() && !effects_running() && !popups_rising()
}

@(private = "file")
actors_resting :: proc() -> bool {
	pools := ACTORS
	for pool in pools {
		for i in 0 ..< pool.count {
			a := pool.base + i * pool.stride
			if psx.lbu(a) & ACTOR_ACTIVE == 0 {
				continue
			}
			if psx.lbu(a + ACTOR_ACTION) != ACTION_IDLE || psx.lbu(a + ACTOR_ANIM_MODE) != ANIM_RESTING {
				return false
			}
		}
	}
	return true
}

@(private = "file")
effects_running :: proc() -> bool {
	for i in 0 ..< EFFECTS.count {
		flags := psx.lbu(EFFECTS.base + i * EFFECTS.stride)
		if flags & EFFECT_ACTIVE != 0 && flags & EFFECT_PERSISTENT == 0 {
			return true
		}
	}
	return false
}

// Whether any popup is a message, or a shown number still in its first
// bounce.
@(private = "file")
popups_rising :: proc() -> bool {
	for i in 0 ..< POPUPS.count {
		p := POPUPS.base + i * POPUPS.stride
		if psx.lbu(p) & POPUP_ACTIVE == 0 {
			continue
		}
		kind := psx.lbu(p + POPUP_KIND)
		if kind != POPUP_NUMBER && kind != POPUP_NUMBER_MARKED {
			return true
		}
		// A hidden number (damage_numbers off) has nothing to read.
		if config.battle_damage_numbers &&
		   (psx.lbu(p + POPUP_PHASE) != 0 || psx.lbu(p + POPUP_STEP) < POPUP_SETTLING) {
			return true
		}
	}
	return false
}

@(private = "file")
window_mask :: proc() -> u32 {
	mask: u32
	for i in 0 ..< WINDOWS.count {
		if psx.lbu(WINDOWS.base + i * WINDOWS.stride) & 1 != 0 {
			mask |= 1 << i
		}
	}
	return mask
}
