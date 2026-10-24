# Field maps

Everything on this page is about walking around: towns, dungeons, interiors.
Field logic lives in the executable and in FLD_MAIN (overlay id 15 at
0x801cc800); map-specific scripts are in the map's own overlay at 0x801f0800.
The game is in field mode when `GAME_MODE` (u8 0x80114850) is 2.

## Map state

| Address | Size | Content |
|---|---|---|
| 0x8011c944 | u16 | current map id (see [story-and-maps.md](story-and-maps.md)) |
| 0x8011c946 | u8 | current section of the map (its first layer) |
| 0x80116bc4 | u16 | map whose data is loaded |
| 0x8011c954 | ptr | map data block (collision and layer tables) |
| 0x80116fac | u8 | HUD shown (the compass in the top-left) |

## Collision grid

All offsets below are relative to the map data block at `[0x8011c954]`.

| Offset | Content |
|---|---|
| +0 | u8 grid count; grid header offsets (u32) start at +4 |
| +2 | u8 attribute array count; offsets at +0xa4 |
| +3 | u8 layer count; layer descriptors at +0xc4 |

A layer's descriptor index is the section (0x8011c946) plus the layer number.
Descriptor byte 0 is the grid header index, byte 1 the attribute array index.

- Grid header: u16 width, u16 height. The grid has `width*2` by `height*2`
  cells.
- Attribute array: one byte per cell, row stride `width*2`. Reads outside the
  grid return 0x10 (wall).
- Attribute high nibble ("kind"): 0x10 wall (0x11 a variant), 0xa0-0xa2
  exit, 0x70 and 0xc0 stairs or slopes. Kind 0x20 cells are levels told
  apart by bit 0 (a balcony rail next to the stairs below it). Kind 0xc0 is
  a stair to another layer: leaving it toward direction `(attr & 3) * 2`
  (the 8-direction index, 0 = -z, clockwise) changes layer. The rest of the
  low nibble is not decoded.
- The grid has no heights. Ledges and drops look open; ground height comes
  from the geometry.

Whether a step from cell attribute a to cell attribute b is allowed (FLD_MAIN
0x801d5c74; `step_allowed` in `qol/autoplay.odin` ports it):

- b is 0x10, 0x12, 0x13, 0x30, 0x50, 0xa3, 0xff or of kind 0x40: blocked.
- b is 0xa4: blocked while bit 0x200 of u16 0x801172aa is set.
- Paired edges, both ways: 0x2f with kind 0xa, 0x2e with kind 0xb, 0x2d with
  kind 7, 0x2c with kind 0xe, 0x2b with kind 0xc: blocked.
- a 0xa3 to kind 7, and kind 7 to 0x2d or 0xa3: blocked.
- kind 2 to kind 2 with different bit 0: blocked.

`PASSABLE` (FLD 0x801d60f8, `(from object, to object, flags)`, 1 = allowed)
wraps that test for one step of an object:

- Bit 0x80 of u16 0x801172aa set: every step is allowed.
- a is the attribute under `from` on its layer (object +2 x, +10 z, +12
  layer), b the one under `to` on its layer. b = 0x11 or 0xf0..0xf2 is
  blocked, then the edge test above (0x801d5c74) must pass.
- Unless flags & 2 is set, the ground at both ends must be within one unit
  (0x10000 in 16.16) of each other (0x801d5fec: two `GROUND` calls at the
  cell corners; a destination of 0xa4 or 0x11 always passes).
- A step along one axis is then allowed. A diagonal also has to clear both
  cells it cuts across (0x801d5e60): the side cell may not close a ramp edge
  against b (the same paired edges as above, kind 7 against kind 7, 0x2d or
  0xa3, kind 2 against kind 2 with different bit 0), the step from a onto it
  must pass the edge test, and its ground must meet the start's.
- From a kind 0xc0 stair cell the side cells are looked up on the stair's
  own layer, except the one that is where the stair leads (`NEXT_POS`
  0x80153a3c in direction `(attr & 3) * 2`), which is on the destination's.

| Function | Address | Arguments |
|---|---|---|
| attribute lookup | exe 0x801537f0 | (x, z, layer) |
| attribute write | exe 0x801538c4 | |
| `GROUND` ground height | exe 0x8014a8a0 | (a0 position s32 16.16 x/y/z, a1 layer) |

Gotcha: `GROUND`'s callees overwrite scratchpad 0x1f800000..0x1f8000ab,
including the GPU packet pointer at 0x1f80006c. Calling it from a hook in the
middle of drawing needs that range saved and restored.

The port runs the ground and step code natively (`qol/collision.odin`):
`GROUND_CORE` 0x8014a9cc (placed models first, then the tile's polygons, then
its heightfield quad), the attribute lookup and write, and `PASSABLE`. Each
leaves the same RAM, scratchpad words and v0 as the game, and knows the
emulated cycles it takes (charged only under `BOF4_MAPCHECK` and old
replays, like the drawing below); `BOF4_MAPCHECK=1` checks them along with the drawing (for
`PASSABLE` the stack the game's frame used, 0x400 bytes below the caller's
`sp`, is left out of the comparison). `PASSABLE` still calls the game's
`GROUND` and `NEXT_POS` for its sub-steps, so it restores the caller's `sp`
and `ra` afterwards. Not reached by any test so far: the lit-triangle path of
`GROUND_CORE` (0x8014b53c..b68c), the 0xa4 wall flag, kind 7 side cells and
the second stair side cell; they are ported from the disassembly only.

## Objects

Field objects (party members, the leader) are 0xfc-byte records from
0x80116fb0. The leader is `0x80116fb0 + u8[0x801172af] * 0xfc` (computed
like this by FLD_MAIN at 0x801cd178), not always object 0; `leader_obj()` in
`qol/movement.odin` does the same. Save building still reads object 0.

| Offset | Content |
|---|---|
| +4 | u8 state: 1 has control, 2 exit walk (out or in), 8 idle stretch |
| +5 | u8 sub-state (a u16 read at +4 picks it up by mistake) |
| +12 | position: s32 x (16.16) at +0, s32 height +4, s32 z +8, u8 layer +12 |
| +84 | sprite record (see [graphics.md](graphics.md)) |

One collision cell is 0x10000. Walking moves 0x2000 per game frame, dashing
0x4000. Direction deltas (8 directions) are s8 (dz, dx) pairs at exe
0x80174944.

## NPCs

NPCs live in a pool of 32 slots, 200 bytes each, at 0x801172b0. Slot byte 0
non-zero = in use (bit 1 visible, bit 3 sprite); the position struct has the
same layout as objects. A second pool at 0x801192cc holds model objects: 32
slots of 156 bytes, position at +12 and sprite record at +84 like the others.
SPAWN fills both pools. Byte 0 bit 2 marks a model: such objects are listed at
0x80116d98+268 (count u32 at +528) and drawn by `MODEL_OBJECTS_DRAW` (exe
0x80145958, called from `SCENE_DRAW` at 0x8014236c), which builds packets at
the scratchpad packet pointer 0x1f80006c. Bit 3 marks a sprite, bit 7 off
screen.

| Function | Address | What |
|---|---|---|
| `SPAWN` | FLD 0x801dfdbc | fills the NPC pool for the current section |
| `NPC_UPDATE` | FLD 0x801da4b0 | runs every NPC slot's script and movement once (only the 32-slot loop) ; scripts draw random numbers from the BIOS rand() (A0:2F, stub exe 0x8016f384), whose seed the port keeps host-side (`psx.rand_seed`) |
| `ANIM_STEP` | exe 0x80152bb4 | a0 = sprite record (obj+84): one animation step |
| `COLLECT` | exe 0x80141f1c | project an object for drawing |
| `PASSABLE` | FLD 0x801d60f8 | object-collision probe for a step |

### Spawn lists

The map overlay (loaded at 0x801f0800) starts with a header: +0 points to
the per-section exit lists, +16 to the spawn list, +32 to the script table
(indexed by spawn record byte 12). `SPAWN` reads the header's spawn list
(header pointer at 0x80116be8) and runs it through the list runner FLD
0x801dfde8 (a0 the list; it keeps its read pointer at 0x801e34b4):

| Byte | Meaning |
|---|---|
| 0..239 | a record of that type: handler table 0x801e3428, length table 0x801e3408 (the length counts the type byte) |
| 240..247 | a condition (table 0x801ccbb0; flag and expression test 0x801e1288, 20 kinds through 0x801ccbe0, e.g. story flags 0x8011b7c0, the section 0x8011c946) |
| 248 | a nested block (0x801e0020) |
| 255 | the end |

| Type | Length | What |
|---|---|---|
| 0..6, 20, 21 | 13 | an NPC: create 0x801e0854 (type 1 0x801e0944); 4 is a special kind |
| 7 | 12 | |
| 8 | 7 | |
| 9 | 10 | |
| 10..12 | 20 | |
| 13 | 3 | |
| 14..19 | 2 | |

