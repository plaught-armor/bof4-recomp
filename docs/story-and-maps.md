# Maps and story progress

## Map ids

A map id is a u16. One bit of the high byte names the area letter of the
map's file, the low byte is the file's number:

| Bit | Area | Files | Contents |
|---|---|---|---|
| 0x1000 | M | `WORLD/AREAM<nnn>.EMI` | towns (1000 = AREAM000, Sarai) |
| 0x0200 | S | `WORLD/AREAS<nnn>.EMI` | interiors (0201 = AREAS001, Sarai tavern) |
| 0x0400 | D | `WORLD/AREAD<nnn>.EMI` | dungeons and outdoor routes |
| 0x0800 | E | `WORLD/AREAE<nnn>.EMI` | world map nodes and event scenes (0805 = South Desert) |

The low byte is the file number itself, so 081e is AREAE030. Exits to
0000, 0001 and 0002 are special destinations, not maps on the disc: 0001
is a camp's way out (camp scene 101a returns to the world map node the camp
was made at); 0000 and 0002 are not decoded yet. Battle backgrounds (`BWORLD/AREAB*`)
are not field maps.

| Address | Size | Content |
|---|---|---|
| 0x8011c944 | u16 | current map |
| 0x8011c946 | u8 | current section |
| 0x8011b720 | 12 bytes | world-map state: return spot (x, z, direction and a copy of 0x8011c948, written by field overlay 15 at 0x801cf758 on leaving a map), cursor byte 0x8011b724 and node pointer 0x8011b728 (written by 0x801f18cc / 0x801f19d8) |
| 0x8011b7c0 | 8 bytes | resume position: area (story chapter) u8, section, map, tile x, z |

To list how every map connects to every other (exits per section, from the
map overlays):

```sh
tools/bof4tools exit-graph overlays
```

Some known maps:

| Map | What |
|---|---|
| 1000 | Sarai (town, one section) |
| 0201 | Sarai tavern (sections 0 and 2 lead to town, 2 also to 0204) |
| 0204 | Sarai shop (sections 1 and 2 to town, 0 to 0201.2) |
| 0414 | cliff canyon (section 2) and the cave camp (section 3) |
| 040f | dungeon with several sections |
| 020b | multi-section interior (sections 4 and 7 joined by stairs) |
| 0805 | South Desert world map node |
| 081e | sand flier cutscene |

## Story flags

Story state is a set of bit arrays in the saved game region, 0x8011b5c0 to
0x8011b898 (save offsets 0xdf4..0x10cc): event flag arrays, a 32-bit progress
word per area, and global flags. Party membership bits are at 0x8011ad84.

Map events are native code in each map's overlay. They change flags through
resident routines in the game mode overlay, each taking the array and a bit
index:

| Routine | Address |
|---|---|
| set | 0x801917d4 |
| clear | 0x801917fc |
| test | 0x80191828 |
| local-area set / clear / test (bit in a0) | 0x80191848 / 0x80191884 / 0x801918c4 |

Per-area progress words: u32 at `0x8011b7d0 + area * 4`. The story sets their
bits roughly in order, so the last bit set is a good measure of how far the
player is. Known beats (from `qol/tracker.odin`):

| Area | Bit | Done when |
|---|---|---|
| 2 | 1 | reached the cliffs on the way to Sarai |
| 2 | 3 | jumped the gaps on the cliff road |
| 2 | 4 | climbed while there was light |
| 2 | 5 | found a place to camp for the night |
| 2 | 6 | Fou-Lu left the tomb |
| 2 | 10 | Fou-Lu headed for the capital |
| 2 | 11 | Fou-Lu escaped the burning woods |
| 4 | 0 | arrived in Sarai (set by the arrival talk) |
| 4 | 12 | asked around Sarai for sandflier parts |
| 4 | 18 | got a shovel and dog in Sandflier Valley |
| 4 | 19 | dug for the part |

Which maps set and test which bits:

```sh
tools/bof4tools story-flags overlays
```

### Finding new beats

Run the port with `BOF4_FLAGLOG=1` (on by default in `bof4-debug` sessions).
Every change in the flag region prints a line as it happens:

```
flag <present> map <map> area <area> <address> <old>-><new> "<last message shown>"
```

The message makes it easy to tell which story moment set the bit. At the
first present after loading, the whole initial state is printed. Add the beat
to `OBJECTIVES` in `qol/tracker.odin` and the table above.

## World map

