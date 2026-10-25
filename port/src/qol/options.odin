// The config's options as the camp menu's Setting screen shows them: one row
// per option, grouped into pages, each changed in place and written back to
// the config file. The Extras command lists the pages up to EXTRAS_LAST and the Screen
// command opens Display (setting_menu.odin); the Options page's rows sit
// among the game's own in its Options screen (options_screen.odin).
//
// Changes apply at once: features read `config` as they run, and options the
// host owns (window, audio, loading, the mouse) are handed over on change.
// Two take effect only on the next start: smooth_motion, whose draw hooks
// are installed at boot, and hardware, the renderer made with the window.
//
// The config file is edited line by line: a `key = value` line under its
// section gets the new value and every other line (comments) stays; a key
// not in the file is added at the end of its section, a missing section at
// the end of the file. The file is written to a temporary name and renamed
// over the old one.
package qol

import "core:fmt"
import "core:math"
import "core:os"
import "core:strings"

import host "ps:psx/host"
import render "ps:psx/render"

import "ps:core"

@(private)
Options_Page :: enum u8 {
	// The Extras pages.
	Field,
	Battle,
	Balance,
	Enemies,
	Pace,
	System,
	Look,
	// The Setting screen's Screen command.
	Display,
	// Rows of the game's own Options screen (options_screen.odin).
	Options,
}

// Extras lists the pages up to this one.
@(private)
EXTRAS_LAST :: Options_Page.Look
@(private)
EXTRAS_COUNT :: int(EXTRAS_LAST) + 1

@(private)
OPTIONS_PAGE_NAMES := [Options_Page]string {
	.Field   = "Field",
	.Battle  = "Battle",
	.Balance = "Balance",
	.Enemies = "Enemies",
	.Pace    = "Pace",
	.System  = "System",
	.Look    = "Look",
	.Display = "Display",
	.Options = "Options",
}

@(private)
Option_Value :: union {
	^bool,
	^f64,
	^int,
	^host.Scale_Mode,
	^host.Filter,
	^host.Detail,
	^Enemy_AI,
	^Ko_Hp_Loss,
}

@(private)
Option :: struct {
	page:         Options_Page,
	section, key: string,
	label, help:  string,
	value:        Option_Value,
	// Numbers: range and step; format shows the value (times 100 when
	// percent).
	lo, hi, step: f64,
	format:       string,
	percent:      bool,
	// Hands the new value to the host; nil when features read it live.
	apply:        proc(),
	// Whether the value now set waits for a restart; nil: never.
	restart:      proc() -> bool,
}

// Most options on one page.
@(private)
OPTIONS_PAGE_MAX :: 10

// Options in all; checked against the table as it is built.
@(private)
OPTION_COUNT :: 69

@(private)
options: [OPTION_COUNT]Option

