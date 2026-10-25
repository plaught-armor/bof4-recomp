// The combos page (not a game feature): the panel's PANEL_COMBOS page lists
// the magic combos and how to make them, names hidden until seen.
//
// Two party members casting magic in a row may combo (the battle rolls it):
// the second spell becomes a combo spell picked by the two elements and the
// second spell's level (docs/battle.md, "Magic combos"). A few characters
// then turn a skill right after a combo into a special one. Whenever a party
// member's action becomes one of these, its bit goes into the config's
// [battle] combos.
package qol

import "core:strconv"

import cpu "ps:psx/cpu"
import host "ps:psx/host"

import "ps:core"

@(private = "file")
ACTION_SKILL :: 0x8011e0c2

// Combo spells 13..28, four per element pair; specials 173..176.
@(private = "file")
FIRST_COMBO :: 13
@(private = "file")
LAST_COMBO :: 28
@(private = "file")
FIRST_SPECIAL :: 173
@(private = "file")
LAST_SPECIAL :: 176
@(private = "file")
SPECIALS_BIT :: LAST_COMBO - FIRST_COMBO + 1

// The config's `combos` with every combo and special.
@(private)
COMBOS_ALL :: (1 << (SPECIALS_BIT + LAST_SPECIAL - FIRST_SPECIAL + 1)) - 1

@(private = "file")
Combo_Family :: struct {
	head:  string,
	names: [4]string,
}

// In skill order: the first spell's element, then the second's.
@(private = "file")
FAMILIES :: [4]Combo_Family {
	{"Fire, then Wind", {"Firewind", "Simoon", "Gigaflare", "Earthbreaker"}},
	{"Wind, then Water", {"Jolt", "Lightning", "Thunderstorm", "Mjollnir"}},
	{"Water, then Earth", {"Storm", "Tempest", "Disaster", "Catastrophe"}},
	{"Earth, then Fire", {"Eruption", "Magma Blast", "Ragnarok", "Supernova"}},
}

// A combo spell's name; combo = skill - FIRST_COMBO.
@(private)
combo_name :: proc(combo: int) -> string {
	families := FAMILIES
	return families[combo / 4].names[combo % 4]
}

// Skill 173 onward: the special, and who makes it after which combos.
@(private = "file")
SPECIALS :: [4][2]string {
	{"Phoenix", "Nina, after Fire then Wind"},
	{"Mudslide", "Cray, after Water then Earth"},
	{"Ice Sword", "Scias, after Wind then Water"},
	{"Reflect", "Ursula, after Earth then Fire"},
}

// Special n (0..3, skill FIRST_SPECIAL + n): its name, who makes it after
// which combos, and its bit in [battle] combos.
@(private)
special :: proc(n: int) -> (name, recipe: string, bit: int) {
	specials := SPECIALS
	return specials[n][0], specials[n][1], 1 << uint(SPECIALS_BIT + n)
}

@(private = "file")
INTRO :: "The second spell's element must follow the first's: Fire, Wind, Water, Earth, then Fire again. The second spell's level (1 to 3) sets the combo's; level 4 takes Fou-Lu's top spell second."

@(private = "file")
COMBOS_PAD :: 12
@(private = "file")
COMBOS_TEXT_W :: PANEL.z - 2 * COMBOS_PAD
@(private = "file")
COMBOS_ROWS :: (PANEL.w - 2 * COMBOS_PAD) / MENU_LINE_H - 1 // the last row is the footer
@(private = "file")
COMBOS_LINES :: 8 + 5 * len(FAMILIES) + 2 * len(SPECIALS) + 2

@(private = "file")
Combos_Line :: struct {
	text:   string,
	colour: int,
	indent: int,
}

@(private = "file")
combos: struct {
	top:  int, // first line shown
	last: u16, // the action skill last vblank
}

// Note a party action that became a combo or special.
@(private)
combos_vblank :: proc() {
	if cpu.lhu(GAME_MODE) != MODE_BATTLE {
		combos.last = 0
		return
	}
	skill := u16(cpu.lhu(ACTION_SKILL))
	if skill == combos.last {
		return
	}
	combos.last = skill
	if cpu.lbu(ACTION) >= 6 {
		return
	}
	bit := 0
	switch skill {
	case FIRST_COMBO ..= LAST_COMBO:
		bit = 1 << (skill - FIRST_COMBO)
		combo_count_use(int(skill - FIRST_COMBO))
	case FIRST_SPECIAL ..= LAST_SPECIAL:
		bit = 1 << (SPECIALS_BIT + skill - FIRST_SPECIAL)
	case:
		return
	}
	if config.battle_combos & bit != 0 {
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "combo %d seen", skill)
	}
	combos_add(bit)
}

// Mark combos as known (bits as in the config's `combos`) and save them.
@(private)
combos_add :: proc(bits: int) {
	config.battle_combos |= bits
	buf: [16]u8
	config_write({{"battle", "combos", strconv.write_int(buf[:], i64(config.battle_combos), 10)}})
}

@(private)
combos_draws :: proc() -> bool {
	return host.osd_panel_shown && host.osd_panel_page == PANEL_COMBOS
}

// Up and Down scroll the page a line.
@(private)
combos_select :: proc(pressed: u16) {
	if !combos_draws() {
		return
	}
	if pressed & host.PAD_UP != 0 {
		combos.top = max(combos.top - 1, 0)
	}
	if pressed & host.PAD_DOWN != 0 {
		combos.top += 1 // combos_draw clamps it to the last screenful
	}
}

@(private)
combos_draw :: proc() {
	lines: [COMBOS_LINES]Combos_Line
	n := 0
	add := proc(lines: []Combos_Line, n: ^int, text: string, colour, indent: int) {
		wrapped: [8]string
		for line in wrapped[:text_wrap(text, COMBOS_TEXT_W - indent, wrapped[:])] {
			if n^ < len(lines) {
				lines[n^] = {line, colour, indent}
				n^ += 1
			}
		}
	}
	seen := config.battle_combos
	add(lines[:], &n, INTRO, MENU_WHITE, 0)
	families := FAMILIES
	for family, f in families {
		n += 1 // a blank line between the parts
		add(lines[:], &n, family.head, MENU_YELLOW, 0)
		for name, level in family.names {
			shown := seen & (1 << uint(4 * f + level)) != 0
			add(lines[:], &n, shown ? name : "???", shown ? MENU_WHITE : MENU_GREY, 8)
		}
	}
	n += 1
	add(lines[:], &n, "Skills right after a combo", MENU_YELLOW, 0)
	specials := SPECIALS
	for special, i in specials {
		shown := seen & (1 << uint(SPECIALS_BIT + i)) != 0
		add(lines[:], &n, shown ? special[0] : "???", shown ? MENU_WHITE : MENU_GREY, 8)
		add(lines[:], &n, special[1], MENU_GREY, 16)
	}
	combos.top = clamp(combos.top, 0, max(n - COMBOS_ROWS, 0))
	menu_window(PANEL.x, PANEL.y, PANEL.z, PANEL.w)
	x := PANEL.x + COMBOS_PAD
	y := PANEL.y + COMBOS_PAD
	for line, row in lines[combos.top:min(n, combos.top + COMBOS_ROWS)] {
		menu_text(x + line.indent, y + row * MENU_LINE_H, line.text, line.colour)
	}
	foot := "Up/Down  Left/Right: Journal"
	if host.osd_panel_pages > PANEL_MASTERS {
		foot = "Up/Down  Left/Right: Journal, Masters"
	}
	menu_text(x, y + COMBOS_ROWS * MENU_LINE_H, foot, MENU_GREY)
}
