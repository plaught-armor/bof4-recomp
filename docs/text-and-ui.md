# Text, menus and controls

## Drawing text

| Function | Address | Arguments |
|---|---|---|
| `TEXT_DRAW` | exe 0x80140b2c | a0 x, a1 y, a2 colour, a3 element count, string pointer at sp+16. Menus and labels. Codes below 33 go through the jump table at 0x80138948. |
| `DIALOGUE_DRAW` | exe 0x8014c464 | draws the open dialogue box: box pointer at [0x8011decc], string pointer at box+12, characters revealed so far u8 at box+29. Draws one character per `TEXT_DRAW` call; codes below 29 go through the jump table at 0x80138a40. |
| message box open | exe 0x8014c1ac | opens a box; but `WINDOWS_TICK` 0x80150018 only runs in FLD_MAIN's message sub-states (e.g. 0x801e25e0, waiting on bit 2 of 0x8011ded0), so a box opened while walking never draws |

Text boxes are 0x50 bytes (0x8011de2c, 0x8011de7c, ...). The text tick
0x8014c840 dispatches on the state byte (+0) through the table at
0x80174630: 0 printing, 3 page end, 7 character delay, 2 choice (handler 0x8014d134) (also seen
while a multi-line text that is not a choice waits). In a choice
the string (+12) is the options separated by 0x01; +1 is 0 until the first
press, and u8 +0x2b is the option under the cursor (Down/Up move it).

`qol/button_text.odin` hooks both draw functions and rewrites button names
inside strings (on a copy on the emulated stack) before the game draws them.

### Control codes

Strings are mostly ASCII with control codes below 0x20. Known:

| Code | Meaning |
|---|---|
| `00` | end of the text |
| `01` | line break (in a choice, between options) |
| `02` | next page |
| `{05}{0a}{15}{N}{06}` | button icon N: 0 Circle, 1 Cross (Confirm), 2 Triangle (Cancel), 3 Square |
| `0a` | takes one byte (a pause, likely) |
| `14 04 0c 82 Yes 01 No 00` | a Yes/No choice |
| `17 <face> <clut>` | the speaker's portrait: face n = face & 31 of the map's face sheet (0x80 mirrored, 0x40 a party face), CLUT row 254 + (clut >> 4), x (clut & 15) * 16; drawn by exe 0x801516ec |
| `22` | a literal `"` |

Named speakers' texts start `17 <face> <clut> Name 01 "`; townsfolk have no
name line. A map's face sheet and palettes are its area file entries
(decoded in `qol/master_faces.odin`): 128x32 tiles, face k at
(8 + 40 * (k % 6), 48 * (k / 6)).

### Messages

`MESSAGE_TEXT` exe 0x8014c0dc (a0 the id, v0 the text): bank id >> 13,
entry id & 0xfff.

| Bank | Text |
|---|---|
| 0 | the map's text: 0x80010000 + u16 table[entry] (the table starts the area file entry loaded there) |
| 1, 3 | from a base word at 0x80010000 |
| 2 | table at 0x80017000 |
| 4 | table at 0x801eb000 |

The portrait: `FACE_DRAW` exe 0x801516ec (a0 x, a1 y, a2 face code, a3
brightness) commits a DR_MODE (tpage 32) through 0x8013ae34(1, 12), then a
POLY_FT4 (code 0x2c, 0x2e when a3 bit 0 is set; colour a3 on all three
channels; tpage 63; CLUT word from the face code's CLUT byte b,
(254 + (b >> 4)) << 6 | (b & 15)) through 0x8013ae34(1, 40). 0x8013ae34
appends a packet to the tail of layer a0's chain (0x80116cf4[layer]) and
skips it when the pool would pass its end (0x8002cfcc + 0x9000 per buffer,
buffer index at 0x80114a04).

Button names also appear as plain words in text: `L1`, `R2`, `START`,
`SELECT`, and pairs like `L1/R1`.

### Font

The system font is a 4bpp texture page at VRAM (960,0), CLUT 10 at (160,240).
The four button icons are 3-texel-wide cells at VRAM x 1002 + 3N, y 184..195.
The scroll-bar tags L1/L2/R1/R2 are 8x5 texels in that page at (208,217),
(216,217), (240,210), (240,217) (background colour 1, foreground 5). The port
redraws these each vblank for the active input device
(`qol/button_icons.odin`). What it draws is worked out again only when
`host.binds_hash()` (every binding plus the device in use) or the Confirm
and Cancel masks change; a world map legend slot is hashed again only when
its texels changed since the last vblank. Together that cut the vblank's
prompt work from about 4% to under 2% of the main thread.

### Japanese text

Japanese text left on the US disc (the Dengeki store before its fan patch,
and AREAM019) uses the same control codes with its own character bytes:

