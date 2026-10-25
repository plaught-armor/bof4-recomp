// Saving: the camp menu's Save anywhere, and autosave.
//
// Save anywhere. The camp menu (SGAMEN.EMI, slot 0x801aa000) enables its
// Save command only where AREA_KIND(map) returns 1, which FLD_MAIN answers for
// the world map alone; elsewhere the command is drawn greyed and confirming
// it buzzes. AREA_KIND serves many other callers, so the hook answers 1 only
// to the two camp menu call sites. Choosing Save then runs the game's own save
// screen (SAVE.EMI), which already stores the current map, the leader's
// position and facing and the camera yaw, so loading resumes where the party
// stood.
//
// Autosave. Each time the party enters a different field map and the player
// has had control for AUTOSAVE_SETTLE, the save is written to the memory card
// in slot 2, as save number `autosave_slot`, so manual saves on card 1 are
// never touched. The save data comes from the game's own builder, SAVE_BUILD
// in SAVE.EMI: its image is copied over the shared overlay slot, SAVE_BUILD
// runs on the save buffer, and everything it changed is put back:
//   - RAM of the overlay slot (SAVE.EMI is not resident in the field);
//   - the save-screen slot byte, set to the autosave number;
//   - the game region (SAVE_BUILD stores the resume position into it);
//   - the CPU registers.
// SAVE_BUILD fills the 0x180-byte card header (title, icon, summary) and
// copies the game region after it; the checksum is the XOR of all bytes before
// SAVE_CHECKSUM, as the save screen computes it. The icon is the one exception:
// SAVE_BUILD reads it from VRAM, where only the save screen uploads it, so the
// header gets the save number's icon from SAVE_ICONS (extracted from the disc
// by `bof4tools emi-extract`) instead.
package qol

import "core:fmt"

import bios "ps:psx/bios"
import cpu "ps:psx/cpu"

import "ps:core"

@(private = "file")
MAP_KIND_WORLD :: 1

// Return addresses of the camp menu's AREA_KIND calls: confirming a command,
// and drawing the Save command enabled or greyed.
@(private = "file")
CAMP_CONFIRM_RA :: 0x801aa40c
@(private = "file")
CAMP_DRAW_RA :: 0x801ab668

@(private = "file")
NO_MAP :: 0xffff
@(private = "file")
LEADER_OBJ :: 0x80116fb0 // the controlled object, as SAVE_BUILD reads it
@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
STATE_PLAYER_CONTROL :: 1

// Vblanks of continuous player control before an autosave, so a map entered
// in passing (a door straight into a cutscene) is not saved mid-fade.
@(private = "file")
AUTOSAVE_SETTLE :: 30

@(private = "file")
SAVE_EMI :: #load("../../../overlays/ov_801aa000_023.bin")
@(private = "file")
SAVE_EMI_SIZE :: 36104
@(private = "file")
SAVE_BUILD :: 0x801acb44 // builds the save at SAVE_BUFFER
@(private = "file")
SAVE_BUFFER :: 0x801af438
@(private = "file")
SAVE_SIZE :: 0x1880
@(private = "file")
SAVE_CHECKSUM :: 0x184f // u8, XOR of the bytes before it
@(private = "file")
SAVE_SCREEN_SLOT :: 0x8011bfb2 // u8, save number 0..14 the save screen uses
@(private = "file")
GAME_REGION :: 0x8011a94c
@(private = "file")
GAME_REGION_SIZE :: 0x1650
@(private = "file")
SAVE_NAME :: "BASLUS-01324BOF4%02dUS"
@(private = "file")
SAVE_ICONS :: #load("../../../overlays/save_icons.bin") // one per save number
@(private = "file")
SAVE_ICON :: 0x80 // offset of the 16x16 4-bit icon in the header
@(private = "file")
ICON_SIZE :: 0x80

@(private = "file")
save: struct {
	map_kind:   cpu.Func_Proc,
	field:      cpu.Func_Proc,
	// Map of the last autosave, and the map and vblank where the current
	// stretch of player control began.
	saved_map:  u32,
	control_at: u64,
	control_on: u32,
	// RAM put back after building an autosave.
	slot_ram:   [SAVE_EMI_SIZE]u8,
	region:     [GAME_REGION_SIZE]u8,
	data:       [SAVE_SIZE]u8,
}

