# Battles

The game is in battle when `GAME_MODE` (u16 0x80114850) is 5 (2 field,
4 event, 6 camera turn). The battle system is overlay 51 at 0x801aa000 with
its round overlay at 0x801cc800 (see [overlays.md](overlays.md)).

## Characters

| Address | Content |
|---|---|
| 0x8011a94c | character records, 7 of 0x98 bytes |
| 0x8011ad88 | party: u8 record indices, up to 6, 0xff empty |
| 0x8011ad84 | party membership bits |

Record offsets: +0 name (8 bytes), +10 u16 level, +20 u16 HP, +30 the 16
own spells (skill ids, 0 empty), +46 the 8 learned-skill slots, +56 u16 max
HP, +66/+68/+70 u16 Pwr, Def, Agl after equipment.

A battle works on its own copies of the records, somewhere in
0x801c0000..0x801e0000, and recomputes their stats as it starts; writes to
the records in 0x8011a94c during a battle do nothing. Find a copy by
matching the name and max HP (`find_fighter` in `qol/autoplay.odin`); the
copy has the same offsets. Pointers to the acting combatant and its target
are at 0x80116d98..0x80116db0.

## Battle loop

The battle's per-frame entry (0x801aa7b4) dispatches the current phase
through the table at 0x801c5e30; phase state at 0x8011ded4.

| Phase | Handler | What |
|---|---|---|
| 2 | 0x801ab298 | command entry; sub-phase 0 (0x801ab2d8) is an 8-frame countdown after the last command |
| 3 | 0x801ccbe0 | the round (sub-phase table 0x801e4dcc); sub-phase 3 runs an actor's action script, the others are bookkeeping |

| Pool | Base | Stride | Count |
|---|---|---|---|
| party combatants | 0x801c79b8 | 0x1a4 | 6 |
| enemy combatants | 0x801c6ec0 | 0x1c8 | 6 |
| effects (ticked by 0x801ba12c; persistent ones by 0x801ba1f0) | 0x801c83a8 | 0x9c | 64 |
| damage number popups (ticked by 0x801af948) | 0x801caab0 | 0x10 | 24 |
| windows | 0x8011db9c | 0x18 | 27 |

Combatant +0 flags (bit 0 active), +4 u8 animation mode (1 resting), +8 u8
action state (3 idle). The round waits on the per-frame masks at
0x8011df34/0x8011df36. Battle camera state is 0x80 bytes at 0x80138170.

`qol/quick_battle.odin` runs bookkeeping phases several times per frame and
`qol/popup.odin` finishes settling damage numbers.

## Enemy-skill learning

Each round action is recorded at 0x8011e0c0: u8 actor (0 Ryu, 6/7 the enemy
slots), u8 kind (1 plain attack for the party and enemies alike, 2 seen from Caps
with no hit, 4 skill), u16 skill id at +2 (a plain attack leaves the last
skill id there). For kind 4 the round
calls LEARN_CHECK 0x801d8208(skill) (round overlay), which returns 0 when the
skill cannot be learned, 1 when someone learned it, 255 when nobody did.

Skill data is at 0x8019add0, 12 bytes per skill id; the low nibble of byte 2
is the learn level, 1 easiest to 8 hardest, 0 not learnable (73 skills have
one). Each party member whose command this round is Guard (combatant +0x139
== 2; 1 is Attack) rolls once, in party order, and the first to pass learns
it:

    part   = min(gauge * 100 / gauge_max, 25)        gauge u16 +0xb8, gauge_max u32 +0xd8
    chance = (part + 75 if +0x120 == 4 and char < 7  char = u8 +0xa4
              + learn stat (u8 +0xf2) + 100) * 100
             / DIV[level - 1, one less at gauge >= max/4, one less again at
                   gauge >= max/2, not below 0]
    DIV    = 1, 2, 4, 8, 12, 16, 32, 64              round overlay data 0x801cc834
    learned when rand() (0x8016f384) % 10000 < chance

Combatant offsets are from the party combatant (0x801c79b8, 0x1a4 each),
whose copy of the character record starts at +0x9c. The gauge was 0 in every
battle tested; Ryu's learn stat is 25, so a level 3 skill is a 31% roll.

Learning goes through SKILL_ADD 0x80194da8(record, skill, mode). The party's
learned skills are bits in SKILL_BITS 0x8011b5c8 (bit = skill - 0x54), and
each record holds 8 slots at +0x2e. Mode 1 (the game's) fails when the bit is
set already or when all 8 slots are full, so a full list loses the skill
without a word; mode 0 sets the bit alone when the slots are full, leaving the
skill for camp. On success the game opens window 0x801ba2b4(3, 4), stores the
learner at +8 of that effect slot (0x801c83a8 + slot * 0x9c), the skill and
learner at 0x8011df30 + 0x18a / + 0x18b, and sets bit 0x08000000 of u32
0x8011deec, which shows text 0x2010, "X learned: Skill!".

`qol/learning.odin` (`[battle] sure_learn`) replaces LEARN_CHECK: no Guard
needed, the first standing member (a guarding one first) always learns, the
rand() is still drawn, and SKILL_ADD runs in mode 0.

### Which enemies know a learnable skill

Enemy combatants are at 0x801c6ec0, 6 x 0x1c8: name at +0x9c (8 bytes), HP
at +0xb0 (u32), the 8 skills it can use at +0x12c (one byte each, repeats
allowed: a Cap holds 0x66 Distracted eight times). They fill in after the
command overlay (BTLCOMD.EMI, overlay 0x33 at 0x801cc800) arrives. Skill
names: 0x80022a00 holds a u16 per skill id, an offset from 0x80022a00 to the
NUL-terminated name. The u32 at the overlay slot is the resident overlay's id
(0x33 command input, 0x34 the round, 0x35 the end).

`qol/examine.odin` (`[battle] examine`, on by default) draws a window at the
top left during the battle's first command input: each enemy kind with a
learnable skill, its skills green until the party knows them, grey after.

## Guard

Guard (command 2) sets bit 0 of the combatant's u16 at +0x134 as the round
starts; ROUND_END 0x801d24e0 (round overlay) clears it with the commands.
Combatant +0x134 is also the hit result the damage code fills (+0x140 s32,
the damage). The physical damage formula 0x801d3b58 halves a hit on a
guarding target 15 times in 16 and cuts it by a quarter otherwise (with
+0xae bit 0x4000 set: halves 3 times in 4). Another formula at 0x801deda8
adds 10 for a guarding target. The damage code reads the bit, not the
command byte. Caps (map 080c) never attacked a guarding Ryu.

`qol/guard.odin` (`[battle] guard_ap`) hooks ROUND_END: each standing member
whose guard bit it clears regains a fifth of its max AP (+0xb4 AP, +0xd8 max
AP, u32), rounded up.

## Random encounters

FLD_MAIN calls 0x801d728c(obj) once per leader step. It counts down a step
budget (u8 0x801172a7), 1 per step walking and 2 running; at zero it flags a
battle (bit 0x200 of u16 0x801172ac) and returns 1. A budget of 0xff asks
0x801d7024 to roll a new one. Bit 0x2000 of u16 0x801172aa disables
encounters; the map table at 0x800fa8a8 (12-byte rows, u16 at +4) says whether
a map has any. `qol/encounter.odin` replaces the check to scale the rate.

## Skill cinematics

Some skills (the dragon transformations) play a long cinematic loaded from a
companion file beside the skill's own: `BMAGIC/MAG060_0` to `MAG211_1`, game
file indices 0x62..0x72. Every skill ends by loading `MAGRET` (file 0xf).
`qol/cinematics.odin` watches file reads (`spu.read_start_hook`) between the
two and, for cinematics already seen (a bitmask in the config's `[battle]`
section, `seen`), runs the game unpaced with the sound off until MAGRET.

Not covered: `MDEMO` cinematics and summons without a MAG companion file.

## Identify

Skill 239, Identify, is in the skill-name table but nobody learns it in the
US release. Its overlay is still on the disc: `BMAGIC/MAGIC239.EMI`, overlay
211 at 0x801e6800. Cast on an enemy, it opens a Data window, drawn by
DATA_DRAW 0x801e9868, showing the kind, name, HP, resistances, EXP, zenny and
items. Circle closes it (bit 0x20 of 0x80116d3a, tested at 0x801e6efc).

| Address | Content |
|---|---|
| 0x8011de24 | pointer to the scan: +8 s16 window x, +10 s16 y, +12 s8 combatant index |
| 0x8011deeb | nonzero: the "unknown" page (no resistances) |
| 0x801c6410 | combatants, 0x1c8 apart (enemies from index 6) |

Combatant +0xe6 holds 4 attack-kind levels (slash, ranged, magic, dragon)
and +0xea 8 element levels (fire, wind, water, earth, holy, mind, status,
death), 0..7 with 2 normal; holy's run two higher. Levels 0 and 1 are weak,
2 and 3 normal, 4 and up resisted.

The resistance rows were one kanji per 12-pixel cell, coloured by level. The
US text puts words there ("Fire", "Slash", ...) that overlap, and the HP
separator string is "?". DATA_DRAW draws them through TEXT_DRAW, called from
0x801e9a50 (separator), 0x801e9afc, 0x801e9b64, 0x801e9bec (element labels)
and 0x801e9c90 (kind labels).

`qol/identify.odin` drops those TEXT_DRAW calls while DATA_DRAW runs and
draws "/" and the rows again: element and weapon icons from the menu icon
sheet (texture page 15, 12x12, skills at v 0xe8 with CLUT 208,240, items at v
0xf4 with CLUT 224,240), tinted red, grey or blue by level (checked in game
by poking an Eye Goo's level bytes before the scan). Dragon has no
icon on the sheet, so a green Dragon Crystal (the items that give Ryu his
forms) is written into a blank part of page 15 (u 0, v 24) with its own
16-colour CLUT at VRAM 976,24 (rows 24..44 of page 15 are unused in battle)
and drawn from there.

With `[battle] identify` Scias gets the skill among his own spells from level
3. The hook is the battle's party setup 0x801aec7c (overlay 0x32 at
0x801aa000), which runs before the records are copied into the combatants.

## Battle rewards

A won battle leaves its totals at 0x8011df48 (u32 EXP) and 0x8011df4c (u32
zenny). BTLEND.EMI (overlay 0x35 at 0x801cc800) runs its first state,
BTLEND_INIT 0x801cca50, every frame until the screen effect is idle
(0x8011c99e == 4, the test at 0x8013c388), then once: EXP is halved, rounded
up, when 0x8011dee6 has flag 0x8; "N EXP" is printed; 0x801cddb0 splits the EXP
among the standing members by level into pending amounts at 0x801c8390 (u32
per member). Later states count the pending EXP into record + 0x0c (u32,
capped at 9999999) and the zenny total into the party's zenny 0x8011ad80
through 0x80195358, which also adds to 0x8011b680. The battle copies the
records back (0x801cdac0) before the count.

`qol/rewards.odin` (`[battle] exp_rate`, `zenny_rate`, 0..16) hooks
BTLEND_INIT and scales both totals on that frame, so the message, the split
and the count use the scaled amounts.

Enemy records come from the battle area file (`BWORLD/AREAB<nnn>.EMI`, the
entry loaded at 0x801f5800): 0xa0 bytes of formations, then 0x108-byte
records. Record +0 is the 8-byte name, u16 +0x10 the zenny, u16 +0x12 the EXP,
u32 +0x28 the HP (zenny/EXP: Cap 8/7, Scorpion 10/20, Zaurus 350/2000, Goo
King 1000/3000). Checked in game with `BOF4_ENEMY_STATS` (debugging.md): the
zenny paid is +0x10's. EXP per enemy runs about 7-80 in the first areas,
200-800 in the middle and 2000-3800 late (Gecko 3800, Cyclops 3500).

Which battle loads is three bytes of the battle state 0x8011ded4: +0x15
(0x8011dee9) the area, +0x16 the formation, +0x17 (0x8011deeb) the boss id.
A field encounter (0x801d4004 in overlay 0) picks the area by weight from
the map's table. The battle file's read, 0x801e73dc in each field map
overlay's own copy, loads file BOSS001 - 1 + area (0x1cd + area) when the
boss byte is set, else AREAB000 + area (0x14b + area), through the loader
0x8013b6f4. The battle overlay then picks the formation from the file's 8
(0x14 bytes each, weighted, 0x801b9a84) and, with a boss, calls the boss's
setup from the table at 0x801c65cc (33 entries, 0 none) by the boss id
(0x801b9980). The setup lives in the BOSS file's 0x801ee800 overlay and
points each boss combatant's +0x140 at its script table. The boss id is the
BOSS file's number, 1..32, so setting both bytes to N and loading BOSS<N>
runs that boss fight as in the story (autoplay `boss N` does this in the
loader). A forced fight still plays the boss's own ending, which may move
the party (Kahn, BOSS007, ends on map 1029).

Prices: the shop's lookup 0x801af6fc (overlay 18, a0 the section, a1 the
item) reads a u16 sell price, and the buy price is twice that. Tables in
GAME (overlay 0x0e): items 0x80199d9c (8-byte entries, price at +6), weapons 0x8019a154 (14,
+12), armor 0x8019a624 (12, +10), accessories 0x8019a96c (12, +10). The
lookup then checks the 7 character records at 0x8011a94c (152 apart) for
byte +0x82 == 45 and takes another path when one has it. Late weapons sell for
10000-30000 (buy 20000-60000).