// Fill the option table (it points into `config`, so it is built at run time).
@(private)
options_init :: proc() {
	table := [?]Option {
		{page = .Field, section = "field", key = "encounter_rate", label = "Encounters", help = "Random battles: 0 none, x2 double", value = &config.encounter_rate, lo = 0, hi = MAX_RATE, step = 0.25, format = "x%.2f"},
		{page = .Field, section = "field", key = "minimap", label = "Minimap", help = "Corner map; Select toggles it", value = &config.field_minimap},
		{page = .Field, section = "field", key = "instant_doors", label = "Quick doors", help = "Rooms seen before open with no load", value = &config.field_instant_doors},
		{page = .Field, section = "field", key = "dengeki", label = "Dengeki", help = "Cut store south-west of Mt. Glom", value = &config.field_dengeki},
		{page = .Field, section = "field", key = "restored_items", label = "Cut goods", help = "Shops sell items the US release never gives", value = &config.field_restored_items},
		{page = .Field, section = "field", key = "teacher", label = "Combo dog", help = "A dog in towns teaches magic combos", value = &config.field_teacher},
		{page = .Field, section = "battle", key = "combo_mastery", label = "Combo training", help = "Combos performed chain more often, then always", value = &config.battle_combo_mastery},
		{page = .Field, section = "move", key = "instant_start", label = "Quick start", help = "Walk on the first frame held", value = &config.move_instant_start},
		{page = .Battle, section = "battle", key = "speed", label = "Speed", help = "Real-time speed of battles", value = &config.battle_speed, lo = 1, hi = MAX_SPEED, step = 0.5, format = "x%.1f"},
		{page = .Battle, section = "battle", key = "quick_turns", label = "Quick turns", help = "No wait between actions", value = &config.battle_quick_turns},
		{page = .Battle, section = "battle", key = "quick_idle", label = "Quick idle", help = "No wait while a round only idles", value = &config.battle_quick_idle},
		{page = .Battle, section = "battle", key = "quick_victory", label = "Quick victory", help = "Short counts; results go on by themselves", value = &config.battle_quick_victory},
		{page = .Battle, section = "battle", key = "damage_numbers", label = "Numbers", help = "Damage and healing numbers", value = &config.battle_damage_numbers},
		{page = .Battle, section = "battle", key = "sure_learn", label = "Sure learn", help = "Seeing an enemy skill learns it, no Guard", value = &config.battle_sure_learn},
		{page = .Battle, section = "battle", key = "guard_ap", label = "Guard AP", help = "Guarding a round regains a fifth of max AP", value = &config.battle_guard_ap},
		{page = .Battle, section = "battle", key = "examine", label = "Examine", help = "List enemy skills to learn at battle start", value = &config.battle_examine},
		{page = .Battle, section = "battle", key = "identify", label = "Identify", help = "Scias knows Identify (enemy data) from level 3", value = &config.battle_identify},
		{page = .Battle, section = "battle", key = "combo_command", label = "Combo menu", help = "Combos in Special's Magic list (or Select) set up a combo", value = &config.battle_combo_command},
		{page = .Balance, section = "battle", key = "exp_rate", label = "EXP", help = "EXP from battles: 0 none, x2 double", value = &config.battle_exp_rate, lo = 0, hi = MAX_RATE, step = 0.25, format = "x%.2f"},
		{page = .Balance, section = "battle", key = "zenny_rate", label = "Zenny", help = "Zenny from battles: 0 none, x2 double", value = &config.battle_zenny_rate, lo = 0, hi = MAX_RATE, step = 0.25, format = "x%.2f"},
		{page = .Balance, section = "battle", key = "damage_dealt", label = "Dmg dealt", help = "Damage the party deals", value = &config.battle_damage_dealt, lo = MIN_DAMAGE_RATE, hi = MAX_RATE, step = 0.25, format = "x%.2f"},
		{page = .Balance, section = "battle", key = "damage_taken", label = "Dmg taken", help = "Damage the party takes", value = &config.battle_damage_taken, lo = MIN_DAMAGE_RATE, hi = MAX_RATE, step = 0.25, format = "x%.2f"},
		{page = .Balance, section = "battle", key = "status_rate", label = "Debuffs", help = "Chance party status effects land on enemies", value = &config.battle_status_rate, lo = 0, hi = MAX_STATUS_RATE, step = 0.25, format = "x%.2f"},
		{page = .Balance, section = "battle", key = "ko_hp_loss", label = "KO HP loss", help = "KO costs max HP until an inn, or a camp", value = &config.battle_ko_hp_loss},
		{page = .Balance, section = "battle", key = "timed_attacks", label = "Timed attacks", help = "Press as an attack lands for bonus damage", value = &config.battle_timed_attacks},
		{page = .Balance, section = "battle", key = "timed_parry", label = "Parry", help = "Press as an enemy attack lands to block it", value = &config.battle_timed_parry},
		{page = .Balance, section = "battle", key = "balance", label = "Rebalance", help = "Tougher enemies, magic pays, less late cash", value = &config.battle_balance},
		{page = .Enemies, section = "battle", key = "enemy_ai", label = "Enemy AI", help = "Enemy smarts: targets, heals, elements, buffs", value = &config.battle_enemy_ai},
		{page = .Enemies, section = "battle", key = "ai_by_strength", label = "By strength", help = "Tougher enemies think harder, up to Enemy AI", value = &config.battle_ai_by_strength},
		{page = .Enemies, section = "battle", key = "ai_moods", label = "Moods", help = "Enemy personalities react to how the fight goes", value = &config.battle_ai_moods},
		{page = .Pace, section = "disc", key = "instant_loading", label = "Fast loads", help = "Skip loads behind a still screen", value = &config.disc_instant_loading, apply = apply_disc},
		{page = .Pace, section = "disc", key = "skip_black", label = "Skip black", help = "Full speed while the screen is black", value = &config.disc_skip_black, apply = apply_disc},
		{page = .Pace, section = "minigame", key = "speed", label = "Minigames", help = "Fishing, Sandflier hunt and Kecak", value = &config.minigame_speed, lo = core.AUDIO_MIN_SPEED, hi = 1, step = 0.25, format = "x%.2f"},
		{page = .Pace, section = "battle", key = "skip_seen", label = "Skip seen", help = "Hurry through skill cinematics seen once", value = &config.battle_skip_seen},
		{page = .System, section = "save", key = "anywhere", label = "Save anywhere", help = "The camp menu's Save works everywhere", value = &config.save_anywhere},
		{page = .System, section = "save", key = "autosave", label = "Autosave", help = "Save on each new map, to card 2", value = &config.autosave},
		{page = .System, section = "save", key = "autosave_slot", label = "Auto slot", help = "Save number autosave uses on card 2", value = &config.autosave_slot, lo = 1, hi = MAX_SAVE_SLOT, step = 1, format = "%.0f"},
		{page = .System, section = "masters", key = "tracker", label = "Masters", help = "Masters command in the camp menu", value = &config.masters_tracker, apply = apply_masters},
		{page = .System, section = "masters", key = "alerts", label = "Master alerts", help = "Notice when a master can teach", value = &config.masters_alerts},
		{page = .Look, section = "window", key = "depth_of_field", label = "Focus", help = "Soften what stands far from the leader", value = &config.window_depth_of_field, apply = apply_effects},
		{page = .Look, section = "window", key = "color_grade", label = "Grade", help = "Colour each town as its light", value = &config.window_color_grade, apply = apply_effects},
		{page = .Look, section = "window", key = "vignette", label = "Vignette", help = "Darken the corners of the field", value = &config.window_vignette, apply = apply_effects},
		{page = .Look, section = "text", key = "subtitles", label = "Subtitles", help = "English lines in the opening movie", value = &config.text_subtitles},
		{page = .Look, section = "text", key = "descriptions", label = "Gear text", help = "Gear descriptions show hidden effects", value = &config.text_descriptions},
		{page = .Display, section = "window", key = "fullscreen", label = "Fullscreen", help = "Fill the screen (F11 also toggles)", value = &config.window.fullscreen, apply = apply_window},
		{page = .Display, section = "window", key = "scale", label = "Scale", help = "Fit, or whole multiples of 640x480", value = &config.window.scale, apply = apply_window},
		{page = .Display, section = "window", key = "detail", label = "Detail", help = "Draw the scene at 1, 2 or 4x resolution", value = &config.window.detail, apply = apply_window},
		{page = .Display, section = "window", key = "filter", label = "Filter", help = "Sharp pixels, or smoothed", value = &config.window.filter, apply = apply_window},
		{page = .Display, section = "window", key = "pause_unfocused", label = "Auto pause", help = "Pause while another window is active", value = &config.window.pause_unfocused, apply = apply_window},
		{page = .Display, section = "window", key = "smooth_motion", label = "60 fps", help = "Draw in-between frames: 60 fps motion", value = &config.window_smooth_motion, restart = restart_smooth_motion},
		{page = .Display, section = "window", key = "hardware", label = "GPU draw", help = "Draw on the graphics card: smoother", value = &config.window_hardware, restart = restart_hardware},
		{page = .Display, section = "window", key = "smooth_effects", label = "Soft FX", help = "Soften see-through effect textures", value = &config.window_smooth_effects, apply = apply_effects},
		{page = .Display, section = "window", key = "smooth_textures", label = "Soft texels", help = "Smooth texel edges of the world and people", value = &config.window_smooth_textures, apply = apply_effects},
		{page = .Display, section = "window", key = "bloom_effects", label = "Glow FX", help = "Light around glowing effects", value = &config.window_bloom_effects, apply = apply_effects},
		{page = .Options, section = "audio", key = "latency_ms", label = "Latency", help = "Lower answers sooner; raise if crackly", value = &config.audio_latency_ms, lo = core.AUDIO_LATENCY_MIN, hi = core.AUDIO_LATENCY_MAX, step = 10, format = "%.0f ms", apply = apply_audio},
		{page = .Options, section = "text", key = "instant", label = "Instant", help = "Show each page of a message at once", value = &config.text_instant},
		{page = .Options, section = "text", key = "hold_to_advance", label = "Hold msg", help = "Holding confirm turns the pages", value = &config.text_hold_to_advance},
		{page = .Options, section = "move", key = "stick", label = "Analog", help = "Left stick walks at its exact angle", value = &config.move_stick},
		{page = .Options, section = "move", key = "run_tilt", label = "Run tilt", help = "Stick tilt that runs; lighter walks", value = &config.move_run_tilt, lo = 0, hi = 1, step = 0.05, format = "%.0f%%", percent = true},
		{page = .Options, section = "camera", key = "rotate_speed", label = "Turn", help = "Speed of the L1/R1 camera turn", value = &config.camera_rotate_speed, lo = 1, hi = MAX_SPEED, step = 0.5, format = "x%.1f"},
		{page = .Options, section = "camera", key = "hold_to_spin", label = "Spin", help = "Keep turning while L1/R1 is held", value = &config.camera_hold_to_spin},
		{page = .Options, section = "camera", key = "stick", label = "R-stick", help = "Right stick turns the camera", value = &config.camera_stick},
		{page = .Options, section = "camera", key = "stick_speed", label = "R speed", help = "Degrees per second at full tilt", value = &config.camera_stick_speed, lo = 1, hi = MAX_STICK_SPEED, step = 10, format = "%.0f/s"},
		{page = .Options, section = "camera", key = "stick_all_maps", label = "All maps", help = "Free turning on fixed-angle maps too", value = &config.camera_stick_all_maps},
		{page = .Options, section = "camera", key = "mouse", label = "Mouse", help = "Right-button drag turns the camera", value = &config.camera_mouse, apply = apply_mouse},
		{page = .Options, section = "camera", key = "mouse_speed", label = "M speed", help = "Degrees per pixel of drag", value = &config.camera_mouse_speed, lo = 0.01, hi = MAX_MOUSE_SPEED, step = 0.05, format = "%.2f"},
		{page = .Options, section = "mouse", key = "menus", label = "M menus", help = "Pointer picks menu rows", value = &config.mouse_menus},
		{page = .Options, section = "camera", key = "screen_shake", label = "Shake", help = "Camera shake of attacks and events", value = &config.camera_screen_shake},
		{page = .Options, section = "camera", key = "third_person", label = "3rd cam", help = "Camera follows behind the leader on the field", value = &config.camera_third_person},
	}
	#assert(len(table) == OPTION_COUNT)
	options = table
}


