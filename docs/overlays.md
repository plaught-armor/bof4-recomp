# Code overlays

Most of Breath of Fire IV's code is not in the executable. It sits in EMI
containers on the disc (see [disc-files.md](disc-files.md)) and is loaded into
fixed RAM regions ("slots") when needed: the field engine when you walk
around, the camp menu when you open it, a battle's code when one starts.

`tools/emi_extract.py` pulls every code entry out of the disc's EMI files,
merges identical copies, and writes them to `overlays/` as
`ov_<slot>_<id>.bin` plus `overlays/manifest.tsv` (file, slot, size, ids,
sha1, and every EMI entry that carries it):

```sh
python3 -I tools/emi_extract.py disc/BIN overlays
```

An overlay's first word, at its slot address, is its global id. The port uses
that (plus a short signature of the function's first words) to tell which
overlay is resident when the game calls an address several overlays share
(`ovl_resident` in `port/src/psx/cpu.odin`).

## Slots

| Slot | Overlays | What loads there |
|---|---|---|
| `0x8003e000` | 1 | boss-battle extra (BWORLD/BOSS031) |
| `0x800f8800` | 3 | map-specific extras (some AREA* files) |
| `0x8018d800` | 2 | **game mode** (SYSTEM/GAME.EMI, id 14): main loop, mode switch, screen fades; RTEST (id 660, test code) |
| `0x801aa000` | 20 | menus: camp (SGAMEN 17), shop 18, MSHOP 19, CAMP 20, GAME 22, SAVE 23, masters 26, COMMU 28/29, field-battle glue 50, map extras 24 |
| `0x801cc800` | 6 | **field engine** FLD_MAIN (id 15, also in BTLRET and D1xxBTL), DEMO 16, battle command/move/end/lose 51-54 |
| `0x801e6800` | 172 | camp sub-screens (id 21: Buttons layouts etc.), battle demos 56-59, one per spell/skill effect (BMAGIC) |
| `0x801ee800` | 39 | enemy/boss AI and party (BWORLD, PLAYER) |
| `0x801f0800` | 368 | one per field map (WORLD/AREA*): the map's own scripts and event code |
| `0x801f8800` | 30 | scenario (SCENARIO/SCE*) |

The ones most mods touch:

- **FLD_MAIN** `ov_801cc800_015.bin`: movement, the step handler, collision
  against objects, exit checks, NPC updates, message windows, the compass HUD.
  See [field.md](field.md).
- **Game mode** `ov_8018d800_014.bin`: game mode dispatch (`GAME_MODE`
  0x80114850, 2 = field), map changes, `FIELD_ENTER` 0x8018de00, fades
  (`FADE_STEP` 0x8018f524, `FADE_DRAW` 0x8018f474).
- **Camp sub-screens** `ov_801e6800_021.bin`: Setting > Buttons (layouts Type
  1-4 at 0x801e8464), shared by camp and COMMU containers.
- **Title** `ov_801aa000_022.bin` (`SYSTEM/GAME.EMI#1`): the title menu and
  its own copy of the camp Setting screen (tick 0x801acd50, Options tick
  0x801acf2c, Buttons tick 0x801ad2fc). See [text-and-ui.md](text-and-ui.md).
- **Map overlays** `ov_801f0800_<id>.bin`: event scripts and the story flag
  writes for each map; good places to find where a flag is set.

## Hooking a function in an overlay

```odin
original, ok := psx.hook_overlay(addr, slot, id, my_proc)
```

`id` is the overlay's global id (the number in the file name). `ok` is false
when the recompiler did not produce a function at `addr` in that overlay;
check that the address is a function start in `tools/funcs.tsv`.

## Ghidra

`ghidra/` holds the project; `tools/ghidra/ImportOverlays.java` loads every
overlay as its own address space (`ov_<slot>_<id>`), `ExportFunctions.java`
writes `tools/funcs.tsv` (space, entry, min, max, name) for the recompiler,
`Decomp.java` / `DecompSpace.java` batch-decompile, and `WritersOf.java` lists
stores to an address. 8508 functions are known; about 1860 have names. Naming
more in Ghidra and re-exporting is one of the most useful things a contributor
can do.