### Level-up growth

The growth table sits at 0x8019bbf8 (overlay 0x0e's data, at 0x8018d800):
800 bytes per character (record order Ryu, Nina, Cray, Scias, Ursula,
Ershin, Fou-Lu), one 8-byte row per level 0..99:

| Row byte | Content |
|---|---|
| +0 | u16 EXP for this level step / 2 (0xffff at 99) |
| +2 | HP gain |
| +3 | high nibble AP gain, low nibble gain of record +0x64 |
| +4 | high nibble Pwr, low nibble Def |
| +5 | high nibble Agl, low nibble Wis |
| +6 | skill id learned (0 none) |
| +7 | Ershin only: a second skill, learned only while flag 11 of 0x8011b878 is set |

0x801956ec (a0 the record) sums the EXP of rows 1..level (x2) for the next
level's threshold; level 99 returns -1. The level-up 0x80196eb8 (a0 the
record, a1 a 16-byte result for the victory screen) counts how many rows the
record's EXP (+0x0c) passes, then for each level gained applies row
*level* (before it rises): each gain plus the master's bonus for that stat
(GAME.EMI s8 table 0x8019de28, 6 bytes per master id from record +0x84: HP,
AP, Pwr, Def, Agl, Wis), clamped at 0, is added to the base stats and to the
current HP/AP. Caps: HP 9999, AP/stats 999. The +0x64 stat gets no master
bonus. The row's skill goes in the first empty slot of +30 (16 own spells).
It ends with the stat rebuild 0x801961b4.

Record stats: base block +0x5c u32 max HP, +0x60 u32 max AP, +0x64 u16 (not
shown on the Status screen; 3..36), +0x66 Pwr, +0x68 Def, +0x6a Agl, +0x6c
Wis (u16 each); the same layout after equipment at +0x38..+0x48; current HP
u32 +0x14, AP u32 +0x18.

Totals at level 50 / 99 from the table (no master bonuses; level 1 bases from
a save):

| | HP | AP | Pwr | Def | Agl | Wis |
|---|---|---|---|---|---|---|
| Ryu | 2706 / 3892 | 293 / 409 | 221 / 304 | 194 / 278 | 188 / 254 | 193 / 263 |
| Nina | 1938 / 3028 | 350 / 476 | 170 / 238 | 157 / 229 | 251 / 329 | 289 / 395 |
| Cray | 3185 / 4604 | 91 / 113 | 260 / 349 | 212 / 295 | 127 / 171 | 119 / 159 |
| Scias | 2407 / 3604 | 196 / 280 | 195 / 277 | 183 / 261 | 219 / 293 | 209 / 279 |
| Ursula | 2261 / 3360 | 224 / 320 | 201 / 283 | 174 / 251 | 196 / 270 | 242 / 316 |
| Ershin | 2759 / 4031 | 132 / 207 | 216 / 302 | 253 / 321 | 155 / 205 | 254 / 439 |
| Fou-Lu | 2720 / 3887 | 302 / 529 | 204 / 317 | 185 / 279 | 187 / 263 | 223 / 415 |

Cray's AP is 19 at level 10 and 49 at 30. Ershin's AP is 14 at level 20;
Ershin's AP and Wis climb from about level 30. Level skills: Nina (Heal 2 ..
Vigor 38), Cray (Protect 1 .. Quake 29), Scias (Sleep 1 .. Restore 36),
Ursula (Fireblast 1 .. Death 34). Ershin's +7 list: Stand Out 12, Death 14,
Blizzard 18, Quake 22, Inferno 27, Typhoon 34, Primus 44. Ryu and Fou-Lu
learn nothing by level.

### Weapons

The weapon table 0x8019a154 (GAME) holds 88 entries of 14 bytes:

| Byte | Content |
|---|---|
| +0 | target (0x6e one, 0x67 all: spread guns) |
| +1 | flags |
| +2 | type: 0x01 sword, 0x11 Scias's blades, 0x21 clubs, 0x31 staves, 0x41 guns, 0x51 spread guns, 0x61 knuckles and claws |
| +3 | effect |
| +4 | who can equip: 0x01 Ryu, 0x02 Nina, 0x04 Cray, 0x08 Scias, 0x10 Ursula, 0x20 Ershin, 0x40 Fou-Lu |
| +5 | element (read for a party plain attack) |
| +6 | unknown, 0..0x10 |
| +7 | high nibble hits (2 = two-hit; compared with combatant +328 at 0x801b4efc), low nibble unknown 1..8 |
| +8 | u16 attack |
| +10 | u16 icon / description id |
| +12 | u16 sell price |

Two-hit weapons: Scramasax, Firangi, Slicer (Ryu); Jang'do, Taegum, Biter,
Render (Scias); Flail, Pole (Cray); MultiGun, Flintlock, Repeater (Ursula);
Royal Sword. Ershin's knuckles all hit once. Highest attack: GooKingSword
152, Nunchaku 145, Linked Pole 133, Dragon Blade 128, Earthbreaker 126.

A party combatant's weapon id is at +284. Weapon specials are keyed by id in
the battle code, not by a table byte: the Cursed Sword (22) check at
0x801dda2c (BTLMOVE) takes HP / 16 from the wielder at the end of each of
its turns; 0x801d3ca4 tests 28 (Cleaver) and 77 (Ghostbuster), 0x801df5e8 tests
79 (Power Glove). Type 0x51 (spread guns) hits every enemy (0x801d5db0).

Character records hold the equipment ids at +0x80 weapon, +0x81 armor, +0x82
accessory (0 none). Armor rows are 12 bytes from 0x8019a624 (+2 type, 0x22
robes; +6 u16 defence). The stat rebuild 0x80196324 (a0 the record) adds
the equipment to the base block into the after-equipment block and caps it;
Wisdom comes from the Wisdom Ring (+20) and Sage's Frock (+5) (and the smith's armor 57 and 64). 0x801961b4 (no arguments) runs it for
every party slot; the game calls it only after an equipment change and at a
battle's end.

### Victory screen

BTLEND runs while the battle phase 0x8011ded4 is 7. Its tick 0x801cc9d0 runs
once per game tick (30 Hz) and dispatches on the state 0x8011ded5 (table
0x801d0a6c), each state on the sub-state 0x8011ded6 (0x801d0a7c, 0x801d0a88,
0x801d0a94):

| state | sub-states | does |
|---|---|---|
| 0 EXP | 0 BTLEND_INIT, 1 0x801cccc8, 2 0x801ccd10 | 1 sets the count 0x8011dee0 to 60; 2 counts, waits for a press, then checks level-ups (0x801956ec) and goes to state 1 or 2 |
| 1 level | 0 0x801cd1a4, 1 0x801cd2fc, 2 0x801cd374 | 2 shows each levelled member (0x8011dee0 is the member index here), one per press |
| 2 zenny | 0 0x801cd518, 1 0x801cd84c, 2 0x801cd8ac | 1 sets the count to 70; 2 counts the zenny, waits for a press, then adds the item drops (0x80194ae8) |
| 3 | 0x801cda6c | leaves: phase + 1 |

While the count runs, each odd tick moves a thirtieth (at least 1) of each
pending amount into the totals, and at 1 the rest; a press during the count
ends it at once. The waits take PAD_PRESSED 0x80116d3a & 0xf6ff (anything but
Select and Start) and need 0x8013c388 to say the screen effect is idle.
Unpressed, the vanilla screen sits on each page until a button.