// The config as it was at start, for options that wait for a restart.
@(private)
config_boot: Config

// Rows of options on a page: the first index and the count.
@(private)
options_on :: proc(page: Options_Page) -> (first, count: int) {
	first = -1
	for o, i in options {
		if o.page == page {
			if first < 0 {
				first = i
			}
			assert(i == first + count, "options page split")
			count += 1
		}
	}
	// The Options page is the game's scrolling Options screen, not a list.
	assert(first >= 0, "options page empty")
	assert(page == .Options || count <= OPTIONS_PAGE_MAX, "options page too long")
	return first, count
}

@(private = "file")
DETAIL_TEXT := [host.Detail]string {
	.X1 = "x1",
	.X2 = "x2",
	.X4 = "x4",
}

// The value as the menu shows it.
@(private)
option_text :: proc(o: Option) -> string {
	switch v in o.value {
	case ^bool:
		return v^ ? "On" : "Off"
	case ^host.Scale_Mode:
		return v^ == .Fit ? "Fit" : "Integer"
	case ^host.Filter:
		return v^ == .Nearest ? "Sharp" : "Smooth"
	case ^host.Detail:
		return DETAIL_TEXT[v^]
	case ^Enemy_AI:
		return ENEMY_AI_TEXT[v^]
	case ^Ko_Hp_Loss:
		return KO_HP_LOSS_TEXT[v^]
	case ^f64:
		if o.percent && v^ == 0 {
			return "Off"
		}
		return fmt.tprintf(o.format, o.percent ? v^ * 100 : v^)
	case ^int:
		return fmt.tprintf(o.format, f64(v^))
	}
	return ""
}