| Address | Content |
|---|---|
| 0x800fae9c | node table in overlay `ov_800f8800_554`: 20-byte records |
| 0x80191958 | test whether the leader is in range of a node |
| 0x801f8a6c | slot 5 of the loaded scenario's header: called on Confirm while a road encounter's balloon is up (see below); SCE04 uses it for the merchant event (map 0814), skipped at nodes in its excluded set |
| 0x80191634 | wrapper calling that slot |
| 0x8019b9d0 | table used by it |
| 0x8011b718 | return map and spot block |
| 0x8011b720, 0x8011b722 | u16 world x, z (node cell << 8): where the map places the leader |
| 0x8011b724 | cursor byte (not the node) |
| 0x8011b728 | u32 pointer to the current node's table row |
| 0x8011b750 | visited bitfield, a bit per node, LSB first; set (0x801f197c) only once Shift is known (0x801f0d1c) |
| 0x80116fb0 | leader object on the node map |
| 0x801f0860 | node lookup (overlay 553) |
| 0x801f16e0 | visited and named test (overlay 553) |
| 0x801f15c8 | vanilla place list builder (overlay 553): list at 0x801f5980, MESSAGE_TEXT then TEXT_DRAW 0x80140b2c |
| 0x801f37fc | the road's "?" prompt |
| 0x801cf598, 0x801cfe5c | MAP_REQUEST and AREA_SET (field overlay), what script op 0x89 uses to go back to the world map |

Map 0805 is the node map itself. The other 0x08xx maps loaded with the
world data overlay (id 0x22a at 0x800f8800) are the road's "?" scenes and
story events; their bank-0 text is a stub (every table entry 0x200, the first
message overwritten), so node names read only on 0805. Bank-0 message `id`
is at lhu(0x80010000 + 2 * id) + 0x80010000.

Flag tests (0x80191828) number bits LSB first within each byte.

### Nodes, roads and their flags

