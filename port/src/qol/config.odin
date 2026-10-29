// Quality-of-life features layered on the recompiled game: native
// replacements for game functions (cpu.hook_overlay) driven by a config file.
//
// Settings come from bof4.ini in the working directory, or the file named by
// BOF4_CONFIG. A missing file means defaults; a malformed value is an error.
// The camp menu's Setting > Extras page changes all but [keys] and [pad]
// bindings in game and writes them back here (options.odin).
//
//   [window]
//   fullscreen = false     ; desktop fullscreen; Alt+Enter or F11 toggles
//   scale = fit            ; fit, or integer (whole multiples of 640x480)
//   filter = nearest       ; nearest (sharp pixels) or linear (smoothed)
//   detail = 2             ; draw the scene at 1, 2 or 4 times the PS1's
//                          ; resolution
//   pause_unfocused = true ; pause while another window has focus
//   smooth_motion = false  ; draw an in-between picture for each repeated
//                          ; frame (30 fps logic shown at 60): field maps
//                          ; and battles redraw the scene, other screens
//                          ; blend prims
//   hardware = true        ; draw the hi-res picture on the graphics card
//                          ; (OpenGL 4.5); false = on the CPU. Read at start
//   smooth_effects = false ; semi-transparent effects mix their texels
//                          ; (bilinear) at detail 2 and 4
//   smooth_textures = false ; the world's textures and people mix their
//                          ; texels at detail 2 and 4, sharpened so texels
//                          ; stay square with soft edges
//   bloom_effects = false  ; additive (glowing) effects light up around
//                          ; them, at detail 2 and 4
//   depth_of_field = false ; third-person field: what stands far from the
//                          ; leader goes soft, at detail 2 and 4
//   color_grade = false    ; third-person field: each map's colour grade
//   vignette = false       ; third-person field: darkened corners
//
//   [audio]
//   latency_ms = 50        ; from a sound being mixed to the speakers, 20..250
//
//   [disc]
//   instant_loading = true ; run at full host speed while the disc loads
//                          ; behind a still picture
//   skip_black = true      ; run at full host speed while the screen is black
//
//   [field]
//   encounter_rate = 1.0   ; random battle frequency, 0 = none, 2 = double
//   minimap = true         ; round map in the top-left corner; Select
//                          ; toggles it on the field
//   instant_doors = true   ; a town door to a room seen before switches to
//                          ; it at once, with no load
//   dengeki = false        ; open the Dengeki store (cut from the US release),
//                          ; a forest south-west of Mt. Glom on the world map
//                          ; (text in English when dengeki/ holds the files
//                          ; `bof4tools dengeki-patch` builds from the fan patch)
//   restored_items = false ; shops also sell the equipment and items the US
//                          ; release never hands out (Ershin's cut armor, Pole,
//                          ; Slayer, three seeds, Wassail, Draught, Spanner)
//   teacher = true         ; a travelling dog in towns along the story
//                          ; teaches the magic combos, a level at a time
//
//   [text]
//   instant = false        ; show each page of a message at once
//   hold_to_advance = true ; holding confirm reveals and turns pages
//   subtitles = true       ; English lines under the opening movie's
//                          ; Japanese voices
//   descriptions = true    ; gear descriptions name the hidden effects the
//                          ; battle code gives (Render's growth, Dragon
//                          ; Blade vs. dragons, Divine Helm's immunity...)
//
//   [battle]
//   speed = 1.0            ; real-time speed of battles, 1 to MAX_SPEED
//   quick_turns = true     ; no wait between one action and the next
//   quick_idle = true      ; no wait while a round only idles (combatants
//                          ; at rest, a damage number settling)
//   quick_victory = true   ; short EXP and zenny counts, and the results
//                          ; go on by themselves after a moment
//   damage_numbers = true  ; damage and healing numbers over combatants
//   skip_seen = true       ; hurry through a skill's cinematic (a dragon
//                          ; transformation) after it has played once
//   sure_learn = true      ; seeing a learnable enemy skill always teaches
//                          ; it, no Guard needed (a guarding member learns
//                          ; first); with the skill slots full it goes to the
//                          ; skills reassigned at camp
//   guard_ap = true        ; a member who guards a round (half damage from
//                          ; attacks) regains a fifth of its max AP
//   examine = true         ; the first command input lists each enemy's
//                          ; learnable skills, green until learned
//   identify = true        ; Scias knows Identify (skill 239, cut from the
//                          ; US release: an enemy's HP, resistances and
//                          ; spoils) from level 3; kept in saves once given
//   exp_rate = 1.0         ; EXP from a won battle, 0 = none, 2 = double
//   zenny_rate = 1.0       ; zenny from a won battle, 0 = none, 2 = double
//   damage_dealt = 1.0     ; damage the party deals, 0.25..16
//   damage_taken = 1.0     ; damage the party takes, 0.25..16
//   enemy_ai = original    ; enemy smarts, 7 tiers each adding to the last:
//                          ; original, aware (no wasted heals, no immune
//                          ; targets), smart (mostly the weakest, heal hurt
//                          ; allies), clever (hit elemental weaknesses),
//                          ; tactical (focus fire, buff allies), cunning
//                          ; (debuff/status the party), ruthless (always the
//                          ; lowest HP, strongest skill), mastermind (more
//                          ; support, damage where it hurts most)
//   ai_by_strength = false ; each enemy's tier follows its max HP against
//                          ; the party's average: under half aware, then a
//                          ; tier per doubling, mastermind from 16 times;
//                          ; enemy_ai is the highest tier any enemy gets
//   ai_moods = false       ; each kind of enemy has a personality (brute,
//                          ; coward, devoted, pack, trickster, proud,
//                          ; machine, steady) and moods from the fight:
//                          ; desperate, enraged, cautious, cocky
//   status_rate = 1.0      ; chance of the party's status effects (and
//                          ; death) landing on enemies, 0..4; immune stays
//                          ; immune
//   ko_hp_loss = inn       ; a member KO'd at the end of a battle loses a
//                          ; tenth of max HP (up to 5 times) until an inn;
//                          ; camp: opening the camp menu gives it back too;
//                          ; off: no loss, and what was lost comes back
//   timed_attacks = false  ; a press as a plain attack lands: x1.5 perfect,
//                          ; x1.2 good (a square cues it once seen)
//   timed_parry = false    ; a press as an enemy's plain attack lands:
//                          ; no damage perfect, half good
//   seen = 0               ; the cinematics played so far (bit per file,
//                          ; kept by the port)
//   combos = 0             ; the magic combos performed so far (bit per
//                          ; combo, kept by the port; F2 Combos page)
//   combo_command = true   ; Combos line in Special's Magic list (or Select) lists the combos
//                          ; the party can cast this round (unseen ones as ???);
//                          ; picking one sets both members' spells and puts
//                          ; the second right behind the first
//   combo_mastery = true   ; each combo performed trains it: 5 levels (1, 3,
//                          ; 6, 10, 15 uses), +5 chain chance each, the
//                          ; fifth sure; a combo never performed chains for sure
//   combo_uses = 0,...     ; times each of the 16 combos was performed
//                          ; (kept by the port, up to 15)
//   balance = false        ; rebalanced mode: enemies x1.5 HP, spells and
//                          ; growth retuned, staves/robes/rings give Wisdom,
//                          ; less late zenny, no gold-enemy EXP farms
//
//   [minigame]
//   speed = 1.0            ; real-time speed of fishing, the Sandflier hunt
//                          ; and Kecak, 0.25 to 1 (0.5 = half speed)
//
//   [camera]
//   rotate_speed = 3.0     ; speed of the L1/R1 camera turn, 1 to MAX_SPEED
//   hold_to_spin = false   ; keep turning while L1/R1 stays held
//   stick = true           ; right stick turns the camera on free-angle maps
//   stick_speed = 120      ; degrees per second at full tilt
//   stick_all_maps = false ; also on maps limited to fixed angles (stick
//                          ; and mouse)
//   mouse = true           ; right-button drag turns the camera: freely where
//                          ; the stick may, else one L1/R1 turn per drag
//   mouse_speed = 0.3      ; degrees per window pixel of drag (0.01 to 4)
//   screen_shake = true    ; camera shake of attacks and events
//   third_person = true    ; camera following behind the leader while walking the
//                          ; field: free turning on every map, L1/R1 (the
//                          ; mouse wheel) zoom
//
//   [mouse]
//   menus = true           ; moving the pointer over a menu row moves the
//                          ; cursor there (qol/mouse_menus.odin)
//
//   [move]
//   stick = true           ; left stick walks toward its exact angle
//   run_tilt = 0.7         ; stick tilt (0..1) that runs; lighter walks
//   instant_start = true   ; walk on the first frame a direction is held
//
//   [save]
//   anywhere = true        ; the camp menu's Save works on every map
//   autosave = true        ; save on entering each field map, to the slot 2
//                          ; card (bof4_slot2.mcd, or BOF4_MCD2)
//   autosave_slot = 15     ; save number on that card used by autosave
//
//   [masters]
//   tracker = true         ; the camp menu's Masters command shows
//                          ; every master's pupil, counter, rewards and
//                          ; level-up bonus
//   alerts = true          ; notice when an apprentice's master has a new
//                          ; skill (or item) ready to teach
//
//   [keys]                 ; console button = keyboard keys (SDL names) and
//   cross = E, Mouse Left  ; mouse: Mouse Left/Middle/Right/X1/X2,
//                          ; Wheel Up/Down (a notch taps the button);
//                          ; an empty value leaves the button unbound
//
//   [pad]                  ; console button = controller buttons (SDL names)
//   cross = a
//
//   [controller]           ; the game's action buttons, set from Setting >
//   custom = off           ; Controls: off uses the game's Type; otherwise
//                          ; nine console buttons for Confirm, Cancel,
//                          ; Action, Menu, Dash, Turn R/L, Rank R/L
//
// The game's own Setting > Options cover what the port does not repeat:
// Dash (Auto runs unless the dash button is held), Camera (Reverse also
// reverses stick and mouse turning) and Vib (the pad is always a DualShock).
package qol

