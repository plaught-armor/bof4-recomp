// Identify (skill 239), cut from the US release, has its scan screen intact
// in MAGIC239.EMI (overlay 211 at 0x801e6800). Its Data window (DATA_DRAW)
// shows the enemy's kind, name, HP, its resistances, EXP, zenny and items.
// The resistances were one kanji each in 12-pixel cells, coloured by level;
// the US strings put words there ("Fire", "Slash", ...), which run into each
// other, and the HP separator string is "?".
//
// While DATA_DRAW runs, the TEXT_DRAW calls it makes for those labels and the
// separator (known by their return addresses) are dropped, and the rows are
// drawn again in the same cells: icons from the menus' icon sheet, tinted by
// the original colour rule (weak red, normal grey, resists blue), and "/".
//
// No one learns the skill in the US release. With `[battle] identify`, Scias
// gets it among his own spells (record + 0x1e, 16 bytes, 0 empty) from level
// 3, as the fan patches give it: PARTY_SETUP fills the party combatants
// before the records are copied into them, so the record is given the spell
// just before, every battle.
package qol

import "core:fmt"

import "../psx"

@(private = "file")
IDENTIFY_SLOT :: 0x801e6800
@(private = "file")
IDENTIFY_ID :: 211
@(private = "file")
DATA_DRAW :: 0x801e9868
@(private = "file")
IDENTIFY_SKILL :: 239

@(private = "file")
PARTY_SETUP :: 0x801aec7c
@(private = "file")
SCIAS :: 3
@(private = "file")
RECORD_LEVEL :: 0x0a // u16
@(private = "file")
RECORD_SPELLS :: 0x1e
@(private = "file")
SPELL_SLOTS :: 16
@(private = "file")
SCIAS_LEVEL :: 3

// DATA_DRAW reads the window's place and the scanned combatant through the
// pointer at SCAN: s16 x at +8, s16 y at +10, s8 combatant index at +12.
@(private = "file")
SCAN :: 0x8011de24
// Nonzero: DATA_DRAW shows its "unknown" page instead (no resistances).
@(private = "file")
SCAN_UNKNOWN :: 0x8011deeb
// Resistance levels (0..7, 2 normal) in the current stat block: 4 attack
// kinds (slash, ranged, magic, dragon), then 8 elements (fire, wind, water,
// earth, holy, mind, status, death).
@(private = "file")
KIND_LEVELS :: 0xe6
@(private = "file")
ELEMENT_LEVELS :: 0xea
@(private = "file")
HOLY :: 4

// TEXT_DRAW return addresses in DATA_DRAW: the HP separator, then the label
// loops of the first row (4 elements, holy, 3 more) and the second (kinds).
@(private = "file")
DROPPED :: [?]u32{0x801e9a50, 0x801e9afc, 0x801e9b64, 0x801e9bec, 0x801e9c90}

// Cells, relative to the window: rows at +49 and +63, 12 pixels from x+6.
@(private = "file")
CELL_X :: 6
@(private = "file")
CELL_W :: 12
@(private = "file")
ELEMENT_Y :: 49
@(private = "file")
KIND_Y :: 63
@(private = "file")
SEPARATOR_X :: 60
@(private = "file")
SEPARATOR_Y :: 32

// The menus' icon sheet, texture page 15: skill icons at v 0xe8 and item
// icons at v 0xf4, 12x12, each row with its CLUT.
@(private = "file")
ICON_PAGE :: 15
@(private = "file")
ICON_SIZE :: 12
@(private = "file")
SKILL_ROW :: [3]int{0xe8, 208, 240} // v, CLUT x, CLUT y
@(private = "file")
WEAPON_ROW :: [3]int{0xf4, 224, 240}
// u of fire, wind, water, earth, holy, mind (swirl), status (down arrow),
// death (skull); of sword (slash), gun (ranged), rod (magic).
@(private = "file")
ELEMENT_U :: [8]int{216, 204, 192, 180, 228, 84, 120, 144}
@(private = "file")
KIND_U :: [3]int{36, 60, 72}

// The original's text colours by level, as tints and as font colours.
@(private = "file")
TINTS :: [3]u32{0x3838d8, 0x484848, 0xd88038} // weak, normal, resists
@(private = "file")
TEXT_COLOURS :: [3]int{MENU_RED, MENU_GREY, 3}