// The value as the config file holds it.
@(private)
option_ini_text :: proc(o: Option) -> string {
	switch v in o.value {
	case ^bool:
		return v^ ? "true" : "false"
	case ^host.Scale_Mode:
		return v^ == .Fit ? "fit" : "integer"
	case ^host.Filter:
		return v^ == .Nearest ? "nearest" : "linear"
	case ^host.Detail:
		return DETAIL_TEXT[v^][1:]
	case ^Enemy_AI:
		return ENEMY_AI_KEYS[v^]
	case ^Ko_Hp_Loss:
		return KO_HP_LOSS_KEYS[v^]
	case ^f64:
		text := fmt.tprintf("%.4f", v^)
		text = strings.trim_right(text, "0")
		return strings.trim_right(text, ".")
	case ^int:
		return fmt.tprintf("%d", v^)
	}
	return ""
}

// Step the value by `dir` (+1 or -1); a toggle flips either way. Returns
// false, changing nothing, at the end of the range.
@(private)
option_step :: proc(o: Option, dir: int) -> bool {
	assert(dir == 1 || dir == -1)
	switch v in o.value {
	case ^bool:
		v^ = !v^
	case ^host.Scale_Mode:
		v^ = v^ == .Fit ? .Integer : .Fit
	case ^host.Filter:
		v^ = v^ == .Nearest ? .Linear : .Nearest
	case ^host.Detail:
		next := int(v^) + dir
		if next < 0 || next > int(max(host.Detail)) {
			return false
		}
		v^ = host.Detail(next)
	case ^Enemy_AI:
		next := int(v^) + dir
		if next < 0 || next > int(max(Enemy_AI)) {
			return false
		}
		v^ = Enemy_AI(next)
	case ^Ko_Hp_Loss:
		next := int(v^) + dir
		if next < 0 || next > int(max(Ko_Hp_Loss)) {
			return false
		}
		v^ = Ko_Hp_Loss(next)
	case ^f64:
		next := clamp(math.round(v^ / o.step + f64(dir)) * o.step, o.lo, o.hi)
		if abs(next - v^) < o.step / 1000 {
			return false
		}
		v^ = next
	case ^int:
		next := int(clamp(math.round(f64(v^) / o.step + f64(dir)) * o.step, o.lo, o.hi))
		if next == v^ {
			return false
		}
		v^ = next
	}
	if o.apply != nil {
		o.apply()
	}
	return true
}