import "core:encoding/ini"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import host "ps:psx/host"
import render "ps:psx/render"

import "ps:core"

Config :: struct {
	window:                host.Window_Options,
	window_smooth_motion:  bool,
	window_hardware:       bool,
	window_smooth_effects: bool,
	window_smooth_textures: bool,
	window_bloom_effects:  bool,
	window_depth_of_field: bool,
	window_color_grade:    bool,
	window_vignette:       bool,
	audio_latency_ms:      int,
	disc_instant_loading:  bool,
	disc_skip_black:       bool,
	encounter_rate:        f64,
	field_minimap:         bool,
	field_instant_doors:   bool,
	field_dengeki:         bool,
	field_restored_items:  bool,
	field_teacher:         bool,
	text_instant:          bool,
	text_hold_to_advance:  bool,
	text_subtitles:        bool,
	text_descriptions:     bool,
	battle_speed:          f64,
	battle_quick_turns:    bool,
	battle_quick_idle:     bool,
	battle_quick_victory:  bool,
	battle_damage_numbers: bool,
	battle_skip_seen:      bool,
	battle_sure_learn:     bool,
	battle_guard_ap:       bool,
	battle_examine:        bool,
	battle_identify:       bool,
	battle_exp_rate:       f64,
	battle_damage_dealt:   f64,
	battle_damage_taken:   f64,
	battle_enemy_ai:       Enemy_AI,
	battle_ai_by_strength: bool,
	battle_ai_moods:       bool,
	battle_ko_hp_loss:     Ko_Hp_Loss,
	battle_timed_attacks:  bool,
	battle_timed_parry:    bool,
	battle_status_rate:    f64,
	battle_zenny_rate:     f64,
	battle_seen:           int,
	battle_combos:         int,
	battle_combo_command:  bool,
	battle_combo_mastery:  bool,
	battle_combo_uses:     [16]int,
	battle_balance:        bool,
	minigame_speed:        f64,
	camera_rotate_speed:   f64,
	camera_hold_to_spin:   bool,
	camera_stick:          bool,
	camera_stick_speed:    f64,
	camera_stick_all_maps: bool,
	camera_mouse:          bool,
	camera_mouse_speed:    f64,
	mouse_menus:           bool,
	camera_screen_shake:   bool,
	camera_third_person:   bool,
	move_stick:            bool,
	move_run_tilt:         f64,
	move_instant_start:    bool,
	save_anywhere:         bool,
	autosave:              bool,
	autosave_slot:         int,
	masters_tracker:       bool,
	masters_alerts:        bool,
}

