# Graphics

## How the game draws

The game builds GPU packets in RAM and links them into an ordering table
(OT) of 1024 buckets, double-buffered; `DrawOTag` walks it. Bucket 0 is
drawn last and holds the HUD. Depth sorting is the only depth there is: the
PS1 has no depth buffer.

The GPU packet pointer (next free packet) is at scratchpad 0x1f80006c.

A packet linked twice closes a loop in the list, which the PS1's GPU DMA
would walk for ever. It happens for a frame after an instant door's world
switch (field.md, interiors): the port's walk (`psx/io/io.odin` `dma_gpu`) marks
each packet it visits and ends the list where it comes round (trace channel
`dma`). Before, the walk ran to its 0x100000 packet limit and stalled the
window for seconds.

### Field drawing

| Function | Address | What |
|---|---|---|
| `SCENE_DRAW` | exe 0x801420a4 | the field scene: map, models, sprites |
| `MAP_DRAW` | exe 0x80144800 | map tiles: floors, roofs (kind 0x3c), shadows (0x3e) |
| tile window | exe 0x8014330c | which tiles around a point ahead of the camera are drawn: half height and half width in cells, u16 at 0x801381e4 / 0x801381e6 (24, 16), centre offset u16 at 0x801381e0 / 0x801381e2; rows go into a list of 64 entries |
| tile corner test | exe 0x80143b84, 0x80144b5c, 0x801464c8, 0x80147d84, 0x80148b34, 0x801491ec | a tile or model part is skipped unless one of its four projected corners lies in -16..335 x -16..255; a near face spanning the screen fails it. The port's recompiler patch points skip it while `cpu.host_camera` (third-person camera); the port's own tile draw (`quad_draw` in qol/map_geometry.odin) then culls with `quad_may_show` instead: a quad goes only when all four corners are behind the lens (SZ 0) or all are in front and past the same screen side |
| packet budget | exe 0x8005aa54 | the frame's map packet count, scratch u16 0x1f800076 (`SC_BUDGET`): 1024, or 1496 while byte 0x801381ea != 0. Packet buffers are 1024 x 52 bytes (0xd000) per frame parity; the draw wraps at 0x8004e800 (`SC_PACKET_WRAP` 0x80). With no cull at all, the third-person tile window's tiles behind the camera spent the whole budget before `MODELS_LIST_DRAW`, and big towns (1001) lost every placed model (houses, the pool statue) to black; with `quad_may_show`, 1001 spends 238 |
| `LAYER_SETUP` / `LAYER_DRAW` | exe 0x80143304 / 0x80145654 | one map layer (see [field.md](field.md#sections)) |
| `LAYER_ADD` | exe 0x8013ae34 | commit a packet run to the OT |
| `MODELS_LIST_DRAW` | exe 0x8014316c | the map's models |
| model list | exe 0x80145674 | placements read from [0x1f800108] |
| model header | exe 0x801497dc | sets [0x1f8000f0] to the model's header |
| `MODEL_DRAW` | exe 0x80145d90 | one model |
| model yaw hide | exe 0x80149ee0 | a0 = placed model; v0 = 0 hides it. A model with byte +2 bit 2 hides from each yaw octant ((CAM_YAW + 0x100) >> 9) whose bit is set in byte +0xb (Sarai's awnings, which would cover the stalls in the fixed views). The third-person camera shows every model |
| model sight test | exe 0x80145c08 | a0 x, a1 z of a placed model; v0 = 0 culls it as out of the fixed view's sight. Scratchpad holds the test per view: centre 0x1f800084/86 (+0x40), manhattan radius s16 0x1f800088, side limit 0x1f80008a, mode byte 0x1f80008d (bit 0 on, bit 1 the other side test; set from (CAM_YAW + 0x100) & 0x600 by 0x80143304). The third-person camera passes every model, since it looks any way |
| `COLLECT` | exe 0x80141f1c | project an object for drawing |
| `MODEL_OBJECTS_DRAW` | exe 0x80145958 | model objects (doors, furniture: pool 0x801192cc) from the list at 0x80116d98+268 |
| `SPRITE_DRAW` | exe 0x8014193c | one sprite (people) |
| sprite OT depth | exe 0x8014a1ac | the sprite's bucket from its depth |
| sprite scale | exe 0x8014a324 | sprite size from depth |
| `SPRITE_PACKETS` | 0x80116cc0 | sprite packet list; the list's draw returns to 0x80142224 |
| `SHADOW_SET` | exe 0x801423f0 | shadows under objects: 35 records of 52 bytes at 0x80118bb0. It copies the sprite's position (+4..+8), scale flag (+15), scale x/y (+16/+20, 16.16) and colour (+24), and the shadow kind from sprite +50; drawn by SPRITE_DRAW right after its sprite (return 0x8014229c). A sprite that asks for depth scaling (+15 set; the game sets 0x140000 / depth) under the third-person camera's short depth got a shadow many times its size, so `third_person.odin` gives the shadow the scale its sprite was drawn at |

Big triangles: the PS1 drops a polygon whose screen size exceeds 1023x511;
the game splits large faces itself, and the port keeps the same rule so
geometry looks the same.

## The port's renderer

The port draws GPU packets in software (`psx/render/gpu.odin`), into VRAM exactly
as the PS1 would (so texture pages, CLUTs and framebuffers interact the
same) and, at the same time, into a hi-res target at `detail` = 1, 2 (the
default) or 4 times the PS1's resolution, with sub-pixel vertices and
perspective-correct textures. `psx/render/raster.odin` draws the hi-res target on
several threads; the result is identical to drawing in order.

Perspective textures use whole numbers only, so the software and GL
renderers pick the same texels (`Persp`, `persp_setup`, `persp_coord` in
`psx/render/gpu.odin`; `persp_coord` in the GL fragment shader). At triangle set-up
each corner gets a weight w = round(2^15 * nearest depth / its depth). A
pixel's coordinate in 256ths of a texel is floor(256 * sum(a t w) / sum(a w))
over its edge weights a (shifted right for triangles of area 2^29 or more,
keeping the sums inside an i64). The nearest texel is (c + 128) >> 8, and
smoothing splits c into texel c >> 8 and fraction c & 255. The software rows
step the sums by whole numbers (the same value as working them out per
pixel); the shader divides in f64 and fixes the quotient with the
remainder. Float perspective had left about 140 pixels a frame one texel
off between the two renderers, and Soft FX blends ±1 apart; both are now 0
in the dragon battle check (Glow and Soft FX, 6 runs).

Vertex depth (for perspective textures, see-through and doorway pictures)
comes from a cache of this frame's GTE projections keyed by the screen x, y
they produced, since the game copies only x, y into packets (it projects
into vertex buffers, e.g. 0x80117000, and builds packets from those, so the
packet address tells nothing). Two vertices at different depths often land
on one pixel (about a hundred a frame in Sarai). The cache keeps both, each
with the run of projections that filed it, and a polygon's corner takes the
one projected closest to its other corners (`depth_fill`); taking the last
one filed instead bent textures across near walls and misplaced ghosts.

Vertices the GTE clamps off screen pile up by the hundred at the corner
pixels (1023, 1023) and (-1024, 1023); a pixel keeps at most `DEPTH_PILE`
of its depths. The table is open-addressed by the top `DEPTH_SLOT_BITS` of
a multiplicative hash, and a probe walks up to `DEPTH_RUN` slots, counting
only its own pixel's entries against the pile limit. Until 2026-10-19 the
hash used only 16 bits and a probe gave up after 8 slots of any pixel, so a
corner whose pixel hashed onto a pile's slots was never filed and its whole
polygon lost perspective: near walls and roofs by the Sarai inn warped while
the camera turned, and see-through drew dark patches there.

Additions, all not PS1 features:

| File | What |
|---|---|
| `psx/render/depth.odin` | depth recovered from GTE projections (a vertex cache like PGXP's) |
| `psx/render/see_through.odin`, `scene/see.odin` | per-pixel fading of what stands between camera and leader: the renderer fades by the cover each polygon is given, the port's scene package decides it |
| `psx/render/depth_buffer.odin` | a depth buffer on the hi-res target under the third-person camera, so the close camera no longer shows the painter's order's mistakes |
| `scene/portal.odin` | draw a packet range only inside (or only outside) an opening's screen shape: neighbour sections seen through doorways |
| `scene/picture.odin` | fill a doorway with a picture drawn off screen: town interiors, and a room's door to its town (cut box) |
| `psx/checkpoint.odin` | frozen-time passes: run game draw code for an extra picture, then restore the machine exactly |
| `qol/inbetween.odin` | 60 fps: an in-between picture for each repeated display frame, drawn by a frozen-time pass with poses blended between two game frames |

Rules for code that runs inside a frozen-time pass: no events or
interrupts run; anything the pass writes outside the saved state (RAM,
VRAM, CPU, GTE, GPU, DMA, interrupt, event and BIOS state, the rand() seed
among it) is not undone, so
hooks that keep their own state must check `events_frozen` (see
[architecture.md](architecture.md)).

The pass runs the frame's end again, and the sound library's voice commit
there (0x8015da50..0x8015df08) writes voice volumes and the key-on/off,
pitch-modulation, noise and reverb registers (0x1f801d80..0x1f801d9a) from
the pass's RAM, a frame older than the chip. `spu_write` drops every SPU
register write while `events_frozen`; kept, they set the voices back once
a game frame and the music and ambience stuttered with smooth motion on.

## Hardware renderer

By default the hi-res target is drawn with OpenGL 4.5 (`psx/render/gl_target.odin`)
instead of the CPU rasterizer. `[window] hardware = false` in bof4.ini (the
Display page's "GPU draw", read at start) keeps it on the CPU, and the
environment variable `BOF4_GL=1` or `BOF4_GL=0` overrides the setting. If
the GL context or a shader fails, the port falls back to software. The CPU
rasterizer at detail 2 cannot hold 60 fps in busy towns (every game frame
took 18-26 ms of host work in Sarai's square, against 16.7 ms). The VRAM
target is always drawn in software, because the game reads VRAM back and
textures come from it.

How it works:

- The hi-res target is an `R32UI` integer texture holding true-colour
  pixels (`r<<16 | g<<8 | b`, 8 bits per channel, mask in bit 31). Texels
  from VRAM are widened 5 to 8 bits; shading, blend modes and fades are
  worked at 8 bits per channel with no dither, so gradients and fades do
  not band. The VRAM target keeps exact 15-bit PS1 pixels. The software
  plot (blend modes, fades, mask, see-through, ghosts, portals, door and
  walk tags) runs in the fragment shader with image load/store, using the
  same integer arithmetic as the software hi-res target (`Target.rgb`), so
  both give the same pixels.
- `[window] smooth_effects` (Display page "Soft FX", default off) samples
  see-through texels of 3D effects bilinearly at 8 bits per channel. Only
  textured semi-transparent polygons with GTE depth qualify, so UI, menus
  and sprite frames stay sharp, and inside them only texels with the stp
  bit set; solid texels keep the nearest sample. A clear texel (0) in the
  2 x 2 footprint takes the nearest texel's colour, so edges do not pick
  up black. The footprint is clamped to the polygon's texture window.
  Software (`smooth_texel` in `gpu.odin`) and the shader use the same
  fixed-point split of the texture attribute, so both give the same
  pixels. It applies to the hi-res target only; VRAM stays PS1-exact.
- `[window] smooth_textures` (Display page "Soft texels", default off)
  mixes the 2 x 2 footprint for every textured polygon with GTE depth (the
  world) and every sprite see-through files a depth for (people), solid
  texels included, as "sharp bilinear": per polygon, `polygon_sharp` takes
  the square root of screen area over texture area (VRAM pixels a texel
  spans, in 256ths, at least 256, at most 64 texels' worth), and on a
  target of shift k the weights are steepened by it shifted left k
  (`sharp_weight`: `clamp(((f - 128) * s >> 8) + 128, 0, 256)`). A
  magnified texel stays a flat square with a one-pixel blended edge, so
  texel staircases on slanted or turning faces soften and edges glide
  instead of snapping as the camera moves; a shrunk texture (far ground)
  gets the plain mix instead of shimmer. The value rides in `Gl_Prim.e.w`
  with flag `Smooth_All`; same integer math in both renderers (checked: no
  new pixel differences between GL and software in Sarai). Soft FX, when
  on, keeps the plain mix for effects.
- Glow floor: on the hi-res target a filed (sprite-like, `m.flat`) additive
  (blend mode 1) texel has 6/31 taken off each channel, saturating
  (`GLOW_FLOOR` in psx/render/gpu.odin and the GL shader). The footstep dust puff's
  gradient stops at 6/31 at its quad's edge, so at the port's scale it lifted
  a hard-edged grey box out of the leader's shadow; with the floor taken off
  the puff fades out to nothing. VRAM keeps the PS1's sum.
- `[window] bloom_effects` (Display page "Glow FX", default off) adds a
  glow around additive effects. A hi-res pixel last written by an additive
  (blend mode 1) see-through texel of a GTE-depth textured polygon carries
  bit 24 (`HI_GLOW`); any later blend or fade drops it. When the shown
  area is converted for the window, the glowing pixels are box-averaged
  down to PS1 resolution, blurred across then down with 9 binomial taps
  (1 8 28 56 70 56 28 8 1, sum 256, edge pixel repeated), stretched back
  bilinearly and added at gain 160/256, clamped to 255. The target keeps
  what was drawn; only the window picture glows. Software (`bloom.odin`,
  SIMD lanes per channel) and the shader (`BLOOM_CS`, three dispatches
  into `R32UI` images, then `CONV_CS`) use the same integer rounding, so
  both give the same pixels. Hi-res target (detail 2 or 4) only.
  Software keeps a flag per 16 x 16 VRAM tile, set wherever a glowing
  pixel is drawn or copied (`move_image`, door pictures) and cleared when
  the tile averages to nothing, so it averages only flagged tiles and a
  frame with no glow costs next to nothing.
- GLSL pitfall: `smooth`, `flat` and `noperspective` are reserved words.
  A variable named `smooth` fails the draw shader's compile, and the port
  then falls back to software drawing with only a log line to show it.
- The CPU still sets each triangle up (edges and attributes, as in
  software) and ships it in a storage buffer; the GPU draws each one as a
  box over its bounds.
- Queued primitives are sorted into draw levels. Each 8 x 8 VRAM cell
  records the highest level that drew there, read there, and touched the
  ghost layer there. A primitive goes one level above any earlier primitive
  it must follow: it reads pixels that one drew, it draws over pixels that
  one read, or both touch the ghost layer where order matters. Otherwise it
  goes at the level of the last primitive that drew there. Each level is
  one draw call in queue order, and levels are separated by texture and
  memory barriers. Solid pixels that only hide ghosts behind them may share
  a level, since any order gives the same result. Both halves of a PS1
  quad share a level. This halved the barriers compared with cutting the
  queue in order at each conflict (73k to 39k per 1000 presents).
- Batches are submitted every 512 primitives and flushed, so the GPU works
  while the CPU runs the game.
- Doorway pictures (`picture_take`, `picture_lay`) and `move_image` stay on
  the GPU. Only the displayed area is read back each present: a compute
  shader converts it to display colour into a mapped buffer, and the extra
  frames used for smooth motion are read back asynchronously, behind a
  fence, so the CPU does not wait for them. The CPU reads the mapped
  buffer in place (still-picture check, frame dumps).
  When SDL draws the window with OpenGL, the GL context shares objects with
  SDL's, and present fills the window texture from that buffer on the GPU
  (a pixel-unpack upload, fenced both ways between the two contexts)
  instead of copying 4.9 MB per present through the driver at detail 2.
  With any other SDL renderer the pixels are copied in with
  `SDL_UpdateTexture` as before.
  On the shared path the CPU no longer waits for the conversion at all:
  only a reader of the pixels (still-picture check while loading, frame
  dumps, snapshots) waits for it. The conversion shader also flags whether
  the picture has a pixel above black, for the black-screen check; that
  flag is waited for only when the last picture was black too, so a black
  stretch is fast-forwarded from its second present instead of its first.
- The VRAM target is drawn by four stream worker threads as draws are
  queued, instead of on the main thread at present time. Each worker owns
  interleaved 8-row bands of VRAM, so they never write the same pixel. When
  a draw samples a texture area that a queued draw writes (render to
  texture), the queue first waits for all workers to finish.

Measured on the baseline replay (the second 1000 presents, RX 7900 XTX):

| detail | software | GL |
|---|---|---|
| 2 | 104.6 presents/s | 339 presents/s |
| 4 | 59.1 presents/s | 237 presents/s |

With GL, the CPU waits for the GPU about 0.6 ms per present at detail 4;
there the GPU is close to the limit, mostly the waits between levels.
Finer cells (4 x 4) and larger batches gave no fewer levels.
The rest is the main thread (game code, triangle setup, checkpoint copies).
A frozen-time pass no longer copies the 2.9 MB depth cache both ways: it
logs each slot the pass first changes and puts those back at restore
(`Depth_Undo`, `psx/render/depth.odin`), which cut checkpoint save and
restore from about 7.7% to 2.7% of all samples. RAM is saved a 4 KB page
at a time, on the pass's first write to each page (`ram_guard` in
`psx/cpu/bus.odin`; every RAM writer, CPU stores, DMA and native code, goes
through it or `ram_touch`), so a pass copies about 70 of the 512 pages
instead of all 2 MB both ways. Build with `-define:RAM_KEEP_CHECK=true` to
have every restore prove that no write went around the guard. VRAM (1 MB)
is still copied whole: a pass changes 45-50 of its 64 8-row bands, so
tracking it would save nothing. A VRAM fill (`fill_rows`) sets each row as at most
two runs (split where it wraps at the right edge) instead of pixel by pixel.
Drawing each triangle as itself instead of its bounding box (half the
fragments) did not change GPU time, so fragment count is not the GPU cost.

`build.sh` builds with `-debug` for symbols but turns off vendor:OpenGL's
`GL_DEBUG`, which `-debug` would otherwise turn on: it calls `glGetError`
after every GL call, a round trip to the driver each time (about 1.6% at
detail 2). `BOF4_GL_DEBUG=true ./build.sh` keeps the checks.

Mesa runs GL calls on a thread of its own (`mesa_glthread`; turning it off
drops detail 2 from about 300 to 237 presents/s), but an upload from
program memory makes the main thread wait for that thread to catch up.
`gl_vram_sync` uploads changed VRAM cells (about 64 strips a present), so
it copies them into a persistently mapped pixel buffer, a ring of
`GL_STAGE_PARTS` parts, and uploads from there; a part is fenced when left
and waited on before it is written again. That took detail 2 from 303 to
318 presents/s.

Every fence (`glFenceSync`) costs as much again: under the GL thread it
runs on the main thread and flushes the driver's commands to the GPU, about
2.5% of the main thread each. Fences are therefore made lazily on one
timeline (`gl_point`, `gl_point_wait`): work that will need waiting for
takes a point, and the fence for it is made only when a wait or `gl_show`
needs one, so the fence `gl_show` makes for the window covers the
conversion and the staging ring too. The conversion's lit flag is cleared
from the CPU instead of by an upload, so `frame_black` trusts a flag that
is already set without waiting. Together about +3%. Left per present: the
`gl_show` fence, the switch to the SDL renderer's context and back, and its
fence after drawing (dropping that one gains under 1%, not worth the race).

`tween_record` (`qol/tween.odin`) puts a frame's primitives in address
order to pair them with the previous frame's. It sorts them with two
stable 13-bit counting passes on the address instead of `slice.sort_by`
(which was 4.6% of the main thread): 325 to 339 presents/s, same order.
Comparing VRAM pages with libc `memcmp` instead of Odin's slice compare
(`draw_start_load` then, `gl_vram_sync`) made no difference.

`build.sh` targets the build machine's own CPU (`-microarch:native`) by
default. `x86-64-v3` (AVX2) measured about 1% over baseline x86-64, and
native (AVX-512 on a 7700X) the same as v3. `BOF4_ARCH=x86-64-v3` or
`BOF4_ARCH=x86-64` builds a binary for other machines. Frames are identical.

`texels_read` (`psx/render/gpu.odin`), which finds the texels a triangle reads in
VRAM for the finer targets' clamp, works out four rows at once in f64
lanes (`core:simd`): edge weights, span clipping and the texel at each
row's two ends. Every value is a whole number below 2^53, so the lanes
match the integer code exactly; the perspective texels are worked out per
lane with the integer `persp_coord`, as the rows read them. A build running old and new on every
triangle (1M+, 88% perspective) found no difference. 4.4% to 3.0% of the
main thread, 2% fewer instructions per replay; frames identical.

The GTE's RTPT (`rtpt`, `psx/gte/gte.odin`) projects its three vertices side
by side in i64 lanes, with a fourth lane that repeats the third so flag
tests need no mask. Flags are ORs, so testing all lanes at once sets the
same bits as three single projections; MAC and IR end as the third vertex
leaves them. The sub-pixel divides run as one lane divide; the Newton
divides, the FIFO pushes and the depth tags stay in vertex order. A build
running old and new on every RTPT (3M+, every regression route) matched
the GTE registers and depth tag arguments exactly. GTE self time went from
4.3% to about 3.3% of the main thread, 0.6% fewer instructions; frames
identical. RTPS keeps the scalar `rtp`.

FLAG bits are set with whole-word stores (`flag_set`; `rtpt` gathers its
bits in a local and stores once). LLVM narrows `gte.flag |= 1 << k` to a
one-byte OR, and `gte_cmd` loads the whole word right after to compute
bit 31; a load cannot be forwarded from narrower stores, so it stalled
until they reached the cache. That load was 40-67% of `gte_cmd`'s self
time; `gte_cmd` went from 2.2% to 0.8% of the main thread. Frames identical.
The same applies to the vertex registers: `gte_write` stores VXY as one
32-bit word rather than two halves, and `rtpt` loads each 16-bit
component on its own instead of one 16-byte vector load across all of
them (that load was about half of `rtpt`'s time; `rtpt` went from 1.2% to
0.8%). The draw stream's head store is a full fence that waits for the
entry just written; prefetching the next entry for writing did not help,
and the fence is needed so a stream thread going idle is always woken.

The depth cache (`see_through.odin`) keeps each slot's fields together in
one 24-byte `Depth_Slot` rather than one array per field. The table (128K
slots, about 3 MB) lives in L3; a probe reads key and gen and a hit the
rest, so a lookup now touches one cache line instead of up to six. About
0.5% fewer cycles over the regression route, frames identical. Prefetching
all of a primitive's corner slots before probing, and setting `pick` as
each corner's count comes in, both measured slower and were dropped.

`draw_start_load` used to compare all 2 MB of RAM with the draw start's
copy on every pass (about 2.8% of the main thread, 5% of a pass). That
compare is bound by memory bandwidth: it reads 4 MB, and an AVX-512
compare measured no faster than the runtime's AVX2 one. RAM pages now
carry versions instead (`ram_ver`, `psx/cpu/bus.odin`). The first write to a
page after a version is taken (`ram_armed`, the same flag ram_guard
already tested for passes) gives the page a new number. Draw starts and
checkpoints save the numbers, and `draw_start_load` copies only the pages
whose numbers differ, with no compare. A draw start made in a preload
child gets fresh numbers when the parent adopts it
(`draw_start_adopt`), because the child counts on from the same numbers.
A `-define:RAM_KEEP_CHECK=true` build also checks every skipped page byte
for byte. A door pass's start load went from 61 to 24 µs.

The cost of an in-between pass on the q22 town replay, averaged over 300
passes:

| Part | Cost |
|---|---|
| Whole pass | 3.4 ms |
| Scene draw | 0.37 ms |
| `doors_between_draw` (the room passes) | 1.65 ms |
| Main `DrawOTagEnv` | 1.29 ms |
| Checkpoint save and restore | 0.12 ms |

So the ordering-table walks dominate it, not the game code. A native
rewrite of the in-between draw would save only about 0.5 ms.

In-between passes draw the hi-res target alone (`hi_only_begin`,
`psx/render/gpu.odin`). Their native VRAM drawing is thrown away at restore and
the picture is captured from the hi-res target, so polygons, rectangles,
lines and picture lays skip native VRAM. Fills and moves still go to
both. A pass that reads VRAM it left undrawn (a move or a download from a
cell drawn hi-only, or a hi-res textured draw from one) sets
`hi_only.missed`. The pass is then drawn again in full, with a `.Game`
trace ("pass read VRAM it did not draw"); the town replay has none. Room
passes nested in an in-between pass inherit this; room passes in real
frames draw both. Whole pass: 3.3 to 2.0 ms, frames identical.

The GL target keeps up to 9 GPU copies of VRAM (`gl_vram_use`,
`psx/render/gl_target.odin`), each with its own shadow. A door pass swaps in its
room's VRAM and names it (`vram_world`), and checkpoint restore names the
town's again. Before this, every door pass uploaded nearly every read cell
twice, once into the room's VRAM and once back. Uploads during passes
dropped from 348 M pixels to 2.5 M over the replay, and the average pass
by about 5%. Any copy is correct to draw with, because its shadow says
what to upload; the name only picks the copy likely to need the fewest
uploads.

Profiling the stream workers: their unwinds through `tri_rows` come out
wrong in `perf`, so they look like main-thread samples under passes. Count
on the main thread directly (a thread id check) before reading a pass
profile.

With `BOF4_TRACE=perf`, every 1000 presents also print how often and how
long the main thread waited for the stream workers, by cause
(`Sync_Cause`, `psx/render/raster.odin`). On the baseline replay at detail 2 the
waits come to about 0.27 s per 1000 presents, nearly all of it
`picture_flush` reading the walk's VRAM right after a walk ends; removing
waits does not speed things up, as the main thread then reaches the next
point where it needs the workers' results. The VRAM ghost flush is queued
to the workers as a job of its own instead of waiting for them.

The game moves a 2 x 1 area onto itself every frame; `move_image` returns
early for such moves, since a GL target would otherwise read the area back
from the GPU twice and wait for it.

Frames match software except for pixels one step off in depth (the
see-through fade still works depth out in floats), and doorway pictures sometimes appearing a present earlier or
later, because preloading timing differs.

On machines with more than one GPU, the headless (offscreen) driver may
pick the integrated GPU. `SDL_HINT_EGL_DEVICE=<n>` chooses the EGL device
(on the test machine 0 was the integrated GPU, 1 the discrete one).
The GL renderer prints its device to stderr at start-up.

## Smooth camera (third person)

The game's view is whole numbers: CAM_YAW in 4096ths of a turn, the
camera fields in whole units, and the GTE projects to whole pixels. With
in-between pictures and a camera that moves every frame, the rounding
makes the picture step unevenly. The port carries the parts past the
whole values and projects with them:

- `pose_blend` (qol/inbetween.odin) rounds the blended camera fields into
  RAM and keeps what it rounded off in `inbetween_frac`; the third-person
  yaw keeps its own fraction (`tp.yaw_frac`, valid only while CAM_YAW is
  still `tp.yaw_wrote`, so the game's own turns and door views get none).
- `exact_set` (qol/third_person.odin) builds the view the unrounded values
  give and hands the GTE the way from the game's view to it
  (`gte.exact_view`: a 3x3 matrix and a translation in view space).
- `rtp`/`rtpt` (psx/gte/gte.odin) still produce the game's whole pixels, and
  also the sixteenths of a pixel the exact view puts each vertex past them
  (signed, up to `EXACT_SLACK` pixels off). The depth cache keeps them
  (`Depth_Slot.sub`), and the hi-res raster adds them to the vertex.
  VRAM stays PS1-exact; only the hi-res picture moves by sub-pixels.
- Sprites are not projected by the GTE: SPRITE_DRAW (0x8014193c) builds
  each 0x2C quad's corners on the CPU from an anchor, the s16 screen x, y
  at sprite +4/+6 (projected earlier by the list routine), plus offsets
  scaled by the sprite's scale (+16/+20, >> 16). Snapped to whole pixels
  they swam against the geometry around them (Sarai's vendors). The
  third-person sprite hook projects the object's position itself
  (`view_full`) and asks `gte.anchor_sub` for the anchor's sixteenths past
  the whole pixel the game wrote (the exact view's when it is on), and
  files them with the sprite's packets (`see_flat_add`, `Flat.sub`); the
  GPU adds them to every corner of those packets.
- The exact view applies in the vblank it was built in and the next
  (`exact_on`). The game builds the view more than once a frame, and some
  of those builds come while the frame is still drawing (a town frame's
  drawing spans up to 3 vblanks).

The camera's own state (the blend toward this camera, the arm's spring,
zoom) steps once a game frame, at the first view build with a new
`GAME_FRAME` (0x80116b20). It used to step at every build: the builds
inside a frame's drawing each moved the arm by another vblank, so parts of
one frame were drawn from different pitches, while its in-between pictures
blended one pitch per frame. With the arm swinging up, every third present
jumped and the next two stalled.

The arm also used to clamp in at any build. The frame's first build comes
before the leader moves, the in-between pose notes the arm then, and a
later build of the same frame (leader moved nearer the wall) pulled the arm
in further; the real frame drew that pitch, its in-betweens blended toward
the noted one. Walking along a wall (Sarai's market awnings) the whole view
jumped on one picture in three: sky line, see-through ghosts, sprites. Now
the arm moves only at the step build, in as well as out. In no longer
snaps either: a wall swinging behind the leader (camera turning, a corner)
cut the arm by half in one frame, a 200-unit pitch pop. It eases in over
`ARM_IN_S` (0.1 s) and out over `ARM_OUT_S` (0.4 s); the lens passing
through the wall meanwhile is cut away by the see-through pass.

A face running up to the lens also popped between solid and ghost (a
Sarai stall awning, whole quads at once). Its near corners were nearer
than H / 2, where the GTE's divide overflows: the quotient stops at
0x1ffff, so those corners land at about twice their view x, y from the
screen offset whatever their depth. Unprojected as H / z, they bent the
face's plane every frame, and its cover (leader behind the plane or not)
flipped. `unproject` (psx/render/depth.odin) takes the quotient as capped
for see-through, door cuts and doorway openings, and the hardware
renderer's shader does the same.

Ghosts were tuned for a low arm, where what hides the leader stands near
the lens. At the game's height and angle the face hiding him is mostly the
block he stands behind, right at his end of the cone, where `SEE_GHOST`
reached 0.75 opacity: in Sarai's block maze he showed at about a quarter
strength, and the vent steam passing before him, ghosted at the same
strength, washed his sprite out. The leader's end is now 0.45 (the lens's
0.3), in `see_through.odin` and the shader's copy alike.

The ghosted cone is round about the leader's middle, `SEE_RADIUS` (160)
across at him, so it reached about a cell past his feet. Standing behind a
Sarai stall awning, its top crossing his boots, the awning was ghosted in a
disc well below him: the merchant under it showed through as a blob, and
his boots and shadow sat in a translucent patch, as if torn off his body.
The cone is now cut off below the line from the lens to his feet, softly
over `SEE_FLOOR` (8..40 view units past it, shrinking toward the lens as
the cone does): the awning is ghosted where it crosses him, solid past
him. "Below" is along world up's part across that line (`see.across`),
whose length is the sine of the camera's tilt from straight down, so the
cut fades out for a camera looking straight down on him, where his feet
lie behind his middle and "below" means nothing.

How far the arm reaches (`arm_reach`, at the step build): the leader's
layer of the collision grid is walked from the leader toward the lens,
`ARM_SAMPLES` (8) samples a cell, on a fan of three lines (the arm, and
`ARM_FAN` (0.75) cells either side at the lens), so a wall beside the lens
counts as well as one behind it. A doorway cell on the middle line keeps
the whole arm (it hangs over the neighbour's rooms). A wall cell stops the
arm only when its polygons (`cell_top`, the highest corner over the cell)
rise above the arm's height there: the grid calls a pond or a cart a wall
too, and the merchant's oasis (map 0814, pond right behind the leader)
pulled the lens down into the sprites. The grid marks walls only at their
foot, though: a roof or an awning over cells it calls floor
(a Sarai house's eave with the leader beside it) let the lens sink into the
slab, and the picture showed the slab's inside face from below. The same
walk now also runs over the section's polygons (`layer_tris` gathers the
triangles of each layer in the arm's box, placed as the passes place them;
`segment_hit` finds the nearest crossing), on five lines from the leader's
middle (`LEADER_MIDDLE` above the feet; map y is up): to the lens, and
`ARM_FAN` cells either side, above and below it. Each hit cuts the arm to
`ARM_MARGIN` (0.3 cells) short of it, never under `ARM_MIN` (0.5). While
the camera turns, the probe also looks `ARM_AHEAD_S` (0.25 s) of the turn
ahead (`ARM_AHEAD_SAMPLES` yaws) and keeps the shortest, so the arm starts
in before a wall swings behind the leader. Each probe gathers the polygons
once for both walks and bins their corner heights into a grid of cells
(`cell_tops`) in one pass: at the game's camera distance the arm crosses
some 30 cells, a town's models give some 4000 triangles in its box, and
scanning them all for every wall cell the grid walk met ran a town with
many models in view at under a third of its speed. A short arm first swings up
(`lift`); once the pitch reaches `BOOM_MAX` it can go no higher and the
arm stops there (`boom_top`); see-through fades what is still in the way.
The lens used to come in along the arm the rest of the way (`pull`), but
`view_at` keeps the leader's size on screen as the lens nears him, so a
lens coming in only widened the view: a dolly zoom, the town swelling and
shrinking round a leader who stayed the same size. Next to a wall the arm
flips between the full arm and the shortest as he walks, and each flip
read as Ryu bouncing in size.

The in-between pass's matrix filter (`qol/inbetween_matrix.odin`) used to
pop the whole picture by a PS1 pixel, down then back, now and then while
the arm moved. It blends a GTE matrix the pass writes unchanged from frame
N-1 toward frame N-2's, taking it for one the pose blend did not touch. A
camera matrix the pose blend did move (only the arm changed) could round
to frame N-1's value and be blended a second time, off the view the exact
projection was made for. `pose_blend` now says whether it moved the camera,
and then the filter blends nothing that pass.

Finding it: replay the session headless with window dumps
(`BOF4_DUMP_WINDOW=1`), list pictures that differ from both neighbours
while those agree; the 640x480 dumps change only on real frames, which
tells the real picture from the extras. Then trace the view build's lift
per build against the pass's (`inbetween_replaying`).

## Sky backdrop (third person)

Each frame starts with a GP0 02 fill of the 320x240 draw buffer to black
(ra 0x8016da94). The game's high camera never looks past the map's edge,
so the black never shows; the low third-person camera does, and sees a
void. `render.backdrop_hook` (`psx/render/gpu.odin` `fill_rect`) lets qol give a
black fill one colour per target row in the hi-res target only; VRAM stays
black, so anything reading it back is unchanged. The hardware renderer
clears one band per run of equal rows (`gl_fill`); door tags are cleared
as for any fill.

`qol/backdrop.odin` fills a sky gradient above the horizon and the map's
ground fading out of a haze below it, for maps in its `SKIES` table (Sarai
1000, canyon 0414); any other map, a room door pass (`interior_pass`), or
the game's own camera keeps the black. A row's colour goes with the
elevation of the ray through its centre at the screen's middle column:
`(0, y - ofy, H)` in view space, taken to world y by column 1 of the view
rotation (CAM_MATRIX 0x801381bc, s16 4.12):

    up = (M[1][1] * (y - ofy) + M[2][1] * H) / |ray|

World y points up in this sense (checked against frames: Sarai's camera
pitched about 33 degrees down, so its top row was ~5 degrees under the
horizon and showed only haze; the canyon's camera, then ~17 degrees down,
showed sky at the top; the third-person camera keeps the game's
pitch). The rotation in RAM at the fill is the frame's own, the real
frame's or an in-between pass's. Roll is ignored.

### Distance fog

A sky map also hazes what stands far off, so the edge where the game stops
drawing round the leader melts into the backdrop instead of popping.
`backdrop` sets `render.fog` each frame it fills a sky: `near`, `inv =
1 / (far - near)`, `most` (256ths) from the map's `Sky`, and the horizon
colour. The map's depths count from the leader's view depth in the view
last built (`third_person_leader_depth`), so zooming out moves the fog
with him instead of burying him in it. Each opaque textured or shaded pixel with a depth tag z > 0 mixes
toward it by

    w = trunc(clamp((z - near) * inv, 0, 1) * most)
    c = (c * (256 - w) + fog * w + 128) >> 8     (per channel)

in `plot` (software, `fog_mix`) and in the hi-res fragment shader (flag
F_FOG, uniforms `fog0`/`fog_c`) alike. Semi-transparent pixels are left
alone. Sarai fogs from 380 to 2680 past the leader; the canyon, whose
cliffs close in, from 1280. A room seen through a door (`interior_pass`) is not fogged. The fog
lapses on its own 8 vblanks after the last sky fill (`FOG_VBLANKS`), so
leaving a sky map, or the game's own camera, clears it. GL and software
match bar a stray 1-step rounding pixel or two.

## Follower fade-in (third person)

At map start each follower steps off the leader fading in
(FOLLOWER_FADE 0x801cdbdc): a count in the task (+0x4e) goes up each step,
c = count * 8, and while c is under half the ground light (byte 0x801381e9)
the follower's sprite is drawn additive (sprite flags +1 bit 2, the party
object's sprite at +0x54) with colour c, c, c (sprite +24). After that the
routine calls 0x80153554, sets obj+0x4a = light << 8, clears the additive
bit and sets the colour to the light. Over bright sand the additive sprite
glows white, then pops to opaque.

With see-through on, `fade_solid` (`qol/third_person.odin`) draws the sprite
solid in the leader's colour and files it (see_flat_add) with
`clear = 1 - c / half`: the see-through layer fades the pixels out by that
share as a ghost, so the follower fades in with true alpha. The sprite's
own flags and colour are put back after the draw. The sprite list's 52-byte
copy drawn next gets the same only when its flags and colour match the
object just drawn (the dust puff also goes through that path and keeps its
own blend).

## HD-2D effects (third person)

Three picture effects in the style of HD-2D, all off by default, on the
Look page of the options (`[window] depth_of_field`, `color_grade`,
`vignette`). They act only while the third-person field camera is up
(`see_through` set within 8 vblanks, leader in front of the lens) and only
on the hi-res target (detail 2 or 4). The target keeps what was drawn; the
effects go on as the shown area is converted for the window
(`psx/render/post.odin` `post_pixel`, GL `CONV_CS`), in this order: depth of
field, glow (`bloom_effects`), colour grade, vignette.

- **Depth per pixel.** Each hi-res pixel carries its view depth in the
  spare bits 25..30 (`HI_DEPTH`): `clamp(min(z, 0x10000) >> 6, 1, 63)`,
  so one step is 64 view units, 0 meaning none. Every opaque draw writes
  it (`plot`, DRAW_FS); semi-transparent pixels keep what was under them;
  fills, VRAM copies, uploads and the party's sprites (z <= 0) give 0.
  Ghost and fade passes keep the bits (`pixel_kept`, `HI_KEPT`).
- **Depth of field.** The focus is the depth step of the leader's middle
  (`see_through.target.z`). The area is averaged to PS1 resolution and
  blurred across then down with the glow's 9 taps (`dof_prepare`, GL
  `BLOOM_CS` with `every`), then stretched back bilinearly. A pixel mixes
  toward the blur by `clamp((|z - focus| - DOF_BAND) * 256 / DOF_RAMP, 0,
  256)` (band 2 steps, ramp 8): the leader and what is round him stay
  sharp, set pieces near the lens and the far town go soft. Pixels with
  no depth (sky fill, menus, text, party) stay sharp.
- **Colour grade.** `qol/grade.odin` builds a 3x3 mix plus offset in
  256ths from the map's look (saturation about luma, warmth as red up and
  blue down, contrast about 128) each time the field camera builds a view
  (`render.grade`, lapses after 8 vblanks). Default look 1.06 / 0 / 1.04;
  Sarai (0x1000) 1.05 / 0.01 / 1.05; canyon (0x0414) 1.05 / 0.01 / 1.06.
  Add a map to `LOOKS` to give it its own.
- **Vignette.** Darkens toward the corners: from 128/256 of the half
  diagonal squared, up to 80/256 darker at the corners.

Integer arithmetic throughout, the same in software and GL; checked in
Sarai: the two differ only where the raster already did (a few dozen
2x2 pixel blocks, the same with the effects off).

## Depth buffer (third person)

The game's ordering table was sorted for its own camera. From the
third-person camera that order is sometimes wrong: a floor polygon filed
after a person draws over his feet, an awning's back edge over the vendor
under it. With see-through up (`see_begin`, hi-res target only) each walk
of the table draws with a depth buffer (`psx/render/depth_buffer.odin`):

- **Who takes part.** Polygons whose three corners carry projected depths
  (GTE perspective polygons) and sprites see-through filed (`see_flat_add`
  with the sprite's feet `at`, `tp.copy_at` for the party). Menus, text,
  fills, VRAM copies and polygons with corners filled in stay in table
  order. VRAM keeps what the PS1 has.
- **Sprites.** A sprite stands upright at its feet, facing the lens across;
  its depth is that plane's, 1 / depth linear down the screen
  (`z_sprite_plane`, `Prim_Mode.z_plane`). Below the feet the plane would
  run on toward the lens, under the floor's own depth, so the floor cut off
  the sprite's bottom rows (the shadow's soft edge read as a hard line);
  `z_plane.z` holds 1 / the feet's depth and `z_on_plane` clamps to it, so
  rows under the feet stay at the feet's depth (GL: `P.w.z`).
- **Test and write.** Every pixel taking part is tested; only a solid
  pixel drawn in full writes (not see-through texels, ghosts or faded
  pixels), keeping the nearer depth. A pixel passes when no more than a
  bias behind the one there: `Z_BIAS` 2 steps for polygons, 48 for sprites
  (their feet run onto the ground in front), plus depth >> 7 for all but
  world quads, whose depths are exact (`Z_Exact`). Among those passing the
  later one wins, as in the table.
- **Decals.** Map art paints detail as quads lying in another's plane: an
  awning's scalloped valance over a stall's wall top in Sarai shares the
  top's plane and corners. The table orders the two by their farthest
  corners, which trade places as the camera moves, so the valance showed
  in some frames and was covered in others (with smooth motion off and on
  the CPU renderer too). `world_decals_mark` (world.odin) runs once per
  walk, at its first world-quad lookup: it sorts the walk's quads by view
  x and marks each one inside another's bounds, within 0.5 units of its
  plane and under 0.9 of its area. A decal's depth is taken `Z_LIFT` (4
  units, past `Z_BIAS`) nearer (`Prim_Mode.decal`, GL `Z_Decal`), so the
  surface under it never draws over it. Sarai: about 500 quads a walk, 10%
  of them decals, 0.25 ms a walk.
- **No clears.** A buffer word is the walk's key `(0xffff - walk) << 16`
  plus the depth in quarter view units, so an earlier walk's word is larger
  than any of this one's and counts as empty; keeping the nearer is one
  min. The buffer is cleared only when the walk count wraps (65535 walks).
- **GL.** `gpu_gl.zbuf` (R32UI image, binding 1). A level holding prims
  with depth is drawn twice: a prepass (`zpass` 1) that lays down depths
  with `atomicMin` and no colour, a `SHADER_IMAGE_ACCESS` barrier, then the
  normal draw testing against them. No fragment-shader interlock on the
  test machine (radeonsi), hence the prepass. It skips gouraud colours,
  the smooth split and affine u, v for perspective prims, and discards at
  once for prims that only test. Cost in Sarai: pull time 13.1 s per 1000
  presents against 10.6 s without (about 2.5 ms a frame on the iGPU).

- **Screen prims.** Packet addresses repeat: the prim pool alternates two
  buffers, so a see-through Flat filed for a sprite (kept up to
  `PORTAL_VBLANKS` frames) can cover the address a later, flat 2D prim is
  built at, and that prim then took the sprite's depth (or a `depth_fill`
  hit) and the z-test or see-through hid it. Dialogue portraits vanished in
  third-person this way (Wyndia's dog, every talk). `scene.screen_add(lo, hi)`
  files a packet range as screen drawing: `exec_polygon` gives prims in it
  no depth and skips the Flats. The third-person hook on `FACE_DRAW`
  (0x801516ec) files the portrait's packets. The list holds `MAX_SCREENS`
  runs and a full one drops its oldest: a portrait is filed every frame,
  each run good for `PORTAL_VBLANKS`, and its packets move on as its text
  grows, so the runs still good stop overlapping the new one. Refusing the
  new run when full left the portrait missing for a frame every few text
  characters.
- **Sprites taking the ground's depth.** `depth_fill` matches a corner to
  the vertices projected at its pixel, and a sprite's corner can land on a
  ground corner's pixel. One such corner gave the sprite a depth, so
  `exec_polygon` skipped its Flat (only prims with no depth looked one up)
  and drew it as scenery: the leader came out ghosted by see-through with
  his shadow gone, and an NPC's shadow behind a raised roof drew over the
  roof as a dark wedge (Sarai market, walking north beside the block). In
  that replay about 7% of sprite quads hit a projected corner; no packet
  inside a Flat ever had all its corners projected. A packet filed by
  `see_flat_add` now skips `depth_fill` and always takes its Flat.

Software and GL agree in Sarai except where the raster already differed (a
1-step colour difference on one 2x2 block at present 3200).

### Sprite seams (texels_cell)

A line through a person's legs turned out not to be depth: the camera
scales the sprite, so the seam between the upper and lower body pieces
lands between VRAM pixels and nearest rounding reads the texel one past the
upper piece's cell (transparent), and the ground shows. `texels_cell`
(`psx/render/gpu.odin`, after `texels_read` for affine textured triangles on the
hi-res target) narrows the read range for a triangle mapped straight onto
the screen (u along x only, v along y only, exact integer cross products):
the end where a coordinate runs out at the triangle's right or bottom edge,
never drawn by the PS1 at its own scale, drops one texel. GL clamps with
the same range (`READ_OK`).

## Native 3D world (third person)

While the third-person camera is in (`cpu.host_camera`) the field's
tiles and placed models are drawn from their view-space corners
instead of the packet's screen positions (`scene/world.odin`). The game still
builds, culls and orders every packet; only where the corners land changes.

- **Filing.** `quad_draw` (`qol/map_geometry.odin`) computes each quad's
  corners with the GTE's rotation and translation (`world_view`, through
  the exact view when on) and files them by packet address
  (`world_quad_add`), for the textured quad and its fog G4. A table
  (open addressing, generation per ordering-table walk, undone after
  frozen-time passes like the depth cache) holds them until `see_end`.
  A frozen-time pass (an in-between picture) files under a generation of
  its own (`world_undo_begin`): under the real frame's, which was filed
  since and walks later, a pass packet at one of its quads' addresses that
  is no world quad (a model's polygon) took that quad's corners, a brown
  slab over the party for the first frames in the bar of 1000.
  Backface and cull tests use the view-space corners
  (`world_may_show`: all four corners behind the near plane or past the
  same side of the screen).
- **Drawing.** `exec_polygon` finds the packet's quad, cuts it at
  `WORLD_NEAR` (2 view units) and projects each corner exactly in 16ths of
  a pixel, each at its own depth; the cut polygon draws as a fan
  (`Prim_Mode.world` lifts the 1024x512 size limit). The whole-polygon
  tests (see-through cover, door cuts, blacks) get up to four GTE-like
  corners, pairs made by the cut merged.
- **Why.** The PS1 GPU takes whole-pixel corners the GTE clamped to
  +-1024 and files corners behind the lens at depth 0. Walls and floors
  running past a close camera bent (warping) and tore. In Sarai with the
  camera zoomed in, walls that bulged with the classic path stand straight.
- **Game camera.** Under the game's own camera (third person off, or a
  scene that takes the view back) nothing is filed and frames match the
  classic path exactly (92/92 window dumps of the Sarai route, taken
  while this was still an option, off).
- **Checked.** Canyon 0414.2 into the s3 cave: where the classic path
  laid a pale smeared plane over the left of the picture, the cave wall
  stands. Town 1001 plaza: same picture as classic, no new holes (the
  black blocks for a few frames after a warp are models still loading,
  in both paths).
- **Known.** A camera pressed against an interior wall (0204 tavern
  doorway) now shows the void past the room's edge, which the classic
  path covered with the smeared behind-lens corner. The spring arm is
  already at its shortest (the boom at `BOOM_MAX`) there, so
  stopping it over cells with no floor changes nothing; it is the room
  seen from where the camera may stand, interiors having no backdrop
  (outdoors the sky fills the void). Clipped UVs round to whole texels;
  the ordering-table depth stays the game's.

## Frame pacing

Each emulated vblank is one present. On a 60, 120 or 240 Hz display the
presents wait for the display's vblank (vsync), and each picture stays up
for 1, 2 or 4 refreshes (`vsync_update`, `draw` in `psx/host/window.odin`). Any
other refresh rate (144 Hz, say) keeps vsync off and sleeps to the console's
59.94 Hz. Frames then stay up for an uneven 2 or 3 refreshes, which shows as
judder, so set such a display to 120 Hz, or use adaptive sync, for smooth
motion. `BOF4_TRACE=perf` logs the vsync choice and every vblank whose host
work took longer than a vblank (`late vblank`).
