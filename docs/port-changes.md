# What the port changes

Everything the native port adds to or changes from the original USA
PlayStation release. Settings live in `port/bof4.ini` (full list with
defaults in `port/src/qol/config.odin`); nearly all of them can also be
changed in game from the camp menu's Setting > Extras page. Features marked
*(not a game feature)* add something the original never had; the rest speed
up, fix or open up what it already does.

## The port itself

- The game's executable and its 24 overlays are statically recompiled from
  MIPS to Odin (`port/src/rec`), with a fallback interpreter for code the
  recompiler did not cover. No emulator core and no BIOS image: the PS1's
  CPU, GTE, GPU, SPU (with its reverb), CD-ROM, MDEC movies, XA audio, pads
  and memory cards are reimplemented (`port/src/psx`).
- Game routines are hooked or rewritten natively where that is faster or
  needed for a feature; game timing and save data stay compatible.
- Memory cards are files: `bof4_slot1.mcd` and `bof4_slot2.mcd`.

## Display and graphics

- Window: fullscreen toggle (Alt+Enter / F11), fit or integer scaling,
  nearest or linear filter, pause when unfocused (and Pause/P/guide button).
- Hi-res drawing: the scene at 1, 2 or 4 times the PS1 resolution, drawn on
  the GPU (OpenGL 4.5, default) or the CPU, in true colour with no dither.
- Smooth motion: an in-between picture for every repeated frame, so the
  30 fps game shows at 60/120/240 Hz (field and battle redraw the scene with
  blended matrices; other screens blend their prims).
- Optional smoothing of effects and textures at detail 2/4 (texels stay
  square with soft edges).
- HD-2D style extras on the third-person field *(not game features)*:
  bloom around additive effects, depth of field, per-map colour grade,
  vignette, distance fog.
- Sky backdrop: outdoor maps fill the void past the map edge (seen from the
  low camera) with a sky/haze gradient per map.
- Depth buffer under the third-person camera, so floors no longer cut
  through people drawn in the game's painter order.
- See-through: only the pixels hiding the leader fade, by real depth.
- Longer, eased screen fades.
- Screen shake can be turned off.

## Field

- **Third-person camera** *(not a game feature)*: low and close behind the
  leader while walking, free turning on every map, L1/R1 (mouse wheel)
  zoom. Spring arm and exact sub-pixel view for jitter-free motion. The
  arm comes in before roofs and awnings over the leader, walls beside the
  lens, and walls a turn is about to swing behind the leader.
- Camera: faster L1/R1 turns (default 3x), hold to keep spinning, right
  stick and right-mouse drag turning on free-angle maps (optionally all
  maps), Reverse in the game's options also reverses them.
- Movement: the left stick walks at its exact angle (run past a set tilt),
  walking starts on the first frame, and the leader moves freely at any
  angle instead of cell to cell.
- **Native field engine**: collision/ground heights, floors and map drawing
  rewritten natively, same results as the game's code. Edited maps can be
  loaded from `BOF4_MAPS=<dir>` (`bof4tools map-block` unpacks/packs map
  blocks), including added Z levels. F4 on the field opens an in-game map
  editor (cells, heights, textures, exits) that saves `<map>.edit` patches.
- **Seamless sections**: neighbouring sections of a map are drawn around the
  loaded one, so rooms and corridors join without a cut.
- **Instant doors**: a town door to a room seen before (or loaded in the
  background by a forked copy of the game) opens at once, with no load;
  doorways show the room behind instead of a dark opening.
- Random encounter rate 0-16x (0 = none).
- Minimap *(not a game feature)*: round map of the walkable ground in the
  top-left corner, turned with the camera, N for north; Select toggles it.
  It replaces the game's compass.
- **Quest tracker** *(not a game feature)*: the field's Menu button pops up
  the current objective; also a Journal row in the camp menu.
- Start opens the camp menu (the PAUSE screen is gone).
- **Combo dog** *(not a game feature)*: a travelling dog in towns along the
  story teaches the magic combos a level at a time: Sarai (the town's own
  dog), then Synesta, Wyndia and Shyde, where he is added with a portrait
  of his own. In four world map "?" scenes he teaches the four character
  specials (Phoenix, Mudslide, Ice Sword, Reflect) and their recipes. The
  Journal says where he was last seen and which scene to try.
- Dialogue portraits no longer vanish in third-person (a stale sprite depth
  at a reused packet address hid them).
- **Dengeki store** (off by default): the store cut from the US release
  reopened in a forest south-west of Mt. Glom, in English when the files from
  `bof4tools dengeki-patch` are present.