config := Config {
	window                 = {pause_unfocused = true, detail = .X2},
	window_hardware        = true,
	audio_latency_ms       = 50,
	disc_instant_loading   = true,
	disc_skip_black        = true,
	encounter_rate         = 1,
	field_minimap          = true,
	field_instant_doors    = true,
	field_teacher          = true,
	text_hold_to_advance   = true,
	text_subtitles         = true,
	text_descriptions      = true,
	battle_speed           = 1,
	battle_quick_turns     = true,
	battle_quick_idle      = true,
	battle_quick_victory   = true,
	battle_damage_numbers  = true,
	battle_skip_seen       = true,
	battle_sure_learn      = true,
	battle_guard_ap        = true,
	battle_examine         = true,
	battle_identify        = true,
	battle_combo_command   = true,
	battle_combo_mastery   = true,
	battle_exp_rate        = 1,
	battle_damage_dealt    = 1,
	battle_damage_taken    = 1,
	battle_status_rate     = 1,
	battle_zenny_rate      = 1,
	minigame_speed         = 1,
	camera_rotate_speed    = 3,
	camera_stick           = true,
	camera_stick_speed     = 120,
	camera_mouse           = true,
	camera_mouse_speed     = 0.3,
	mouse_menus            = true,
	camera_screen_shake    = true,
	camera_third_person    = true,
	move_stick             = true,
	move_run_tilt          = 0.7,
	move_instant_start     = true,
	save_anywhere          = true,
	autosave               = true,
	autosave_slot          = MAX_SAVE_SLOT,
	masters_tracker        = true,
	masters_alerts         = true,
}