// No sheet icon fits dragon attacks, so a green Dragon Crystal (what gives
// Ryu his forms) is drawn into a blank spot of the icon page (rows 24..44 of
// page 15 are unused in battle) with its own CLUT beside it, a five-tone
// facet ramp and the sheet's dark outline. If either spot is taken, the
// word is drawn instead.
@(private = "file")
DRAGON_U :: 0
@(private = "file")
DRAGON_V :: 24
@(private = "file")
DRAGON :: [ICON_SIZE]string {
	"000000000000",
	"000001100000",
	"000013410000",
	"000134451000",
	"001344556100",
	"014444556610",
	"015555667710",
	"001554667100",
	"000154671000",
	"000016710000",
	"000001100000",
	"000000000000",
}
@(private = "file")
DRAGON_CLUT_X :: 976
@(private = "file")
DRAGON_CLUT_Y :: 24
// Transparent, outline, unused, then the crystal light to dark.
@(private = "file")
DRAGON_COLOURS :: [16]u32{0, 0x585858, 0, 0xd8f8d8, 0x78c878, 0x389848, 0x186030, 0x103820, 0, 0, 0, 0, 0, 0, 0, 0}
@(private = "file")
ICON_SHEET_X :: 960

@(private = "file")
identify: struct {
	draw:   psx.Func_Proc,
	text:   psx.Func_Proc,
	setup:  psx.Func_Proc,
	inside: bool, // DATA_DRAW is running
}

@(private)
identify_init :: proc() -> bool {
	draw, draw_ok := psx.hook_overlay(DATA_DRAW, IDENTIFY_SLOT, IDENTIFY_ID, data_draw)
	text, text_ok := psx.hook(TEXT_DRAW, text_draw)
	setup, setup_ok := psx.hook_overlay(PARTY_SETUP, SLOT_MENU, BATTLE_ID, party_setup)
	if !draw_ok || !text_ok || !setup_ok {
		fmt.eprintf("qol: identify function %08x / %08x / %08x not found\n", DATA_DRAW, TEXT_DRAW, PARTY_SETUP)
		return false
	}
	identify.draw = draw
	identify.text = text
	identify.setup = setup
	return true
}

@(private = "file")
party_setup :: proc() {
	record := char_record(SCIAS)
	if config.battle_identify && psx.lhu(record + RECORD_LEVEL) >= SCIAS_LEVEL {
		for slot in u32(0) ..< SPELL_SLOTS {
			spell := psx.lbu(record + RECORD_SPELLS + slot)
			if spell == IDENTIFY_SKILL {
				break
			}
			if spell == 0 {
				psx.sb(record + RECORD_SPELLS + slot, IDENTIFY_SKILL)
				break
			}
		}
	}
	identify.setup()
}

@(private = "file")
text_draw :: proc() {
	if identify.inside {
		dropped := DROPPED
		for ra in dropped {
			if psx.cpu.r[31] == ra {
				return
			}
		}
	}
	identify.text()
}

// 0, 1 weak; 2, 3 normal; 4.. resists. Holy's levels run two higher.
@(private = "file")
level_group :: proc(level: u32, holy: bool) -> int {
	l := holy ? int(level) - 2 : int(level)
	return l < 2 ? 0 : l < 4 ? 1 : 2
}

@(private = "file")
data_draw :: proc() {
	scan := psx.lw(SCAN)
	x := int(i16(psx.lhu(scan + 8)))
	y := int(i16(psx.lhu(scan + 10)))
	who := combatant(u32(i8(psx.lbu(scan + 12))))
	identify.inside = true
	identify.draw()
	identify.inside = false
	if psx.lbu(SCAN_UNKNOWN) != 0 {
		return
	}
	menu_text(x + SEPARATOR_X, y + SEPARATOR_Y, "/")
	tints := TINTS
	skill_row, weapon_row := SKILL_ROW, WEAPON_ROW
	element_u := ELEMENT_U
	for u, i in element_u {
		group := level_group(psx.lbu(who + ELEMENT_LEVELS + u32(i)), i == HOLY)
		menu_sprite(x + CELL_X + i * CELL_W, y + ELEMENT_Y, ICON_SIZE, ICON_SIZE, u, skill_row[0], ICON_PAGE, skill_row[1], skill_row[2], tints[group])
	}
	kind_u := KIND_U
	for u, i in kind_u {
		group := level_group(psx.lbu(who + KIND_LEVELS + u32(i)), false)
		menu_sprite(x + CELL_X + i * CELL_W, y + KIND_Y, ICON_SIZE, ICON_SIZE, u, weapon_row[0], ICON_PAGE, weapon_row[1], weapon_row[2], tints[group])
	}
	group := level_group(psx.lbu(who + KIND_LEVELS + len(kind_u)), false)
	dragon := DRAGON
	dragon_x := x + CELL_X + len(kind_u) * CELL_W
	if texels_place(ICON_SHEET_X, DRAGON_U, DRAGON_V, dragon[:]) && clut_place(DRAGON_CLUT_X, DRAGON_CLUT_Y, DRAGON_COLOURS) {
		menu_sprite(dragon_x, y + KIND_Y, ICON_SIZE, ICON_SIZE, DRAGON_U, DRAGON_V, ICON_PAGE, DRAGON_CLUT_X, DRAGON_CLUT_Y, tints[group])
	} else {
		colours := TEXT_COLOURS
		menu_text(dragon_x + 4, y + KIND_Y, "Dragon", colours[group])
	}
}
