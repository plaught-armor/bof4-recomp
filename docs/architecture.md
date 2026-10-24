# Port architecture

The port runs Breath of Fire IV natively on a PC without a PlayStation
emulator's CPU core. It is written in [Odin](https://odin-lang.org/).

```
port/src/
  main.odin   loads SLUS_013.24 from ../disc, opens the .cue, starts everything
  rec/        generated: every game function recompiled from MIPS to Odin
  psx/        the emulated PS1 the recompiled code runs on, plus host features
  qol/        quality-of-life features and mods, hooked into game functions
```

## How the game's code runs

`bof4tools recomp` is a static recompiler. It reads the executable and every
code overlay (`overlays/`, see [overlays.md](overlays.md)) and turns each MIPS
function into an Odin procedure working on the emulated CPU registers
(`psx.cpu.r[0..31]`) and memory bus (`psx.lw`, `psx.sw`, `psx.lbu`, ...).
Function boundaries come from `tools/funcs.tsv` (exported from Ghidra with
`tools/ghidra/ExportFunctions.java`).

```sh
# from the repo root; regenerates port/src/rec byte-identical
tools/bof4tools recomp exe disc/SLUS_013.24 overlays tools/funcs.tsv port/src/rec
tools/bof4tools recomp ovl disc/SLUS_013.24 overlays tools/funcs.tsv port/src/rec
```

Every call the game makes goes through `psx.call(addr)` (`psx/cpu.odin`):

1. Executable functions are looked up in a flat table indexed by address.
2. Overlay functions are looked up by address among the overlays that can
   load there, picking the one whose code is resident in RAM right now.
3. BIOS calls (`0xa0`, `0xb0`, `0xc0`) go to the high-level BIOS in
   `psx/bios.odin`.
4. Anything else falls back to the MIPS interpreter (`psx/interp.odin`) and is
   reported once on stderr as `interpreting 0x... (ra 0x...) at present N`. If
   you see one of those, the function is missing from `funcs.tsv`: add it and
   regenerate.

Under the CPU, `psx/` emulates the rest of the console: GPU (an OpenGL
renderer by default, a software one with `[window] hardware` off, both
with extensions, see [graphics.md](graphics.md)), GTE, SPU and XA
audio, CD-ROM reading the real disc image, MDEC movies, pads and memory cards,
timers, DMA, interrupts. Host-side it owns the window, input devices and
audio output (SDL).