NPC create allocates a slot (0x801e1610, 0 when the pool is full) and calls
NPC init FLD 0x801e0598 (a0 the slot, a1 the record), which copies the
record's fields and keeps no pointer to it:

| Record byte | Meaning |
|---|---|
| 0 | type |
| 1..2 | u16 sprite id, 0xffff none (looked up in the map's sprite table) |
| 3, 4 | tile x, z |
| 5 | low nibble: facing / height |
| 6 | animation |
| 7 | move kind (0 stands, keeping x/z at slot +184/+188; most townsfolk 1) |
| 8, 9 | flags |
| 10..11 | u16 message id into slot +192: 0xffff none, bit 15 an event |
| 12 | script index into slot +186; slot +176 becomes the script pointer (the entry at that index of the map's script table, header +32) |

Init also sets slot +196 (`+0xc4`) bit 0 when the message id is not 0xffff
and +194 bit 3 is clear (the NPC can be talked to). Bit 1 holds the NPC
still: the random walk FLD 0x801db45c (per object at `[0x801e3494]`) skips
a slot with +0x4e set or +196 bit 1, else draws `RAND` against the table at
0x801e33f4 (by +9) and starts a step (0x801db2c8 sets +4 = 4, walking).
Sarai's dog's script sets bit 1; with move kind 0 alone an NPC still wanders.

Sarai's dog (AREAM000, record at 0x801f248d): `00 7c 00 22 11 00 80 00 01
82 12 00 03` (sprite 0x7c, tile 34,17, standing, message 0x0012, script 3).
`BOF4_NPC_SPRITE` (debugging.md) prints every NPC init and can swap sprites.

The map's sprite table is its area EMI entry 0, loaded at 0x8004e000: a u32
count, then 8-byte entries {u16 sprite id, u16 slot, u16 VRAM (low byte the
texture page x / 64, high byte the v offset), u16 0}. Sprite lookup exe
0x80153260 (a0 sprite record, a1 id) searches it. Sprite 7 is in 372 of the
373 maps (a shared object, not a person).

### Talking

FLD 0x801dac08 handles the NPC the leader faces (`[0x801e3494]`): it needs
slot +194 bit 3 clear and a message id at +192 other than 0xffff. With bit 15
set the id is an event (0x801daac0); otherwise `SHOW_MESSAGE` exe 0x8014c090
shows it and the field state 0x80114870 becomes 2. `SHOW_MESSAGE` looks the
text up with `MESSAGE_TEXT` exe 0x8014c0dc (a0 the id, v0 the text; banks in
[text-and-ui.md](text-and-ui.md#messages)), stores the id at 0x8011de2c+8 and
the text at +12/+16, opens the box (0x8014c1ac with 0) and clears
0x8011ded0.

Shopkeepers and the inn are slot types the talk handler checks first (only
when byte 0x8011a8fc+6 is not 255):

| Slot +1 | What | Effect |
|---|---|---|
| 5 | shop | 0x8011a8fc+12 = 1, 0x8011a909 (the shop index) = slot +186, +14 = slot +2; field state 6, then 0x8018f880(2). The GAME overlay's field-state dispatch 0x8018e068 (jump table 0x8018d804, 11 entries) turns state 6 into GAME_MODE 7, the shop |
| 21 | Manillo fish trade | same writes, field state 9: GAME_MODE 10, the MSHOP overlay (0x13); slot +186 is the Manillo index |
| 6 | inn | +12 = 0, field state 7 (GAME_MODE 8); 0x801dae4c copies slot +186 to 0x8011a909 and prices the stay from the table at 0x801a1080 |

Slot +186 comes from spawn record byte 12 (copied by the NPC init 0x801e0598;
for other types the byte is the script index) or from script op 0xa0 (handler
0x801df77c, ops dispatched through 0x801cc8cc by op - 1): `a0 TT SS II` sets
slot +1 = TT, +4 = SS, +186 = II, so a script can turn any NPC into a
shopkeeper. Ops 32, 34, 44, 28, 46, 47 and 95 use +186 as a step counter.
Only FLD writes 0x8011a909. Which map opens which shop:
[battle.md](battle.md#shops-by-map). The faerie village builds its shop
NPCs itself (overlay 0x800f8800 id 27, ~0x800fbc90): building kind 4 is an
item shop, slot type 5 with index 6 + byte 0x8011b9fe (flags +192 = 0x800e),
kind 5 the equipment shop, index 12 + that byte (+2 = 16, +192 = 0x800f),
kind 6 the inn. The byte picks one of four stock lists (0..3).

### Combo dog

`qol/teacher.odin` (`[field] teacher`) makes a travelling dog the combo
teacher, and in four world map "?" scenes he teaches the specials.
`MESSAGE_TEXT` is hooked, and on a stop's map and section the dog's
message id returns lesson text the port writes at 0x80016c00 (free: past the
longest bank 0 text, 0x80010000 + at most 0x5f6d, and before bank 2's table
at 0x80017000). Talking teaches the four combos of the stop's level
(`[battle] combos` bits) and lists them; once they are known the dog just
sends the party on. The camp Journal's "Combo dog" line names the last stop
whose lesson the party knows and the next one, and after the first lesson
the first scene whose special is still to learn (`teacher_journal`, read
from the combo bits, no state of its own).

Stops (`STOPS`): Sarai (1000, level 1) uses the town's own dog (message
0x0012, face code `17 09 06`). Synesta (1002, level 2, tile 24,23), Wyndia
(1009, level 3, tile 14,13) and Shyde (1021, level 4, tile 18,15) get one
added, message 0x0fff:

- **Sprite.** Sarai's dog (sprite 0x7c) is read from AREAM000 on the disc:
  its sheet (64 halfwords x 136 rows, from the type 3 sprite sheets entry,
  32x32-halfword tiles from VRAM 384,0, 14 across), its CLUT and its
  animation bank. The map's sprite table (area entry 0 at 0x8004e000: u32
  count, then 8-byte entries {u16 sprite id, u8 slot, u8 0, u8 page x / 64,
  u8 v, u16 0}) gets an entry for him. An entry's index picks its animation
  bank in the table at `[0x8011a84c]` (u32 offsets from the table, area entry
  1), so that table is rebuilt at 0x8004b000 with his bank after it. Its slot
  picks its CLUT: RAM 0x80038200 + slot * 32, VRAM row 496 + (slot + 16) / 16.
  The sheet goes on a texture page the town leaves empty (Synesta page 5,
  v 112; Wyndia and Shyde page 0xb).
- **Spawn.** The `SPAWN` hook (0x801dfdbc, the map's spawn script) runs a
  13-byte NPC record of ours (at 0x8004e7f0, 0xff after it) through
  `SPAWN_LIST` (0x801dfde8) after the map's own. The record's script byte
  indexes the map's script table, which in a scene may be short or absent
  (084b's table pointer is 0), so it is 0 and the slot's script pointer is
  then cleared: no script runs. Without a script he would wander (move
  kind 0 is not enough), so `dog_hold` sets slot +196 bit 1 each field
  frame (NPC init runs after the spawn list and rewrites it).
- **VRAM is stale at spawn.** The town's load writes its sheets after the
  spawn script, so `field_tick` puts the sheet, CLUT and portrait back each
  field frame they differ (through `psx.vram_put`).
- **Portrait.** AREAM006 face 2 (the brown dog) goes into face cell 24 of the
  face sheet at 960,256 (VRAM 962,448), past every town's faces, with its
  CLUT at 240,255 (CLUT byte 0x1f), a row the towns leave free: text code
  `17 18 1f`.

Scenes (level 0, `special` 0..3; tile, page 0xb): a house in the woods
(0807, Phoenix, 27,13), a desert camp (0832, Mudslide, 16,15), a forest path
(0830, Ice Sword, 9,51), a beach (084b, Reflect, 17,82). Talking names the
special and gives its recipe ("Who can make it after First then Second",
from `special` in combos.odin) and sets its `[battle] combos` bit. The scenes
load battle-magic data only into VRAM rows 256..320 of 0x1e080200, so the
portrait cell (962,448, stale magic data there) is safe to overwrite.

Testing: the autoplay pulses confirm while a box is open; after a `goto` to
the dog, `pulse off` and `press cross 1` per page (a long press lets
`hold_to_advance` flip every page at once). The early-story test save has
no control in Synesta (the party is not placed there), so that stop is only
checked by the spawn trace (`BOF4_NPC_SPRITE=0:0` lists `npc sprite 7c at
24,23`). `combos_add` writes the config file, so give each run a fresh
copy of it. The autoplay also answers a box in state 2 as a choice, which
flips the dog's pages on its own; snap every few frames to see them.

## Scripts

An object's script runs in FLD's interpreter (0x801dc798, called per object
from 0x801d7cf8 and for the object at `[0x801e3494]` from 0x801db9c0). The
script pointer is the object's u32 +0xb0 (176); map scripts sit in the map's
overlay at 0x801f0800. An opcode byte below 192 jumps through the table at
0x801cc8cc (161 entries, opcodes 1 to 161, index op - 1); 192 and up go to
0x801df82c. Handlers go back to the loop at 0x801df7d0.

| Op | Handler | Bytes | What |
|---|---|---|---|
| 0x5b | 0x801ddfc0 | 9 | map request: +1 u16 map, +3 section, +4 s16 x, +6 s16 z (256 a cell), +8 facing. `AREA_SET` (0x801cfe5c), the camera yaw (`[0x80138168 + 38]`) into the kept yaw 0x8011c948, then `MAP_REQUEST` (0x801cf598) |
| 0x0d | | 3 | +1 u16 message id: `SHOW_MESSAGE`, field state 0x80114870 = 2 |
| 0x0f | | 2 | +1 index: call the map's native function `[header + 0x24][index]` (a0 the object) |
| 0xc0 | 0x801df82c | | sets the +0xbc timer |
| 0xc4, 0xc6..0xcf | 0x801dfcb0 | 1 | halt: returns without advancing (ops 192 and up first return if +0x4e is set; table 0x801ccb54) |
| 0x89 | 0x801df18c | 2 | back to the world map: kept yaw 0x200, `AREA_SET(0x805, 0)`, `MAP_REQUEST(0x805, 0, [0x80120dd4], [0x80120dd6], +1)` |

`MAP_REQUEST` is also called by `EXIT_CHECK` (0x801d5c30) and by overlay
code (0x8018dd90, 0x801f8b70, 0x801f8d00). Byte scanning every map overlay
finds about 120 op 0x5b requests (a scan, so a few may be data): about half
arrive at 0, 0, leaving the placement to the destination's setup, the rest
at a cell. Sarai's (1000 and its rooms) overlays have none. Town and room
pairs with one: 1002 to 020b.4/020b.7 (seven, with arrivals) and to 022e.1
(three, 0, 0), 1029 to 020b (four), 101e to 0223.2 (two), 102e to 021e.0,
0205 to 1001.0 (two), 020b to 1002.0, 020e to 1007.0 (three); at 0, 0: 1005
to 020a.2, 1006 to 0214.1, 1014 to 0224.0, 021f to 101b.0, 1031 to 1027.0.

## Movement: the step handler

The game moves in whole cells. Each frame the leader has control, FLD_MAIN's
`STAND` (0x801d10e0) reads the pad, and `CHOOSE_STEP` (0x801d1298) picks a
step: it tries the held direction, then one notch clockwise, then one
counter-clockwise (table at 0x801e315c: 0, +1, -1), taking the first
passable. For each it computes the next position (exe 0x80153a3c), checks
the cell attribute, objects (`PASSABLE`), and runs `EXIT_CHECK` (0x801d5828)
on the destination. `STEPPER` (0x801d1b30) then moves the leader over the
following frames. Events, exits and encounters all fire from the step path.

The port's free (non-tile) walking (`qol/free_move.odin`) replaces `STAND`
for the leader: it slides per axis with `PASSABLE` probes, and on every cell
change runs one fake one-frame step through `STEPPER` so events and
encounters still fire. When the held direction's step leads onto an exit, it
snaps to the cell and lets `CHOOSE_STEP` take the step, so doors work as in
the original. A square stopped only by the corner of a wall beside the way
ahead (walking a little off-centre into a doorway: Sarai 0204's door, from x
3.74 the square's left side reaches the wall at 3,8) is nudged across toward
its cell's middle at walking speed, so it slips past the corner as the grid
step would.

## Exits

Exit lists: `[[[0x80116be8]] + 4 * section]` points at the current section's
list of 12-byte entries, ended by 0xffff (`exit_list` in `qol/sections.odin`).

| Offset | Content |
|---|---|
| +0 | u16 destination map id |
| +2 | u8 destination section |
| +3 | bit 0: the exit's cells run along z (else along x) |
| +4, +5 | u8 x, z of the first exit cell |
| +6, +8 | s16 x, z arrival point in the destination (256 a cell); 0, 0 leaves the party to the destination's setup scripts |
| +10 | u8 number of exit cells |
| +11 | facing on arrival (low 3 bits, 8 directions); required for the exit to trigger; not the walk-out direction |

Warping to a map with a section index the map does not have sends
`EXIT_CHECK` looping over garbage until the game hangs.

## Sections

A map can have several sections joined by exits within the same map (a
dungeon's rooms). Only the current section is loaded for collision and
objects. The port draws neighbouring sections through their doorways and
crosses between them without a fade (`qol/sections.odin`):

- Map geometry is drawn in layers: `LAYER_SETUP` 0x80143304, `LAYER_DRAW`
  0x80145654. Drawing a neighbour section means shifting the GTE translation
  (`SET_TRANS` 0x80169e34, camera matrix 0x801381bc) and the camera target
  (0x801381a4) around `LAYER_SETUP`.
- A section owns a run of the map block's layers, starting at the layer with
  the section's index. Its layer count is `((byte 3 of its descriptor & 0xe)
  >> 1) + 1`, where the descriptor is `block + lw(block + 0xc4 + 4 * section)`
  (read at 0x80149728). The game copies the loaded section's count to
  0x80138170 (at 0x80142e00), so that byte is no good for a neighbour
  (`section_layers` in `qol/minimap.odin`).
- An exit can sit on a section's upper layer (020b s4's exit is at the top of
  a stair, on layer 5 of 4..5). Its layer is the one whose attribute grid has
  an exit attribute (high nibble 0xa) at the exit's first cell. Ground height
  and walls for the neighbour's offset are read on that layer.
- Neighbour offsets: the difference between the two exits' middles; height
  from `GROUND` at the exits' facing edges, where the sections meet (on a
  stair the ground still climbs through the exit cells). `GROUND` right at
  an edge can read a wall top, so the port reads it halfway out and doubles
  the slope. Height in view units = ground difference * 128 / 256.
- A neighbour can be an upper storey over this section's rooms (020b s7 over
  s4). Its tiles are hidden only over this section's floor, not where it has
  its own floor.
- Exit walks run on: in 020b the stair climb continues through the exit
  cells. The leader is at height 1.62 cells in the middle of s4's exit cells
  and arrives in s7 at -1.38, then climbs to 0. Both sections model the shared
  stair.
- Floor tile runs are at 0x8017c618 (count u16 at scratch 0x1f800090): 8 bytes
  each, +0 tile pointer, +4 s16 count, +6/+7 s8 block x/z (tile view =
  block*256 - 64, a tile is 2x2 cells, 16 bytes each). Tile u16 kind: bit 0 set
  = heightfield quad with a shared model, clear = (kind >> 1) own polygons.
  Writing kind 0 hides a tile (clearing only bit 0 makes the second pass read
  garbage).
- Neighbour sections are modelled with solid rock where this section's rooms
  are, so they are only drawn inside the door opening (portal clipping in the
  port's renderer).
- Another floor is drawn whole instead: a neighbour whose arrival point is
  half a cell or more above or below this side of the doorway. A floor below
  always (it shows down the stairwell); a floor above only while the leader
  walks on the layer holding the exit (object position byte +12, the layer
  counted from the section's first; 020b s4 switches to layer 1 at the foot
  of the stair). Of a floor above, only its rooms' tiles and the placed
  models on its walked cells are drawn.
- Placed models: a layer descriptor's u8 +2 is the model count, 12-byte
  entries from +4: u16 +0 model id, u8 +2 flags (0x20 drawn, &3 rotation),
  u16 +4 x and +8 z in 16 view units (1/8 cell). `SCENE_DRAW` calls
  `MODELS_DRAW` (0x80145674) for the layer right after `LAYER_DRAW` when
  DRAW_FLAGS bit 3 is set; clearing 0x20 hides a model. Black blocks around
  rooms are placed models too, some off the section's grid (020b s7 0x0b and
  0x18 at 7,8 cover the stair below).
- The black blocks round a stairwell share a placed model (and tiles) with
  the stair's top steps, so they cannot be hidden by model. While a floor is
  drawn whole, the port leaves black polygons out of its packets instead:
  `psx/blacks.odin` keeps packet address runs, and a polygon in a run whose
  colour (or texels at the middle and toward each corner) is black is not
  drawn. Runs cover the open floor's tiles and models, and this section's own
  layers while any neighbour is open (020b s4's other layers model blacks
  over s7's stair too). Runs lapse after PORTAL_VBLANKS.
- A stair running through a doorway has no wall: the neighbour offset adds
  the wall beyond the door only when both door edges read the same ground as
  the cells beside them. 020b s4/s7 are [8, 512, -2] apart, so the two
  flights meet on one rail.
- See-through ghosts only the pixels that hide the leader (a cone from the
  lens to his sprite), roofs included, so an upper floor's level faces over
  the stairs no longer ghost whole and show the void behind them as dark
  patches. (Until 2026-10-20 roofs ghosted whole, and `see_floors_open`
  turned that off while a floor was drawn whole.)

Interiors in towns (shops, houses) are separate maps. Since 2026-10-21 the
port shows no picture in doorways (`DOOR_PICTURES :: false` in
`qol/interiors.odin`): doors are fast in and out through instant doors, and
the doorway's dark back draws as the game has it. The rest of this part
describes the picture code, still there behind that constant;
`qol/interiors.odin` used to render the interior into a picture once you had
been inside and show it in the doorway.

- Black faces in rooms: a room's lens can hang outside its front wall, and
  from the third-person camera the black polygons round the room then cover
  the floor and the leader (Sarai 0204.2). With see-through up in a non-town
  map (`psx.see_through_set(..., room)`, room = map id & 0x1000 == 0), a
  polygon that see-through would ghost, not a sprite, not semi-transparent,
  black (`polygon_black`, psx/blacks.odin) and not a thin strip (both
  screen extents over `SEE_BLACK_THIN` 40 px, `see_thin`) is not drawn.
  Towns draw all their black faces: clotheslines are black strips seen edge
  on.

How the picture lines up with the doorway:
- The room map models a black curtain past its own door, standing in for
  the town. It is a vertical plane about 126 view units toward the town's
  lens, with a lid. The room pass leaves out every black polygon
  (`psx.blacks_all_begin`/`blacks_all_end`). It also measures how far across
  the door's opening the left-out curtain reached.
- The exit cells need not sit square on the modelled doorway. In Sarai 0204
  the town's doorway back spans -0.17..0.83 of the exit opening's width,
  while the room's curtain is centred. A pass measures only with the whole
  opening on screen and in front of the lens (`door_whole`); an opening cut
  by the screen edge measured part of the curtain and shook the room by up
  to a tile. Once `SLIDE_READINGS` (3) readings in a row agree within
  `SLIDE_AGREE` (8) view units, that place is kept for the door
  (`interiors.settled`, per town and room, kept across visits) and the room
  slides there by half the distance each pass. 0204.2 settles at -31, 0204.1
  at +31, 0201.2 at -1.
- The curtain counts from `CURTAIN_BEFORE` (256) before the opening's plane
  to `CURTAIN_BEHIND` (96) behind it. 0204.1's black floor strip ends 64..71
  behind the plane; at 64 it was rejected and the door never settled on the
  first approach.
- The doorway back is the town polygons on the opening's plane, within 0.25
  of its sides. A door picture also takes walls on that plane up to 0.6 past
  the sides (`PICTURE_SIDE`): 0204's doorway is an alcove wider than its back,
  and its left part drew a dark strip. Only the back proper counts for the
  slide.
- Some doorways model their back off the exit cells' far side. Sarai's
  tavern (0201.2, exit 26,15-16) puts it about 131 view units (a tile)
  toward the town, so nothing lies on the plane. While no back is on the
  plane, `back_off` looks for an upright polygon parallel to it, at most
  `BACK_BEFORE` (256) before it, inside its sides and spanning its height
  but no higher. The wall beside a doorway reaches about 1.5 openings up
  and is rejected. `psx.picture_off` reports the nearest one, and the door
  moves its picture's opening and front out by that much (`inset`, set
  once per door load).
- Depths come from projections filed by screen position (last write wins).
  A hidden house-floor vertex at the same pixel can give a back corner a
  depth about 450 behind the plane, so `back_at` puts one too-deep corner
  back on the plane along its ray. A corner in front of the plane is never
  moved: that is a doorway side.
- Picture pixels the room never drew (value 0) keep the town's pixel.
- In-between frames (smooth motion) draw the room again from the
  in-between view: `doors_between_draw` runs a room pass nested in the
  in-between pass (psx/checkpoint.odin allows one nesting level) for up to
  `MAX_DOOR_PASSES` doors the real frame showed, into the door's own
  `between` pixels; the pass measures nothing and does not step the room's
  people. Warping the real frame's picture through the door's plane
  (`door_warp`, the earlier approach) is right only on that plane: the room
  behind it moved with the wrong parallax, a jitter every real frame while
  the camera turned. The warp is still the fallback when a room cannot be
  drawn. A picture added for a door replaces the one added for it before
  (`picture_add`'s owner); keyed by pixels instead, the real frame's picture
  stayed in the list beside the in-between one and showed in its place.
- With smooth motion off, a frame frozen for a door's room pass in the third
  person view builds its own view (`build_view`); it used the in-between
  camera, which is not set then, and the doorway showed black.
- Entering through any door of the map (`door_to`) goes without fades, as a
  section crossing does: sections.odin `map_request` clears the fade bytes
  0x80116bcc/cd, holds the last picture through the disc load (`DOOR_HOLD`
  600 presents at most, cut to `ENTER_HOLD` at field enter) and the held
  picture fades out over the room (HOLD_FADE). Leaving a room into the town
  works the same. Nothing fades to black, on a first visit too.
  - While a picture is held, psx/platform.odin `fast_forward` runs the
    emulation unpaced (nothing live is seen), so the load passes in a few
    hundred ms rather than ~3 s.
  - The third-person yaw (CAM_YAW 0x8013818e) carries into the room, turned
    by the change in the leader's facing (object +0x4c, 0..7, 0x200 yaw units
    a step): a room's frame may be turned from the town's, and the game
    faces the leader the same way through the door, so the camera keeps its
    angle to the leader.
- Rooms not yet visited load in the background (`preload_step`). Once the
  town's world is noted, the port forks the process (psx/preload.odin). The
  child calls the map request (`0x801cf598`, a0 map, a1 section, a2/a3 the
  exit's arrival x/z at record +6/+8, facing byte +11 at sp+16, ra
  `0x801d5c38` as the field's exit check does) from the field draw. It then
  plays on unpaced and unseen until the room's world is noted, copies it into
  shared memory and exits. Meanwhile the parent plays on, takes the world when
  it is ready, and gives up after 1200 vblanks. Up to `PRELOAD_LOADS` (4)
  doors load at a time, each in its own child with its own shared memory,
  the untried doors nearest the leader first, and each door is tried once per
  town visit. In the 1000 to 0201.0 test all four started within 10 vblanks
  and the room was ready before the party reached its door. In Sarai a load takes 24 to 306 vblanks. When the party takes
  the door whose room is loading, `door_enter` waits for the child (at most
  2 s, `PRELOAD_WAIT`, a frozen frame) instead of loading the room from the
  disc a second time; in Sarai's 0201.0 that put the room up about 170
  presents sooner.
  - fork() copies only the calling thread. So BIOS threads (OpenTh/ChangeTh,
    which the game uses for its loader) are ucontext coroutines on that one
    thread (psx/coroutine.odin), and they carry over into the child.
  - The child shows nothing, plays no sound and reads the pad as released.
    It runs raster jobs inline, because the raster pool's threads are not
    copied. Autoplay stands aside in the child. The child dies with the
    parent (PR_SET_PDEATHSIG).
The people inside live on: each town frame a door is drawn, the port runs
the game's `NPC_UPDATE` (FLD_MAIN 0x801da4b0: scripts, moves and animations)
in the noted room's world before drawing it, and the world keeps the RAM it
leaves. The town's party is moved far off for the call (x + 0x40000000, as
for a neighbour section's people) so no script reacts to it, and the room
draws from its own `rand()` seed, so the town's numbers stay as they were.
A room not drawn does not step.

### Instant doors

With `[field] instant_doors` (on by default), a door to a map whose world is
noted (the town on the way back, a room seen or loaded in the background)
switches the machine to that world at the next field draw, with no disc load
(`door_enter` and `world_enter` in `qol/interiors.odin`). A world is the map's
RAM (`MAP_LOCAL` ranges, the map block from 0x80069800 up to where its load
ended, field mode byte 0x80114870 and state index 0x80114852), VRAM, the sound
effect bank and the CPU registers at its field draw. Leaving a world keeps the
global state (party, items, flags, the save region). Checked against a normal
load: the RAM after an instant entry equals a first load of the map, apart
from the stack, timers, play time and leftovers a disc load leaves of the map
before.

What a load does that the switch redoes by hand:
- Map setup (`0x801cf760`, FLD_MAIN block at 0x801cf7f4) notes the map left
  at `LEFT_MAP` 0x8011b718: u16 map id (from `FIELD_MAP` 0x8011c944), u16 x
  and z (party object position >> 8), u8 section | (party object byte 0x18 <<
  4). Scripts read it to place the party. `left()` writes the same.
- The arrival point and facing come from the map request record
  (`MAP_REQUEST` args stored at 0x80116bc6 x, 0x80116bc8 z, 0x80116bcb
  facing). The ground height under it: s16 x/z at 0x8011c94c/0x8011c950,
  `GROUND_HEIGHT` 0x8014a908 (a0 = that record) returns it in v0. `arrive()`
  sets every party object's position and facing.
- `KEPT_YAW` 0x8011c948 holds the camera yaw, written at the exit request by
  0x801d1500 and carried into the next map; the switch keeps it.
- Sounds: 24 slots of 0x14 bytes at `SOUND_SLOT` 0x8011ce10 (+0 flags, +2
  first voice, +3 voice count, +4 u16 sound id, +6 byte, +0x10 owning
  object) and voice tables 0x8011cd24..0x8011cde4. A load stops every sound
  (`SOUND_STOP` 0x8013f2d4, a0 slot). Lasting sounds such as Sarai's fountain
  (id 0x300) are started once by the map's script as it loads, so the switch
  stops the town's and starts the world's again (`SOUND_PLAY` 0x8013f268, a0
  id, a1 byte +6, a2 object), keeping the voice tables global. Only the
  slots whose sound loops are started again (`World.lasting`, taken at note
  time with `psx.voice_loops`: the slot's first voice is keyed on and its
  sample's end block has the repeat flag). One-shots still sounding when
  the world was noted (id 0x301, a periodic overlay call; 0x20e, slot flag
  1) were replayed at every door, more of them each switch; the original
  plays none there. A room's id 0x300 is its own sample (0204.2's at
  0x53c10, the town's fountain at 0x5a180), so it cannot play on through
  the door; the fountain opens on one long voice-16 note before its
  splashes (about 25 vblanks), in the original too.
- Sound effects bank: each map load DMAs its bank from staging 0x80054000
  into SPU RAM from 0x53c10 (town to 0x62610, 0201 to 0x76290, 0204.1 to
  0x5c090) about 100 presents after entry. `psx.dma_spu_hook` reports SPU
  uploads; a world keeps its bank range of SPU RAM and the switch writes it
  back. Music is not re-uploaded and plays on through doors.
- Sound library state stays global: the library BSS from 0x8017c6a0 to
  0x8017db00 (libspu's register shadow, voice attributes and the libsnd
  sequencer, code 0x80155000..0x80161000; the key-on mask is committed from
  0x8017d168 at 0x8015dabc) is left out of `MAP_LOCAL`. Taken with the
  world, every switch wrote back stale voice and key-on state under the
  live voices and the sound clicked and cut out. Still taken with the world
  and differing at each switch: libcd state 0x8017c2c0..0x8017c400 and the
  timers at 0x8017c5c0..0x8017c6a0.
- The libsnd score table is global too: `SsSetTableSize(0x8011d77c, 1, 6)`
  (0x8015a544, called from 0x8013d408) puts 6 * 0xb0 bytes of sequence
  state (read position, tempo, timing) at 0x8011d77c..0x8011db9c, so the
  `MAP_LOCAL` range there stops at 0x8011d77c. Taken with the world, every
  switch put the music back to where it was when the world was noted:
  notes came late, bunched or were lost.
- SPU timing: the SPU event is rescheduled from its due cycle
  (`psx.schedule_period`), not from when it was handled. Counting from
  the handling time lost each overshoot, so the SPU mixed about 0.9% slow
  (about 43,700 Hz), beyond the host's 0.5% rate correction, and the host
  queue ran dry every 5 s or so. The `.Perf` report lists the rate mixed,
  the queue's lowest level and dry runs.
- A world keeps the GPU draw state and display start it had when noted
  (`World.gpu`, `World.disp`). The switch copies the picture on show into
  both buffers of the world (`psx.move_image`), writes the world's VRAM back
  around that rectangle (`psx.vram_replace` with a keep rectangle), and
  restores the draw state and display start. `MAP_LOCAL` includes
  0x80114a04..0x80116b00: the byte saying which of the two frame buffers is
  drawn (the main loop flips it after `DrawOTagEnv` returns at 0x8013971c),
  and both buffers' DRAWENV, DISPENV and ordering table. Without it the
  noted frame's table was stale and the buffer flip ran out of step, which
  held the old picture two vblanks longer. The rest of the noted frame runs
  from the world's field draw into its own table, so the room's first
  picture is the next one sent. The in-between pass's poses are reset
  (`inbetween_world_switch`): the old world's poses would blend with the
  new.
- A world goes stale when the story moves on: it is keyed on a hash of the
  event, area and global flags 0x8011b5c0..0x8011b898 (less `LEFT_MAP`, the
  world-map return spot and cursor up to 0x8011b72c, and the resume position
  0x8011b7c0..c8, which change on every map) and the party
  bits 0x8011ad84..8c (`story_key`). A door to a world from before loads
  from disc as usual, and the new load is noted in its place.
- The third-person camera (`qol/sections.odin` `map_request`) keeps its yaw
  through the switch and eases from the town's lens, moved into the room's
  coordinates by the door's shift (`door_enter_shift`), to where the room's
  own camera puts it. The arm stays out while the cover below is on.
  The ease of the target (`DOOR_EASE_W`, a frame) and the arm coming in
  from the town's (`DOOR_ARM_W`, a second; `tp.door_in` until it is in) are
  critically damped springs that start at rest. Exponential eases moved
  the camera most on the first room frame (eye 43 view units up and
  2.3 degrees of pitch from a standstill at the door), which read as a
  jump; the arm's ease also snapped the rest of the way when the cover
  ended.
- Walking through a ready door (`door_ready`: its world kept and of the
  story as it stands, or still loading in the background) the party does not
  stop. The field's exit check (`EXIT_CHECK` 0x801d5828: a0 a step's
  destination position, a1 direction, a3 out byte, 0xff when nothing) fires
  as a step toward an exit cell starts, from `CHOOSE_STEP` and from the
  arrival of each step; free walk (`qol/free_move.odin`) hooks it to report
  nothing on a door's exit cells (`door_exit_at`), so the leader walks onto
  them, with the ground taken a cell back from the way through. Past their
  middle on the way through, `door_through` asks for the map as the exit
  check's caller (0x801d5be8) does: `KEPT_YAW` from the camera yaw, then
  0x801cfe5c (a0 map, a1 section; called `AREA_SET`), then `MAP_REQUEST`
  0x801cf598 (a0 map, a1 section, a2/a3 arrival x/z, 256 a cell, stack +16
  facing; it only stores them at 0x80116bc4.. and sets field mode 4) with the
  exit's arrival. Marked as walked through, the switch puts each party
  object and its step target where it stood less the door's shift (rounded
  to target units) and the camera target likewise, and the camera's ease
  is left off: nothing jumps (checked on 1000 to 0201.0 and back: leader
  20.16 to 5.91 cells, target and eye continuous). Before, the leader stood
  at the exit cell's middle until the request and the room put the party on
  the arrival cell, two cells past where the shift maps it, with a faked
  walk of the drawn party between.
- The shift lines up the doorway's picture, which can be wider than the
  exit's cells: walking out of 0204.2 at room x 3.94 put the leader at town
  27.56,30.19, on the wall cell beside the exit (cells from 28), where
  free move refused every step. After the shift, `through_clamp` finds the
  arrival section's exit back to the map left (`exit_to` with `LEFT_MAP`'s
  map and section) and moves the whole party across the exit's way only, so
  the leader is inside its run of cells by free move's `RADIUS` (0x5000).
- Followers fade in from black as each steps off the leader at a map's
  start: task `FOLLOWER_FADE` 0x801cdbdc (a0 the task; state byte +4). State
  0 sets, for each member but the leader (index 0x801172af) not flagged in
  0x801172aa, bit i of 0x801172ac, colour +0x6c to 0, +0x5f to 1 and
  semi-transparency (+0x55 bit 1). State 1 (wait), only while the party
  object at task +8 walks (`OBJ_GAIT_ANIM` +0xfa not 0, 6, 7, 11 or 12),
  finds the next flagged member whose step target (+0x9c) differs from that
  object's, clears its bit and goes to state 2; with none left it clears
  0x20 and frees itself (0x80153084). State 2 counts +78 and sets the colour
  to count * 8 until it reaches `GROUND_LIGHT` 0x801381e9 / 2, then the full
  colour (cell light lookup 0x8014a8a0), drops the semi-transparency and goes
  back to state 1. In the original the half-faded followers are added over
  the room's black, so they never show; a room noted ahead holds them
  mid-fade, and walked in through an instant door they were black
  silhouettes over the town cover. With the cover on, `interiors_follower_fade`
  runs each step to its end, and at the switch `followers_shown` runs every
  live fade task (a model object, `MODEL_OBJS` 0x801192cc, kind byte +1 = 4) with
  the party marked as walking, so the room's first frame already has them in
  colour. The task's own turn comes after the field draw.
- A request arriving at 0, 0 (most script op 0x5b requests, some exits)
  leaves the party to the map's setup scripts. A room switched to at once
  ran them when it was noted, and `arrive` would set the party down on cell
  0, 0, so such a request loads as the game's (with its fades) unless it
  is walked through or a script's (sections.odin `map_request`).
- A script's request (op 0x5b, told by `MAP_REQUEST`'s return address
  0x801de044) is made wherever the party stands, so it gets no cover and
  no camera ease: the room comes in at the black of the game's own fade
  out. The map change fades out with `FADE_WAIT` (0x8018f5ac: a0 s16 speed,
  a1 blend), which steps `FADE_STEP` (returning to 0x8018f5f8) with its
  counter on its own stack (+16, frame 0x28 bytes) and waits a frame
  between steps through the task wait 0x8013a4ac. The field draws run
  between those steps, but none after the last, so the step that ends the
  fade is reported as still running once (fade.odin, `door_dark_hold`):
  the next field draw sees full black and switches (`world_enter`). The
  fade's task keeps its own registers through the switch, but its stack
  is in the swapped range (0x801f0800..0x80200000), so `FADE_WAIT`'s frame
  is kept from the town's; it ends there, and the field goes on to set the
  map up. The map wanted (0x80116bc4) is the one in already (0x8011c944,
  checked at 0x801cf940), so there is no disc read: the setup runs the
  map's own scripts (placing the party, 0, 0 included) and fades in, about
  20 black frames in all against about 130 for the load. Swapping at the
  first field draw instead (as a door does) cut with no fade; swapping at
  black without the kept frame restarted the fade out from the room's
  stack.
  Now 28.31 and it walks out onto the plaza.
- A door pair has one shift both ways. The slide along the opening
  (`Door.along`, measured on the town side from the doorway back against the
  room's curtain) is kept per pair as a vector (`interiors.settled`); a town
  door settling also settles the room's door back by the opposite slide.
  Measured alone, the room's door had none, and walking out landed 0.3 of a
  cell off where walking in had come from.
- Walking into a room from its town, the town is drawn once more every frame
  from the room's lens, its building included (`door_pass` with `cover`), and
  laid over the room (`psx.cover_add`, tag `DOOR_COVER`): the room and its
  people show only through its doorway, so the first room frame matches the
  last town frame. The town's black sky is laid too. The cover is
  full for `COVER_VBLANKS` (30) and eases out over `COVER_TAIL` (10). With
  the third-person camera the lens can still be outside the building after
  30 vblanks, and the room showed with void around it; there the cover is
  held until the lens is over the room's floor (`door_lens_in`: the eye from
  the room's view against the around door's box less `AROUND_WALL`), noted
  once as `cover_in`, and the tail runs from that. It is only checked once
  the doors found are the room's (`doors_key`), else the town's left-over
  doors latched it at once. 1000 to 0204.2: latched 66 vblanks in, no void
  frame, then a 10-vblank crossfade. The cover also fades
  as the lens comes within `COVER_FADE` (96 view units) of the doorway's plane
  and ends when the lens crosses it. Tested on 1000 to 0201.0.
- The way back (room to town), third-person: the room's exit cells often lie
  well past its drawn walls, so the leader walked several cells of black
  before the switch cut to the town. `door_out` lays the cover over the room
  as the leader walks out, in line with the exit's cells: none `OUT_RAMP`
  (3) cells before the exit's middle, all of it there (smoothstep), where
  `door_through` switches, so the room's last frame is the town's first.
  The floor's box can't set the start: the dark way out is floor too
  (0204.2's box runs to z 10, its exit middle at 8.5). This cover is laid
  unsided (`cover_add(sided = false)`: no lens-side test, no `COVER_FADE`),
  and the party sprites are drawn over it. Position from `leader_obj()`.
  0204.2 to 1000: the town comes in over ~20 frames, no hard cut.
- The first room frame has no town pass of its own yet (it runs before the
  send of the frame after). The switch grabs the picture on show
  (`psx.picture_take`, `first_cover`) and `doors_find` lays it as that
  frame's cover, so the room never shows a frame of bare void. It keeps
  the town's view moved by the door's shift (`first_cover_view`): the
  room's first view is exactly that (checked on 1000 to 0201.0), and the
  frames after warp the picture on from it.
- The cover is drawn at the send before with that frame's camera
  (`pic_view`). Real frames warp it onto the current
  camera (`door_warp`), as in-between frames do; laid unwarped, real frames
  lagged the in-between ones by a frame of camera motion and the picture
  juddered back and forth through the door.
- The cover's opening, where the room shows through, is the outline on the
  picture of the doorway's dark back as the town pass drew it
  (`psx.curtain_hole`, a `psx.Cover_Hole`: the convex hull of the corners of
  the black polygons left out, in picture coordinates). For the doorway of
  the door walked in through (`interiors.enter_quad`/`enter_front`, set by
  `door_enter` with `enter_ok`), the pass also lays a blank picture
  (`psx.picture_blank_add`): its back drawn black, its corners noted with
  the curtain's, so the opening is there even where the town drew no
  curtain. The walk tests each pixel against the opening after reading the
  cover, in picture coordinates; a warped cover clamps to the picture's
  edges. The GL path does the same (`pic_blank` uniform).
- `psx.cover_add` takes the opening by pointer (`&d.cover_hole`) and
  `picture_flush` copies it as it lays the cover: the frame's own cover pass
  runs after `cover_add` and overwrites the pixels and the opening, and a
  copy taken at `cover_add` paired the new pixels with the old opening (on
  the first room frame, `first_cover`'s empty one: the doorway showed
  black).
- The room's own curtain at its doorway (its black polygons there) would
  hide the room in the opening. While a cover is due (`cover_due`), the
  frame leaves out black polygons about the cover's doorway (`cover_door`,
  `curtain_at` in psx/blacks.odin) as it does in a curtain run.
- Party members stay over the cover the whole time it is laid, walking in
  or out (qol/third_person.odin `sprite_draw`), seen through the town's
  walls. Hiding those past the doorway (`door_cover_front`, removed) lost
  the leader for ~25 frames on 1000 to 0204.2 while the lens was still over
  the roof. The cover's doorway stays black: it is left open (`curtain_hole`)
  but the room there is its unlit exit way, past the room's walls.
- An in-between picture fades the cover by its pose's time
  (`inbetween_vblank`, between the real frames round it), not the vblank it
  is shown at; by the clock, in-betweens faded ahead of the next real frame
  and the fade went back and forth.
- The room's first frame has no pose of its own to blend from (`cut_in`).
  The in-between pass makes one (`cut_from` in qol/inbetween.odin): the
  room's first pose with the camera and the party objects (0x80116fb0, 3 of
  0xfc bytes, the same in both worlds) carried back by the town's last
  step; the room's other objects stand, and matrices are not blended. One
  more in-between frame shows across the switch; two presents still repeat
  the picture on show while the room's first frame waits on the frame
  buffer flip.
- Near a door the world is noted again every frame (`interiors.renote`,
  `world_take`), so the cover draws the town's people where they stood a
  frame before, and the way back goes on from there.
- The room places the party a cell or two past the doorway. For
  `PARTY_WALK_VBLANKS` after the switch the party's objects are drawn moved
  back toward where they stood in the town (`party_walk_call` around
  `FIELD_DRAW` and `SCENE_DRAW` 0x801420a4, whose `COLLECT` 0x80141f1c
  projects each sprite), so they walk on in from there. Only real frames move
  them: in-between pictures blend positions the real frames already drew
  moved. While the cover is on, party sprites (and the 52-byte copies drawn
  after each sprite) are tagged in front (`see_flat_add` `front`) and drawn
  over the cover and the room.
- The ground under a door is read a cell inside its own map (`exit_way`) and
  at the arrival cell on the other map (`Door.there`): a room's exit cells may
  lie past its floor (0201's read 768 and lifted the town by 384 view units).

### Stitch table (removed)

A door's slide settles only once its whole doorway has been on screen
(`door_whole`). A table of 29 town doors' slides, measured beforehand by
autoplay's `doors near` survey, once let a room line up in its door picture
the first time. It went on 2026-10-23: with door pictures off
(`DOOR_PICTURES`, doors made fast on 2026-10-21) a slide only moved a
walked-through party along the doorway, up to two cells, before
`through_clamp` put it back in the exit cells, so a walked-through door now
shifts the party by its cells alone. Turning door pictures back on measures
the slides live again.

### A room's door to its town

Rooms keep their own maps, scenes and coordinates; Sarai is joined up by
drawing, not by merging blocks (merged blocks would pass the 0x1a000 cap,
"Edited maps"). In a room of the town (map without the 0x1000 bit, door to a
map with it), the door back to the town (`Door.around` in
`qol/interiors.odin`) shows the town only through its doorway, like any door
picture; round the room stays the game's black.
- The cut box: the room's own building, drawn in the town, would stand in
  the doorway and hide the street. `floor_open_box` (qol/floors.odin) gives
  the box of the section's cells that are not walls; widened by
  `AROUND_WALL` (6) cells, it becomes an x/z box in the town's world space.
  While the pass draws (`psx.cut_begin`), a polygon with known depths (not a
  sprite) whose corners overlap the box and reach more than `AROUND_ABOVE`
  (48 view units) over the door's ground is left out.
- Walking in, the cover (the town with the building) is laid over the room.
- Earlier the whole town picture was laid wherever the room drew only its
  clear, with the room's black curtains left out (`surround_add`). It showed
  the desert all round the room and through its see-through walls, and the
  third-person arm swung out through the door over it; both are gone.

## Map geometry

The map block is always at 0x80069800 (pointer at 0x8011c954). Its layout
(header tables, layers, tile grid of 16-byte tiles, 4-byte polygon refs,
32-byte polygons) is described at the top of `qol/map_geometry.odin`, which
also decodes and re-encodes layers (`BOF4_MAPCHECK` checks the round trip
byte for byte).

- `LAYER_SETUP` 0x80143304 picks tile runs around the view (0x8017c618).
  `LAYER_TILES_DRAW` 0x80143930 then runs pass 1 (0x80143958, heightfield
  quads) and pass 2 (0x80144800, each tile's polygons).
- `MODELS_DRAW` 0x80145674 walks the layer's placed models (12 bytes each:
  group, colour set, flags with quarter turn in bits 0-1 and "hides from
  octants" in bit 2, x/y/z in 16-unit steps, octant mask). A model whose box
  centre or a corner passes the fixed view's sight test (`MODEL_IN_VIEW`
  0x80145c08) and that does not hide from the camera's octant (`MODEL_SHOWN`
  0x80149ee0) goes to `MODEL_DRAW` 0x80145d90, which turns each 24-byte
  polygon's corners, tests the first corner against the same sight and draws
  it with its own copy of the tile quad code.
- The port draws both tile passes (`tiles_draw_native`) and the placed models
  (`models_draw_native`) natively; both share one quad routine (`quad_draw`,
  with per-copy code addresses in `TILE_QUAD`/`MODEL_QUAD`). The packets,
  ordering-table links, scratchpad words and counts they leave are the game's,
  byte for byte. While any of the optional per-polygon helpers is in use
  (scratch bytes 0x1f8000a8..aa, routines 0x8014bc44/84/c4) they run the
  game's code instead.
- The native drawing knows the emulated cycles the game's code takes on each
  path (spans of its instruction addresses at `CYCLES_PER_INSN` each, with
  interrupts run at the same loop edges), but charges them only under
  `BOF4_MAPCHECK` and when replaying a record from before 2026-10-22
  (`psx.charge_native`). Otherwise it is free: charged, it was about two of
  the three vblanks a Sarai frame took, the cause of the town's 20 fps
  walking. Free, vblanks and CD reads land elsewhere in the frame than on a
  PS1.
- `BOF4_MAPCHECK=1` runs the game's drawing and the native one on every frame
  and logs RAM differences and cycle mismatches (drawings an interrupt falls
  inside are skipped, their timing differs by nature). Expected: `0 differ`,
  `0 in cycles`.

### Floors

The map block's +0xc4 table (count at +3) holds one descriptor per layer,
the floor the step and ground code walk on: +0 layer (tile grid), +1
attribute grid (+0xa4 table, count at +2), +2 placed model count (12-byte
models from +4), +3 flags (bit 0 lit ground, bits 1-3 layers - 1 on a
section's first floor). A section is the run of floors starting at its own
index. Floors with their own attribute grid are Z levels of one room joined
by stairs (0201's tavern hall: floor 2 on the ground, floor 3 a gallery at
ground 768, stair cell 0xc0 climbing 64..768); floors that share a grid are
extra tile layers over one floor (1000).

`qol/floors.odin` decodes and re-encodes a descriptor (`map_floor_decode`,
`map_floor_encode`; `BOF4_MAPCHECK` checks the round trip), and with
`BOF4_FLOORDUMP=<dir>` writes `<map>.json` once per map and block: every
floor's header, attribute cells (hex rows) and the ground height of each cell
(`GROUND` run natively on the cell, leaving no trace in the game's state).
A map that shows a second block (a door room swapped in) also gets
`<map>-1.json`.
`python3 -I tools/floors_png.py <map>.json <out dir>` draws each floor as a
PNG (grey by ground height, walls red, exits blue, stairs green).

### Edited maps

A map's block is entry 4 of its file (`WORLD/AREA*.EMI`, load address
0x80069800), loaded raw. With `BOF4_MAPS=<dir>`, `<dir>/<map>.blk` replaces
it (`qol/map_mods.odin`): each disc DMA chunk into the block is written over
with the edited bytes, and the first chunk writes the whole edited block, so
it may be longer than the disc's. Its end is capped at 0x80083800, where the
party's models (`PL*.EMI`) load on every map (0x1a000 bytes; the largest disc
block, AREAD046, is 0x19e1c). Instant doors are told the edited end, so a
noted world keeps the whole block. Checked 2026-10-19 with the phase-7
1000 block (added layer 3): 1000 to 0204.2 and back out ran to the same
presents as the disc block (in 1778, out 2049), the block was read once,
and the town came back from its noted world with the new layer drawn.

```sh
python3 -I tools/map_block.py extract disc/BIN 0201 mods/0201.blk
# edit the "cells" rows of a BOF4_FLOORDUMP file, then
python3 -I tools/map_block.py cells mods/0201.blk 0201.json mods/0201.blk
```

Checked: an unedited block leaves the baseline replay's frames unchanged;
walling 0201's stair cell (floor 2, cell 2,8: 0xc0 to 0x10) stops the climb
to the gallery; a block padded past the disc's size loads whole.

A background room load (`preload.odin`) runs in a fork() copy of the port,
which reads the edited block itself: the log shows `maps: <map> from ...`
again when the main process later loads that map.

#### In-game editor

F4 on the field, with the player in control, opens the map editor
(`qol/map_editor.odin`); F4 again leaves, as does any map, section or block
change. The party stands still, the d-pad moves a cursor (camera-relative;
L1/R1 still turn the camera) from the leader's cell, and every edit changes
RAM at once. Start writes `<maps>/<map>.edit` (`BOF4_MAPS`, default `maps`
in the working directory), which `qol/map_mods.odin` applies on every later
load of the map, after a `<map>.blk` if there is one. Autoplay's `edit`
command stands in for F4.

| Tool (L2/R2) | Edits | Pad |
|---|---|---|
| Cell | the cursor cell's attribute (00, 10/11 walls, 20/21, a0-a2 exits, c0-c7 stairs) | Triangle/Square brush, Circle picks, Cross (held) paints |
| Vertex | the corner height of every ground tile at the nearest vertex | Triangle +1 (16 units up), Square -1, Cross sets the brush, Circle picks |
| Tile | all four corner heights of the cursor's tile | as Vertex |
| Texture | a ground tile's texel cell (byte 3), turn and flip (byte 0 bits 1-3), slot and UV base (byte 2) | Select picks the field, Triangle/Square change it, Circle picks, Cross (held) paints |
| Exit | the fields of the section's exit under the cursor (12-byte entries in the code overlay) | Cross edits: Up/Down field, Left/Right +-1, Triangle/Square +-16, Circle done |

Select picks the next floor of the section (Texture: the next field). The
overlay shows the floor's non-plain cells within 8 of the cursor as dots
(walls red, 2x green, exits yellow, stairs cyan), the exits as yellow boxes
(the one being edited cyan) and a HUD with the cell, the tool's values and
its keys. Lines and dots are drawn over everything, also through roofs.

A `.edit` file is text, one run of bytes per line, offsets from the part's
start, `#` comments:

```
block 1b8f 03                # map data block (at 0x80069800)
overlay 11f8 1c 1d           # code overlay (0x801f0800): vanilla bytes, edited bytes
```

The overlay also holds minigame code, so an overlay line goes in only when
every vanilla byte matches what loaded; otherwise the whole overlay patch is
left out with a log line. Limits: a room an instant door shows from its kept
copy (`interiors.odin`) shows that copy until the map loads from disc again;
heights, textures and cells only change existing tiles (no tiles or models
are added); the world map and minigames are not editable.

Checked 2026-10-24 on 1000 (warp 26,33): a cell painted 10, a vertex raised
three steps (4 tiles' corners, +3 each), exit 0204:2's x moved 28 to 29,
saved, and a fresh run loaded the patch with all six bytes in RAM.

#### Block layout

All offsets in the block are relative to its start and 4-aligned; the parts
follow the 0x134-byte header in this order, each running to the next one's
offset (the last to the block's end):

| Header | Holds |
|---|---|
| +0..+3 | counts: layers, model groups, attribute grids, floors |
| +0x04 | u32[8] layer offsets (tile grids, `qol/map_geometry.odin`) |
| +0x24 | u32[32] model group offsets |
| +0xa4 | u32[8] attribute grid offsets |
| +0xc4 | u32[8] floor descriptor offsets (Floors, above) |
| +0xe4..+0x123 | a 64-byte table per material, not offsets (0x801553e4 reads `block[0xe4 + i] & 31`, `i` from a cell byte) |
| +0x124 | offset of an extra table, 0 when absent (103 of 374 blocks have one) |
| +0x128 | offset of the model colour table (always present, runs to the end) |
| +0x12c | a small count, not an offset |
| +0x130 | always 0 |

A zero table entry means that slot is empty. Nothing inside the parts points
outside them: a block laid out again with gaps between parts plays the same.

#### Taking a block apart

```sh
python3 -I tools/map_block.py unpack mods/1000.blk work/1000
# edit work/1000/layer0.json, floor0.json, attrs0.bin ...
python3 -I tools/map_block.py pack work/1000 mods/1000.blk
```

`unpack` writes `header.bin`, `layer<n>.json`, `group<n>.bin`,
`attrs<n>.bin`, `floor<n>.json`, `extra.bin` and `colours.bin`; `pack` lays
them out again and rewrites the header's offsets, so parts may grow or
shrink (the 0x1a000 cap still holds). Every one of the disc's 374 blocks
comes back byte for byte from `unpack` and `pack`.

A layer's JSON holds `width`, `rows` (`[x, count, first tile]` per row of
tiles), `tiles`, `refs` (`[count, first polygon]`) and `polys`. A ground
tile (`flags` bit 0) has `ref`, `page`, `cell` and four corner `heights`
(corners (x,z) (x+1,z) (x,z+1) (x+1,z+1), signed bytes, positive is up); one
step is 16 drawing units and 32 of `GROUND`'s (a tile is 512 of `GROUND`'s
units across, a cell 256). Other tiles list their polygons as
`polys: [first, count]`. A floor's JSON holds `layer`, `attrs`, `flags` and
its placed `models` (`group`, `colours`, `flags`, `x`, `y`, `z`, `octants`;
`pad` bytes kept as they are).

Checked: 0201 laid out again with 512 bytes after a model group and two
attribute grids plays the tavern stair route with every dumped frame
unchanged; 1000 with four parts padded gives the baseline replay's frames;
lowering 1000's ground tiles x 10..16, z 13..19 (inner corners to -8) makes the
floor dump's ground -256 there and the leader walks at height -1.00 cells in
the pit (autoplay trace, `BOF4_AUTO_TRACE`). Drawing of edited heights was
not looked at closely (the pit sits under a faded roof).

#### Adding a Z level

A floor becomes a Z level of its section by getting its own attribute grid;
stairs then move the leader onto it. Its grid has (layer width * 2) x
(rows * 2) cells of the floor's own layer, which may be smaller than the
first floor's (1000: layer 0 is 25 x 28 tiles, layer 2 20 x 24); all layers
of a section share their origin, so cell (x, z) is the same spot on each.
A floor that shares the first floor's grid while its layer is narrower reads
it with the wrong row length, which is harmless while nothing walks there.

A stair is a pair of cells. On the lower floor, the cell is `0xc0 | d`
(bit 2 clear), `d` its direction (0 -z, 1 +x, 2 +z, 3 -x); the cell it leads
to, one step that way, is `0xc4 | d'` on the upper floor with `d'` pointing
back (pairs on the disc: c0/c6, c1/c7, c2/c4, c3/c5). Stepping off a stair
cell along its direction (`NEXT_POS`, 0x80153a3c) calls 0x80153958, which
looks for the first floor of the section, upward from the walker's for a
lower stair and downward for an upper one, whose cell at the destination is
a stair (kind 0xc), and moves the walker to that floor. The ground of both
cells must still be within one cell height (256) of each other, so the lower
floor needs a ramp up to the stair cell (0201's tavern: 64, 320, 576, 768).

Done on 1000 (its rooftops are drawn by layer 2, floor 2, at ground 768):

- `attrs1.bin`: 40 x 48 bytes, 0x00 where floor 2's dumped ground is 768 or
  more, 0x10 (wall) elsewhere; cells (17, 12) and (18, 12) 0xc6.
- `floor2.json`: `"attrs": 1`. `pack` raises the header's grid count.
- `attrs0.bin`: cells (17, 13) and (18, 13) 0xc0.
- `layer0.json`: ground tiles x 8..9, z 6..8 sloped, corner rows z 6, 7, 8,
  9 at heights 24, 16, 4, 0, giving cells z 13..16 ground 576, 416, 224, 96.

With `BOF4_MAPS` the leader walks up the ramp from (18, 16), changes to layer
2 at height 3.00 on cell (17, 12), walks the roof (4.00 on its raised part,
the roof's edges stop it), and walks back down to layer 0 and on across the
map (`BOF4_AUTO_TRACE`, which logs the layer; snapshots show the leader
standing on the roof). The ramp's tiles are drawn sloped with plain cliffs
at their sides. Not tried: more floors than a section has layers, NPCs or
doors on an added level.

#### Adding a drawn layer

A level of new geometry is a new layer with a floor of its own;
`tools/add_layer_1000.py` builds one on 1000 (a platform at height 1.50
over the plaza west of the arrival spot, a ramp up to it and stairs from
floor 0). What it takes:

- `layer3.json`: `width` in tiles, then one `[x, count, first tile]` row per
  tile row from the section's origin; rows before the new geometry are
  `[0, 0, 0]` (1000's layer 3: width 14, 15 empty rows, then rows
  `[9, 5, 0]` and `[9, 5, 5]`). Ground tiles as above with `flags` 7; the
  heights draw the top. `page`'s low bits pick the texture slot (4 is the
  stone and sand 1000's layer 2 uses); bits 6-7 hold `ref`'s high bits, so
  set `page` with the `ref` in mind (196 = slot 4 with `ref` 255, none).
- Sides: a ground tile draws only its top, so a raised one floats. Its `ref`
  points at `refs[ref] = [count, first]` polygons drawn with it: one quad per
  outward side, corners bottom a, bottom b, top a, top b, wound so the side
  faces out (tile-local corners for -z (0,0) (16,0), +z (16,16) (0,16), +x
  (16,0) (16,16), -x (0,16) (0,0)), `texture` 4, `flags` 0, `uv`
  `[[31,143],[0,143],[31,143-2ha],[0,143-2hb]]` for top heights `ha`, `hb`,
  shaded darker on minus sides (colours 26423) than plus (16913). The other
  winding is culled.
- `floor3.json`: `{"layer": 3, "attrs": 1, "flags": 1, "models": []}`, and
  floor 0's flags raised to the new layer count (bits 1-3 layers - 1: 0x7
  for 4). `pack` raises the header's layer and floor counts (04 13 02 04 on
  1000); the +0xe4 table is per material and needs no new bytes.
- `attrs1.bin`: the walkable top 0x00, all else 0x10; the stair cells (18,
  31..33) 0xc7, with (17, 31..33) 0xc1 in `attrs0.bin`. The ramp's ground
  runs from 0 at its foot, so no ramp is needed on floor 0.

With `BOF4_MAPS` the platform draws with its side walls, the leader climbs
from (16, 32), changes to layer 3 on the stair, walks the ramp to height
1.50 and the platform, and walks back down to layer 0 at x 17.27
(`BOF4_AUTO_TRACE`). `BOF4_MAPCHECK` gives `round trip same` for every layer
and floor, layer 3 included (10 tiles, 10 refs, 12 polygons). The autoplay
`goto` does not path across stairs; drive the stair step with `stick`.

## Camera

The field camera block is in the executable; `VIEW_BUILD` (0x8014307c, runs
several times a frame) builds the view matrix from it.

| Address | Content |
|---|---|
| 0x80138184 | H (projection distance, lens) |
| 0x80138188 | near |
| 0x8013818c | pitch |
| 0x8013818e | yaw (0..4095; reset to 512 on a section crossing) |
| 0x8013819c | distance |
| 0x801381a4 | target |
| 0x801381bc | camera matrix (column 1 is world up in view space) |
| 0x801381c8 | matrix row 2 |
| 0x801381d8 | TRZ |

FLD_MAIN's rotate trigger is at 0x801d94e8 (L1/R1). The port's third-person
camera (`qol/third_person.odin`) hooks `VIEW_BUILD` and these.

The leader's object state byte tells who has the camera: 1 player control,
8 idle (after standing still), 2 a scene moving the leader, 5 turning to talk
to an NPC, 6 the field menu open. A talk runs in `GAME_MODE` 4 (event) with
the leader back at 1; a shop in mode 7. The third-person camera stays (with
its see-through and stick yaw) through talks, the menu and shops, and blends
back to the game's camera only for scenes (state 2) and other modes; L1/R1
zoom works only under player control or idle.
