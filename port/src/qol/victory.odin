// Victory screen pace.
//
// BTLEND.EMI (overlay 0x35 at 0x801cc800) runs the results while the battle
// phase (BATTLE_STATE) is RESULTS. END_TICK runs once per game tick (30 Hz) and
// dispatches on STATE, then each state on SUB (tables at 0x801d0a6c and
// 0x801d0a7c / 0x801d0a88 / 0x801d0a94):
//
//   state 0  EXP    sub 0 init, 1 sets COUNT to 60, 2 counts and waits
//   state 1  level  sub 2 shows each member's level-up and new skills, one
//                   per press (state 0 goes here only when someone levels)
//   state 2  zenny  sub 1 sets COUNT to 70, 2 counts and waits
//   state 3         leaves (BATTLE_STATE + 1)
//
// While COUNT runs, every odd tick moves a thirtieth of each member's
// pending EXP (0x801c8390, u32 per member) or of the pending zenny into the
// totals, and at 1 the rest. Sub 2 of states 0..2 then waits for a press
// (PAD_PRESSED & 0xf6ff, anything but Select and Start); a press while
// counting ends the count at once.
//
// With `quick_victory` the hook cuts COUNT to QUICK_COUNT on entry to a
// count, and once the count is over and the screen has held for HOLD ticks
// it presents a confirm press to the original tick, as text.odin does, so
// the results go by without a button. A press still advances at once.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private = "file")
END_ID :: 0x35
@(private = "file")
END_TICK :: 0x801cc9d0

@(private = "file")
STATE :: 0x8011ded5 // u8
@(private = "file")
SUB :: 0x8011ded6 // u8
@(private = "file")
COUNT :: 0x8011dee0 // u8 count-down; in state 1 the member being shown
@(private = "file")
RESULTS :: 7
@(private = "file")
LEVEL_STATE :: 1
@(private = "file")
LAST_WAIT_STATE :: 2
@(private = "file")
WAIT_SUB :: 2

@(private = "file")
QUICK_COUNT :: 10 // ticks, from 60 / 70
@(private = "file")
HOLD :: 45 // ticks a finished panel stays up

@(private = "file")
victory: struct {
	tick:  psx.Func_Proc,
	wait:  u32, // STATE | SUB << 8 of the wait being held, 0 none
	held:  u32, // ticks since that wait's count ended
}

@(private)
victory_init :: proc() -> bool {
	original, ok := psx.hook_overlay(END_TICK, SLOT_ENGINE, END_ID, victory_tick)
	if !ok {
		fmt.eprintf("qol: battle end function %08x not found\n", END_TICK)
		return false
	}
	victory.tick = original
	return true
}

@(private = "file")
victory_tick :: proc() {
	state, sub := psx.lbu(STATE), psx.lbu(SUB)
	if !config.battle_quick_victory || psx.lbu(BATTLE_STATE) != RESULTS || state > LAST_WAIT_STATE || sub != WAIT_SUB {
		victory.wait = 0
		victory.tick()
		return
	}
	// In state 1 COUNT is a member index, and each member's page is a wait
	// of its own.
	wait := state | sub << 8
	if state == LEVEL_STATE {
		wait |= psx.lbu(COUNT) << 16 | 1 << 24
	}
	if wait != victory.wait {
		victory.wait = wait
		victory.held = 0
		if state != LEVEL_STATE && psx.lbu(COUNT) > QUICK_COUNT {
			psx.sb(COUNT, QUICK_COUNT)
		}
	}
	if state != LEVEL_STATE && psx.lbu(COUNT) != 0 {
		victory.tick()
		return
	}
	victory.held += 1
	if victory.held < HOLD {
		victory.tick()
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "victory: state %d member %d, confirm pressed", state, psx.lbu(COUNT))
	}
	pressed := psx.lhu(PAD_PRESSED)
	psx.sh(PAD_PRESSED, pressed | psx.lhu(CONFIRM_MASK))
	victory.tick()
	psx.sh(PAD_PRESSED, pressed)
}
