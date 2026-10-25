# Breath of Fire IV recomp

A native PC port of Breath of Fire IV (PlayStation, US release SLUS-01324),
made by statically recompiling the game's MIPS code to [Odin](https://odin-lang.org/).
The recompiled code runs on a reimplemented PS1 (CPU, GTE, GPU, SPU, CD-ROM,
MDEC, XA, pads, memory cards), with no emulator core and no BIOS image. On
top of that, a quality-of-life layer adds hi-res OpenGL rendering, smooth
60/120/240 Hz motion, a free third-person camera, seamless towns, faster
doors and text, battle and balance options, restored cut content and more.
See [docs/port-changes.md](docs/port-changes.md) for the full list.

**This repository contains no game code or data.** You need your own copy of
the disc. The recompiled code (`port/src/rec`) is generated from it on your
machine by `setup.sh` (`setup.bat` on Windows).

## Building

Requirements:

- Linux or Windows, x86-64
- [Odin](https://odin-lang.org/) (developed with `dev-2026-10`); on Windows
  Odin also needs the MSVC build tools and Windows SDK (see Odin's install
  guide)
- OpenGL 4.5 drivers; on Linux also SDL2 (Windows uses the `SDL2.dll` that
  ships with Odin)
- ps-recomp's `core` package
  (tracing, capture, PNG, environment), checked out as `ps-recomp/` in the
  repository root, or anywhere else named by `PS_RECOMP`

Steps:

1. Rip your disc as a cue plus raw (2352-byte sector) bin tracks. Put
   `Breath of Fire IV.cue`, `Breath of Fire IV (Track 1).bin` and
   `Breath of Fire IV (Track 2).bin` in the repository root.
2. Run `./setup.sh` (on Windows, `setup.bat` from an
   "x64 Native Tools Command Prompt"). It does the following:
   - builds the tools into `tools/bof4tools` (`tools/build.sh`, or
     `tools\build.bat` on Windows);
   - extracts the disc's files to `disc/` (`bof4tools disc-extract`);
   - checks that the executable is the US release;
   - extracts the code overlays to `overlays/` (`bof4tools emi-extract`);
   - recompiles everything into `port/src/rec` (`bof4tools recomp`);
   - builds the port (`port/build.sh`, or `port\build.bat` on Windows,
     which also copies `SDL2.dll` next to `bof4.exe`).
3. Run the port from `port/`: `cd port && ./bof4` (Windows: `cd port`,
   then `bof4`).

The build targets the build machine's CPU (`-microarch:native`). To build a
binary for other machines, set `BOF4_ARCH=x86-64-v3` before running setup.
After the first setup, `port/build.sh` (`port\build.bat`) rebuilds on its
own.

On Windows the port does not load rooms ahead in the background: Linux does
that in a `fork()` copy of the game, which Windows lacks. Rooms load when the
party walks in, as on the PS1.

Settings are in `port/bof4.ini`. Most can also be changed in game, from the
camp menu's Setting > Extras page. Memory cards are
`port/bof4_slot1.mcd` and `port/bof4_slot2.mcd`.

## Layout

| Path | What |
|---|---|
| `port/src/psx` | the emulated PS1 and host platform (window, audio, input, renderer) |
| `port/src/qol` | features and mods, hooked into game functions |
| `port/src/rec` | generated: the recompiled game code (not in the repo) |
| `tools/` | `bof4tools` (in Odin): recompiler, disc and overlay extractors, map block tool, research helpers; Ghidra scripts |
| `docs/` | reverse-engineering and modding notes: start at [docs/README.md](docs/README.md) |

## Modding

[docs/architecture.md](docs/architecture.md) explains how the port runs the
game and how to hook a game function. The other guides record what is known
about the game's field engine, maps and story flags, battle, text, and
graphics, with addresses.

## License

GPL-3.0; see [LICENSE](LICENSE). Breath of Fire IV is © Capcom. This project
is not affiliated with or endorsed by Capcom.