The emulated CPU runs at the PS1's clock. Recompiled code charges a flat
`CYCLES_PER_INSN` (2) per instruction; the routines the port rewrote
natively (map drawing and ground code, see [field.md](field.md)) take no
emulated time. They used to charge the game's cycles path by path, and in a
busy town that drawing was most of the frame: Sarai needed three vblanks
per game frame (20 fps walking, against 30 in rooms). Free, it fits in two.
Replays of recordings from before 2026-10-22 charge them again
(`psx.charge_native`, from the record's `T` entries) until the replay ends.

`BOF4_CLOCK=<n>` (testing only) multiplies every scheduled event delay and
timer divider by n, so the game's code gets n times the cycles between
vblanks while audio and timers keep their real rates (`clock_mul` in
`psx/io.odin`).

The SPU mixes on a thread of its own (`spu_mixer` in `psx/spu.odin`): the
sound event only counts 32-sample batches due, and anything that reads or
changes SPU or CD audio state (registers, sound RAM, SPU DMA, XA sectors,
a fork) first calls `spu_sync`, which waits for the thread and mixes what
is left. Each batch therefore sees exactly the state it would have at its
event, and the audio comes out byte for byte the same (checked with
`BOF4_AUDIO_DUMP`). With the sound RAM IRQ enabled, and in forked children,
batches mix on the machine's thread at their event. A mod that touches SPU
state from outside `psx/` must go through `spu_sync` or `psx.sound_ram()`
(which syncs).

## Patch points

For a change inside a function that a whole-function hook cannot reach,
`PATCHES` in `tools/recomp.odin` maps an instruction address to an Odin
condition and a target label in the same function: the generated code
jumps there when the condition holds. Regenerate after editing it.

## Hooks: replacing a game function

Any recompiled function can be replaced with Odin code. The replacement gets
the original back, so it can run code before or after the game's version,
change its arguments or results, or skip it.

```odin
// Executable function
original, ok := psx.hook(0x8014307c, my_view_build)

// Function inside an overlay: address, load slot, overlay id
original, ok := psx.hook_overlay(0x801d1298, 0x801cc800, 15, my_step)
```

Inside a hook the arguments are in the MIPS registers: `a0..a3` are
`psx.cpu.r[4..7]`, further arguments on the emulated stack at `sp+16`
(`psx.cpu.r[29]`), the result in `v0` (`r[2]`). Read and write game memory
with `psx.lw/lh/lhu/lb/lbu` and `psx.sw/sh/sb`.

Hooks on one address chain: the original `psx.hook` returns is whatever was
installed before, so the hook installed last runs first. The order on the
shared draw and frame routines follows the `init` chain in `qol/config.odin`
and is listed in `qol/game.odin`.

`qol/` has two shorthands for the overlays hooked most:
`hook_field(addr, fn)` for FLD_MAIN (field logic, slot 0x801cc800, id 15) and
`hook_game_mode(addr, fn)` for the game mode overlay (slot 0x8018d800, id 14).

A complete feature, pared down from `qol/fade.odin` (which also eases the
level), capping every screen fade's speed:

```odin
FADE_STEP :: 0x8018f524 // a0 = ^s16 counter, a1 = speed; v0 1 when done
FADE_SPEED_MAX :: 0x800

fade: struct { step: psx.Func_Proc }

fade_init :: proc() -> bool {
	fade.step = hook_game_mode(FADE_STEP, fade_step) or_return
	return true
}

fade_step :: proc() {
	c := &psx.cpu
	speed := i32(i16(c.r[5]))
	c.r[5] = u32(clamp(speed, -FADE_SPEED_MAX, FADE_SPEED_MAX))
	fade.step() // the game's own function, with the capped speed
}
```

To call a game function from Odin, set up the argument registers and
`psx.call(addr)`. Some functions check their return address; `game_call` in
`qol/encounter.odin` calls one as if from a given `jal`.

Other hook points the emulation layer offers:

| Hook | When it runs |
|---|---|
| `psx.vblank_hook` | once per emulated vblank (60 Hz); `qol/config.odin` `vblank` fans out to features |
| `psx.pad_hook` | each pad read: takes and returns the held button mask |
| `psx.read_start_hook` | a CD read starts, with its LBA (used to spot which file loads) |
| `psx.card_read_hook` | a memory card file is read (save patching, e.g. `BOF4_WARP`) |
| `psx.dma_spu_hook` | after a DMA upload to sound RAM, with its SPU address and size |

## Worlds: switching maps without a load

`qol/interiors.odin` keeps whole maps as worlds: the map's RAM, VRAM, its
sound effect bank in SPU RAM and the CPU registers, noted at the map's field
draw. Rooms not visited yet are loaded by a forked child (`psx/preload.odin`)
and handed back through shared memory. With instant doors the machine enters
a noted world in place of a disc load: `psx.draw_start_enter` resumes the
world's frame, `psx.vram_replace` swaps the VRAM, and the global state
(party, flags, save region) stays. Map load side effects the game does on
its own (the left-map record, stopping and restarting sounds, the arrival
point) are redone by hand; [field.md](field.md) lists them. A world noted
before a story change is dropped and the map loads from disc.

## Smooth motion (60 fps) and the in-between pass

The game's logic runs once per two or three vblanks on the field and in
battle, so each picture is shown more than once. With `[window] smooth_motion`,
the port draws an in-between picture for every repeat (`qol/inbetween.odin`):
it saves RAM and VRAM (`psx/checkpoint.odin`), blends camera and object
positions part of the way (with P vblanks per game frame, the k'th repeat k/P
of the way), re-runs the game's draw code, then restores everything. During that pass `psx.events_frozen` is true.

When the passes run: each game frame records its poses into a small ring of
notes, and the frame's send queues the in-between pictures for the vblanks
the frame is shown on. Drawing every pass at the send stalls the main thread
long enough to starve the sound queue, so the send predraws only as many
steps as the longest of the last `SPAN_HISTORY` (8) frames' drawings spanned
(`draw_spans`, vblanks from the send to the end of the next frame's drawing,
clamped to 2..period) and each remaining step is drawn at its own present. A
draw-time spike that was not foreseen still costs a repeated picture now and
then. With the previous frame's span alone, a field alternating between two
and three vblanks of drawing (a town doorway with its room picture) froze a
picture every other frame.

Things the game places through a matrix outside the pose blend (the battle
camera, objects outside `OBJECT_SETS`) are blended by their GTE matrix
writes (`qol/inbetween_matrix.odin`): a write the pass makes unchanged from
frame N-1 takes the value `f` of the way from frame N-2's. When the pose
blend moved the camera, the filter blends nothing: every matrix built from
the camera is blended already, and one that merely rounds to frame N-1's
value would be blended twice.

The checkpoint holds RAM, VRAM, the flat-colour list, the picture and black
lists (`picture.odin` `backs`, `blacks.odin` `blacks`) and the floors-open
stamp, because a pass's walk flushes and refills them with the blended
camera. Passes may add pictures for interior doors but must not store the
picture index on the door (`interiors.odin`): the pass's picture list is not
the real frame's.

A pass may hold one pass nested in it: an in-between pass draws a door's
room again from its own camera (`doors_between_draw`) in a room pass of its
own. The nested checkpoint keeps the outer one (`outer`) and restores it as
the running pass on restore; its saved picture is the outer pass's buffer,
which takes tiles it lacks from the outer pass's saved picture first
(`hi_load`).

RAM pages carry version numbers (`ram_ver`). Every writer already calls
`ram_guard`, and the first write after a version is taken renews it. So
`draw_start_load` copies only the pages whose versions differ from the
draw start's. A RAM writer that skips `ram_guard` or `ram_touch` breaks
this outside passes too, not only inside them. In-between passes draw the
hi-res target only (`hi_only_begin`) and are drawn again in full if they
read VRAM they left undrawn.

Rules for hooks that keep their own state:

- Do not advance per-frame state during the in-between pass; it is undone.
- Host-side state that affects drawing (camera offsets, fades) must be
  recorded per game frame and blended in the pass, or it flickers every other
  present (see `pose_record` / `pose_blend` in `inbetween.odin`).
- Anything new that reads or writes the high-resolution render target inside
  a pass must call `hi_touch` (see [graphics.md](graphics.md)).

## The qol layer and config

`qol.init` (`qol/config.odin`) loads `bof4.ini` (or `BOF4_CONFIG`) and calls
every feature's `*_init`, which installs its hooks. To add a feature:

1. Create `port/src/qol/<feature>.odin` in package `qol`.
2. Name the addresses you use as constants with a comment saying what they
   are; they then show up in [address-map.md](address-map.md). Addresses more
   than one feature uses live once in `qol/game.odin` (overlay slots, game
   state, the field map and camera, the draw routines, battle combatants with
   `combatant(id)`, character records with `char_record(i)`); check there
   before naming one, since a file-private constant of the same name silently
   shadows the shared one.
3. Write `<feature>_init :: proc() -> bool` that installs hooks, and add it to
   the chain in `init`.
4. If it needs a setting: add the field to `Config`, a `case` in the parser in
   `config.odin`, the documented line in the comment at its top, and a row in
   `options.odin` so it shows on the in-game Setting > Extras pages.
5. Build with `./build.sh` from `port/` and run `./bof4`.

The port's own text (menus, popups) is drawn with the game's font and window
routines (`qol/menu_draw.odin`, `qol/popup.odin`), and host overlays (the
minimap) with `psx/osd.odin`.

## Building

Needs the Odin compiler and SDL2. From `port/`:

```sh
./build.sh                 # optimized with debug info, writes ./bof4
BOF4_OPT=none ./build.sh   # unoptimized
BOF4_GL_DEBUG=true ./build.sh  # check glGetError after every GL call (slower)
BOF4_ARCH=x86-64-v3 ./build.sh # for other machines (AVX2); the default is this CPU (native)
./bof4                     # reads ../disc/SLUS_013.24 and "../Breath of Fire IV.cue"
```

Run it with `port/` as the working directory; disc and cue paths can also be
given as the first two arguments.
