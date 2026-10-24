# Breath of Fire IV: modding and reverse-engineering notes

This folder records what is known about Breath of Fire IV (US PlayStation
release, SLUS-01324) and about the native port in `port/`, so that anyone can
build on it: change how the game plays, add features, or keep reverse
engineering it.

Nothing here contains game data. To run the port or check any of this you need
your own copy of the disc (`Breath of Fire IV.cue` plus its two `.bin` tracks
in the repo root). `setup.sh` (`setup.bat` on Windows) in the repo root builds
the tools (`tools/bof4tools`), extracts the disc's files to `disc/`
and its code overlays to `overlays/`, then regenerates `port/src/rec` and
builds the port.

## Guides

| Guide | What it covers |
|---|---|
| [architecture.md](architecture.md) | How the port works: static recompiler, emulated PS1 underneath, hooks, the `qol` feature layer, config. **Start here to write a mod.** |
| [overlays.md](overlays.md) | Code overlays: load slots, ids, which disc file carries which, how to hook a function inside one. |
| [disc-files.md](disc-files.md) | The game's file table, EMI containers, textures, save files. |
| [field.md](field.md) | Field maps: collision grid, positions, objects and NPCs, the step handler, exits, sections, the camera. |
| [story-and-maps.md](story-and-maps.md) | Map ids, areas, story flags, exit tables, how to find new story beats. |
| [text-and-ui.md](text-and-ui.md) | Text drawing, dialogue boxes, button-icon codes, menus, controls, screen fades. |
| [battle.md](battle.md) | Combatant records in battle, skill cinematics. |
| [graphics.md](graphics.md) | Ordering table, map tiles and models, sprites, GTE, and what the port's renderer adds. |
| [debugging.md](debugging.md) | Every `BOF4_*` environment variable: tracing, dumps, input scripts, warps, the test autopilot. |
| [port-changes.md](port-changes.md) | Everything the port adds to or changes from the original game, by area, with the setting for each. |
| [wizard-mode.md](wizard-mode.md) | What the fan Wizard Mode hard mod changes (reference for balance work). |
| [address-map.md](address-map.md) | Generated table of every RAM address the port names, with notes and source lines. |

## Conventions

- Addresses are PS1 virtual addresses in KSEG0 (`0x80xxxxxx`), the scratchpad
  (`0x1f800000..0x1f8003ff`), always hex.
- `exe` means the main executable `SLUS_013.24` (loaded at 0x80010000);
  everything at 0x8018d800 and above belongs to an overlay unless said
  otherwise (see [overlays.md](overlays.md)).
- Function names in capitals (`STEPPER`, `MODEL_DRAW`) are the names the
  port's source gives them. Ghidra-style `FUN_xxxxxxxx` names are unnamed.
- Field coordinates: one collision cell is 0x10000 in 16.16 fixed point.
- "Verified" in these notes means checked by running the game; anything
  marked "guess" or "not decoded" is open for someone to finish.

## Keeping the notes current

- `address-map.md` is generated. After adding or renaming address constants in
  `port/src`, regenerate it from the repo root:

  ```sh
  tools/bof4tools address-map port/src docs/address-map.md
  ```

  A constant gets a row when it is a top-level `NAME :: 0x8xxxxxxx` (or
  `0x1f80xxxx`) in any file outside `port/src/rec/`. The comment on its line
  and the comment block just above it become the row's notes, so write the
  comment where you name the address.
- The other guides are written by hand. When you find something new about the
  game, add it to the guide it belongs to, with the address, what you saw, and
  how you checked it.
