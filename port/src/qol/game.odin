// Game addresses more than one feature uses. A feature's own addresses stay
// in its file; one that a second feature starts using moves here, so each
// address has one name (docs/address-map.md is built from these).
package qol

import "ps:psx"

// Overlay slots (docs/overlays.md); each hook names its overlay id itself.
SLOT_GAME :: 0x8018d800 // SYSTEM/GAME.EMI, id 0x0e: main loop, item/skill/growth tables
SLOT_MENU :: 0x801aa000 // menus, and the battle glue (BWORLD, id 0x32)
SLOT_ENGINE :: 0x801cc800 // FLD_MAIN (id 0x0f), and battle command/move/end 0x33..0x36
BATTLE_ID :: 0x32 // the battle glue in SLOT_MENU; an overlay's first word is its id

// Game state.
GAME_MODE :: 0x80114850 // u16: 1 loading, 2 field, 4 event, 5 battle, 6 camera turn, 7 shop
PLAY_HOURS :: 0x8011ad90 // u32
PLAY_MINUTES :: 0x8011ad94 // u8
CHAR_RECORDS :: 0x8011a94c // the character records, name at +0; char_record() finds one
CHAR_RECORD_SIZE :: 0x98
CHAR_COUNT :: 7
RECORD_HP_MAX :: 0x38 // u32, after equipment and KO marks
PARTY_SLOTS :: 0x8011ad88 // u8 record index per slot, EMPTY_SLOT when empty
PARTY_SLOT_COUNT :: 6
EMPTY_SLOT :: 0xff
ZENNY :: 0x8011ad80 // u32
RAND :: 0x8016f384 // v0 = the game's next random number
RECOMPUTE :: 0x801961b4 // GAME.EMI, no arguments: STAT_REBUILD for each party slot
TEXT_BOX :: 0x8011decc // u32 pointer to the active message box; +0 is its state
MESSAGE_TEXT :: 0x8014c0dc // a0 message id; v0 its text (id >> 13 picks the bank, 2 the item descriptions at 0x80017000)

// The play time a feature last saw, for play_time_jumped.
@(private)
Play_Clock :: struct {
	read:    bool,
	minutes: u32,
}

// Field map.
MAP_ID :: 0x80116bc4 // u16, the map loaded
FIELD_MAP :: 0x8011c944 // u16, the map the field runs (until a request's map loads, the one left); AREA_KIND's argument
MAP_SECTION :: 0x8011c946 // u16 (most read the low byte), the section: the index of its first layer descriptor
MAP_BLOCK :: 0x8011c954 // u32, the map's data block
AREA_KIND :: 0x801d91f0 // FLD: a0 FIELD_MAP; v0 1 on the world map / where the party may save
PARTY_OBJ :: 0x80116fb0 // the party's field objects, 0xfc bytes each
NPCS :: 0x801172b0 // the people; u8 +0 0 when free
NPC_SIZE :: 200
NPC_COUNT :: 32
SPAWN :: 0x801dfdbc // FLD: the map's spawn script, for the section at MAP_SECTION
SPRITE_PACKETS :: 0x80116cc0 // u32, the next free byte of this frame's prim pool