`qol/victory.odin` (`[battle] quick_victory`, default on) hooks the tick: it
cuts the count to 10 ticks on entry, and once a page's count is over and it
has held 45 ticks (1.5 s) it presents a confirm press for that tick, so the
results go by with no input.
## Item sources

Every item the party gains goes through GIVE 0x80194ae8 (GAME, overlay 0x0e;
a0 the kind, a1 the id, a2 the signed count). Kinds: 0 items (122), 1
weapons (88), 2 armor (80), 3 accessories (87), 4 skills (256), 5 key items
(48); the names are INIT.EMI entry 6. GIVE also sets an "ever obtained" bit
at 0x8011a94c + 3216 + kind * 16 + (id >> 5) * 4, and it is the only writer
of that block, so the block shows what a save has ever held. GIVE is never
called through a pointer and never from the exe: 143 direct call sites, all
in overlays. There is no field-script give op; the field overlay (FLD) calls
it only for search spots (0x801d2af4, 0x801d2c50) and chests (0x801d3aa0,
0x801d3c58).

| Source | Where | Format |
|---|---|---|
| Chests | map spawn lists, spawn type 9 | 221 chests |
| Search spots | map spot records, 8 bytes | an item when byte 7's high nibble is 0: +4 kind, +5 id, low nibble of byte 7 the count |
| Enemy drops | BWORLD enemy record +0x38 and +0x3c | {u16 kind << 8 \| id, u8 chance index}; chance 0, 2, 4, 16, 32, 64, 128, 256 out of 256. The battle overlay 0x32 copies them to combatant +292/+296 (0x801ae4f0) unless flag byte 10 bit 0x80 is set; a formation can override them (0x801adee4: formation byte 8 flags, bytes 10..15 big-endian kind/id) |
| Shops | SHOP.EMI entry 9 (overlay 0x12 at 0x801aa000), table 0x801af9a8 | 41 shops x 32 bytes: u8 count, u8 0, then up to 15 (id, kind) byte pairs. The shop index is 0x8011a909. Shop init sets the buy list's count byte 0x8011dc83 (list window 0x8011dc5c + 24, byte +15) from the table, then 0x801af694 copies the pairs, order kept, into the 0x801e8aa8 buffer; the list scrolls past 8 rows. Init at 0x801af480 rewrites the current shop's count in place when map - 553 < 2. The price routine 0x801af6fc doubles the table's sell price for the buy price (with an accessory 45 check). Which map opens which shop: [Shops by map](#shops-by-map) |
| Manillo fish trade | MSHOP.EMI entry 9 (overlay 0x13), table 0x801aeed8 | 56 x 8 bytes: id, kind, fish 1..3, count 1..3; fish item = fish + 45, 0xff none |
| Stamp Card | MSHOP, table 0x801af0d0 | 3-byte {kind, id, cost}, 8 rows: Magic Shard 3, Power food 3, Swallow Eye 3, Fish-head 3, Coupons 25, Dragon Tear 50, Linked Pole 75, Render 99 |
| Fairy farm | COMMU03.EMI entry 9 (overlay 0x1e), table 0x801ae1ac | 3-byte {kind, id, ?}: the 8 seeds Fire .. Holy (88..95) |
| Fairy shop | COMMU09A.EMI entry 7 (overlay 0x24), table 0x801ad130 | 12-byte {u32 cost, u32 kind, u32 id} |
| Junk smith | AREAS013 (`ov_801f0800_444`), recipe 0x801f16f4 | three junk items in, one Ershin armor out (see "The junk smith" below) |
| Map trades | map overlays (`ov_801f0800_*`) | small (kind, id) tables, e.g. the utensil chain (AREAS017, 0x801f0e50: Toothpick .. Fork) and junk parts (AREAM018, 0x801f0978) |
| New-game inventory | GAME.EMI entry 1 (overlay 0x16), presets at 0x801b5808 | 220-byte presets: item/count arrays at +52/+68 items, +84/+100 weapons, +116/+132 armor, +148/+164 accessories (loop 0x801b3e60). Preset 0 is the new game (Healing Herb x3, Aurum); the rest are debug starts |
| Starting gear | character records 0x8011a94c + 152 * n, +0x80/+0x81/+0x82 | given back by 0x80191bdc when a member leaves |
| Faerie village | overlay 0x1b (`ov_800f8800_027`, AREAE024..028, AREAS041/042) | 0x800fdee8 gives the grown item (+34/+35 of 0x8011b9bc, see "The faerie village crop" below); 0x800fdd00 gives faerie finds from the 4 x 8 (kind, id) table 0x800ff138 (junk, food, utensils, rings) |

### Shops by map

The shop index 0x8011a909 is written only by the field talk handler, from the
shopkeeper slot's +186 (spawn record byte 12 of a type 5 record, or script op
`a0 05 SS II`; [field.md](field.md#talking)). Found by walking every map
overlay's spawn lists for type 5 records and scanning the scripts for op a0:

| Shop | Map | Notes |
|---|---|---|
| 0 | AREAM019 (0x1013) | the Dengeki test village |
| 1 | AREAS007 (0x0207) | |
| 2, 3 | AREAM000 (0x1000, Sarai) | 2 is fishing gear; it and 34 recur at fishing spots through op a0 |
| 4 | AREAM002 (0x1002, Synesta) | |
| 5 | AREAS011 (0x020b) | script (op a0) |
| 6..9 | faerie village item shop | 6 + the building's stock byte: 6 basic, 7 consumables and Wisdom Seed, 8 trick items, 9 bombs |
| 12..15 | faerie village equipment shop | 12 + the stock byte; the count is rewritten per village record (SHOP init 0x801af448..0x801af480: 0x800f88e4(), record +26) |
| 16 | AREAM001 (0x1001) | probably also AREAD057, AREAD065, AREAE031 (script `a0 05 00 10`) |
| 18, 19 | AREAM012 (0x100c) | |
| 22 | AREAS045 (0x022d) | |
| 24, 25 | AREAM033 (0x1021, Shyde) | |
| 26 | AREAS020 (0x0214) | |
| 28 | AREAS018 (0x0212) | |
| 29 | AREAM020 (0x1014) | |
| 30 | AREAE031 (0x081f), AREAS031 (0x021f) | |
| 31, 32 | AREAM017 (0x1011) | script |
| 33 | AREAS050 (0x0232) | script |
| 34, 35 | AREAM025 (0x1019) | 34 fishing gear |
| 36 | AREAM018 (0x1012) | Mithril Armor, Wolfskin, consumables |
| 38 | AREAD004 (0x0404) | script 10 (`a0 05 00 26` at 0x801f389e) of a hidden NPC with the shopkeeper sprite 0x3a |
| 39 | AREAS052 (0x0234) | the Dengeki store (seen at run time: 0x8011a909 = 0x27) |
| 40 | AREAE076 (0x084c) | |

No reference found, so probably never opened: 10 (close to 37), 11 (Damascus
gear), 17 (the Midas goods of 39 in another order), 20, 21, 23 (the goods of
22), 27, 37. The Manillo trades (talk type 21, MSHOP index in slot +186):
AREAM000 6, AREAM009 (Wyndia) 4, AREAM017 5, AREAM019 0, AREAM025 1,
AREAM031 3, AREAM033 2.

### Never-granted items

The union of the sources above, plus starting gear and constant-argument
calls, leaves these with no way to get them in normal play (fish 45..74 are
assumed to come from fishing). Stats are from GAME's equipment tables (see
Weapons above):

- Weapons: 53 Pole (Cray club, attack 66, two hits, sells for 8000) and 84
  Slayer (sword for Ryu, Scias and Fou-Lu, attack 80, two hits, sells for
  20000).
- Items: 108 Wassail +, 110 Draught +; 119..121 have no name. (106 Elixer +
  comes from elsewhere; the crop below cannot make any + drink.)
- Debug presets only: 47 Stout Mail, item 120.

An earlier pass listed Ershin's armor 49..69, the Spanner, the Master's
Rod, the Speed, Reflex and Sight Seeds, Wassail and Draught here: the smith,
the masters and the faerie crop give them with a variable id, which a
constant-argument scan cannot see. Variable-id GIVE
calls checked since: AREAS033 (`ov_801f0800_464`, takes a weapon), the hunting
maps AREAS057..059 and AREAE051..053 (meats 84..87, table 0x801f271c),
AREAM000, AREAM007, AREAE046 (table 0x801f0c60) and SCE01 (constants or
known goods). The shared masters overlay `ov_800f8800_025` gives a master's rewards at
0x800f8ccc from 24-byte records at 0x800f9684 (13 records, record 0 empty):
{u32 flags, two host-map handler pointers, four (kind, id) reward pairs at
+12, u32 0}. The current master is the byte 0x8011b7b4 (0x8011a94c + 3688);
the reward count reached is 0x8011a94c + 3413 + master. All rewards are
skills except record 6, Gyosil (fishing points, per Almar's Guides): Ring of
Ice (accessory 28), Spanner (59), Master's Rod (60). The rest of the
variable-id GIVE sites move goods the party already has or hands out known
tables: SGAMEN (0x11) and SHOP (0x12) equip swaps, buying and selling (+13
kind, +14 id, +15 count); CAMP takes item 35; the new-game overlay's preset
loop; the battle overlays' equip swaps, held items (+314), spoils list
(0x801cda1c) and steal, which reads the target's drop pair at combatant +292;
fishing (overlay 024, fish id + 45 from 0x801c3ac8); chests and spots
(overlay 015, struct +4 kind << 8 | id, +7 count); the faerie village
overlays (crop slots, fairy shop 0x801ad130, seed swaps 0x801ae1ac).

### The faerie village crop

The faerie village overlay `ov_800f8800_027` grows one item at a time. Its
per-frame update (0x800fb738) calls 0x800f97e0, which runs once the village
level (byte 0x8011b9c0) is 3 or more and no crop is waiting (+35 of the
block 0x8011b9bc is 0). The three ingredient slots are (id, count) at +28,
+30 and +32; ripening counts battles (0x8011b67c) scaled by the faeries
working job 3 (records 0x8011b9fc, 40 bytes each). The recipe 0x800f8cc8
then sets the item at +34 and its count at +35, which 0x800fdee8 gives.

Each fish (items 45..74) has {value, group} in the table 0x800fee68: value
times count adds to a score, and the slot counts for its group. Group 0:
Jellyfish 1, Martian Squid 16, Man-o'-War 1, Octopus 12, Acheron 64. Group
1: Bullcat 11, Sturgeon 47, Flatfish 9, Angler 27. The rest are group 2.
Bird Drop, Rotten Meat and Scorched Rice (112, 113, 34) add their count to
a spoil score instead, and any other item adds its count to the score; both
count as group 2. The group with the most slots wins (ties: 0 over 1 over
2, with a quirk when group 0 trails group 2).

| Rule | Item |
|---|---|
| score under 8 | 6 Berries x1 |
| spoil score s (capped at 3, cleared when the score is 16 or more) and a random 0..3 below s | group 0: 111 Dark Draught; group 1: 109 Draught; group 2: 105 Elixer or 107 Wassail (coin flip); x1 |
| otherwise, group 0 | 100 + score mod 5: Strike, Reflex, Dodge, Sight, Target Seed |
| group 1 | 96 + score mod 4: Strength, Hard, Speed, Sage Seed |
| group 2 | 88 + score mod 8: Fire .. Holy Seed |

A seed's count is the number of thresholds {8, 16, 24, 32, 40, 48, 57, 64}
the score reaches (1..8). The code adds one to the drink id (the + kind)
when the score is 96 or more and the group is not 0, but a score that high
has already cleared the spoil score, so Wassail + and Draught + never grow.

### The junk smith

Ershin's armor 49..69 comes from the smith on AREAS013 (`ov_801f0800_444`,
Mt. Glom per the wiki). The player hands over three junk items; the state
block at 0x801f4388 holds their ids at +8, +10 and +12, 0x801f1d80 takes them
(GIVE kind 0, count -1) and 0x801f1f28 gives armor +2 (armor 48 Stout Mail
when +2 is 0xff). The recipe 0x801f16f4 looks each id up in the 4-byte table
0x801f421c {item, element, opposite element, 0}: 81 Glass Shard, 82 Iron
Scraps and 114 Bent Screw are plain (0xff); 116 Dirty Filter is wind (0),
115 Old Tire earth (1), 117 Burnt Plug fire (2), 118 Rusty Pipe water (3);
wind opposes earth and fire opposes water. Order does not matter; +1 records
which rule matched. Rules, first match wins (emulated over all 84 sets):