// Whether the option toggles (confirm flips it) rather than counts.
@(private)
option_toggles :: proc(o: Option) -> bool {
	#partial switch _ in o.value {
	case ^f64, ^int, ^host.Detail, ^Enemy_AI, ^Ko_Hp_Loss:
		return false
	}
	return true
}

@(private = "file")
apply_window :: proc() {
	if !host.window_apply(config.window) {
		host.osd_toast("Display change failed")
	}
}

@(private = "file")
apply_audio :: proc() {
	core.audio_apply(config.audio_latency_ms)
}

@(private = "file")
apply_disc :: proc() {
	host.instant_loading = config.disc_instant_loading
	host.skip_black = config.disc_skip_black
}

@(private = "file")
apply_effects :: proc() {
	render.smooth_effects = config.window_smooth_effects
	render.smooth_textures = config.window_smooth_textures
	render.bloom_effects = config.window_bloom_effects
	render.depth_of_field = config.window_depth_of_field
	render.vignette = config.window_vignette
}

@(private = "file")
apply_mouse :: proc() {
	host.mouse_drag = config.camera_mouse
}

@(private = "file")
apply_masters :: proc() {
	masters_init()
	if host.osd_panel_page >= host.osd_panel_pages {
		host.osd_hide_panel()
		host.osd_panel_page = PANEL_JOURNAL
	}
}

