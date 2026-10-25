# Debugging and testing

Everything here is controlled by environment variables on the `bof4`
binary. Run it from `port/` (it reads the disc and config from the working
directory). Without a display, set `SDL_VIDEODRIVER=offscreen`. Run one
instance at a time: two share the memory card files.

## Running

| Variable | Meaning |
|---|---|
| `BOF4_CONFIG=<file>` | config file instead of `bof4.ini` |
| `BOF4_MCD=<file>`, `BOF4_MCD2=<file>` | memory card images for slots 1 and 2 |
| `BOF4_DEVICE=keyboard\|ps\|xbox\|switch` | fix the button prompt family |
| `BOF4_FAST=1` | run unpaced (as fast as the host can) |
| `BOF4_OSD_PANEL=<n>` | start with the debug panel shown on page n |
| `BOF4_WARP=map[.section][:x,z]` | every save loaded resumes on that map (hex id, see [story-and-maps.md](story-and-maps.md)), section (decimal) and tile; a section the map lacks hangs the game |
| `BOF4_FLAGLOG=1` | log every story flag change with the last message shown |
| `BOF4_NPC_SPRITE=<from>:<to>[:<x>,<z>]` | every NPC spawned with sprite `<from>` (hex) gets sprite `<to>`, standing at tile x,z (decimal) when given; every spawn is printed as `npc sprite S at x,z script N`, so `0:0` lists a map's NPCs. For looking at sprites a map's sprite table lists but no NPC shows (field.md NPCs) |
| `BOF4_ENEMY_STATS=<hp>,<exp>,<zenny>` | every enemy record gets this HP, EXP and zenny (decimal) before the battle setup copies it; with `[battle] balance` and `BOF4_TRACE=game` the scaled values are logged as `balance: enemy ...` (battle.md Rebalanced mode) |

## Recording and replaying