@(private)
DEFAULT_CONFIG_PATH :: "bof4.ini"

// Upper bound for rates: beyond this the game's counters saturate anyway.
@(private)
MAX_RATE :: 16
// Damage cannot be cut further: below this a battle may not end.
@(private)
MIN_DAMAGE_RATE :: 0.25
// Past 4 every status chance short of immune reaches 100%.
@(private)
MAX_STATUS_RATE :: 4

// Upper bound for speed-ups: past this the host cannot keep up anyway.
@(private)
MAX_SPEED :: 8

// Save numbers per memory card, as the game's save screen shows them.
@(private)
MAX_SAVE_SLOT :: 15

// Fastest right-stick camera turn, degrees per second.
@(private)
MAX_STICK_SPEED :: 720

// Fastest mouse-drag camera turn, degrees per window pixel.
@(private)
MAX_MOUSE_SPEED :: 4

// Load the config file: before host.platform_init, which reads the renderer
// choice.
boot :: proc() -> bool {
	if !load_config() {
		return false
	}
	config_boot = config
	render.hardware_renderer = config.window_hardware
	return true
}

// Install every feature hook (after boot and host.platform_init).
init :: proc() -> bool {
	masters_init()
	host.vblank_hook = vblank
	host.instant_loading = config.disc_instant_loading
	render.smooth_effects = config.window_smooth_effects
	render.smooth_textures = config.window_smooth_textures
	render.bloom_effects = config.window_bloom_effects
	render.depth_of_field = config.window_depth_of_field
	render.vignette = config.window_vignette
	host.skip_black = config.disc_skip_black
	core.audio_apply(config.audio_latency_ms)
	bios.pad_set_rumble(1)
	host.mouse_drag = config.camera_mouse
	return host.window_apply(config.window) && encounter_init() && text_init() && camera_init() && movement_init() && save_init() && tracker_init() && popup_init() && learning_init() && combo_menu_init() && guard_init() && rewards_init() && damage_init() && ai_init() && ko_loss_init() && status_init() && victory_init() && quick_battle_init() && shake_init() && warp_init() && menu_draw_init() && button_text_init() && identify_init() && balance_init() && camp_menu_init() && setting_menu_init() && map_geometry_init() && collision_init() && sections_init() && fade_init() && inbetween_init() && interiors_init() && map_mods_init() && map_editor_init() && mouse_menus_init() && dengeki_init() && restored_init() && teacher_init() && descriptions_init() && npc_swap_init() && cinematics_init() && autoplay_init()
}

