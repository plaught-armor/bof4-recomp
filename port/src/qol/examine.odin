// Auto examine: which enemies know a skill the party can learn.
//
// BoF3's Examine is gone from BoF4, so nothing in the game says which enemy
// uses a learnable skill. Each enemy combatant holds the 8 skills it can use
// (ENEMY_SKILLS); a skill is learnable when the low nibble of byte 2 of its
// skill data is nonzero (learning.odin), and known when its bit is set in
// SKILL_BITS (masters.odin). With `examine`, the battle's first command input
// (BTLCOMD.EMI, overlay 0x33 at 0x801cc800) shows a window at the top of the
// screen: one line per enemy kind that has a learnable skill, its skills in
// green while nobody knows them and in grey once learned. The window closes
// when the first round starts (BTLMOVE.EMI, overlay 0x34, in the slot).
//
// Skill names come from the game's own table: SKILL_NAMES holds a u16 offset
// per skill id, from SKILL_NAMES, to a NUL-terminated name.
package qol

import "../psx"

@(private = "file")
COMMAND_ID :: 0x33
@(private = "file")
ROUND_ID :: 0x34
@(private = "file")
GAME_MODE_BATTLE :: 5

@(private = "file")
ENEMY_COUNT :: 6
@(private = "file")
ENEMY_NAME :: 0x9c // 8 bytes, NUL-padded
@(private = "file")
ENEMY_NAME_LEN :: 8
@(private = "file")
ENEMY_SKILLS :: 0x12c // 8 skill ids
@(private = "file")
ENEMY_SKILL_COUNT :: 8

@(private = "file")
SKILL_DATA_SIZE :: 12
@(private = "file")
LEARN_LEVEL :: 2
@(private = "file")
SKILL_NAMES :: 0x80022a00
@(private = "file")
SKILL_NAME_MAX :: 16

@(private = "file")
BOX_X :: 8
@(private = "file")
BOX_Y :: 8
@(private = "file")
BOX_W :: 200 // left of the game's enemy list window
@(private = "file")
BOX_PAD :: 8
@(private = "file")
NAME_GAP :: 12
@(private = "file")
SEPARATOR :: ", "

@(private = "file")
Examine_Line :: struct {
	name:   [ENEMY_NAME_LEN]u8,
	skills: [ENEMY_SKILL_COUNT]u8,
	count:  int,
}

@(private = "file")
examine: struct {
	// Set when a battle starts, cleared when its first round does.
	armed: bool,
	lines: [ENEMY_COUNT]Examine_Line,
	count: int,
}

// Called every frame end; true while the window is up.
@(private)
examine_draws :: proc() -> bool {
	if psx.lhu(GAME_MODE) != GAME_MODE_BATTLE {
		examine.armed = true
		return false
	}
	switch psx.lw(SLOT_ENGINE) {
	case ROUND_ID:
		examine.armed = false
	case COMMAND_ID:
		if !config.battle_examine || !examine.armed {
			return false
		}
		// The enemies fill in after the overlay arrives; read them each frame.
		examine_gather()
		return examine.count > 0
	}
	return false
}

// One line per enemy name, with the distinct learnable skills of all the
// enemies of that name.
@(private = "file")
examine_gather :: proc() {
	examine.count = 0
	for e in u32(0) ..< ENEMY_COUNT {
		p := enemy_combatant(e)
		if psx.lbu(p + ENEMY_NAME) == 0 || psx.lw(p + COMBATANT_HP) == 0 {
			continue
		}
		name: [ENEMY_NAME_LEN]u8
		for k in u32(0) ..< ENEMY_NAME_LEN {
			name[k] = u8(psx.lbu(p + ENEMY_NAME + k))
		}
		line: ^Examine_Line
		for &l in examine.lines[:examine.count] {
			if l.name == name {
				line = &l
			}
		}
		for k in u32(0) ..< ENEMY_SKILL_COUNT {
			skill := u8(psx.lbu(p + ENEMY_SKILLS + k))
			if psx.lbu(SKILL_DATA + u32(skill) * SKILL_DATA_SIZE + LEARN_LEVEL) & 0xf == 0 {
				continue
			}
			if line == nil {
				line = &examine.lines[examine.count]
				line^ = {name = name}
				examine.count += 1
			}
			listed := false
			for s in line.skills[:line.count] {
				listed ||= s == skill
			}
			if !listed {
				line.skills[line.count] = skill
				line.count += 1
			}
		}
	}
}

@(private)
examine_draw :: proc() {
	rows, width := examine_layout(false)
	menu_window(BOX_X, BOX_Y, width + 2 * BOX_PAD, 2 * BOX_PAD + rows * MENU_LINE_H)
	examine_layout(true)
}

// Lay the lines out in the window, drawing them when `draw` is set: names
// in a column, then each enemy's skills, wrapping under the first skill when
// the row is full. Returns the rows and the widest row's width.
@(private = "file")
examine_layout :: proc(draw: bool) -> (rows, width: int) {
	name_w := 0
	for &l in examine.lines[:examine.count] {
		name_w = max(name_w, menu_text_width(enemy_name(&l)))
	}
	left := BOX_X + BOX_PAD + name_w + NAME_GAP
	right := BOX_X + BOX_W - BOX_PAD
	for &l in examine.lines[:examine.count] {
		y := BOX_Y + BOX_PAD + rows * MENU_LINE_H
		if draw {
			menu_text(BOX_X + BOX_PAD, y, enemy_name(&l))
		}
		x := left
		for skill in l.skills[:l.count] {
			buf: [SKILL_NAME_MAX]u8
			name := skill_name(skill, buf[:])
			if x > left {
				if x + menu_text_width(SEPARATOR) + menu_text_width(name) > right {
					rows += 1
					y += MENU_LINE_H
					x = left
				} else if draw {
					x = menu_text(x, y, SEPARATOR)
				} else {
					x += menu_text_width(SEPARATOR)
				}
			}
			name = menu_text_fit(name, right - x)
			if draw {
				menu_text(x, y, name, MENU_GREY if skill_known(skill) else MENU_GREEN)
			}
			x += menu_text_width(name)
			width = max(width, x - BOX_X - BOX_PAD)
		}
		rows += 1
	}
	return rows, width
}

@(private = "file")
enemy_name :: proc(l: ^Examine_Line) -> string {
	n := 0
	for n < ENEMY_NAME_LEN && l.name[n] != 0 {
		n += 1
	}
	return string(l.name[:n])
}

// The game's name for a skill, copied into buf.
@(private)
skill_name :: proc(skill: u8, buf: []u8) -> string {
	at := SKILL_NAMES + u32(psx.lhu(SKILL_NAMES + u32(skill) * 2))
	n := 0
	for n < len(buf) {
		ch := u8(psx.lbu(at + u32(n)))
		if ch == 0 {
			break
		}
		buf[n] = ch
		n += 1
	}
	return string(buf[:n])
}
