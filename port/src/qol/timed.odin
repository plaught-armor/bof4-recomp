// Timed hits: a perfect attack and a perfect parry.
//
// An action runs in round sub-phase 3 (BATTLE_STATE reads ROUND_ACTION in its low
// half) with the round record at ACTION: the actor's id (below ENEMY_IDS a
// party member), its kind (KIND_ATTACK for a plain attack, for the party and
// enemies alike) and the skill id. Each hit ends in HP_APPLY (damage.odin),
// and a given attacker's attack lands the same number of game frames after
// its action starts every time (Ryu 23, a Cap 25, at 30 Hz), so the timing
// is learned: the first time an attacker attacks, each hit's lead from the
// action start is stored under its key (the character, or the enemy's
// name, with the kind and skill), and from then on a square closes in the
// middle of the screen on each hit's frame.
//
// The press is judged when the hit lands, from the confirm presses seen in
// the frames before it (presses are kept per game frame): the first press
// in the CUE frames before the hit counts, so mashing fails. In the last
// PERFECT frames it is perfect, in the GOOD frames before those it is good,
// earlier it misses. With no learned cue the window is the same, the press
// just has no square to follow.
//
//   timed_attacks  the party's plain attacks on enemies: perfect x1.5,
//                  good x1.2
//   timed_parry    enemies' plain attacks on the party: a perfect parry
//                  takes no damage, a good one half (as Guard)
//
// The rate joins damage.odin's multipliers, so the damage number shows it.
package qol

import "ps:psx"

import "ps:core"

@(private = "file")
ROUND_ACTION :: 0x0303 // phase 3 the round, sub-phase 3 an actor's action
@(private = "file")
ACTION_KIND :: 0x1 // u8
@(private = "file")
ACTION_SKILL :: 0x2 // u16
@(private = "file")
KIND_ATTACK :: 1

@(private = "file")
PARTY_CHAR :: 0xa4 // u8 character id
@(private = "file")
ENEMY_NAME :: 0x9c // 8 bytes, NUL-padded

// Windows in game frames before the hit, the hit's own frame included.
@(private = "file")
CUE :: 15
@(private = "file")
PERFECT :: 3
@(private = "file")
GOOD :: 3

@(private = "file")
ATTACK_PERFECT :: 1.5
@(private = "file")
ATTACK_GOOD :: 1.2
@(private = "file")
PARRY_PERFECT :: 0.0
@(private = "file")
PARRY_GOOD :: 0.5

// Cue square in screen space: half sizes, the closing one shrinking by
// CUE_STEP a frame onto the target's.
@(private = "file")
CUE_X :: 160
@(private = "file")
CUE_Y :: 104
@(private = "file")
CUE_HALF :: 8
@(private = "file")
CUE_STEP :: 3
@(private = "file")
CUE_WHITE :: 0xffffff
@(private = "file")
CUE_YELLOW :: 0x00d0ff // GP0 colours are BGR
@(private = "file")
RESULT_FRAMES :: 20

@(private = "file")
TIMING_COUNT :: 64
@(private = "file")
HIT_MAX :: 8
@(private = "file")
PRESS_COUNT :: 16

@(private = "file")
Timing :: struct {
	key:   u64,
	count: u8,
	leads: [HIT_MAX]u16, // game frames from the action start
}

@(private = "file")
Grade :: enum u8 {
	Miss,
	Good,
	Perfect,
}

@(private = "file")
GRADE_TEXT := [Grade]string {
	.Miss    = "",
	.Good    = "Good",
	.Perfect = "Perfect!",
}

@(private = "file")
timed: struct {
	timings:     [TIMING_COUNT]Timing,
	next:        int, // the slot a new key takes
	acting:      bool,
	start:       u32, // GAME_FRAME the action started
	key:         u64,
	learned:     ^Timing, // nil while the action's timing is not known
	learning:    Timing,
	hits:        int, // distinct hit frames so far this action
	last_hit:    u32,
	last_grade:  Grade,
	presses:     [PRESS_COUNT]u32,
	press_next:  int,
	result:      Grade,
	result_till: u32,
}