// Field camera and frame.
CAMERA_YAW :: 0x8013818e // u16, 0x1000 = full circle
CAM_TARGET :: 0x801381a4 // s16 x, y, z, the point the view centers on, 256 a cell
CAM_MATRIX :: 0x801381bc // s16 3x3, the view's rotation (0x1000 = 1); row 2 is forward
CAM_TR :: 0x801381d0 // s32 x3, the view's translation
VIEW_BUILD :: 0x8014307c // a0 = view center; builds the view matrix from the camera
FRAME_END :: 0x80139ba8 // links the layer chains into the ordering table
FRAME_END_RET :: 0x801397c0 // the return address of the main loop's FRAME_END call
FIELD_DRAW :: 0x801cccbc // FLD_MAIN: map draw for the field frame
SCENE_DRAW :: 0x801420a4 // objects, sprites and map layers
// `jal SCENE_DRAW`, the instruction a frame body places right after its
// first draw call (the scene render's own delay slot follows it).
JAL_SCENE_DRAW :: 0x0c000000 | (SCENE_DRAW & 0x0fffffff) >> 2
SPRITE_DRAW :: 0x8014193c // a0 = sprite record: one field sprite into the OT, 0x2C quads built on the CPU from the anchor at +4/+6 and offsets scaled by +16/+20 (>> 16)
LAYER_DRAW :: 0x80145654 // the layer at DRAW_LAYER: map geometry into the OT
MODELS_DRAW :: 0x80145674 // the placed models of DRAW_LAYER (SC_LAYER)
DRAW_OTAG_ENV :: 0x8016c034 // a0 = ordering table, a1 = DRAWENV
MAIN_DRAW_RET :: 0x8013971c // the main loop's DrawOTagEnv call

// Hooks on one address chain: psx.hook hands each hook the one installed
// before it as its original, so the hook installed last (later in init's
// chain in config.odin) runs first. The chains on shared addresses, first
// to run on the left; reordering init changes them.
//   VIEW_BUILD     interiors > shake > third_person > game
//   FRAME_END      inbetween > menu_draw > game
//   DRAW_OTAG_ENV  interiors > inbetween > game
//   LAYER_DRAW     interiors > sections > game
//   MODELS_DRAW    sections > map_geometry > game
//   MESSAGE_TEXT   descriptions > teacher > game

// Battle.
// Battle flow state, a byte each: phase, sub-phase, step, sub-step. The
// battle's per-frame entry (0x801aa7b4, in SLOT_MENU) dispatches the phase
// through the table at 0x801c5e30; each handler dispatches its sub-phase the
// same way, and so on down.
BATTLE_STATE :: 0x8011ded4
ACTION :: 0x8011e0c0 // the acting combatant's action: u8 +0 actor (6 and up an enemy), u16 +2 skill
// Combatant ids (ACTION +0, a hit's target): below ENEMY_IDS the party's
// slots, then the enemies; combatant() finds either.
ENEMY_IDS :: 6
PARTY_COMBATANTS :: 0x801c79b8
PARTY_COMBATANT_SIZE :: 0x1a4
ENEMY_COMBATANTS :: 0x801c6ec0
ENEMY_COMBATANT_SIZE :: 0x1c8
COMBATANT_HP :: 0xb0 // u32, party and enemy alike
COMBATANT_HP_MAX :: 0xd4 // u32, the live max HP; the HP gauge (0x801c37e8) clamps HP to it
SKILL_DATA :: 0x8019add0 // 12 bytes per skill id

@(private)
party_combatant :: proc(member: u32) -> u32 {
	return PARTY_COMBATANTS + member * PARTY_COMBATANT_SIZE
}

@(private)
enemy_combatant :: proc(slot: u32) -> u32 {
	return ENEMY_COMBATANTS + slot * ENEMY_COMBATANT_SIZE
}

@(private)
combatant :: proc(id: u32) -> u32 {
	return enemy_combatant(id - ENEMY_IDS) if id >= ENEMY_IDS else party_combatant(id)
}

// Whether this is a different game from the one the clock last saw (a save
// loaded, a new game, or the first read): play time only moves forward a
// minute at a time.
@(private)
play_time_jumped :: proc(clock: ^Play_Clock) -> bool {
	minutes := psx.lw(PLAY_HOURS) * 60 + psx.lbu(PLAY_MINUTES)
	jumped := !clock.read || minutes < clock.minutes || minutes - clock.minutes > 1
	clock^ = {true, minutes}
	return jumped
}

@(private)
char_record :: proc(index: u32) -> u32 {
	return CHAR_RECORDS + index * CHAR_RECORD_SIZE
}