// Follow the game's state once per emulated vblank.
@(private = "file")
vblank :: proc() {
	speed_follow_mode()
	controls_vblank()
	button_icons_vblank()
	tracker_vblank()
	dengeki_vblank()
	restored_vblank()
	village_vblank()
	minimap_vblank()
	map_editor_vblank()
	cinematics_vblank()
	subtitles_vblank()
	combos_vblank()
	combo_menu_vblank()
	balance_vblank()
	autoplay_vblank()
	interiors_vblank()
	pressed := panel_vblank()
	journal_select(pressed)
	combos_select(pressed)
	if masters_active() {
		masters_vblank(pressed)
	}
}

@(private)
load_config :: proc() -> bool {
	path, named := config_path()
	if !named && !os.exists(path) {
		return true
	}
	m, err, ok := ini.load_map_from_path(path, context.temp_allocator)
	if err != nil || !ok {
		fmt.eprintln("config: cannot read", path, err)
		return false
	}
	// A setting this version does not know (one removed since, or a typo) or
	// cannot parse is skipped with a warning and keeps its default, so a
	// file from an older version still starts the game.
	for section, pairs in m {
		for key, value in pairs {
			if !apply_setting(section, key, value) {
				fmt.eprintf("config: %s: ignoring bad setting [%s] %s = %s\n", path, section, key, value)
			}
		}
	}
	return true
}