// Once per game frame, from the frame end (menu_draw.odin).
@(private)
timed_tick :: proc() {
	if !config.battle_timed_attacks && !config.battle_timed_parry {
		return
	}
	frame := psx.lw(GAME_FRAME)
	if psx.lhu(PAD_PRESSED) & psx.lhu(CONFIRM_MASK) != 0 {
		press_note(frame)
	}
	acting := psx.lhu(GAME_MODE) == MODE_BATTLE && psx.lhu(BATTLE_STATE) == ROUND_ACTION
	if acting && !timed.acting {
		action_start(frame)
	} else if !acting && timed.acting {
		action_end()
	}
}

@(private = "file")
action_start :: proc(frame: u32) {
	timed.acting = true
	timed.start = frame
	timed.key = action_key()
	timed.learned = nil
	timed.learning = {key = timed.key}
	timed.hits = 0
	if .Game in core.trace.active {
		core.tracef(.Game, "timed: actor %d kind %d skill %d starts", psx.lbu(ACTION), psx.lbu(ACTION + ACTION_KIND), psx.lhu(ACTION + ACTION_SKILL))
	}
	for &t in timed.timings {
		if t.key == timed.key && t.count != 0 {
			timed.learned = &t
		}
	}
}

@(private = "file")
action_end :: proc() {
	timed.acting = false
	if timed.learned != nil || timed.learning.count == 0 {
		return
	}
	timed.timings[timed.next] = timed.learning
	timed.next = (timed.next + 1) % TIMING_COUNT
	if .Game in core.trace.active {
		core.tracef(.Game, "timed: learned %016x, %d hits, first at %d", timed.learning.key, timed.learning.count, timed.learning.leads[0])
	}
}

// The attacker (character id, or enemy name), kind and skill.
@(private = "file")
action_key :: proc() -> u64 {
	actor := psx.lbu(ACTION)
	who: u64
	if actor < ENEMY_IDS {
		who = u64(psx.lbu(party_combatant(actor) + PARTY_CHAR))
	} else {
		name := combatant(actor) + ENEMY_NAME
		who = u64(psx.lw(name)) | u64(psx.lw(name + 4)) << 32
		who = who * 0x9e3779b97f4a7c15 | 1 << 63 // apart from character ids
	}
	// A plain attack leaves the last skill id in place.
	kind := psx.lbu(ACTION + ACTION_KIND)
	skill := kind == KIND_ATTACK ? 0 : psx.lhu(ACTION + ACTION_SKILL)
	return who ~ u64(kind) << 40 ~ u64(skill) << 48
}

@(private = "file")
press_note :: proc(frame: u32) {
	last := timed.presses[(timed.press_next + PRESS_COUNT - 1) % PRESS_COUNT]
	if last == frame {
		return
	}
	timed.presses[timed.press_next] = frame
	timed.press_next = (timed.press_next + 1) % PRESS_COUNT
}

// From HP_APPLY: the multiplier the press earns this hit on `target`, 1 when
// the hit is not one the options time.
@(private)
timed_rate :: proc(target: u32) -> f64 {
	actor := psx.lbu(ACTION)
	if !timed.acting || psx.lbu(ACTION + ACTION_KIND) != KIND_ATTACK {
		return 1
	}
	attack := actor < ENEMY_IDS && target >= ENEMY_IDS
	parry := actor >= ENEMY_IDS && target < ENEMY_IDS
	if !(attack && config.battle_timed_attacks) && !(parry && config.battle_timed_parry) {
		return 1
	}
	frame := psx.lw(GAME_FRAME)
	// One judgement per hit frame; an attack on several targets at once
	// shares it.
	if timed.hits == 0 || frame != timed.last_hit {
		if psx.lhu(PAD_PRESSED) & psx.lhu(CONFIRM_MASK) != 0 {
			press_note(frame)
		}
		from := frame - CUE + 1
		if timed.hits > 0 {
			from = max(from, timed.last_hit + 1)
		}
		before: int
		timed.last_grade, before = judge(from, frame)
		if timed.learning.count < HIT_MAX {
			timed.learning.leads[timed.learning.count] = u16(frame - timed.start)
			timed.learning.count += 1
		}
		timed.hits += 1
		timed.last_hit = frame
		timed.result = timed.last_grade
		timed.result_till = frame + RESULT_FRAMES
		if .Game in core.trace.active {
			core.tracef(.Game, "timed: actor %d target %d hit at +%d, press %d before, %v", actor, target, frame - timed.start, before, timed.last_grade)
		}
	}
	switch timed.last_grade {
	case .Perfect:
		return ATTACK_PERFECT if attack else PARRY_PERFECT
	case .Good:
		return ATTACK_GOOD if attack else PARRY_GOOD
	case .Miss:
	}
	return 1
}