| Bytes | Characters |
|---|---|
| 0x5e..0x8b | hiragana あいうえお … わをん, in gojūon order |
| 0x8c..0xad | ぁぃぅぇぉっゃゅょ, then voiced が … ぼ and half-voiced ぱ … ぽ |
| 0xae..0xfd | katakana in the same order: ア … ン, small ァ … ョ, ガ … ポ |
| 0x5d, 0x5b, 0x40 | ー, …, ・ |
| 0x3c | 「 (opens a spoken line) |
| 0x20, 0x21, 0x24, 0x3f, 0x30..0x39 | space, !, 、, ?, digits |
| 0x12 xx, 0x13 xx | a kanji (two bytes) |

A scan of every text bank on the disc (message tables in EMI entries; a
message counts as Japanese with 4+ bytes in 0x8c..0xfd outnumbering spaces)
finds only three Japanese banks: the Dengeki store's forest AREAD068 and
store AREAS052 (the same 27-message bank) and AREAM019. No Shift-JIS text
is on the disc either. The port translates all three
([story-and-maps.md](story-and-maps.md#dengeki-store-cut-from-the-us-release)).

### World map legends

The world map's button legends ("△ ··Camp", "SELECT ··Map", "L1/R1
··Search", ...) are sprites from 8bpp texture page 0x8a (VRAM x 640, y 0),
CLUT at (0,248). Letters are colour 8 (lit) or 12 (greyed) with outline 14 on
background 24. Button parts, as page texels (u, v, width, height):

| Legend | Slots |
|---|---|
| node legend, greyed and lit rows | Triangle Camp (0,102) and (0,118), 22x10; Cross Enter (0,131) and (0,147), 22x11 |
| panel under it (sprite u56 v96, 72x64, drawn at screen 16,170) | SELECT Map (64,128) 22x8; Square Menu (64,136) 22x9 |
| map view | Triangle Cursor (8,171); SELECT Back (8,180); Square List, greyed (8,192); SELECT Back (8,200) |
| place list panels at u 120 and 192 | L1/R1 Search v206; Triangle or Circle Speed+ v214; Square List v223; SELECT Back v232; 21 wide |

The world map overlay (0x801f0800) reads Confirm from the action table
(0x801f26e8, 0x801f1b88, 0x801f2390, 0x801f316c, 0x801f3928) and the Menu
action 0x80116d8a at 0x801f2740 (to its menu phase 4); Triangle (0x801f19b8,
0x801f20b8) and Select (0x801f1a14, 0x801f2098) raw; L1|R1 from scratchpad
0x1f80002e (0x801f2680). `qol/world_legend.odin` redraws the slots for the
input device; the Menu legend shows Start, the port's menu button.

## Controls

| Address | Content |
|---|---|
| 0x80116d84 | action table: 9 u16 pad masks (Confirm, Cancel, Action, Menu, Dash, Turn R, Turn L, Rank R, Rank L) |
| 0x801e8464 | overlay 21: the game's four layouts (Type 1-4) |
| 0x8011ad78 | u8 chosen layout type |

The game copies the chosen type into the action table when the Buttons screen
is cancelled and when the camp menu closes (0x801aa784). The port's controls
screen (`qol/controls_screen.odin`) replaces the game's Buttons screen
(`BUTTONS_TICK` 0x801b6fd4 wrapped, `BUTTONS_DRAW` 0x801afcac replaced) and
writes its custom layout back after those copies.

Pad masks as the game sees them (`PAD_*` in `psx/host/platform.odin`; the action
table uses the same bits): L2 0x0001, R2 0x0002, L1 0x0004, R1 0x0008,
Triangle 0x0010, Circle 0x0020, Cross 0x0040, Square 0x0080, Select 0x0100,
Start 0x0800, Up 0x1000, Right 0x2000, Down 0x4000, Left 0x8000. A set bit
means pressed. Names usable in configs and `BOF4_INPUT` are `PAD_NAMES` in
`psx/host/input.odin`.

## Settings

The camp menu's Setting screen has the game's Options rows: Vib, Dash
(Manual/Auto), Camera (Normal/Reverse), D-Pad (L45/0/R45), Text speed, Sound,
BGM, SE; plus Buttons and Screen. The port adds its own rows between the
game's (`qol/options_screen.odin`), replaces Screen with its Display page and
adds Extras pages (`qol/options.odin`, `qol/setting_menu.odin`).

The title screen's Option entry runs a second copy of the same Setting code
in title overlay 22 (`SYSTEM/GAME.EMI#1`, slot 0x801aa000), so the port hooks
both copies and every page works from the title too. The two copies differ
only in addresses and message ids; each hooked constant is a
`[Setting_Overlay]` array (`.Camp`, `.Title`) indexed by `setting_overlay`,
which the hook wrapper sets before the shared tick or draw runs. The title
copy differs in three ways:

- The tick skips the camp's window-draw gate. Cancel on the Command list plays
  the cancel sound and returns to the title menu: s16 0x801148d8 = 3, s16
  0x801148da = 0.
- The Command window draws the window record at u32 0x8011de24, not a0.
- The open and shut steps are inline in the title copy, not calls; the port
  repeats them (`command_open_step`, `command_shut_step`).

Two labels differ between the copies: the camp copy says Reset where the title
copy says Default.

## Camp menu

The camp menu is overlay 0x11 (`SYSTEM/SGAMEN.EMI`, slot 0x801aa000). Its
Command window lists Item, Special, Equip, Status, Change, Setting and Save;
the port adds Masters (with `[masters] tracker`) and Journal after them
(`qol/camp_menu.odin`), so the game's commands keep their rows and the
cursor byte stays their command number.

| Address | Content |
|---|---|
| 0x801aa28c | CAMP_TICK: cursor, confirm, cancel, front/back swap, Select's message (hand port) |
| 0x801ab57c | COMMAND_DRAW: the open Command window (hand port; opening and closing run as the game's) |
| 0x801ac448 | TIME_DRAW: the Time window, y 169 (hand port when rows push it down) |
| 0x801ac668 | ZENNY_DRAW: the Zenny window, y 192 (hand port when rows push it down) |
| 0x8011dcec | Command window record: +4 open, +6 width (0x4c open), +0xc cursor |
| 0x8011a902 | u8 nonzero while a command's screen is up |
| 0x8011de24 | pointer to the Time/Zenny record: +3 shut, +6 width, +0xe colon shown, +0xf blink frames |
| 0x801510e8 | side window frame: a0 x, a1 y, a2 width, a3 0 |
| 0x801521c4 | window tab: a0 x, a1 y, a2 tab (9 Time, 10 Zenny, 0x100 Command), a3 |
| 0x80141104 | number: a0 x, a1 y, a2 width, a3 format, [sp+16] value |
| 0x801e7610 | the zenny mark: a0 x, a1 y, a2 0x3c00, a3 5 |

Time and Zenny share their record, take their width from the Command
window's as it opens, and shrink (76, 64, then 16 a frame) when a command's
screen opens. Their contents only draw at width 76. With nine rows the port
grows the Command window 14 pixels and draws both windows that much lower;
with eight the game's own draws run.

Command icons are 12x12 texels from the 4-bit sheet in texture page 13 (VRAM
x 832), row v 0x80 from u 0x30, CLUT (144, 241). The port writes Masters' icon
at u 0xcc v 0x80 and Journal's at u 0xe8 v 0xf0, unused texels, and falls back
to a game icon if either spot ever holds something else.

Journal and Masters open pages of the port's panel (psx OSD panel, also F2):
Left/Right turns pages, Cross/Circle/Triangle close it. The journal lists the
current objective and the beats done, newest first, from the quest tracker's
table (`qol/tracker.odin`, see story-and-maps.md). The Combos page after it
lists the magic combos and how to make them, names hidden until a party
member's action becomes one (`qol/combos.odin`, see battle.md "Magic
combos"); Masters comes last when its tracker is on.

Select at a battle member's command menu opens the Combo window
(`qol/combo_menu.odin`, top-left, x 24 y 24 w 272): the title, the target
enemy's name on the right for a single-target first spell, then the
combos, 5 at a time (scrolling), each its name (yellow when picked), "Mastery n/5" and a grey line
"Nina: Sever, then Cray: Frost". Up/Down picks, Left/Right the target,
Confirm sets it up, Cancel or Select closes; see battle.md "Combo command".

## HUD

The compass in the top-left of the field is FLD_MAIN task 0x801ce370; it
draws while u8 0x80116fac is non-zero.

## Screen fades

All full-screen fades in the field and between maps come from the game mode
overlay:

- `FADE_DRAW` 0x8018f474 (a0 level 0..0xff, a1 layer, a2 blend) draws one
  320x240 rectangle (GPU command 0x62), subtractive for fades to black,
  additive for white; the grey level is the fade's progress.
- `FADE_STEP` 0x8018f524 (a0 pointer to an s16 counter 0..0x7fff, a1 speed,
  a2 layer, a3 blend)
  draws level `counter >> 7` and adds the speed; returns 1 when done.
- 0x8018f5ac (a0 s16 speed, a1 blend) loops it a frame per step; wrappers from 0x8018f8cc use speeds
  from ±0x2000 (4 frames) to ±0x100. A map change uses 0x1000 (8 frames).
- Fade state bytes for a map change: 0x80116bcc / 0x80116bcd.

Battle and other overlays carry their own copies of the fade code.