## Text and menus

- Messages: instant pages, or hold confirm to reveal and turn pages.
- Opening movie subtitles (`[text] subtitles`, on by default): its Japanese
  voice lines, left untranslated in the US release, show in English at the
  bottom of the picture.
- Gear descriptions (`[text] descriptions`, on by default; Extras "Gear
  text"): 22 weapons, armor and accessories whose hidden effects the US text
  leaves out say what they do (Render's growth, the Rigs' resists, Topaz
  Tear's Holy absorb, Dragon Blade's x1.5 vs. dragons and so on), written
  from the battle code. See docs/battle.md "Item descriptions".
- Save anywhere from the camp menu; autosave on entering each field map to
  the slot 2 card (save 15 by default), so card 1 saves are never
  overwritten.
- Setting screen: a fifth command, Extras, with every port option; the
  Buttons screen redrawn as a controls screen.
- Masters panel *(not a game feature)*: F2 or the camp menu's Masters command
  lists every master with portrait, pupil, counter, each reward and what it
  needs (green when ready) and the level-up bonus; a notice when a reward is
  ready.
- Button prompts in text, help lines and world map legends follow the device
  in use (pad or keyboard/mouse).
- Full keyboard, mouse and controller rebinding (`[keys]`, `[pad]`, and the
  game's action buttons in `[controller]`), rebindable in game.

## Battle

- Speed 1-8x real time; quick turns (no pause between actions), quick idle
  (no dead time while a damage number settles), quick victory (short counts,
  pages go on by themselves).
- Damage and healing numbers over combatants *(not a game feature)*.
- Skip a skill's cinematic (dragon transformations) after it has played once.
- **Enemy-skill learning**: seeing a learnable skill always teaches it, no
  Guard needed; overflow goes to the skills reassigned at camp. The first
  command input lists each enemy's learnable skills (green once learned).
- Guard pays: a member who guards a round regains a fifth of max AP.
- **Identify** (skill 239, cut from the US release) restored: Scias learns it
  at level 3 and it shows an enemy's HP, resistances and spoils.
- **Combos** *(not game features)*: a Combos page in the F2 panel (names
  hidden until performed), a Combos line in the Special > Magic list (or
  Select) that sets both members' spells at once, and combo mastery
  (5 levels by uses, +5 chain chance each, the fifth sure; a combo never
  performed always chains).
- Tuning: EXP and zenny rates, damage dealt and taken (0.25-16x), status
  effect chance on enemies (0-4x, immune stays immune).
- **Enemy AI** in 7 tiers above the original (aware, smart, clever,
  tactical, cunning, ruthless, mastermind); enemies never cast a skill
  they lack the AP for, and with "By strength" each enemy's tier follows
  its max HP against the party's (bosses think hardest). With "Moods" each
  kind of enemy has a personality (coward, pack, brute...) and turns
  desperate, enraged, cautious or cocky as the fight goes.
- Timed attacks and parries (off by default) *(not game features)*: a press
  as a plain attack lands gives x1.5/x1.2 damage, or no/half damage taken.
- **Rebalanced mode** (off by default): enemies with 1.5x HP (2x from 10000), attack
  spells stronger but dearer, debuffs and heals cost more, staves, robes and
  rings give Wisdom, more HP per level, less EXP from GoldGang/Gold Fly and
  less zenny late, hits on enemies capped at 9999 (no Kaiser one-shots), and
  a chained combo costs the second member extra AP.
- KO max-HP loss: a member KO'd at the end of a battle loses a tenth of
  max HP (up to 5 times) until an inn (or camp, or off).

## Minigames

- Slow motion for fishing, the Sandflier hunt and Kecak (down to 0.25x),
  with sound kept on the beat.
- Audio latency setting (20-250 ms) for rhythm timing.

## Disc

- Instant loading: the game runs at full speed while the disc reads behind a
  still picture.
- Skip black: full speed while the screen is all black.
- Movies and streamed audio keep their normal pace.

## Debug and modding aids *(not game features)*

- `BOF4_DEBUG_DIR` input recording and F12 snapshots (picture, RAM, VRAM);
  `BOF4_CAPTURE` real-time video capture.
- `BOF4_WARP` to load any save on another map; `BOF4_NPC_SPRITE` to list and
  swap NPC sprites; `BOF4_AUTO` / `BOF4_CHEAT` test autopilot.
- Root `docs/` (battle, field, graphics, text, disc files, overlays, an
  address map built from the port's named constants) and `tools/` for
  modders.