`BOF4_DEBUG_DIR=<dir>` writes every pad state, camera drag and pointer move to
`<dir>/input.rec`; F12 saves a snapshot there (window picture, game frame,
main RAM, VRAM as a picture and raw as `_vram.bin`: 1024x512 u16, which keeps
bit 15 and the texel indices of 4bpp and 8bpp pages). Emulation is driven by emulated vblanks ("presents"), so
`BOF4_REPLAY=<dir>/input.rec` replays the session exactly, given the same
disc, config and starting memory cards. Live input adds on top, so a replay
can be taken over at its end. Format: see the header of `psx/record.odin`;
buttons and sticks are a ps-recomp core input record (`core/record.odin`),
which starts with `V 1` and keeps button masks in pad wire order. A record
made before the port moved onto core has no `V` line and is refused;
`python3 tools/rec_v1.py <files>` converts such records in place.
After the `V` line, a record starts with `T 0 2` (native rewrites take no emulated time); one
without a `T` entry is from before 2026-10-22, and its replay charges the
game's cycles for them as it was recorded, until its last entry (see
[architecture.md](architecture.md#how-the-games-code-runs)). Recording
during a replay writes the replayed buttons and sticks along with live
input, so the new record plays back the same. Records made before
2026-10-22 may hold stray `I <present> 0` entries written by the forked
background loader (instant doors); they replay as they were recorded.

Scripted input without a recording (all lists are comma-separated):

| Variable | Format |
|---|---|
| `BOF4_INPUT` | `<present>:<hex mask>[:<presents>]` hold a pad mask (see [text-and-ui.md](text-and-ui.md#controls)) |
| `BOF4_STICK` | `<present>:<lx>/<ly>/<rx>/<ry>[:<presents>]` stick positions -1..1 |
| `BOF4_POKE` | `<present>:<hex addr>:<hex byte>` store a byte into RAM |
| `BOF4_DRAG` | `<present>:<x>[/<y>][:<presents>]` camera drag |
| `BOF4_POINT` | `<present>:<x>/<y>` move the mouse pointer to display pixel (x, y) (mouse menus) |

## Dumps

| Variable | Meaning |
|---|---|
| `BOF4_DUMP=<dir>` | write frames (every `BOF4_DUMP_EVERY` presents, default 30) and RAM (every `BOF4_DUMP_RAM`, default 1500) there, from present `BOF4_DUMP_FROM` |
| `BOF4_DUMP_WINDOW=1` | dump the window picture rather than the PS1 frame |
| `BOF4_DUMP_HASH=1` | write no dump files: each dump becomes a `kind  present  XXH3` line in `<dir>/hashes.tsv` (the regression runs in `tests/` use it) |
| `BOF4_FLOORDUMP=<dir>` | write each map's floors (attribute cells, ground heights) as `<map>.json` there, see field.md Floors |
| `BOF4_MAPS=<dir>` | load `<map>.blk` from there in place of a map's data block and apply `<map>.edit` patches; the F4 map editor saves there (default `maps`), see field.md Edited maps |
| `BOF4_SPRITES=<dir>` | write every distinct texture rectangle a 4- or 8-bit textured polygon or rectangle draws as a PNG in its CLUT's colours (index 0 transparent), named `<tex x>_<tex y>_<clut x>_<clut y>_<u>_<v>_<w>x<h>.png`; rectangles under 8 pixels are skipped, duplicates too, at most 20000 (`psx/sprite_dump.odin`). Collects coloured sprites while VRAM holds them, e.g. for reference art |
| `BOF4_RAMDUMP=<file>` | save main RAM at exit (also when an autopilot script ends or times out) |
| `BOF4_AUDIO_DUMP=<file>` | write the audio output (s16le, 44100 Hz, stereo) |
| `BOF4_CAPTURE=<file.mkv>` | record the window as a 60 fps video on the wall clock, from present `BOF4_CAPTURE_FROM` (default 1); a picture shown late is repeated for as long as it stayed up, so stalls show as they were seen. Run paced (no `BOF4_FAST`); needs `ffmpeg` on the PATH; Matroska survives the process being killed |

A RAM dump is 2 MiB, address 0x80000000 at offset 0.
`tools/bof4tools field-state ram.bin [--grid] [--layer=N]` prints the map,
exits, party and NPCs it holds; `--layer` picks the collision layer of a
section with an upper floor.

## Tracing

| Variable | Meaning |
|---|---|
| `BOF4_TRACE=io,irq,...` | channels to log, or `all`: `io irq event sio timer dma cdrom gpu bios call block interp mem perf game` |
| `BOF4_TRACE_AT=10000-10003` | only while the present count is in this range (decimal) |
| `BOF4_TRACE_PC=80171500-80171900` | limit block, call and interp lines to a PC range (hex) |
| `BOF4_WATCH=80116d0c[-80116d10]` | log every CPU store into the range (channel `mem`) |
| `BOF4_TRACE_FILE=<path>` | write the trace there instead of stderr |

Each line is `<present> <cycles> <channel> <message>`.

The port prints `interpreting <address>` the first time it reaches code that
was not recompiled. Add the address to `tools/funcs.tsv` and regenerate (see
[architecture.md](architecture.md)).

## Autopilot

For playing long stretches unattended (`qol/autoplay.odin`):

- `BOF4_CHEAT=1` keeps the party at full HP, and in battle at 999 Pwr, Def
  and Agl (see [battle.md](battle.md)), so confirming the default attack wins.
  `BOF4_CHEAT=hp` leaves the stats alone and instead zeroes every hit, status
  and death aimed at the party, so fights last as long as usual.
- `BOF4_AUTO=<script>` runs a script, one command per line, `#` comments.
  Confirm is pulsed during battles, events and field text boxes that hold
  the leader, so dialogue goes by on its own. A choice takes its first option
  the first time it shows, the next option the next time, so menus that come
  back, like a help menu, are left. Choices are told apart by their options
  and the text box shown before them; the count for one resets once the
  player has had control for 30 vblanks.
  With `BOF4_REPLAY` as well, the script starts only after the replay's
  last entry, so the replay plays out untouched.
- `BOF4_AUTO_TRACE=1` logs the leader's position, height (in cells, positive up), layer (floor of the section), heading and target every
  4 vblanks while walking.

| Command | What |
|---|---|
| `wait N` | N vblanks |
| `press BUTTON [N]` | hold a button (`PAD_NAMES`) for N vblanks (default 4) |
| `stick DEG N` | push the left stick toward world angle DEG (0 = -z, clockwise) |
| `goto X Z` | walk the leader to tile X, Z along the collision grid (or onto an exit, until the map changes) |
| `until map M` | wait until map M (hex) is loaded |
| `until field` | wait until the player has control on the field |
| `until world` | wait until the world map has control |
| `fight` | pace on the spot with the encounter step budget held at 1 until a battle starts, then wait for control after it |
| `fight start` | as `fight`, but done as soon as the battle starts, so later commands drive the battle menu (Attack, Special, Use Item, Guard; Ryu's Special, Meditate, Aura turns him into a dragon) |
| `boss N` | the next battle loads `BWORLD/BOSS<N>.EMI` (1..32) in place of the encounter's area, with its boss setup and scripts: `boss 7` then `fight start` fights Kahn anywhere. The swap happens in the file loader 0x8013b6f4, since the encounter rewrites the area until the file is read |
| `pulse on\|off\|qte\|manual` | `off` stops the confirm presses autoplay sends through battles and events, so `press` alone drives them; `qte` presses confirm on cue for learned timed hits; `manual` also stops autoplay answering choices and backing out of menus a talk opens (shops, the Dengeki lottery), so the script presses everything |
| `log TEXT` | print TEXT |
| `poke A V` | write byte V to RAM address A (hex), to set up a test |
| `grid` | print the collision grid (`#` wall, `E` exit, `/` stairs, `@` leader), then the raw attribute bytes (hex) of the 7x7 cells round the leader |
| `snap` | take a snapshot (with `BOF4_DEBUG_DIR`) |
| `point X Y` | move the mouse pointer to display pixel X, Y (mouse menus) |
| `edit` | start or leave the map editor, as F4 |
| `tour [N]` | visit every reachable exit and back, logging where each leads, N levels deep |
| `doors [near]` | walk up to every door to a room on this section in turn and face it until the room's slide settles, logging `autoplay: door TTTT.S to RRRR.S slide x y z` (or `not settled`, or `gave up on door RRRR.S: why`); the survey behind the removed stitch table (field.md "Stitch table (removed)"); a slide settles only with door pictures on. With `near`, only the door nearest the leader. A door the walk cannot reach (`no way`, `goal not open`) is given up at once |
| `talk` | talk to every NPC in the section, nearest first; climbs stairs (kind 0xc cells) to reach NPCs on other layers; a talk set off on the way (a shop counter) blocks that step |
| `request M S X Z F` | ask for map M (hex) section S, arriving at X, Z (256 a cell) facing F, as script op 0x5b does (see field.md "Scripts"); stands in for scenes not reached yet |
| `timeout N` | set the timeout for later commands |
| `clock N` | run the CPU at N times the PS1's clock from here (`psx.clock_set`, which sets `psx.clock_mul`; testing only) |
| `quit` | exit |

Besides choices, the autopilot plays two Sarai minigames on its own: the
tavern drinking contest and the information broker's guessing game (see
[story-and-maps.md](story-and-maps.md#sarai-minigames)).

A command that times out takes a snapshot (with `BOF4_DEBUG_DIR`) and exits
with status 3; the end of the script exits with 0. Example:

```sh
cd port
SDL_VIDEODRIVER=offscreen BOF4_FAST=1 BOF4_CHEAT=1 BOF4_AUTO=route.txt \
  BOF4_DEBUG_DIR=/tmp/run ./bof4 2>&1 | grep autoplay
```

### Checkpoints

Long routes are slow even unpaced, so keep checkpoints: save in the game at
a point of interest, copy both memory card files aside, and start later runs
from copies (`BOF4_MCD`/`BOF4_MCD2`) together with a short recorded replay
(`BOF4_REPLAY`) that loads that file from the title screen. Copy the cards
before each run: the game may save over them. `BOF4_WARP` reaches a map
directly, but a map entered that way may lack the state its story set up.
Give it a tile: without one the saved tile is kept, which on another map is
often off the grid and leaves the party stuck in the void (040f without a
tile; `BOF4_WARP=040f.0:2,3` walks normally). A section can also be ahead of
the save's story: 040f section 1 spawns the party as ids 1 and 2 while the
leader id stays 0, so nobody takes control there.

Tips: keep each run short, give it a `timeout`, and check the RAM dump with
`bof4tools field-state` rather than rerunning to look again.