@(private)
apply_setting :: proc(section, key, value: string) -> bool {
	switch {
	case section == "keys" || section == "pad":
		return parse_binding(section, key, value)
	case section == "controller" && key == "custom":
		return parse_controller_custom(value)
	case section == "window" && key == "smooth_motion":
		return parse_bool(value, &config.window_smooth_motion)
	case section == "window" && key == "hardware":
		return parse_bool(value, &config.window_hardware)
	case section == "window" && key == "smooth_effects":
		return parse_bool(value, &config.window_smooth_effects)
	case section == "window" && key == "smooth_textures":
		return parse_bool(value, &config.window_smooth_textures)
	case section == "window" && key == "bloom_effects":
		return parse_bool(value, &config.window_bloom_effects)
	case section == "window" && key == "depth_of_field":
		return parse_bool(value, &config.window_depth_of_field)
	case section == "window" && key == "color_grade":
		return parse_bool(value, &config.window_color_grade)
	case section == "window" && key == "vignette":
		return parse_bool(value, &config.window_vignette)
	case section == "window":
		return apply_window_setting(key, value)
	case section == "audio" && key == "latency_ms":
		return parse_int(value, core.AUDIO_LATENCY_MIN, core.AUDIO_LATENCY_MAX, &config.audio_latency_ms)
	case section == "disc" && key == "instant_loading":
		return parse_bool(value, &config.disc_instant_loading)
	case section == "disc" && key == "skip_black":
		return parse_bool(value, &config.disc_skip_black)
	case section == "field" && key == "encounter_rate":
		return parse_range(value, 0, MAX_RATE, &config.encounter_rate)
	case section == "field" && key == "minimap":
		return parse_bool(value, &config.field_minimap)
	case section == "field" && key == "instant_doors":
		return parse_bool(value, &config.field_instant_doors)
	case section == "field" && key == "dengeki":
		return parse_bool(value, &config.field_dengeki)
	case section == "field" && key == "restored_items":
		return parse_bool(value, &config.field_restored_items)
	case section == "field" && key == "teacher":
		return parse_bool(value, &config.field_teacher)
	case section == "battle" && key == "speed":
		return parse_speed(value, &config.battle_speed)
	case section == "battle" && key == "quick_turns":
		return parse_bool(value, &config.battle_quick_turns)
	case section == "battle" && key == "quick_idle":
		return parse_bool(value, &config.battle_quick_idle)
	case section == "battle" && key == "quick_victory":
		return parse_bool(value, &config.battle_quick_victory)
	case section == "battle" && key == "damage_numbers":
		return parse_bool(value, &config.battle_damage_numbers)
	case section == "battle" && key == "skip_seen":
		return parse_bool(value, &config.battle_skip_seen)
	case section == "battle" && key == "sure_learn":
		return parse_bool(value, &config.battle_sure_learn)
	case section == "battle" && key == "guard_ap":
		return parse_bool(value, &config.battle_guard_ap)
	case section == "battle" && key == "examine":
		return parse_bool(value, &config.battle_examine)
	case section == "battle" && key == "identify":
		return parse_bool(value, &config.battle_identify)
	case section == "battle" && key == "damage_dealt":
		return parse_range(value, MIN_DAMAGE_RATE, MAX_RATE, &config.battle_damage_dealt)
	case section == "battle" && key == "damage_taken":
		return parse_range(value, MIN_DAMAGE_RATE, MAX_RATE, &config.battle_damage_taken)
	case section == "battle" && key == "enemy_ai":
		for name, tier in ENEMY_AI_KEYS {
			if value == name {
				config.battle_enemy_ai = tier
				return true
			}
		}
		return false
	case section == "battle" && key == "ai_by_strength":
		return parse_bool(value, &config.battle_ai_by_strength)
	case section == "battle" && key == "ai_moods":
		return parse_bool(value, &config.battle_ai_moods)
	case section == "battle" && key == "status_rate":
		return parse_range(value, 0, MAX_STATUS_RATE, &config.battle_status_rate)
	case section == "battle" && key == "timed_attacks":
		return parse_bool(value, &config.battle_timed_attacks)
	case section == "battle" && key == "timed_parry":
		return parse_bool(value, &config.battle_timed_parry)
	case section == "battle" && key == "ko_hp_loss":
		for name, mode in KO_HP_LOSS_KEYS {
			if value == name {
				config.battle_ko_hp_loss = mode
				return true
			}
		}
		return false
	case section == "battle" && key == "exp_rate":
		return parse_range(value, 0, MAX_RATE, &config.battle_exp_rate)
	case section == "battle" && key == "zenny_rate":
		return parse_range(value, 0, MAX_RATE, &config.battle_zenny_rate)
	case section == "battle" && key == "seen":
		return parse_int(value, 0, CINEMATICS_ALL, &config.battle_seen)
	case section == "battle" && key == "combos":
		return parse_int(value, 0, COMBOS_ALL, &config.battle_combos)
	case section == "battle" && key == "combo_command":
		return parse_bool(value, &config.battle_combo_command)
	case section == "battle" && key == "combo_mastery":
		return parse_bool(value, &config.battle_combo_mastery)
	case section == "battle" && key == "balance":
		return parse_bool(value, &config.battle_balance)
	case section == "battle" && key == "combo_uses":
		return parse_combo_uses(value, &config.battle_combo_uses)
	case section == "minigame" && key == "speed":
		return parse_range(value, core.AUDIO_MIN_SPEED, 1, &config.minigame_speed)
	case section == "text" && key == "instant":
		return parse_bool(value, &config.text_instant)
	case section == "text" && key == "hold_to_advance":
		return parse_bool(value, &config.text_hold_to_advance)
	case section == "text" && key == "subtitles":
		return parse_bool(value, &config.text_subtitles)
	case section == "text" && key == "descriptions":
		return parse_bool(value, &config.text_descriptions)
	case section == "camera" && key == "rotate_speed":
		return parse_speed(value, &config.camera_rotate_speed)
	case section == "camera" && key == "hold_to_spin":
		return parse_bool(value, &config.camera_hold_to_spin)
	case section == "camera" && key == "stick":
		return parse_bool(value, &config.camera_stick)
	case section == "camera" && key == "stick_speed":
		return parse_range(value, 1, MAX_STICK_SPEED, &config.camera_stick_speed)
	case section == "mouse" && key == "menus":
		return parse_bool(value, &config.mouse_menus)
	case section == "camera" && key == "mouse":
		return parse_bool(value, &config.camera_mouse)
	case section == "camera" && key == "mouse_speed":
		return parse_range(value, 0.01, MAX_MOUSE_SPEED, &config.camera_mouse_speed)
	case section == "camera" && key == "stick_all_maps":
		return parse_bool(value, &config.camera_stick_all_maps)
	case section == "camera" && key == "screen_shake":
		return parse_bool(value, &config.camera_screen_shake)
	case section == "camera" && key == "third_person":
		return parse_bool(value, &config.camera_third_person)
	case section == "move" && key == "stick":
		return parse_bool(value, &config.move_stick)
	case section == "move" && key == "run_tilt":
		return parse_range(value, 0, 1, &config.move_run_tilt)
	case section == "move" && key == "instant_start":
		return parse_bool(value, &config.move_instant_start)
	case section == "move" && key == "free":
		// Free walk is always on now; older files may still set it.
		return true
	case section == "save" && key == "anywhere":
		return parse_bool(value, &config.save_anywhere)
	case section == "save" && key == "autosave":
		return parse_bool(value, &config.autosave)
	case section == "save" && key == "autosave_slot":
		return parse_int(value, 1, MAX_SAVE_SLOT, &config.autosave_slot)
	case section == "masters" && key == "tracker":
		return parse_bool(value, &config.masters_tracker)
	case section == "masters" && key == "alerts":
		return parse_bool(value, &config.masters_alerts)
	}
	return false
}