@(private = "file")
restart_smooth_motion :: proc() -> bool {
	return config.window_smooth_motion != config_boot.window_smooth_motion
}

@(private = "file")
restart_hardware :: proc() -> bool {
	return config.window_hardware != config_boot.window_hardware
}

// The config file: BOF4_CONFIG, or bof4.ini in the working directory.
@(private)
config_path :: proc() -> (path: string, named: bool) {
	path = os.get_env("BOF4_CONFIG", context.temp_allocator)
	if path != "" {
		return path, true
	}
	return DEFAULT_CONFIG_PATH, false
}

// Longest config file the writer takes, in lines.
@(private = "file")
INI_MAX_LINES :: 4096

// Write the changed options into the config file. Returns false, with the
// error printed and the file untouched, when it cannot be read or written.
@(private)
options_save :: proc(changed: []bool) -> bool {
	assert(len(changed) == len(options))
	entries := make([dynamic]Config_Entry, context.temp_allocator)
	for o, i in options {
		if changed[i] {
			append(&entries, Config_Entry{o.section, o.key, option_ini_text(o)})
		}
	}
	return config_write(entries[:])
}

@(private)
Config_Entry :: struct {
	section, key, value: string,
}

// Set each entry's `key = value` in the config file, keeping its other lines.
// Returns false, with the error printed and the file untouched, when it
// cannot be read or written.
@(private)
config_write :: proc(entries: []Config_Entry) -> bool {
	path, _ := config_path()
	old := ""
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			fmt.eprintln("config: cannot read", path, err)
			return false
		}
		old = string(data)
	}
	lines := make([dynamic]string, context.temp_allocator)
	for line in strings.split_lines(old, context.temp_allocator) {
		append(&lines, line)
	}
	if len(lines) > INI_MAX_LINES {
		fmt.eprintln("config: too long to edit:", path)
		return false
	}
	// split_lines leaves an empty last line for the final newline.
	if len(lines) > 0 && lines[len(lines) - 1] == "" {
		pop(&lines)
	}
	for e in entries {
		ini_set(&lines, e.section, e.key, e.value)
	}
	text := strings.join(lines[:], "\n", context.temp_allocator)
	return ini_replace(path, strings.concatenate({text, "\n"}, context.temp_allocator))
}

// Set `key = value` under [section], editing the line in place when there is
// one.
@(private = "file")
ini_set :: proc(lines: ^[dynamic]string, section, key, value: string) {
	entry := fmt.tprintf("%s = %s", key, value)
	current := ""
	section_end := -1 // index after the section's last key line
	for line, i in lines {
		t := strings.trim_space(line)
		if strings.has_prefix(t, "[") {
			current = strings.trim_space(strings.trim_suffix(strings.trim_prefix(t, "["), "]"))
			continue
		}
		if current != section || t == "" || t[0] == ';' || t[0] == '#' {
			continue
		}
		section_end = i + 1
		eq := strings.index_byte(t, '=')
		if eq < 0 || strings.trim_space(t[:eq]) != key {
			continue
		}
		lines[i] = entry
		return
	}
	if section_end < 0 {
		// Section missing, or present with no keys: add the key after the
		// header, or a new section at the end.
		for line, i in lines {
			t := strings.trim_space(line)
			if strings.has_prefix(t, "[") && strings.trim_space(t[1:len(t) - 1]) == section {
				inject_at(lines, i + 1, entry)
				return
			}
		}
		if len(lines) > 0 && strings.trim_space(lines[len(lines) - 1]) != "" {
			append(lines, "")
		}
		append(lines, fmt.tprintf("[%s]", section), entry)
		return
	}
	inject_at(lines, section_end, entry)
}

// Replace the file's contents through a temporary file and a rename, so a
// failure leaves the old file whole.
@(private = "file")
ini_replace :: proc(path, text: string) -> bool {
	temp := fmt.tprintf("%s.tmp", path)
	if err := os.write_entire_file(temp, transmute([]u8)text); err != nil {
		fmt.eprintln("config: cannot write", temp, err)
		return false
	}
	if err := os.rename(temp, path); err != nil {
		fmt.eprintln("config: cannot replace", path, err)
		return false
	}
	return true
}
