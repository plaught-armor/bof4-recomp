// Random encounter rate.
//
// The field overlay (SYSTEM/FLD_MAIN.EMI, overlay 0x0f at 0x801cc800) calls
// 0x801d728c(obj) once per movement step of the party leader. It counts down
// a step budget at STEPS_LEFT, 1 per step when obj+0x4d bit 0 is set (walking)
// and 2 otherwise (running); at zero it flags the battle and returns 1. A
// budget of 0xff asks 0x801d7024 to roll a new one.
//
// This replacement keeps that logic and scales the steps taken by
// config.encounter_rate through a fractional accumulator, so the rate works
// per step and is unaffected by how often frames are drawn.
package qol

import "core:fmt"
import "core:math"

import "../psx"

import "ps:core"

@(private)
FLD_MAIN_ID :: 0x0f

@(private = "file")
ENCOUNTER_CHECK :: 0x801d728c
@(private = "file")
ROLL_BUDGET :: 0x801d7024
@(private = "file")
AREA_ENCOUNTERS :: 0x801d6ef0

// Field state bytes read by the check.
FIELD_FLAGS :: 0x801172aa // u16, bit 0x2000: encounters disabled, 0x200: exit 0xa4 closed
@(private = "file")
FIELD_EVENTS :: 0x801172ac // u16, bit 0x200: random battle pending
@(private)
STEPS_LEFT :: 0x801172a7 // u8
@(private = "file")
LEADER_ID :: 0x801172af // u8
@(private = "file")
GAME_REQUEST :: 0x80114870 // u8, nonzero while a mode change is pending
@(private = "file")
MAP_INDEX :: 0x8011b724 // u8
@(private = "file")
MAP_TABLE :: 0x800fa8a8 // 12-byte rows, u16 at +4: map has encounters

@(private = "file")
encounter: struct {
	// Fractional steps carried between checks.
	carry: f64,
}

@(private)
encounter_init :: proc() -> bool {
	_, ok := hook_field(ENCOUNTER_CHECK, encounter_check)
	return ok
}

// Replace a FLD_MAIN function; returns the original.
@(private)
hook_field :: proc(addr: u32, fn: psx.Func_Proc) -> (psx.Func_Proc, bool) {
	original, ok := psx.hook_overlay(addr, SLOT_ENGINE, FLD_MAIN_ID, fn)
	if !ok {
		fmt.eprintf("qol: field function %08x not found\n", addr)
	}
	return original, ok
}

// Call a game function as `jal target` from `ret - 8` would.
@(private)
game_call :: proc(target, ret: u32) {
	psx.cpu.r[31] = ret
	psx.call(target)
}

@(private = "file")
encounter_check :: proc() {
	c := &psx.cpu
	ra, sp := c.r[31], c.r[29]
	c.r[29] = sp - 0x18
	c.r[2] = encounter_step(c.r[4]) ? 1 : 0
	c.r[29], c.r[31] = sp, ra
}

// One leader step on a field map; true starts a random battle.
@(private = "file")
encounter_step :: proc(obj: u32) -> bool {
	if psx.lhu(FIELD_FLAGS) & 0x2000 != 0 || psx.lbu(GAME_REQUEST) != 0 {
		return false
	}
	if psx.lbu(obj + 1) != psx.lbu(LEADER_ID) || !area_has_encounters(obj) {
		return false
	}
	left := psx.lbu(STEPS_LEFT)
	if left == 0xff {
		psx.cpu.r[4] = left
		game_call(ROLL_BUDGET, 0x801d7370)
		return false
	}
	if left != 0 {
		per_step := psx.lbu(obj + 0x4d) & 1 != 0 ? 1.0 : 2.0
		encounter.carry += per_step * config.encounter_rate
		taken := math.floor(encounter.carry)
		encounter.carry -= taken
		left = u32(max(f64(left) - taken, 0))
		if .Game in core.trace.active {
			core.tracef(.Game, "encounter: %v steps taken, %d left", taken, left)
		}
		psx.sb(STEPS_LEFT, left)
		if left != 0 {
			return false
		}
	}
	psx.sh(FIELD_EVENTS, psx.lhu(FIELD_EVENTS) | 0x200)
	return true
}

@(private = "file")
area_has_encounters :: proc(obj: u32) -> bool {
	psx.cpu.r[4] = psx.lhu(FIELD_MAP)
	game_call(AREA_KIND, 0x801d72ec)
	if psx.cpu.r[2] & 0xff == 1 {
		row := MAP_TABLE + psx.lbu(MAP_INDEX) * 12
		return psx.lhu(row + 4) != 0
	}
	psx.cpu.r[4] = obj
	game_call(AREA_ENCOUNTERS, 0x801d733c)
	table := psx.cpu.r[2]
	return table != 0 && psx.lbu(table + 4) != 0xff
}