| Junk | Armor |
|---|---|
| three different plain (81 82 114), three different elements, or two opposite elements | 48 Stout Mail (failure) |
| two non-opposite elements plus anything that is not a third element: wind+fire, wind+water, earth+water, earth+fire | 49 Booster, 50 Panzer, 51 Maelstrom, 52 Gravedigger |
| two different plain plus an element: 82+114, 81+82, 81+114 | 53 Orihalcyon, 54 Defender, 55 Quicksilver |
| three of one: 82, 81, 114, 117, 116, 118, 115 | 56 Mithril Rig, 57 Psychometer, 58 Lightning, 59 Fire Rig, 60 Whirlwind, 61 Water Rig, 62 Earth Rig |
| a plain pair plus anything else: 82, 81, 114 | 63 Heavy Armor, 64 Spirit Armor, 65 Light Armor |
| an element pair plus a plain: 117, 116, 118, 115 | 66 Flame, 67 Wind, 68 Hydro, 69 Earth Armor |

Junk sources (wiki, not checked in code): Morph's steal item follows the
element of the last hit (fire Burnt Plug, wind Dirty Filter, water Rusty
Pipe, earth Old Tire), random drops, AREAM018's junk pickup (0x801f0978:
114, 115, 118) and fishing.

Restored goods: the port's `[field] restored_items` option (Extras > Field,
"Cut goods", default off; `src/qol/restored.odin`) appends the never-granted
goods to shops after 0x801af694 runs, once the shop table hashes to vanilla
(counts excluded): shop 36 (AREAM018) Pole, Wassail + and Draught +;
38 (AREAD004) Slayer. Tiers were picked from each shop's goods and its map
([Shops by map](#shops-by-map)); the drinks were in shop 37 at first, which
nothing opens. The Slayer, which
"sometimes attacks allies", is repriced (captured row, so the option swaps
back at once) to 8000 sell, under the Slicer (78, two hits, 10000), instead
of 20000. The drinks and Pole stay vanilla. Ershin's armor (repriced),
the Spanner, the three seeds, Wassail and Draught were sold here too until
the smith, Gyosil and the faerie crop turned up: they are vanilla content,
and the armor's shop prices would have made forged junk sell for thousands. `BOF4_SHOP=<index>`
opens every shop as that index (testing). After a weapon or armor is bought
the shop always asks "Do you want to equip" it, even when nobody present can
wear it; "Equip who" then shows the members and confirm on one who cannot
does nothing. That is vanilla (seen with Nina's Reed Baton and Ryu alone).

Price reference for the Ershin armor (a value scale, not used by the port):
body armor by defence (Scale Mail def 20 1050, Brigandine 35 2400, Full Plate
47 3000) plus an accessory's price for its effect gives 49..52 1500, 53 5000,
54/55 4500, 56 3150, 57 3550, 58 8000, 59..62 1950, 63 2650, 64 2550, 65
4000, 66..69 1950. Armor stacks with accessories (58 Lightning with Winged
Boots is Dodge +40%, Agility +60 with Speed Boots), 53's +20 critical is
twice Burglar Garb's (def 77, 6000), and no vanilla gear casts at battle
start. A resistance adds little in vanilla (Ranger Garb def 16 "Resists
Fire" 750 against Steel BPlate def 17 650; Magma Armor costs what
BlizzardMail does).

The in-game descriptions add effects the stat rebuild does not show: 49
Booster, 50 Panzer, 51 Maelstrom and 52 Gravedigger counter with Firewind,
Jolt, Storm and Eruption; 54 Defender and 55 Quicksilver cast Barrier and
Speed when a battle starts; 53 Orihalcyon raises critical hits (record +88);
+89 is Dodge (58 Lightning +20%, 65 Light Armor +10%); 59..62 are "Strong vs."
an element (weak vs. its opposite), 66..69 "Resists" one.

Armor effects are keyed by id in the stat rebuild (0x80193950, a switch on
ids 10..69 through the jump table 0x8018d978, helper 0x801946e8). The Ershin
set: 53 record +88 += 20; 57 Wisdom += 20; 58 Agility (+70) += 40 and +89 +=
20; 59..62 one resistance (+78..+81) +3 and its opposite -2 (59 78/80, 60
79/81, 61 80/78, 62 81/79); 64 Wisdom += 10; 65 +70 += 20, +89 += 10; 66..69
resistance +78..+81 +1.

Vanilla armor in the same switch: 10 Magma Armor +78/+81 +2, +79/+80 -1;
12 BlizzardMail the reverse; 15 Mist Armor +83/+84/+85 +2; 20 Chopam Plate
+74/+75/+76 +1; 29 Burglar Garb +88 += 10; 30 Gideon's Garb Power (+66) +=
10; 37 Robe of Wind +79 +2, +89 += 5; 38 Sage's Frock Wisdom += 5; 39 Holy
Robe +83/+84/+85 +1; 40 Phantom Dress +82 -3, +83 = +85 = 7; 41 Diana's
Dress +83/+84/+85 +2; 43 Star Dress +64 += 5; the rest one resistance step.
Accessories run through 0x80193c80 (jump table 0x8018da68, ids 7..54): 7
Divine Helm +85 = 7 (death immune), 11 Dragon Helm +83/+84/+85 +1, 12
Titan's Boots Power +10, 13 Wisdom Ring Wisdom +20, 14 Speed Boots Agility
+20, 15 Hawk's Ring +90 += 50, 16 Artemis' Cap +91 += 25, 17 Hunting Cap
+86 += 40, 18 Winged Boots +89 += 20, 26..29 Rings +78..+81 = 7, 30 Aura
Ring +83 +1, 31 Barrier Ring +83 +3, 32 Life Sandals +84 +1, 33 Light
Bangle +84 +3, 34 Talisman +85 +1, 35 Diamond Ring +85 +3, 36 Topaz Tear
+82 = 7 (absorbs Holy), 41/42 Soul/Spirit Ring +64 (CP) x1.5/x2, 46..49
Wards +78..+81 +2, 50 Astral Ward +76 +2 and +74/+75 -1, 51 Body Ward the
reverse, 53 Red Cape +87 += 50, 54 Toothpick +88 += 5.

### Item descriptions

Gear description ids sit in the 0x4000 bank (weapon record +10, armor and
accessory record +8), read through MESSAGE_TEXT (0x8014c0dc: a0 id, v0 the
text; id >> 13 is the bank). Bank 2 is loaded at 0x80017000 in camp, shops
and battle and ends at 0x8001c572. Its strings sit back to back with no NUL
between them: code 0x19 lo hi ends a string by continuing with string
lo | hi << 8, so many descriptions share a tail and none can be grown in
place. Other codes: 0x01 new line, 0x07 n a parameter (1 Pwr/Def, 2 Wgt, 6
the element), 0x05 2 .. 0x04 6 a coloured skill name (0x09 n).

Shared tails worth knowing: 0x4012 "Pwr Wgt", 0x4013 the same plus
"\x07\x06 attack", 0x4014/0x4015 the ranged pair, 0x4016 "Def Wgt", and
0x405e "Def Wgt  Blessed armor", which Mist Armor, Holy Robe, Diana's Dress
and Dragon Helm end with: "Blessed armor" is their +83/+84/+85 (mind,
status, death) resists from the switches above.

The US text leaves out most hidden effects. `[text] descriptions` (port
qol/descriptions.odin) rewrites 22 of them with what the code above does:
weapons 19 Dragon Blade, 20 Royal Sword, 22 Cursed Sword, 28 Cleaver, 29
Render, 40 BlessedStaff, 41 Ouroboros, 57 Linked Pole, 72 Homing Bomb, 77
Ghostbuster, 84 Slayer, 86 Dragonslayer; armor 15 Mist Armor, 39 Holy Robe,
41 Diana's Dress, 59..62 the Rigs; accessories 7 Divine Helm, 11 Dragon
Helm, 36 Topaz Tear. The new strings go to 0x8001d000 (free in camp and
battle up to the item names at 0x80021800), and each fires only when the
first 24 bytes at the game's pointer hash to the vanilla text, so another
bank loaded at 0x80017000 is never touched. Naro's "Better Descriptions"
hack (romhacking.net 9575) covers the same ground; two of its claims differ
from the code: Render's Power tops out at 1000 battles (+1 per 20, up to
+50), not 2000, and Linked Pole does x1.25 when the foe's level is higher
and x0.75 otherwise, the reverse of the hack's text.

The second GIVE in overlay 0x19 (0x800f8e58) reads the same master
record pairs: kind 4 (a skill) is stored at 0x8011a94c + 3690 for the
learned-skill message, any other kind goes to GIVE. Every variable-id GIVE
site has now been checked.

## Skill sources

Skill data is a 256 x 12-byte table at 0x8019add0 in GAME (overlay 0x0e);
the last u16 is the description id. Descriptions live in CAMP.EMI entry 8
(loaded at 0x80017000: a u16 offset table, then NUL-terminated strings), and
id 0x4000 + n is string n; 0x4000 and 0x4060 mean no description. Skills
reach a character, or a combatant, through:

| Source | Where |
|---|---|
| Level-up | growth table 0x8019bbf8, 800 bytes per character, chars 0..6: 8-byte rows per level, byte 6 the skill, byte 7 Ershin's second |
| Starting spells | GAME.EMI entry 1 (overlay 0x16), 0xb3e0 |
| Masters | ov_800f8800_025 records 0x800f9684 (kind 4 pairs) |
| Enemy skills | BWORLD enemy record lists (8 ids each), learned in battle (052, 0x801d8490) |
| SKILL_ADD 0x80194da8 callers | CAMP 0x801aaaac/0x801aac74, debug 0x801b41fc (overlay 0x16), MASTER 0x801acdfc, enemy learning 0x801d8490 |
| Meditate 76 | AREAD057 (overlay 312) code at 0x801f0d8c |
| Dragon forms 211..224 | menu table 050 0x801c6000, 4 rows of 6 (row 2 in Fou-Lu's chapter, +1 when the dragon record has flag 0x80, upgraded); entry + 211 is the form |
| Dragon attacks 60..66, 74, 75, 244..249 | BTLMOVE (052) table 0x801cc804, 15 ids, each with its own effect file 279 + i (0x801cc814); 0x801ced4c plays the file, any other id goes to 0x801e1d20 |
| Fou-Lu (char 9, his own chapter) | 050 0x801b31f4 sets HP 9999 / MP 999 and copies 14 skills from 0x801c6190: 244 Dark Wave, 209 Soul Rend, 161..172 |

Dragon records: GAME 0x80195f40(i) returns the 6-byte record of form i,
Ryu's at 0x8011b8d8, Fou-Lu's at 0x8011b8fc when 0x8011b6b4 == 6. +0 flags
(1 owned, 0x80 upgraded), +2 u16 HP, +4 u16 max HP. A transformed combatant
has +0x1a3 bit 0 set and char id 7 (Ryu) or 8 (Fou-Lu); reverting (050
0x801c0824, 0x801c10dc) stores HP back into the record, clears the bit, sets
the char id back to 0 or 6 and rebuilds the combatant with GAME 0x8019671c.
In battle the menu state byte is 0x8011ded7 (table 0x801d5b9c in 051); the
Dragon picker is 0x801d0254 (sub-state 2 of state 1), which needs the
record's HP nonzero and sets the action to 211 + table entry.

Skills 67..73 (Onslaught .. Holy Circle) carry the same dragon-attack flags
(byte 7 = 1, byte 9 = 0x10) as 60..66 and use the generic effect path;
244..249 copy 75, 60, 62, 63, 61, 64 (same descriptions). 254/255 are the
battle-start casts of armor 54/55.

Egg Magic 55 Sacrifice, 56 Boil, 57 Hatch (byte 4 = level 1, 2, 3) is the
Magic page of the egg form that 141 Egghead ("User becomes an egg", 0 AP)
gives: an egg shows only these three, greyed until the egg's level (the
counter by its portrait) reaches the skill's. Seen in game 2026-10-23
(Egghead poked into Ryu's spells).

### Never-granted skills

With every source above plus the enemy lists, these have no source:

| Skill | Data | Notes |
|---|---|---|
| 230 Shift | all zero but the description "Allows instant travel. Press the SELECT button on the World Map." | not cut: nothing checks skill 230, but vanilla Shift is world map fast travel behind area 0x2a bit 216, granted by the teaching girl in Shyde after Chek ([story-and-maps.md](story-and-maps.md#shift)). |
| 241 Rakhasa | Last Resort's description (0x4171) | likely a scripted copy of Last Resort |
| 83 Aura Smash, 242 (copy), 243 Whiteout | description 0x4157, the "%s attack vs %s, ignores Def." template | scripted |
| 59 Filch, 80 Vacuum, 208 Revolution, 210 Stasis, 225 Cheering, 226 CoveringFire, 233 Punch, 234 Kick, 250..253 Booster/Panzer/Maelstrom/Gravedigger | no description | enemy or event actions through boss scripts (combatant +0x140, see Enemy AI); 80, 208, 210, 226, 233, 234 have BMAGIC files |
| 160 | all zero | empty slot |

The boss scripts were not traced: an enemy combatant is 0x801c6ec0 + index
* 0x1c8 (052 0x801d6238), and its script table pointer +0x140 is set outside
overlays 050..052.

## Damage multipliers

Every hit of the round (BTLMOVE.EMI, overlay 0x34) ends in HP_APPLY
0x801d8ecc, about 20 callers, one per damage formula. It reads the hit
context at 0x8011e130: +0 u8 target id (below 6 a party member, else an
enemy), +0xc the target combatant, +0x10 the hit record, whose +0xc is the
s32 damage (negative heals). HP_APPLY takes the damage from HP (+0xb0),
clamped to 0..max HP (+0xd4); HP 1000000 marks an invincible target and is
left alone, and bit 8 of record +0x6f skips the hit.

The damage number is spawned before HP_APPLY from the same value, by
0x801af818(target, kind, value) or 0x801af890(target, phase, kind, value) in
battle overlay 0x32, into the popup pool at 0x801caab0 (24 x 16: +0 bit 0 in
use, +1 step, 0 at spawn, +2 target, +3 phase, +4 kind, +8 value).

`qol/damage.odin` (`[battle] damage_dealt`, `damage_taken`, 0.25..16) hooks
HP_APPLY, scales positive damage by the rate for the target's side (capped
at 999999), rewrites the popup at step 0 with the same target and the old
value, then runs the game's HP_APPLY.

## Timed hits

`[battle] timed_attacks` and `timed_parry` (`qol/timed.odin`, off by
default). An action runs while PHASE 0x8011ded4 reads 0x0303 in its low half
(phase 3 the round, sub-phase 3 an actor's action), with the round record
above. Every hit of a plain attack (kind 1) lands a fixed number of game
frames (30 Hz, GAME_FRAME 0x80116b20) after its action starts: Ryu 23, a Cap
25. So the port learns each attacker's leads the first time it attacks
(keyed by character id, combatant +0xa4, or the enemy's name, +0x9c, with kind
and skill) and from then on draws a closing white square onto a yellow one in
mid-screen, reaching it on the hit's frame.

Each hit is judged in HP_APPLY (see Damage multipliers): the first confirm
press in the 15 frames before the hit counts, so mashing fails; within 3
frames is Perfect, the 3 before that Good, earlier a miss. The rate joins the
damage multipliers, so the number shows it:

| | Perfect | Good |
|---|---|---|
| party attack on an enemy | x1.5 | x1.2 |
| enemy attack on the party (parry) | x0 | x0.5 |

Skills and spells are not timed. Autoplay `pulse qte` presses a frame before
each learned hit (tested: Perfect on both, Cap hit 19 -> 0, Ryu 0.25 -> 0.375
of base with `damage_dealt = 0.25`).

## Enemy AI

An enemy decides its action when its turn comes up in the round:
0x801d6238(enemy index) in the round overlay, called from 0x801cd4bc for
actor ids 6 and up (party actors go to 0x801d5530). It sets the round record
at 0x8011e0c0 (actor = index + 6) and the actor pointer 0x8011e02c, then:

- status +0xae bit 0x10 (confused): 0x801d6fdc picks instead, at random;
- flags +0xac bit 2: no action;
- when 0x8011deeb is set, the enemy's own script runs first: the function at
  +8 of the table that +0x140 points to, called with the combatant;
- one roll picks a 2-bit action kind from the enemy's pattern byte,
  0x801c65a8[+0x11c], four kinds per byte: 0 attack; 1 kind 2 when +0xac bit
  0x100 (sets +0x158 bit 0); 2 kind 3 when bit 0x200; 3 a skill when bit
  0x400, one of the 8 at +0x12c picked at random. A kind whose bit is clear
  falls back to attack. Kind goes to +0x15d and record +1, the skill to
  +0x15e and record +2, the target to +0x15c and 0x8011e0f8;
- 0x801d6650 then may move a single party target to a member that covers it
  (combatant +0x120 == 10).

Attack targets come from 0x801d68d8 and skill targets from 0x801d6b64 (by the
skill's data). A forced target (0x8011deec bit 0x2000, the id at 0x8011e075)
wins. For a party target an enemy with +0xac bit 0x800 takes the member with
the least HP (0x801d7388); every other one takes a random standing front
member (0x801d72d0, which the confused path also uses). 0x801d7434 is the
enemy with the least HP and 0x801d71f8(id) a random enemy other than id, for
skills on allies. 0x801aed7c(id) says whether a combatant can be targeted.

`qol/ai.odin` (`[battle] enemy_ai`) has seven tiers above original, each
adding to the one before:

| Tier | Party target | Heal ally below | Elements | Buff / hinder chance |
|---|---|---|---|---|
| aware | game's random | never | avoid members it cannot hurt | - |
| smart | least HP for max HP, 2 in 3 | 1/4 | avoid | - |
| clever | as smart | 1/3 | swap to a list skill hitting harder | - |
| tactical | focus fire: one member until it falls, then healer > caster > weakest | 1/2 | as clever | buff 2 in 6 |
| cunning | as tactical | 1/2 | as clever | 2 in 6 each; answers buffs, dragons |
| ruthless | least HP in points (more AP on a tie) | 1/2 | most power x rate | 2 in 6 each |
| mastermind | as ruthless, healer > caster first | 1/2 | most power x rate, member with least HP for the rate | 3 in 6 each |

With `ai_by_strength` (Extras, Enemies page) each enemy gets its own tier on
its first turn: its max HP (+0xd4) against the standing front members'
average, under half Aware, then a tier per doubling, Mastermind from 16
times; `enemy_ai` is the highest any enemy gets. Kept for the battle, so a
dragon form does not change it. Tested: a 12288 max HP Eye Goo against a
355 average got Mastermind (Clever with enemy_ai clever).

With `ai_moods` (`qol/moods.odin`, Enemies page) each enemy kind has a
personality, looked up by its BWORLD record name (combatant +0x9c, 8 bytes,
NUL-padded; 138 names across the AREAB files, 41 more in BOSS001..032):
coward (Goos, vermin, Gold Fly, Egg Gang, the boss Sparrow), devoted (the
healers: GooNurse, ZombieDr, Cap; Won-qu, the guard of Fou-lu's tomb, and
A-tur, Fou-lu's other centuries-old servant; Bellwyd, Marl's healer on Mt.
Yogy), pack
(troops and squads, the boss Grunts, Soldier and EliteTrp), trickster
(fungi, spirits, thieves, mages, Fantam, Diviner, Evoker, Loam), proud
(kings and giants, Kahn, Joh the warrior spirit of Rasso, Ymechaf his
samurai guardian, Glebe the creature the Cove worships as its god, Fou-lu and his
Tyrant, Astral and Infinity forms, Marl the god of Mt. Yogy, Ight the
invincible knight Rasso summons), brute (beasts, bugs, Zombie, Maman,
Skulfish, Angler, Papan (Maman's mate), Yohm's beasts Kham and Khafu, Klod the beast Marl summons, Kahbo and Kamyu
at the Fou castle),
machine (Bots, Armor, Generatr, the four pillars sealing Ershin in
Ershin's Mind: Umadap, Azeus, Agiel, Yeleb; no moods) and steady (the rest, including
the bosses whose story role gives no nature: Il, whose part is unknown,
and Dragonne, which the fan wiki says has no part in the plot). Glebe
(`boss 23`) logs "Glebe is Proud"; `boss 15` logs "Marl is Proud" and "Klod
is Brute", `boss 18` "Azeus is Machine" and "Umadap is Machine". Tested: the Sparrow (`boss 8`, Ryu alone) is Coward: it opens cocky (Ryu low), turns cautious with its HP poked to 300/600 and desperate at 150/600 ("Sparrow is desperate!" banner); its list has only Feeding Time (a hindrance, which confuses), so a desperate rolled attack stays an attack. Fleeing is the boss script's own and was not seen. Bosses go through the same DECIDE hook after their scripts. Each turn its mood comes
from the fight, the first that matches: desperate (own HP below a
personality's share, or half its side fallen: no buffs or hindrances, the
strongest damage skill instead of a plain attack), enraged (a party member
felled an ally, or hit it for a large share of its max HP: every action at
that member for 3 of its turns; tracked in the HP_APPLY hook, where
0x8011e0c0 still holds the actor), cautious (hurt, or a dragon form up:
heals allies below 8/12 and buffs more) and cocky (the front below a share
of its max HP while its own is above half: the game's random target, more
buffs and hindrances). The tier still limits what it can work out. When an
enemy decides its turn in a new mood, a window at the top left says so
("Zaurus is enraged!", red for enraged and desperate, green for wary,
yellow for cocky) for 60 game frames, beside the game's skill-name box. Tested
on a poked Eye Goo: coward turned cautious, then desperate and healed
itself; renamed Zaurus (brute) it hit back with Sever at the member who hit
it; renamed Bandit (trickster) with the party at 30 HP it went cocky,
spread its targets and buffed itself.

The target pick replaces 0x801d72d0 for enemies that are not confused. The
action pass hooks DECIDE after the original (enemies with +0xac bit 0x400
only, not confused); a learnable skill the party does not know is never
swapped. Every tier only casts what it has the AP for (castable): a rolled
skill it cannot pay for becomes a plain attack, and every swap picks list
skills it can pay for. In order: heal a hurt ally from the list, aimed at it; turn a heal
rolled with every ally above three quarters into another skill, aimed
from here on like a rolled one; cast a list
buff on the enemy itself or an ally not given it yet; cast a list debuff or
status on the healthiest standing front member not given it yet; aim a rolled
buff or hindrance at someone who has not had it, or with nobody left turn a
hindrance into a list damage skill, or either into a plain attack; aim or swap
a rolled damage skill by element rate. Who was given what is the enemies' own
casts this battle (a bit per skill per combatant id; a group target marks the
whole side), cleared when GAME_MODE (0x80114850) leaves 5; a status skill
counts only while the target still has a status (+0xae), a debuff only
until the member is buffed in that stat again, and a member's marks go when
its char id changes (dragon form in or out).

Cunning and up answer first, without a roll: a list hindrance on the
unmarked front member it is worth most on, worth being the buff over 100 in
the stat a debuff lowers plus 50 for a dragon form (nothing when neither).
Tactical, cunning and mastermind pick a new party target by role first:
healer (knows a Heal-family skill with the AP for it), then caster (a damage
skill), then the rest; ruthless takes the least HP regardless.

Enemy AP: enemies spend AP like the party. The cast (0x801cdf04, the round
step the 0x801e4e34 table dispatches from 0x801cdec4) loads the cost from
skill data +4, cut to 3/4 for a party actor whose +0x11e is 40, and unless
0x8011deec bit 0x80000 is set compares it against AP (+0xb4, u32) plus the
u16 at +0xb8; short, it calls 0x8014c0dc(0x2027) (likely the not-enough-AP message) and
the turn is lost. Paid, the
cost comes off +0xb8 first, then AP (0x801ce114). DECIDE never checks AP, so
a vanilla enemy at 0 AP keeps rolling skills and wasting turns. Eye Goo has
5 AP; Heal (44) costs 5, Sever (4) and Frost (7) 3, Protect (39) and 41 2.
Test: an Eye Goo poked to 99 AP and a 12288 max HP healed itself every turn
at Smart and up until AP ran out, then (with castable) attacked; the `ai:`
qol trace prints each decision with the enemy's AP.

Buff state: a u8 percent per stat, 100 normal, 8 slots at party combatant
+0x18c and enemy combatant +0x1b0. Might (effect id 0x2c) set an enemy's
slot 0 (power) to 120 and block A power +0xde went 18 to 21; Weaken (0x29)
set Ryu's slot 1 (defense) to 80 and +0xe0 went 19 to 15. Debuff effect ids
0x28..0x2b (Blunt, Weaken, Slow, Enfeeble) lower slots 0..3 (0 and 1
confirmed). Buff ids 0x2c..0x31 (Might, Protect, Shield, Speed, Inspire,
Barrier); only Might's slot is confirmed.

Party combatants hold a copy of the char record at +0x9c (record +0x14 HP is
+0xb0): char id at +0xa4 (7 and up in a dragon form; Aura, skill 211, took
Ryu 0 to 7, max HP 50 to 459), the record's 16 skill ids at +0xba and 8
learned at +0xca, AP at +0xb4. Pattern action 1 (kind 2) is Guard ("Cap is
guarding").

### Element rate

0x801d4910(mask) returns the action's rate in percent: the average over the
mask's bits, 100 with none (mask & 0x1f == 0). Bits 0..3 (fire 1, wind 2,
water 4, earth 8) read the target's level for that element and index the s16
table 0x801e509c: levels 0..7 = 200, 150, 100, 75, 50, 25, 0, -100. Holy (bit
0x10) reads its own level and the table 16 bytes on: 200, 200, 150, 150, 125,
100, 50, 0. Level 1 also sets the weak bit 0x200 in 0x8011deec. 0x801d4e10
returns the action's mask: skill data +6 for a skill (kind 4), or the weapon's
element when skill +0 bit 0x2000 is set and the actor is party; the weapon's
(char +0x11c, table 0x8019a154 + 5) for a party plain attack; 0 for an enemy
plain attack. The physical calc 0x801d4afc uses tables 0x801e5170, 0x801e5180
(random 90..110), 0x801e5190 and 0x801e51a0.

Combatant stat blocks, party and enemies alike: block A at +0xd4 is current
(max HP first), block B at +0xf8 base, 0x24 bytes each. In a block +0x12 holds
4 levels and +0x16 the 8 element/kind levels (+0xea in A, +0x10e in B; 2 is
normal, 1 weak, 6 immune, 7 absorbs). 0x801b32e0 sets both; enemy-script
commands in overlay 0x32 write B (+0x10e at 0x801add44, +0x10a, +0x138).
0x801d5444 reads +0xea, which the AI uses (assumed to be the copy the hit
context at 0x8011e15a gets).

Tested on the Ryu vs 2 Caps battle by poking skill lists and forcing skill
rolls (pattern byte 0x801c65a8 = 0xff): Heal 44 in a Cap's list healed a low
Cap, wasted heals went to Distracted 102; cunning, Ryu fire-immune and
water-weak, swapped a rolled Flare for water 7; Might went to the caster,
then the other Cap, then never again; Weaken went on Ryu once; mastermind
then attacked instead of repeating them. Casting a poked skill the enemy does
not own hangs the battle (its effect is not loaded), with or without the AI;
the AI only picks from the enemy's own list.

Skill data bytes used (0x8019add0 + id * 12): +0 target flags, 0x80 on the
Heal family (Heal, Rejuvenate, Restore, Vitalize, Vigor, Purify, Remedy, 117),
0x08 on support skills (buffs, debuffs, heals); +2 low nibble learn level;
+3 power (Flare 15, Fireblast 30, Inferno 80; Blunt-style debuffs hold their
amount there); +4 AP cost; +6 element bits; +9 0x04 buff, 0x01 debuff, 0x08
status, 0x02 barrier, 0x10 breath; +10 effect id (debuffs 0x28..0x2b, Might
0x2c to Barrier 0x31, Sleep 0x25). Skills 1..3 fire, 4..6 wind, 7..9 water,
10..12 earth, 29 holy, 31..33 status, 34..37 debuffs, 38 up buffs.
Byte 0 alone does not tell the side:
0x801d6b64 reads it against the actor's side.

## KO max-HP loss

Character records (0x8011a94c, 0x98 each) keep base max HP at +0x5c, the
effective max HP at +0x38 and a KO mark count at +0x83 (0..5). A member
still KO'd (+0x14 HP 0) when a battle ends gets up with 1 HP, bit 0x8000 of
+0x12 cleared and one more mark: BTLEND.EMI 0x801cdca0, and the battle
overlay's own end path (0x801abd48). The battle overlay's revive at
0x801b3058 (when 0x8011deec bit 0x400000) and round action sub-op
0x801dc658 (max HP -10% as a cost; the combatant's own count at +0x11f, or
+0x155 for enemies) bump it too. The inn clears it (0x80195210, overlay
0x0e).

0x801961b4 (overlay 0x0e at 0x8018d800, no arguments) rebuilds the stats of
the 6 party slots (indexes at 0x8011ad88, 0xff empty): it copies the base
stats at +0x5c over +0x38, then 0x80196324 takes base/10 x marks off the
max HP and clamps HP to it. Every mark site ends in this call.

`qol/ko_loss.odin` (`[battle] ko_hp_loss` = inn, camp or off) hooks
0x801961b4. inn is the game's way. camp also clears the party's marks on
each tick of the camp menu (camp_menu.odin) and adds back base/10 x marks to
+0x38, as the next recompute would; HP stays as it is. off clears the marks
before every recompute, so max HP stays whole and HP lost to marks comes back
at the next one (any battle end or equip change).

## Status resist roll

Status skills, death and the other effects with a resist roll ask
0x801d378c(kind, grade) in the round overlay (0x34), which returns 1 when
the effect misses. Kind indexes the target's levels at 0x8011e15a (s8; the
status command passes 6, death 4), grade the levels at 0x8011e156 (the
skill's grade, high nibble of skill data byte 2 for skills). The target's
level is looked at first: 0 or less always lands, 6 and up (5 for kind 4)
never does; then the grade's level the same way. Otherwise, in percent:

    min(caster 0x8011e0e4 / 5 + 50, 100) * max(75 - target 0x8011e154 / 5, 25) / 100
    * rate[grade level] * rate[target level] / 10000

with rate 0x801e4fb8 = 150, 100, 75, 50, 25 for levels 1..5 (kind 4 takes
the target's rate from 0x801e4fc8 = 200, 100, 50, 0). The effect lands when
RAND % 100 is below the chance, so a high-level target (most bosses) is down
to a few percent. 0x801da278 is the status command (arg +0 the status
bits, +2 bit 0 a removal, bit 7 no roll, +3 a second roll path through
0x801df3fc); 0x801da4f4(bits) sets the bits on the target (status u16 at
combatant +0xae), less those its accessories (+0x11e) block.

`qol/status.odin` (`[battle] status_rate`, 0..4) hooks 0x801d378c and, for a
party member targeting an enemy, runs the same check with the chance scaled;
the immune levels stay immune. At 1 the game's own check runs.

The test cheat `BOF4_CHEAT=hp` also makes the party status-proof in the same
file: the resist roll on a party member always misses (death too), and
0x801da4f4 is called with no bits for a party member, so the no-roll
statuses do not land either, bit 0x80 among them (which also sets combatant
+8 to 2). With no bits it returns 0, as when an accessory blocks them.
Tested on the Sparrow (`boss 8`): its six Feeding Time casts all missed and
the run lasted to the end.

## Magic combos

Party actions in one round chain into a combo; the state sits at 0x8011df30:
+8 u8 hits, +0xc u32 damage, +0x54 16 u8 counters, one per element bit.
0x801ce208 adds 1 to the counter of every bit set in the skill's element
mask (skill data 0x8019add0 + id * 12, +8 u16: bit 0 fire, 1 wind, 2 water,
3 earth, 4 holy, 6 death). 0x801ce2b0 resets the combo when the chain breaks;
round end (0x801d11c8) clears the counters and updates the records for the
masters: most hits u8 0x8011b694, most damage u32 0x8011b734.

0x801d802c(skill) gives a magic action (0x8011e0c1 == 4, party actor) its
combo level: with two or more of bits 0..3 set, the highest of those
counters, else the counter of the skill's own element (0x801b2d08 picks it,
0x801b0e80 the lowest bit), minus 1. 0x801d4620 scales the spell's power by
(100 + 20 * level) percent, so each earlier same-element hit in the chain
adds 20 %.

Skills 13..28 are the two-element combo spells, four levels per pair:
fire then wind 13 Firewind, 14 Simoon, 15 Gigaflare, 16 Earthbreaker; wind
then water 17 Jolt, 18 Lightning, 19 Thunderstorm, 20 Mjollnir; water then
earth 21 Storm, 22 Tempest, 23 Disaster, 24 Catastrophe; earth then fire 25
Eruption, 26 Magma Blast, 27 Ragnarok, 28 Supernova. They have no learn
level and no menu text. Skill data byte 6 holds element bits (also ANDed as
a mask at 0x801dff5c); byte 7 is a hit/power factor read at 0x801d514c, not
a tier.

### Starting a combo

0x801b222c (overlay 050, 0x801aa000), called from overlay 052 at
0x801ce29c, decides whether two consecutive party actors chain: both must
be casting magic (actor +313 == 4). It reads the element table at
0x801e4fd8 (stride 14) and rolls 0x801b25a8(a0 = the earlier caster, a1 =
the one chaining onto it, both combatant indexes): chance 75 (85 while
0x8011df50 == 0), +10 per actor whose +286 == 52, +5 when the two spells'
element masks (data +8) share a bit, +5 when either actor's Agl (+0xe2) is
above the standing enemies' mean Agl + 1 (with no enemy standing the game
divides by zero; MIPS leaves -1); it chains when rand() % 100 < chance. On true the
caller resets the counters, sets bit 0x40 of 0x8011ded4+24 and adds the
counters; on false it goes to 0x801ce434.

### Swapping the spell

Overlay 052 (`ov_801cc800_052.bin`, load 0x801cc800), 0x801ce62c..0x801ce7c0,
runs while that flag is set and the combo count (0x8011df30+32) is above 0.
The current actor is the order list 0x8011df30+0x74 at index
0x8011df30+2, the previous one the entry before it; actors are 420 bytes
from 0x801c79b8, +313 the action type, +314 the skill.

1. Specials, 0x801cea2c(cur, prev): when the current skill's data +8 has
   flag 0x20 (a skill, not magic) and the previous skill is in the pair list
   at 0x801e4ec4 ((13,1) (14,1) (15,1) (17,2) (18,2) (19,2) (21,3) (22,3)
   (23,3) (25,4) (26,4) (27,4)), the result table 0x801e4ee0 gives
   [idx * 2] the new skill and [idx * 2 + 1] the character id, which must
   match the acting actor's record (0x8011e0c0+12 pointer, +164): 1 → 173
   Phoenix by Nina (1), 2 → 175 Ice Sword by Scias (3), 3 → 174 Mudslide by
   Cray (2), 4 → 176 Reflect by Ursula (4). Character records from
   0x8011a94c: Ryu, Nina, Cray, Scias, Ursula, Ershin, Fou-Lu.
2. Otherwise 0x801ce980(skill) gives each spell's level from the (skill,
   level) pairs at 0x801e4e70, ended by 0xff: base spells 1..12 levels
   0, 1, 2 per element; combos 13..15, 17..19, 21..23, 25..27 levels 0, 1, 2;
   enemy skills 0x98 Burn 0, 0x99 Eddy 0, 0x9a Icicle 1, 0x9b Plateau 1,
   0x9f Flame Pillar 2; Fou-Lu's 161..172 0, 1, 2 each. While 0x8011df50 == 2
   (Fou-Lu's chapter) 163 Hwajeh, 166 Ahryu P'ung, 169 Pa Bing'ah and 172
   Patoh Pah are level 3. Both spells need a level. Each element is the
   lowest-bit index (0x801b0e80) of the highest set bit (0x801b2d08,
   priority 0x2000 down) of data +8; the current element must be
   (previous + 1) & 3, the cycle fire (bit 0), wind, water, earth, fire.
   The new skill is 0x801e4e50[previous element * 4 + current level]
   (bytes 13..28), so the second spell sets the combo's level and level 4
   (16, 20, 24, 28) needs Fou-Lu's top spell second, in his chapter.

The new id goes to the action (+16 pointer, +6) and 0x8011e0c2,
0x801d6b64 fills +4 / 0x8011e0f8, and a type-10 message is queued with
0x8015011c(25, 1). Skill 201 (Recall) instead picks at random from the 16
bytes at 0x801e4e60 (98 98 98 98 98 06 07 07 0a 2c 2c 30 2a 1f 1e 95).

Skill names are a NUL-terminated list from id 1 ("Flare") in
SYSTEM/INIT.EMI, loaded near RAM 0x80022c11.

`qol/combos.odin` notes each combo or special a party member's action
becomes (0x8011e0c0 < 6, 0x8011e0c2) in `[battle] combos` (bit id - 13 for
13..28, bits 16..19 for 173..176) and lists them on the panel's Combos page,
unseen ones as ???. Tested with Nina, then Cray or Ryu: Sever then Frost
became 17 Jolt.

### Party and combatants

The battle party comes from the party order list 0x8011b6b4 (6 character
ids, 0xff ends it; 0x801aec7c, called from 0x801aae40, sets combatant +0 =
11, +1 = slot, +164 = character id). Poking it before a battle adds members
(the debug save's party is Ryu alone; PARTY 0x8011ad88 does not work).
Party combatants are 420 bytes from 0x801c79b8, enemies 0x1c8 bytes from
0x801c6ec0; both hold the name at +0x9c (8 bytes, NUL-padded), +0xa4 the
character id, +0xae u16 state (0x8000 down), +0xb4 u16 AP, +0xba the 16
known skills, +0xe2 u16 Agl. Enemy current HP is u16 at +0xb0, max HP at
+0xd4 (copy at +0xf8). The action record is +312 target, +313 type (1
attack, 2 guard, 4 magic), +314 u16 skill.

Targets in that record: 0..5 party, 6 + n enemy n, group masks 64 (all
enemies), 16 and 32. A skill's targets byte (data +0) with `& 0x61 == 0x60`
is one enemy; `& 0x41 == 1` a group.

### Command input

The command input state is 0x8011ded4: +0 phase (1 while the party
chooses), +1 step, +2 menu (2 the command menu, 4 a command chosen), +3 the
chosen command's step (7 commits a spell), +4 its substep, +6 mode (1 menu,
4 spell), +7 members done, +14 s8 the choosing member, +15 the command
cursor (1 Magic), +16 u16 flags (0x200 menu; 0x40 of +24 is the chain flag
above), +31 the member in each committed slot, +36 u16 per character, the
kept spell cursor. 0x8011dd88 is nonzero while the menu waits. Overlay
0x33 (BTLCOMD.EMI at 0x801cc800) runs it: 0x801ccc90 the command menu step
(a0 = the state), 0x801cfa20 the Magic command's first step, 0x801d0b00 the
spell commit. 0x8011e02c points at the choosing member's action record (+4
target, +6 skill). The spell window 0x8011dddc keeps its cursor in bytes
12..14; from the character's kept cursor v: +12 = v & 7, +13 = v >> 8, +14
= (v >> 3) & 0x1f.

The Special list (the Magic command's step +3 = 1) runs substeps from the
table at 0x801d5bcc (steps from 0x801d5b9c: 0 0x801cfa20, 1 0x801cfc9c, 2
0x801d061c, 3 0x801d07d0, 7 0x801d0b00): substep 0 0x801cfcd8 waits on
buttons (a0 = the state), 1 0x801d00d8 slides the window right 80 a frame
to x 336 and goes to step 3 (target), 2 0x801d0254. The spell window
0x8011dddc: +0 and +3 set while up, +8 x, +10 y (s16), +12 page (0 Magic,
1 Skill; Left/Right, mask 0xa000, toggle it), +13 the first slot shown, +14
the cursor's row of six, 16 px apart; the slots are party +186 (Magic) and
+202 (Skill), 16 each. Up/Down come from the repeat bits 0x80116d3e
(0x4000 down, 0x1000 up) through 0x801d118c, the cursor move; Up on row 0
does nothing and the cursor can rest on an empty slot. Confirm on a spell
clears +3, sets the record's skill and goes to substep 1.

The menu step 0x801ccc90 reads confirm (pressed 0x80116d3a & mask
0x80116d84; Item greyed, state 0x80 of +174, refuses with sound 0x205),
square (cursor 7), cancel (mask 0x80116d86), the Charge/Escape page key
(sound 0x206, cursor 4), Left/Right (repeat 0x80116d3e, next or previous
member, sound 0x202), then Up/Down (sound 0x200; cursor 0..3, wrapping,
skipping Item while greyed). Cursor 4 is Charge, 5 Escape.

Drawing (overlay 0x32): 0x801c49ec draws the main page, 0x801c4e58 the
Charge/Escape page; both called from 0x801c1ecc. The window record's
pointer is 0x8011de24: +8 x, +10 y, +12 s8 the second page's slide (56 out).
0x801c555c(x, y, id) draws sprite id from the 5-byte table at 0x801aa6a8
(u, v, w, h, CLUT byte; CLUT x 16 * (byte >> 4) on VRAM row 241, texture
page 13). The main page: id 1 the HP frame at (x, y); window (x+44, y+20,
56, 72); while the cursor is under 4 and the second page is in, ids 4 (the
Menu tab), 43 (R1), 37 (arrow) at y+16; HP with 0x80141104 at (x+13, y),
colour 2 down, 6 for state 0x4000; AP at (x+19, y+63), with the bonus
(+184) under it; the portrait 0x801514a8 at (x+2, y+11). Labels at x+48,
y+26 / 42 / 58 / 74: Attack 9, Special 10, Item 11 (45 greyed), Guard 12,
lit 13..16 on the cursor. The labels are 48x13 at u 144 (v 0, 16, 32, 48)
and u 192 (Charge v 0, Escape v 16), CLUT 2, lit 3, greyed 15; nibble 4 is
the plate, 3 the outline, 1 and 2 the letters. Id 31 is a small "Combo"
word (u 48, v 128, 29x8). Page 13 is blank in battle at u 96..191, v 240..255.

### Round order

0x801b0504 (overlay 0x32 at 0x801aa000, once per round after command input)
writes the turn order to 0x8011dfa4 (count u8 0x8011df33): combatants
0..5 party, 6 on enemies. It sorts by speed: Agl, plus 1 / 4 / 2 by action
type; a party member with +288 == 1 and character id < 7 gets 999 three
times in four (rand & 3); enemies get random noise. So consecutive casters
are likely but not sure to stay consecutive.

### Combo command

`qol/combo_menu.odin` (`[battle] combo_command`): the Special list's Magic
page (or a list Select opens at the command menu) shows the combos
the choosing member can make this round with one other member: pairs that include it, the first acting earlier by Agl, the first
spell the cheapest affordable one of an element, the second any affordable
spell of the next element. Combos not yet seen (`[battle] combos`) are
listed too, named "???" (the help line still shows the two spells), so a
combo can be found on purpose instead of by chance.
Left/Right picks the enemy for a single-target first spell. A partner that
already chose an attack, guard or spell gets its spell written into its
record; one still to choose skips its menu: the hook at 0x801ccc90 picks
Magic, the hook at 0x801cfa20 writes the record and jumps to the commit
(step 7), so AP, cursors and the done list stay the game's. After
0x801b0504 the second member is moved right behind the first in the turn
order.

The combo lines: on the Magic page of the Special list, one line per combo
in the member's empty slots after its spells (a member whose 16 Magic slots
are full gets none; Select still works), named for the combo with the AP of
the member's own spell and the combo spell's icon (0x801953e4: a0 x, a1 y,
a2 skill; the game's list draws it at window x + 5; one element bit in skill
data +8 picks u 48 + 12 * (15 - bit), two or more the many-element orb at
u 240, v 0xe8 of texture page 15, CLUT 0x3c0d), and while the game's cursor sits on one, the pair of
spells on the help window's second line. The hook at 0x801cfcd8 (the list
step) takes Confirm on such a slot (the game refuses an empty slot with sound
0x205) and does what the game's Confirm on a spell does (0x801cfe34..e90):
the member's own spell into the record's skill (+6 of the record at
0x8011e02c), sound 0x201, window +3 cleared, the cursor saved at 0x801d5c74,
substep 1. The game then slides the window away, runs its target choice
(step 3) and commits; the plan waits armed until the member's committed slot
shows its spell, then the partner's spell is aimed at the enemy the member
chose. Cancel at the target choice comes back to the list and drops the plan.

Training (`combo_mastery`): each combo performed counts in `[battle]
combo_uses` (16 counts, up to 15); levels at 1, 3, 6, 10 and 15 uses add 5
each to 0x801b25a8's chance (rewritten natively), and level 5 always
chains. A party combo never performed (0 uses) also always chains, so the
first try (from the combo list or cast by hand) lands and teaches it, even
when the dog has already shown its recipe.

## Rebalanced mode

`qol/balance.odin` (`[battle] balance`, off by default) makes the game
harder and magic worth its AP. No game table is stored in the port: each
GAME.EMI table region (overlay 0x0e at 0x8018d800) is captured the first time
its bytes hash to the vanilla FNV-1a value, a patched copy is built from it,
and every vblank the region is set to the copy the option wants, so turning
it off restores vanilla at once.

- Skills: attack spells 1-12 +20 % power and AP (AP rounded up); buffs 38-43 +2 AP;
  debuffs and status spells costing 1-3 AP cost 3 more; Heal, Rejuvenate,
  Restore +25 % AP; Purify, Remedy +2 AP.
- Items: Healing Herb sells for 30 (was 10); bombs 23-32 double power,
  +50 % price.
  Checked in game (shop 26): Healing Herb costs 60 to buy (20 without the
  option), Molotov 150 (100); a Molotov hits for 400 (200).
- Growth: HP gains x1.4; Cray +1 AP on even levels; Ershin +1 AP on levels
  1-30. Master bonuses larger, with trade-offs.
  Checked in game over levels 4 to 14: Ryu gains 521 HP (376 without the
  option), Nina 412 (297), Cray 352 (253) and Cray's AP ends 25 (22). With
  master 3 poked into Ryu's record +0x84 (bonus 40 HP, -3 AP, +4 Pwr, +3 Def,
  -3 Agl, -3 Wis with the option; 25, -2, 3, 2, -2, -2 without) the HP gain
  rises by 400 (250), Pwr by 40 (30), Def by 30 (20). Negative bonuses come
  out a little short because a level's gain does not go below 0.
- Wisdom: after the stat rebuild, staves add half their attack, robes half
  their defence and rings a flat bonus to record +0x48 (cap 999). Once the
  tables change (the option toggled, or the overlay read again, as after a
  load), the next field tick runs 0x801961b4 for the party. It also runs
  after a play time jump (0x8011ad90 u32 hours, 0x8011ad94 u8 minutes going
  back or ahead more than a minute: a save loaded, a new game), so a save
  made with the other setting loses its stale Wisdom.
  Checked in game: Nina with a staff (attack 5) and robe (defence 5) goes
  from 26 to 30 Wisdom. The field rebuild covers only the PARTY list
  0x8011ad88, so a member poked into the battle order alone is rebuilt by
  the battle setup instead.
- Enemies: the enemy setup 0x801b9b18 (BATTLE overlay 0x32; a0 the enemy slot
  0..5, a1 the formation) copies a BWORLD record (0x108 bytes from
  0x801f58a0, record index at formation byte 0, 3 bytes per slot) into the
  enemy combatant (0x1c8 bytes from 0x801c6ec0). Record +0x28 u32 HP goes to
  combatant +0xb0 (HP) and +0xf8, record +0x10 u16 zenny to +0x11e u16,
  record +0x12 u16 EXP to +0xa8 u32. The live max HP is combatant +0xd4: the
  HP gauge routine 0x801c37e8 (reached through 0x801c38a8 from 0x801c27bc for
  enemies) clamps HP to it, so a scaled HP must be written to +0xb0, +0xd4
  and +0xf8 together. After it, HP x1.5 (x2 from
  10000; was x2.5/x3 before timed hits and the enemy AI), EXP cut to half the HP where it is at least 1000 and above the HP
  (GoldGang, Gold Fly), zenny past 500 halved. Records with HP exactly
  1000000 (the invincible marker HP_APPLY tests for: Scias BOSS010, Ight
  BOSS017, Fou-lu BOSS032) are left as they are, or scaling would make them
  damageable.
  Checked in game (2026-10-23, after fixing two bugs: the scaled HP went only
  to +0xf8 and the gauge put it back, and the EXP and zenny offsets were
  swapped): Eye Goo shows 225/225 HP (150/150 without the option); Nina's
  Sever costs 4 AP (3 without). With `BOF4_ENEMY_STATS=9000,8999,600`
  (debugging.md) two enemies pay 1100 zenny (1200 without).
- Hits on an enemy are capped at 9999 in the HP_APPLY hook (`qol/damage.odin`);
  Kaiser with the Cursed Sword and Last Resort otherwise hits for hundreds
  of thousands.
- Combos: 0x801b222c returns 1 when the next turn chains (see Starting a
  combo); the turn order is at 0x8011dfa4 with the current position at
  0x8011df32 and the count at 0x8011df33. With the option on,
  `qol/combo_menu.odin` charges the member chaining on half the two spells'
  AP, rounded up, when the chain is made; a member without that plus their
  own spell's AP does not chain.
  Checked in game: Nina's Sever then Ryu's Frost (4 AP each with the
  option) chain into Jolt and Ryu pays 4 + 4 AP (12 to 4).