// The first press in from..hit grades the hit; also returns how many frames
// before the hit it came, -1 for none.
@(private = "file")
judge :: proc(from, hit: u32) -> (Grade, int) {
	first: Maybe(u32)
	for p in timed.presses {
		if p - from <= hit - from && (first == nil || p < first.?) {
			first = p
		}
	}
	p, ok := first.?
	switch {
	case !ok:
		return .Miss, -1
	case hit - p < PERFECT:
		return .Perfect, int(hit - p)
	case hit - p < PERFECT + GOOD:
		return .Good, int(hit - p)
	}
	return .Miss, int(hit - p)
}

@(private)
timed_draws :: proc() -> bool {
	if !config.battle_timed_attacks && !config.battle_timed_parry {
		return false
	}
	return psx.lw(GAME_FRAME) < timed.result_till || cue_left() >= 0
}

// For autoplay's `pulse qte`.
@(private)
timed_acting :: proc() -> bool {
	return timed.acting
}

@(private)
timed_cue_left :: proc() -> int {
	return cue_left()
}

// Frames until the action's next learned hit, -1 when no cue is due.
@(private = "file")
cue_left :: proc() -> int {
	if !timed.acting || timed.learned == nil || psx.lbu(ACTION + ACTION_KIND) != KIND_ATTACK {
		return -1
	}
	actor := psx.lbu(ACTION)
	if actor < ENEMY_IDS ? !config.battle_timed_attacks : !config.battle_timed_parry {
		return -1
	}
	now := int(psx.lw(GAME_FRAME) - timed.start)
	for lead in timed.learned.leads[:timed.learned.count] {
		left := int(lead) - now
		if left >= 0 && left < CUE {
			return left
		}
	}
	return -1
}

@(private)
timed_draw :: proc() {
	if left := cue_left(); left >= 0 {
		cue_square(CUE_HALF, CUE_YELLOW)
		cue_square(CUE_HALF + left * CUE_STEP, CUE_WHITE)
	}
	if psx.lw(GAME_FRAME) < timed.result_till && timed.result != .Miss {
		text := GRADE_TEXT[timed.result]
		menu_text(CUE_X - menu_text_width(text) / 2, CUE_Y + CUE_HALF + 4, text, MENU_YELLOW if timed.result == .Perfect else MENU_WHITE)
	}
}

// A square outline of four flat lines.
@(private = "file")
cue_square :: proc(half: int, colour: u32) {
	l, t, r, b := CUE_X - half, CUE_Y - half, CUE_X + half, CUE_Y + half
	cue_line(l, t, r, t, colour)
	cue_line(r, t, r, b, colour)
	cue_line(r, b, l, b, colour)
	cue_line(l, b, l, t, colour)
}

@(private = "file")
cue_line :: proc(x0, y0, x1, y1: int, colour: u32) {
	LINE_TAG :: 0x03000000
	LINE :: 0x40000000
	LINE_BYTES :: 0x10
	prim := psx.lw(SPRITE_PACKETS)
	psx.sw(prim, LINE_TAG)
	psx.sw(prim + 4, LINE | colour)
	psx.sw(prim + 8, u32(x0) & 0xffff | u32(y0) << 16)
	psx.sw(prim + 12, u32(x1) & 0xffff | u32(y1) << 16)
	game_routine(PRIM_COMMIT, {1, LINE_BYTES, 0, 0, 0})
}