World map overlay `ov_800f8800_554` (the place list and markers) and
`ov_801f0800_553` (AREAE005.EMI #21, the walking map) hold the tables.

Node record (20 bytes, 108 nodes, the table ends with 0xff):

| Offset | Content |
|---|---|
| +0, +1 | map x, y |
| +2, +3 | visibility code and bit (see below) |
| +4..+7 | road (edge) id per direction, 0xff none |
| +8..+11 | node reached per direction |
| +12 | node type |
| +14 | u16 name id: a message in bank 0 of map 0805's text (0x1e = "?", 0x1f = camp) |
| +16 | land: the continent the node's roads join |
| +18 | u16 region |

Visibility (0x800f8844(code, bit); 0x800f8930(node) passes +2, +3): code 0xff is
always shown. A code with 0x80 set picks list `bit` of the pointer table
0x800fb788: 3-byte (area, bit, expected) triples ended by 0, all must match.
Any other code tests bit `bit` of story word 0x8011b7d0 + code * 4. Codes
can name area 0x2a (0x8011b878), a long bitfield of world map flags.

Road record (12 bytes, table 0x800fa8a8): +8 code, +9 bit, gated the same
way. 0x801f0ac4 builds a node's direction mask from its roads.

Node to map table, overlay 553 around 0x801f5280, 12 bytes: map u16, flags
u16, node x/y, entry tile x, z, direction. The visited bitfield 0x8011b750
colours a node marker (8 visited, 26 not).

"?" nodes (name id 0x1e) that enter area 08 scenes, from that table (entry
tile, then what gates the node's marker):

| Node | Map | File | Entry | Shown by |
|---|---|---|---|---|
| 107 | 0807 | AREAE007 | 27,15 | area 9 bit 5 (as Wyndia) |
| 88 | 0832 | AREAE050 | 16,17 | area 0x0e |
| 78 | 0830 | AREAE048 | 9,53 | area 0x0e |
| 75 | 084b | AREAE075 | 17,84 | area 0x10 |
| 102 | 0843 | | 29,45 | area 0x11; a minigame ("Point" box) |
| 27, 85, 104, 103 | 082a, 0849, 0826, 0827 | | | world flags |

The combo dog teaches the four specials in 0807, 0832, 0830 and 084b
([field.md](field.md#combo-dog)).

### Shift

Shift is a vanilla feature, learned late: the teaching girl in Shyde grants
it once Chek's events are done (the grant below). Skill 230 in the skill
table is not used for it. "Shift known" is area 0x2a bit 216 (0x8011b893 mask 0x01). Overlay 553's
test 0x801f0d1c returns it while 0x801172ae bit 1 is clear (0x80191828 tests
a bit, 0x801917d4 sets one, both (base, bit)). With it set:

- The node map marks the node the party stands on visited (0x801f197c).
- Select (the "Map" key) opens the zoomed-out map with the info box "To use
  Shift, select a location and press the (Confirm) button." Visited nodes
  show a red dot; L1/R1 jump the cursor between nodes; Confirm on a node
  that is visited and named (0x801f16a0) and not the current one (0x801f26d0)
  asks "Use Shift to travel to <name>? Yes/No", and Yes reloads the node map
  there. It works across lands (tested Cliff in the South Desert to the
  Tomb in the Zhinga Mts.).
- 0x801f2528 and 0x801f3798 pick other help lines / cursor starts.

0x801172ae bit 1 would turn Shift off, but no instruction on the disc sets
it: a scan of the executable and every overlay finds byte stores to
0x801172ae only with masks 0x01, 0x04 and 0x40 (and halfword stores to
0x801172ac stop at 0x801172ad). Its only readers are the two copies of the
test. The second copy is overlay 582 (WORLD/AREAE033.EMI #11, map 0821, the
sailing minigame: Row / Sail / Anchor, wind, supplies) at 0x801f0c7c. Anchor
(Triangle) calls 0x801f35a4, which looks for one of 12 landing spots
(table at 0x801f3d18, 16 bytes each: tile x, tile z, destination map, ...)
within one tile of the ship (tile x/z at 0x80119368 +14/+22; spot 10 also
needs area 0x2a bit 128). Landing at spot 2 (tile 24,7, map 0831, a fishing
spot) sets area 0x2a bits 137+136; spot 10 (tile 44,44) sets 32+136. Then,
when Shift is known, it marks node 82 (spot 2) or node 83 (spot 10) visited
(0x8011b750). Tested: teleporting the ship to spot 2 and anchoring sets
node 82 (0x8011b75a bit 2) when the test answers yes and leaves it clear
otherwise.

The grant: map 0x1020 (AREAM032, whose bank holds Shyde's sandflier text)
has a tutor's talk script at 0x801f1080 (map overlay 524, `ov_801f0800_524`;
header +24) that tests area 0x2a bit 0xd8 and runs answer handlers from the
table at 0x801f10ac. Its bank messages 61..75: "Hello again, everyone...
What would you like to know about?" with choices Shift / The ancient dragons
/ Turning into a dragon / Never mind. Choice 0 the first time (0x801f094c,
choice at object +43) sets bit 216 and shows message 65: "Da-da-ta-da-da-dat-
dat-ta-da! Congratulations! You are now able to use the spell Shift! Shift
lets you travel instantaneously to any city, village, or place you've
already been to. Press the SELECT button while on the world map to use it.
You can go to any of the places highlighted with a red dot." Later visits
(0x801f09c0) show 71..75, the same help without the grant.

The script is the map's event 0 (header +24 is the event table: an NPC
whose message id has bit 15 set runs event id & 0x7fff through FLD
0x801daac0 and list runner 0x801dfde8). Event 0 at 0x801f1080:
`13 05 f3 0e 2a d8 0d 40 00 fc 0d 46 00 fd 10 06 ff`, i.e. message 64 if
area 0x2a bit 216 is clear, else message 70. The teaching girl is the spawn
record `00 cf 03 1f 0a 00 84 01 02 30 00 80 00` (sprite 0x03cf, tile
(31,10) on the drawbridge platform, message 0x8000), alone in the condition
block `f0 0e 0d 05 ... fd`: she appears once area 0x0d bit 5 is set
(0x8011b804 mask 0x20). Spawn-list conditions: `f0` runs the block when its
test is true, `f3` when false; test kind 0x0e (0x801e1414) is a story bit
(area, bit). Event VM op 0x3d `3d <area> <bit>` sets a story bit, 0x3e
clears one.

Area 0x0d bits 4 and 5 are Chek beats: 13:4 is set by the Chek interior
(AREAS036, overlay 467, 0x801f3eff), and Chek (AREAM054, map 0x1036,
overlay 546) spawns four objects under `f0 0e 0d 04 f3 0e 0d 05`, the last
(sprite 0x0320) running script 3 at 0x801f2890, which sets 13:5 and area
0x2a bit 11 (0x801f28be). Nothing on the disc clears 13:4 or 13:5. Only map
0x1020 has the girl (AREAM033, 0x1021, shares the text bank but not the
NPC). Walkthroughs place her in Shyde after the party comes back and Marlok
pays for the sandflier.

Verified: with 0x8011b804 = 0x20 (Shift option off), requesting map 1020 at
(8064, 3200) shows her next to the stairs; talking and picking Shift sets
0x8011b893 to 1.

Test: from the node map, `poke 8011b893 1` and the visited bytes
0x8011b750..0x8011b75f to 255, then `press select 2`, `press l1 2`,
`press cross 2`.

### Dengeki store (cut from the US release)

The JP magazine-promo store is on the US disc: forest AREAD068 (map 0x0444)
with a house door at tile 22,12 into the store AREAS052 (map 0x0234). Their
text on the disc is Japanese. A test village, AREAM019 (map 0x1013), has its
exits into the forest; see [Noritake's Town](#noritakes-town-cut-test-village).

- World map node 34 ("?", south-west of Mt. Glom, enters 0x0444 at 18,37):
  shown by area 0x2a bit 0xa5 (0x8011b88c mask 0x20).
- Its road to Mt. Glom (node 32), edge 0x27, uses list 4: area 0x2a bits 0x5a
  (Mt. Glom, 0x8011b883 mask 4) and 0xa5.
- Area 0x2a bit 0x8d (0x8011b889 mask 0x20) opens the place: without it the
  forest overlay (AREAD068 #11) disables the door (object 0x2b) and the store
  overlay (AREAS052 #12, 0x801f26f4) disables object 0x16.
- Nothing in the US game sets bits 0xa5 or 0x8d; the fan patch (romhacking.net
  hack 7410) sets them in a save. The port's `[field] dengeki`
  (port/src/qol/dengeki.odin) keeps both set once Mt. Glom's bit is set.
- The blue Manillo sells Midas' Armor (5000z), Medallion (888z), Toothpick,
  Chopsticks and Straw; the orange one runs a lottery (3,000 / 30,000 /
  300,000 zenny prizes). Talk to it from tile 1,7 facing right.
- The lottery (AREAS052 entry 12, overlay at 0x801f0800): a ticket costs
  300z and is item 83 (US name "LotteryStub"), given with 0x80194ae8(1, 83,
  1). Buying one also stores the battle count (ENCOUNTERS, 0x8011b67c) at
  0x8011b77c. The talk state is byte 0x8011b7b3, dispatched by 0x801f2610
  through the table at 0x801f2740. Bytes 0x8011b7b2..b7b8 are generic map
  scratch that about 70 maps share. State 0 (0x801f0fbc) counts the tickets
  held (0x80194c70(0, 83), into 0x8011b7b5). With at least one, and at least
  5 battles since the purchase, the talk goes to the draw (state 2).
- The draw is rolled when it is shown (0x801f0b14, called from 0x801f1c84)
  with RAND, into 0x801f2884 as nibble BCD: five unique four-digit 1st
  prizes, three last-three-digit 2nd prizes (0xf000 | digits), and one
  last-two-digit 3rd prize (0xff00 | digits). The board labels 1等/2等/3等
  are Japanese graphics. Verified in the port: buy, poke ENCOUNTERS up 5,
  draw board, highlight sweep, "It is a dud".
- The win check (0x801f2090..0x801f21a8): ticket numbers are u16 nibble BCD
  at 0x8011b768 (record base 0x8011a94c + 3612), and the ticket checked is
  the last one, tickets[0x8011b7b5 - 1]. The sweep index (s8 at 0x801f2876,
  0..8) steps each time the counter at 0x8011b7b8 reaches 8. The ticket is
  compared with prize[index], ORed with 0xf000 for indices 5..7 and 0xff00
  for 8. A match plays 0x8014c090(13/14/15), adds the prize with 0x80195358
  (300,000 for indices 0..4, 30,000 for 5..7, 3,000 for 8), sets
  0x80114870 = 2 and bumps 0x8011b7b4. No match after index 8 gives
  0x8014c090(16), the dud. Win verified in the port by poking ticket 0 and
  prize 0 to 0x1234 during the sweep: the board rings 1234, the Manillo says
  "Truly, nozing else can compare." and zenny goes 377 -> 300,377.
- English text: the fan patch (Dengeki Store Restoration v1.0, hack 7410)
  changes the text entry (the one loaded at 0x80010000) of both maps, adds a
  64-byte colour table entry (kind 0x80037c00) to AREAD068 and a 14th entry
  to AREAS052 (type 3 texture, 0x1800 bytes, rows cut from AREAM000.EMI), and
  moves every later file in the executable's file table (+1 sector after
  AREAD068, +3 after AREAS052). `bof4tools dengeki-patch` rebuilds the two
  files from the patch's xdelta files and the disc without running its
  Windows programs; the port serves them from `port/dengeki/` at sectors past
  the disc's end (file table entries 0x28e and 0x3b7 rewritten while the
  option is on, `spu.sector_hook`). The game sizes file reads from the EMI
  header, never from the table (loader 0x8013b6f4, file-to-LBA 0x8013c264).
  AREAM019 has no patch.

### Noritake's Town (cut test village)

AREAM019 (map 0x1013) is a small village that nothing leads to. Its place
name, message 0, is のりたけさんのまち, "Noritake's Town". Its text bank (the
entry loaded at 0x80010000, 0xb54 bytes) is Japanese only, and the
Japanese's offsets and ids are below.

- Exits, section 0: cells 15..18,5 lead to 0x0444 13,27 and cells 4,16..18 to
  0x0444 26,6. The US forest has no exits back, and neither of those forest
  cells has exit attributes. With `[field] dengeki` the port adds one
  (`qol/village.odin`): the forest's section 0 exit list (in overlay data at
  0x801f0868, three entries, nothing free after it) is copied to 0x80016f00
  with a fourth entry and the section's pointer repointed, and cells
  23..26,5, the dead end just north of 26,6, get attribute 0xa0. The entry
  leads to 0x1013.0 at 5,17 facing 0. The port's free walk takes the facing as the way through
  (`exit_way`): with facing 2 the leader walked onto the cells heading north
  and nothing happened, so the facing matches the step north.
- Spawn list (overlay AREAM019 #8, `ov_801f0800_511`, list 0x801f0928): most
  villagers use message 1, かいわ ("talk"). Two shopkeepers (sprite 0x3a,
  19,19 and 20,19) use message 2, a 1c-style shop prompt with a Buy / Sell /
  Never mind choice. The shop sells Healing Herb, Vitamin, MultiVitamin,
  SuperVitamin and King's Sword at 0z. A Manillo (sprite 0x17, record type
  21, at 20,10 behind a fence; talk from 19,10 facing right) uses message 3
  and opens the US fish trade. Two hidden NPCs (18,14 and 18,16, state 6)
  use message 0. Message 4, a Dragon God statue with Rest / Save, is used by
  no NPC.
- Masters: the bank holds two masters' full text. Gyosil the fisherman
  (ids 5..47; in the US release he is in AREAM017) teaches "Mind's Eye"
  (しんがん) and his rewards follow the fishing rank. Beito (ids 48..79), who
  never made it into the US game, wants his pupils to "take it slow"; his
  rewards (Withdraw, Backhand, Megaphone) follow the play time (20, 25 and 30
  hours). The overlay has three scripts in the table at 0x801f091c. Script 0
  (0x801f08f0, used by the event NPC at 12,6, sprite 0x23, message 0x8000)
  only shows Gyosil's opening, message 0x0a or 0x0b, whose choice leads
  nowhere. Scripts 1 (message 0x21, Gyosil) and 2 (message 0x41, Beito)
  end with `10 00` / `10 01`, which call the overlay's native functions
  0x801f0804 and 0x801f0840. Those call the shared master overlay 025
  (0x800f886c) and request a master talk with bytes 0x8011b7b2..b4 = 0x24,
  0, master 9 or 2. No NPC uses scripts 1 or 2; in the US game master 9 is
  Bunyan, whose map (AREAD116) has a byte-identical function.
- The port's `[field] dengeki` (port/src/qol/village.odin) replaces the bank
  with its own English translation once the disc's bank (FNV-1a 0x9db92e78)
  has loaded: the same 256 ids, each pointing at the English for its
  Japanese message, with the Japanese text codes kept.

Order of the Sarai chapter's flags (area 4): bit 8, then bit 10 (merchant on
the world map, map 0814), bit 14 (shop 0204.0), then Sandflier Valley bits 18
and 19.

The merchant: a road on the world map with an encounter area (road record
+4, table 0x800fa8a8, 12 bytes each) can stop the walk with an encounter
balloon. The walking overlay's state 0x801f37fc then counts 30 frames
(object +78); Confirm (pad 0x80116d3a) within them calls the scenario's slot
5 (wrapper 0x80191634) before the battle. SCE04's slot needs map 0805, area
4 bit 8 set and bit 10 clear, and the leader outside five node boxes (Sarai,
the camp, the crater's two "?" nodes, the cliff canyon; tested by
0x80191958, box bytes xmin, zmin, xmax, zmax); it then requests map 0814 at
0x1200, 0x1700 facing 2 in place of the battle. Confirm is what starts a
road battle at all: a direction pressed, or the 30 frames running out,
drops the balloon and the walk goes on. The autopilot route: from the camp, `press right`
toward the crater's "?" node with Cross pressed four times in the first 20
frames, at encounter_rate 16.

### Maps with no static way in

A sweep of all 374 field maps (2026-10-23) looked for every way into each
map: exit lists, op 0x5b requests in the map overlays, native `li a0, map`
before `MAP_REQUEST` (0x801cf598) or `AREA_SET` (0x801cfe5c), the SCENARIO
scripts, and the world map's node table. 57 maps have no static way in.
Apart from Noritake's Town, none of them looks cut:

- Story and event maps entered by computed requests: 0233/0812 (P'ung Ryong
  talk), 041a, 046d, 048f (ending save), 0801, 081a-081c (Faerie village),
  081e (sand flier), 082c, 082e, 0847/0848 (Sa Ryong), 084c, 084d/1004,
  084e, 084f/0850 (Chedo), 1029 (Synesta after the war), 1035, 1037.
- Fishing spots 044b and 0804. Treasure scenes ("You found..." / "Do you
  want to leave?") 0239-023b, 0809, 0833-0835.
- Maps whose 0x80010000 text bank is the 520-byte stub (no dialogue). Seen in
  game, they are terrain for world-map "?" scenes and story events: 045e
  (jungle path), 0467 (desert canyon, 24x8, no exits or NPCs), 047a (soldiers
  on a scaffold, a cutscene), 0488 (planks over mud), 082b/082f and
  0841/0842 (desert), 0808, 0836-083a (forest, 0838/0839 autumn),
  083b/083c/083e-0840 (plains), 083d (rocky ground). 0836-0842 all have
  28x28 grids.
- 1026 (AREAM038) is a night camp: a tent, a campfire and a chest. The tent's
  door (14,11) leads to 021e (AREAS030), the camp tent interior, which
  returns through special exit 0002. Camps E018, M026, M046 and M047 use the
  same tent door.

These maps spawn the party at a default 26,32. On the small ones that cell is
outside the grid, so a bare `BOF4_WARP=<map>.0` shows only the party in black.
Give a cell (`BOF4_WARP=1026.0:9,9`).

`bof4tools emi-extract` used to skip map overlays with fewer than four `jr ra`
(such as AREAD068's 0x144-byte one), so the exits of about 88 maps were
missing from `bof4tools exit-graph overlays` and the sweep read the area EMIs
directly. Fixed: an entry that opens with its own id followed by an
instruction (high half nonzero) counts as code, which adds the 82 small map
overlays; the data tables that share the id word follow it with a small
offset instead. `port/src/rec` was regenerated from the fuller dump, so these
maps' code now runs recompiled instead of interpreted (Dengeki forest route:
RAM and frames identical to the interpreted build).

## Sarai minigames

**Drinking contest** (tavern, scenario `SCENARIO/SCE04` loaded at
0x801f8800, entry 0x801f8a28 stored at 0x801fa718). State at 0x801fa810: u8
+0 phase (2 = waiting for a drink), u8 +4 last drink. Each drink fills the
win bar by 48 (Circle, Triangle) or 32 (Square, Cross) less a penalty for
repeating a button, and one of two losing bars (Square/Triangle or
Circle/Cross) by as much plus a penalty for repeating that pair. Triangle
costs 5 gold (gold u32 at 0x8011ad80). Alternating Circle and Triangle wins
in six drinks.

**Information broker** (overlay at 0x801f0800). Phase table 0x801f26b4
(entry handler 0x801f1428 in slot 1), state u8 0x801f26d4 (1 = entering an
offer), total paid s16 0x801f26ce, offer being entered s16 0x801f26d0. Offers
add up; at the price of 123 the broker talks, and exactly 123 sets the
reward byte 0x8011b7a5.
The same table feeds the field pop-up (the Menu button) and the camp menu's
Journal page, which lists every beat before the current one as done.
