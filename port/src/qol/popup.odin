// Battle damage numbers.
//
// The battle overlay (BWORLD/AREABnnn.EMI, overlay 0x32 at 0x801aa000) shows
// every number and short message that pops up over a combatant through
// POPUP_SPAWN(target, kind, value), which takes a free entry from the popup
// pool and starts its rise-and-fade animation. The popup tick draws `kind`
// as:
//   0x00 : `value` alone in digits (damage, or a heal when negative)
//   0x80 : the same with a marker drawn beside it
//   other: a message from the system text, with `value` formatted into it
//          where the message has a number (misses, status changes, ...)
//
// POPUP_TICK runs once per popup per frame: it steps the popup's animation
// through the state handlers in POPUP_STATES (indexed by phase +3 and step +1;
// the handlers move the popup, consume rand() and free it when done), then
// draws it. With `damage_numbers` off, number popups are still spawned and
// animated exactly as the game does, so battle timing and the random number
// sequence are unchanged; only their drawing is skipped. Messages still appear.
//
// With quick idle (quick_battle.odin), a number whose settle is all the round
// still waits on runs the rest of its state handlers at once after this
// frame's draw, so it is freed and the round moves on.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private = "file")
POPUP_TICK :: 0x801af9d8 // a0 = popup
@(private = "file")
POPUP_STATES :: 0x801aa314 // [3][3] handler addresses, by phase then step
@(private = "file")
POPUP_PHASES :: 3
@(private)
POPUP_STEP :: 0x1 // u8
@(private = "file")
POPUP_TARGET :: 0x2 // u8
@(private)
POPUP_PHASE :: 0x3 // u8
@(private)
POPUP_KIND :: 0x4 // u8
@(private = "file")
POPUP_VALUE :: 0x8 // i32

@(private)
POPUP_NUMBER :: 0x00
@(private)
POPUP_NUMBER_MARKED :: 0x80

// Longest popup life in game frames is ~29; a bound for finishing one.
@(private = "file")
MAX_POPUP_STEPS :: 64

@(private = "file")
popup: struct {
	tick: psx.Func_Proc,
}

@(private)
popup_init :: proc() -> bool {
	original, ok := psx.hook_overlay(POPUP_TICK, SLOT_MENU, BATTLE_ID, popup_tick)
	if !ok {
		fmt.eprintf("qol: battle function %08x not found\n", POPUP_TICK)
		return false
	}
	popup.tick = original
	return true
}

// Animate a number popup without drawing it; anything else runs as usual.
@(private = "file")
popup_tick :: proc() {
	c := &psx.cpu
	p := c.r[4]
	kind := psx.lbu(p + POPUP_KIND)
	number := kind == POPUP_NUMBER || kind == POPUP_NUMBER_MARKED
	if config.battle_damage_numbers || !number {
		popup.tick()
	} else {
		phase, step := psx.lbu(p + POPUP_PHASE), psx.lbu(p + POPUP_STEP)
		if .Game in core.trace.active && phase == 0 && step == 0 {
			core.tracef(.Game, "popup: hidden kind %02x target %d value %d",
				kind, psx.lbu(p + POPUP_TARGET), i32(psx.lw(p + POPUP_VALUE)))
		}
		popup_step(p)
	}
	if number && quick_idle() {
		popup_finish(p)
	}
}

// Run one animation step of popup p without drawing it.
@(private = "file")
popup_step :: proc(p: u32) {
	c := &psx.cpu
	phase, step := psx.lbu(p + POPUP_PHASE), psx.lbu(p + POPUP_STEP)
	if phase >= POPUP_PHASES {
		return
	}
	ra := c.r[31]
	c.r[4] = p
	psx.call(psx.lw(POPUP_STATES + (phase * POPUP_PHASES + step) * 4))
	c.r[31] = ra
}

// Step popup p until its handlers free it.
@(private = "file")
popup_finish :: proc(p: u32) {
	for n in 0 ..< MAX_POPUP_STEPS {
		if psx.lbu(p) & POPUP_ACTIVE == 0 {
			if .Game in core.trace.active {
				core.tracef(.Game, "quick idle: popup %08x finished, %d steps cut", p, n)
			}
			return
		}
		popup_step(p)
	}
	fmt.eprintf("qol: popup %08x still active after %d steps\n", p, MAX_POPUP_STEPS)
}