@(private)
save_init :: proc() -> bool {
	save.map_kind = hook_field(AREA_KIND, map_kind) or_return
	if len(SAVE_EMI) != SAVE_EMI_SIZE {
		fmt.eprintfln("autosave: SAVE.EMI image is %d bytes, expected %d", len(SAVE_EMI), SAVE_EMI_SIZE)
		return false
	}
	if len(SAVE_ICONS) != MAX_SAVE_SLOT * ICON_SIZE {
		fmt.eprintfln("autosave: save_icons.bin is %d bytes, expected %d", len(SAVE_ICONS), MAX_SAVE_SLOT * ICON_SIZE)
		return false
	}
	save.saved_map = NO_MAP
	save.control_on = NO_MAP
	save.field = hook_game_mode(MODE_FIELD, field_tick) or_return
	return true
}

@(private = "file")
map_kind :: proc() {
	c := &cpu.state
	ra := c.r[31]
	map_id := c.r[4]
	save.map_kind()
	if !config.save_anywhere || ra != CAMP_CONFIRM_RA && ra != CAMP_DRAW_RA || c.r[2] == MAP_KIND_WORLD {
		return
	}
	if ra == CAMP_CONFIRM_RA && .Game in core.trace.active {
		core.tracef(.Game, "save: camp menu on map %04x (kind %d), save allowed", map_id & 0xffff, c.r[2])
	}
	c.r[2] = MAP_KIND_WORLD
}

@(private = "file")
field_tick :: proc() {
	save.field()
	map_id := u32(cpu.lhu(FIELD_MAP))
	in_control :=
		cpu.lhu(GAME_MODE) == GAME_MODE_FIELD &&
		cpu.lbu(LEADER_OBJ + OBJ_STATE) == STATE_PLAYER_CONTROL &&
		map_id != NO_MAP
	now := cpu.vblanks()
	if !in_control {
		save.control_on = NO_MAP
		return
	}
	if save.control_on != map_id {
		save.control_on = map_id
		save.control_at = now
	}
	// With autosave off, the map counts as saved, so turning it on saves
	// from the next map on.
	if !config.autosave {
		save.saved_map = map_id
	}
	if map_id == save.saved_map || now - save.control_at < AUTOSAVE_SETTLE {
		return
	}
	save.saved_map = map_id
	autosave(map_id)
}

@(private = "file")
autosave :: proc(map_id: u32) {
	number := config.autosave_slot - 1
	build_save(number)
	name := fmt.tprintf(SAVE_NAME, number)
	if !bios.card_write_file(bios.CARD_SLOT_2, name, save.data[:]) {
		fmt.eprintfln("autosave: writing %s to the slot 2 card failed", name)
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "save: autosaved map %04x as %s on card 2", map_id, name)
	}
}

// Run SAVE_BUILD for save `number` and copy the finished save to save.data,
// leaving the emulated machine as it was.
@(private = "file")
build_save :: proc(number: int) {
	regs, hi, lo := cpu.state.r, cpu.state.hi, cpu.state.lo
	slot_ram := cpu.mem_slice(SLOT_MENU, SAVE_EMI_SIZE)
	region := cpu.mem_slice(GAME_REGION, GAME_REGION_SIZE)
	copy(save.slot_ram[:], slot_ram)
	copy(save.region[:], region)
	screen_slot := cpu.lbu(SAVE_SCREEN_SLOT)

	copy(slot_ram, SAVE_EMI)
	cpu.sb(SAVE_SCREEN_SLOT, u32(number))
	cpu.call(SAVE_BUILD)
	buf := cpu.mem_slice(SAVE_BUFFER, SAVE_SIZE)
	icons := SAVE_ICONS
	copy(buf[SAVE_ICON:SAVE_ICON + ICON_SIZE], icons[number * ICON_SIZE:][:ICON_SIZE])
	x: u8 = 0
	for b in buf[:SAVE_CHECKSUM] {
		x ~= b
	}
	buf[SAVE_CHECKSUM] = x
	copy(save.data[:], buf)

	copy(slot_ram, save.slot_ram[:])
	copy(region, save.region[:])
	cpu.sb(SAVE_SCREEN_SLOT, u32(screen_slot))
	cpu.state.r, cpu.state.hi, cpu.state.lo = regs, hi, lo
}
