# Breath of Fire IV recomp

A native PC port of Breath of Fire IV (PlayStation, US release SLUS-01324),
made by statically recompiling the game's MIPS code to [Odin](https://odin-lang.org/).
The recompiled code runs on a reimplemented PS1 (CPU, GTE, GPU, SPU, CD-ROM,
MDEC, XA, pads, memory cards), with no emulator core and no BIOS image. On
top of that, a quality-of-life layer adds hi-res Vulkan rendering, smooth
60/120/240 Hz motion, a free third-person camera, seamless towns, faster
doors and text, battle and balance options, restored cut content and more.
See [docs/port-changes.md](docs/port-changes.md) for the full list.

**This repository contains no game code or data.** You need your own copy of
the disc. The recompiled code (`port/src/rec`) is generated from it on your
machine by `setup.sh` (`setup.bat` on Windows).

## Building

Requirements:

- Linux, x86-64. Only Linux is tested: the Windows scripts (`setup.bat`,
  `port\build.bat`) are untested, and macOS is untested and has no scripts
- [Odin](https://odin-lang.org/) (developed with `dev-2026-10`); on Windows
  Odin also needs the MSVC build tools and Windows SDK (see Odin's install
  guide)
- on Linux SDL2 (Windows uses the `SDL2.dll` that ships with Odin)
- about 10 GB of free RAM to build
- for drawing on the GPU: a Vulkan 1.3 driver with dynamic rendering local
  read and 64-bit shader integers and floats (without one the port draws in
  software)
- ps-recomp (its recompiler, the emulated PS1 in its `psx` package, and
  the `core` package: tracing, capture, PNG, environment): a submodule at
  `ps-recomp/`, fetched by `git clone --recursive` or
  `git submodule update --init`; `PS_RECOMP` names another checkout.
  Older commits of this repository pin ps-recomp commits from before its
  history was squashed for release; their submodule does not check out

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
   - recompiles everything into `port/src/rec` (ps-recomp's recompiler, with
     `tools/recomp.tsv`);
   - builds the port (`port/build.sh`, or `port\build.bat` on Windows,
     which also copies `SDL2.dll` next to `bof4.exe`).
3. Run the port from `port/`: `cd port && ./bof4` (Windows: `cd port`,
   then `bof4`).

The build targets the build machine's CPU (`-microarch:native`). To build a
binary for other machines, set `BOF4_ARCH=x86-64-v3` before running setup.
After the first setup, `port/build.sh` (`port\build.bat`) rebuilds on its
own; `port/build.sh debug` (`port\build.bat debug`) adds debug info.

On Windows the port does not load rooms ahead in the background: Linux does
that in a `fork()` copy of the game, which Windows lacks. Rooms load when the
party walks in, as on the PS1.

The hi-res picture is drawn with Vulkan by default. The environment variable
`BOF4_GPU` picks the renderer: `vk` (Vulkan) or `sw` (the CPU rasterizer,
also `[window] hardware = false` in bof4.ini). With no Vulkan device that
will do, the port draws in software. See
[docs/graphics.md](docs/graphics.md#hardware-renderer).

Settings are in `port/bof4.ini` (written when a setting changes in game;
missing means defaults). Most can also be changed in game, from the
camp menu's Setting > Extras page. Memory cards are
`port/bof4_slot1.mcd` and `port/bof4_slot2.mcd`.

## Layout

| Path | What |
|---|---|
| `port/src/qol` | features and mods, hooked into game functions |
| `port/src/rec` | generated: the recompiled game code (not in the repo) |
| `tools/` | `bof4tools` (in Odin): setup, disc and overlay extractors, map block tool, research helpers; Ghidra scripts |
| `docs/` | reverse-engineering and modding notes: start at [docs/README.md](docs/README.md) |
| `tests/` | `run.py`: replays recorded sessions and routes headless and compares every present against a recorded reference, see [tests/README.md](tests/README.md) |

## Modding

[docs/architecture.md](docs/architecture.md) explains how the port runs the
game and how to hook a game function. The other guides record what is known
about the game's field engine, maps and story flags, battle, text, and
graphics, with addresses.

## License

GPL-3.0; see [LICENSE](LICENSE). Breath of Fire IV is © Capcom. This project
is not affiliated with or endorsed by Capcom.