@(private)
apply_window_setting :: proc(key, value: string) -> bool {
	w := &config.window
	switch key {
	case "fullscreen":
		return parse_bool(value, &w.fullscreen)
	case "pause_unfocused":
		return parse_bool(value, &w.pause_unfocused)
	case "scale":
		switch value {
		case "fit":
			w.scale = .Fit
		case "integer":
			w.scale = .Integer
		case:
			return false
		}
		return true
	case "detail":
		switch value {
		case "1":
			w.detail = .X1
		case "2":
			w.detail = .X2
		case "4":
			w.detail = .X4
		case:
			return false
		}
		return true
	case "filter":
		switch value {
		case "nearest":
			w.filter = .Nearest
		case "linear":
			w.filter = .Linear
		case:
			return false
		}
		return true
	}
	return false
}

// A comma-separated list of keyboard keys or controller buttons for one
// console button; it replaces that button's default sources (an empty list
// leaves it unbound).
@(private)
parse_binding :: proc(section, key, value: string) -> bool {
	bit := host.pad_bit_from_name(key) or_return
	names := make([dynamic]string, context.temp_allocator)
	for n in strings.split(value, ",", context.temp_allocator) {
		if t := strings.trim_space(n); t != "" {
			append(&names, t)
		}
	}
	if section == "keys" {
		return host.bind_keys(bit, names[:])
	}
	return host.bind_buttons(bit, names[:])
}

@(private)
parse_bool :: proc(value: string, out: ^bool) -> bool {
	switch value {
	case "true":
		out^ = true
	case "false":
		out^ = false
	case:
		return false
	}
	return true
}

@(private)
parse_speed :: proc(value: string, out: ^f64) -> bool {
	return parse_range(value, 1, MAX_SPEED, out)
}

@(private)
parse_int :: proc(value: string, lo, hi: int, out: ^int) -> bool {
	v, ok := strconv.parse_int(value, 10)
	if !ok || v < lo || v > hi {
		return false
	}
	out^ = v
	return true
}

@(private)
parse_range :: proc(value: string, lo, hi: f64, out: ^f64) -> bool {
	v, ok := strconv.parse_f64(value)
	if !ok || v < lo || v > hi {
		return false
	}
	out^ = v
	return true
}
