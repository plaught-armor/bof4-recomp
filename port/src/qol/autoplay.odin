// Test autopilot (not a game feature): plays through the game unattended to
// find bugs.
//
// BOF4_CHEAT=1 keeps the party's records at full HP with Pwr, Def and Agl at
// CHEAT_STAT, so a battle is won by confirming the default attack.
// BOF4_CHEAT=hp leaves the stats alone and zeroes every hit on the party
// (damage.odin) and every status or death aimed at it (status.odin), so the
// party never falls but a fight lasts as long as usual (to watch every enemy
// act).
//
// BOF4_AUTO=<file> runs a script of one command per line ('#' starts a
// comment). Throughout, confirm is pulsed in battles, events and while a
// field text box holds the leader, so dialogue and battles go by on their
// own. A choice is answered with its first option the first time it shows
// during a stretch without control, the next option the next time, and so on,
// so a menu that comes back (a help menu) is left eventually. With
// BOF4_REPLAY, the script (and the confirm pulses) start only after the
// replay's last entry. Commands:
//
//   wait N            N vblanks
//   press BUTTON [N]  hold a button (host.PAD_NAMES) for N vblanks (default 4)
//   stick DEG N       push the left stick toward world angle DEG (0 = -z,
//                     clockwise) for N vblanks
//   goto X Z          walk the leader to tile X, Z along the collision grid
//                     (or onto an exit tile, until the map or section changes)
//   until map M       wait until map M (hex, as BOF4_WARP) is loaded
//   until field       wait until the player has had control on the field for
//                     SETTLE vblanks
//   until world       the same on the world map (moved with press: a
//                     direction goes to the next place that way, cross
//                     enters it)
//   log TEXT          print TEXT
//   poke A V          write byte V to RAM address A (hex), to set up a test
//   point X Y         move the mouse pointer to display pixel X, Y
//   grid              print the leader's collision grid ('#' wall, 'E' exit,
//                     '/' stairs, '@' the leader), to plan routes, then
//                     the raw attributes of the cells around the leader
//   snap              take a snapshot (BOF4_DEBUG_DIR)
//   edit              start or leave the map editor, as F4 (map_editor.odin)
//   boss N            the next battle loads BWORLD/BOSS<N>.EMI (1..32) in
//                     place of its area's enemies (BATTLE_AREA, BATTLE_BOSS),
//                     to test a boss fight from any encounter (then `fight`)
//   fight [start]     walk to and fro with the encounter budget at one step
//                     until a battle starts; done once control is back after
//                     it (with start, as soon as the battle starts)
//   pulse on|off|qte|manual  whether confirm is pulsed in battles and events
//                     (on at first); off, a battle's commands are left to
//                     press; qte, pulsed but not during an action, where
//                     confirm is pressed a game frame before each learned
//                     hit (timed.odin); manual, nothing is pressed for the
//                     script: choices stay open and menus a talk opens are
//                     not backed out of
//   tour [N]          go through every exit the leader can reach on this map
//                     section and back, logging where each leads (a door
//                     back to the world map is left by confirming there),
//                     with a snapshot (BOF4_DEBUG_DIR) on each arrival; with
//                     N > 1, tour each place reached too, N levels deep,
//                     each place once
//   talk              walk up to every NPC on this map section in turn,
//                     nearest first, and talk to it (confirm until control
//                     comes back), logging each; with none left on the
//                     leader's layer, climb a stair to another layer that
//                     has some
//   doors [near]      walk up to every door to a room on this map section
//                     in turn and face it until the room's slide settles
//                     (interiors.odin), logging each slide: the stitch
//                     table's survey; with `near`, only the door nearest
//                     the leader (a town whose levels the walk cannot climb
//                     between is surveyed a warp per door)
//   clock N           run the CPU at N times the PS1's clock from here
//                     (io.clock_mul; testing only)
//   quit              exit
//
// Every command but quit gives up after its timeout (`timeout N` sets it for
// the rest of the script, default STEP_TIMEOUT vblanks); then the run is
// stuck: a snapshot is taken (with BOF4_DEBUG_DIR) and the port exits with
// status 3. The end of the script exits with status 0.
package qol

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"

import cpu "ps:psx/cpu"
import host "ps:psx/host"
import io "ps:psx/io"

import "ps:core"

@(private = "file")
CHAR_HP :: 20 // u16
@(private = "file")
CHAR_PWR :: 66 // u16 each: Pwr, Def, Agl after equipment
@(private = "file")
CHEAT_STAT :: 999
// Where a battle keeps its copies of the party's records.
@(private = "file")
FIGHTERS_FROM :: 0x801c0000
@(private = "file")
FIGHTERS_TO :: 0x801e0000

@(private = "file")
MODE_FIELD :: 2
@(private = "file")
MODE_EVENT :: 4
@(private = "file")
MODE_MENU :: 7 // a shop's screens
@(private = "file")
MODE_BATTLE :: 5
// The battle to load (BATTLE_LOAD, 0x801e73dc in a field overlay, reads both): the BWORLD area (file
// AREAB000 + area), or with BATTLE_BOSS set the boss (file BOSS001 - 1 +
// area). BATTLE_BOSS is the boss's id, 1..32 as its file: the battle
// overlay calls the boss's setup from the table at 0x801c65cc by it, which
// gives the boss combatants their script tables (+0x140).
@(private = "file")
BATTLE_AREA :: 0x8011dee9
@(private = "file")
BATTLE_BOSS :: 0x8011deeb
// The file loader (a0 = file index). Each field map's overlay carries its
// own copy of BATTLE_LOAD, which hands it the area's file.
@(private = "file")
FILE_LOAD :: 0x8013b6f4
@(private = "file")
AREAB_FILE :: 0x14b // AREAB000.EMI
@(private = "file")
AREAB_LAST :: 0x1cd // AREAB130.EMI; BOSS001.EMI follows
@(private = "file")
BOSS_FILES :: 32
@(private = "file")
BOX_STATE_CHOICE :: 2 // u8 box +0: a choice is open
@(private = "file")
BOX_STEP :: 1 // u8, 0 while a choice box waits for the first press
@(private = "file")
BOX_CURSOR :: 0x2b // u8, the option a choice's cursor is on
@(private = "file")
CHOICE_TEXT_MAX :: 512 // bytes of a choice's string scanned for options
@(private = "file")
BOX_TEXT :: 12 // u32, the box's string
@(private = "file")
CONFIRM_MASK :: 0x80116d84 // u16, the game's confirm buttons, then cancel
@(private = "file")
FLD_MAIN_ID :: 0x0f
@(private = "file")
OBJ_STATE :: 0x4 // u8
@(private = "file")
STATE_CONTROL :: 1
@(private = "file")
STATE_IDLE :: 8
@(private = "file")
STATE_WORLD :: 17 // on the world map
@(private = "file")
OBJ_POS :: 0xc
@(private = "file")
POS_LAYER :: 0xc // u8

@(private = "file")
STEP_TIMEOUT :: 60 * 60
// Vblanks of control in a row `until field` waits for.
@(private = "file")
SETTLE :: 30
// Confirm is held PULSE_ON of every PULSE vblanks.
@(private = "file")
PULSE :: 8
@(private = "file")
PULSE_ON :: 3
@(private = "file")
TRACE_EVERY :: 4
// Vblanks spent walking each way while pacing for a battle.
@(private = "file")
FIGHT_PACE :: 20
// The longest grid side the walk's search handles (tiles are u8).
@(private = "file")
GRID_MAX :: 256

@(private = "file")
Op :: enum u8 {
	Wait,
	Press,
	Stick,
	Goto,
	Until_Map,
	Until_Field,
	Until_World,
	Log,
	Poke,
	Point,
	Grid,
	Snap,
	Edit,
	Quit,
	Timeout,
	Tour,
	Talk,
	Fight,
	Pulse,
	Request,
	Doors,
	Clock,
	Boss,
}

@(private = "file")
Talk_Phase :: enum u8 {
	Pick,
	Walk,
	Face,
	Chat,
	Climb,
}

@(private = "file")
Tour_Phase :: enum u8 {
	Plan,
	Go,
	Arrive,
	Back,
	Return,
	Lost,
}

// One place of a tour: the first is where it started, each next one a place
// an exit of the one before led to.
@(private = "file")
Tour_Frame :: struct {
	phase:  Tour_Phase,
	// Its map and section.
	place:  [2]u32,
	// One tile per reachable exit, and the next one to visit.
	exits:  [TOUR_MAX][2]i32,
	count:  int,
	next:   int,
	// The exit tile leading back to the place before, or -1, -1 for none
	// (the world map: confirm enters again).
	back:   [2]i32,
}

// Deepest a tour goes, and most places it visits.
@(private = "file")
TOUR_DEPTH :: 8
@(private = "file")
TOUR_PLACES :: 256

// Vblanks a walk keeps at one step (a cell takes about 16) before it counts
// the step as blocked and goes around; and most blocked steps remembered.
@(private = "file")
WALK_BLOCKED_T :: 90
@(private = "file")
WALK_BLOCKED_MAX :: 64

// Vblanks a talk turns toward the NPC, and presses confirm before giving up.
@(private = "file")
TALK_FACE :: 12
@(private = "file")
TALK_WAIT :: 90
// Talks started on the way (walking into someone, or onto a shop counter's
// trigger) before an NPC counts as out of reach. One started next to it
// (diagonals too) is taken as its talk: a shopkeeper across a counter.
@(private = "file")
TALK_INTERRUPTS :: 3
// Most stairs a talk tries, and vblanks it pushes up or down one.
@(private = "file")
TALK_STAIRS :: 32
@(private = "file")
TALK_CLIMB :: 60

// Most doors `doors` visits; vblanks it waits for the map's doors to be
// found, walks to a spot before a door and then faces it before going on;
// and cells before the doorway it first stands.
@(private = "file")
DOORS_MAX :: 8
@(private = "file")
DOORS_NONE :: 120
@(private = "file")
DOORS_WALK :: 300
@(private = "file")
DOORS_FACE :: 240
@(private = "file")
DOORS_BACK :: 3

// Most exits a tour visits.
@(private = "file")
TOUR_MAX :: 64
// Vblanks a tour waits for a way to an exit before skipping it, and
// walking to one before giving up on it.
@(private = "file")
TOUR_NO_WAY :: 120
@(private = "file")
TOUR_STUCK :: 1200
// Most different choices remembered between spells of control.
@(private = "file")
CHOICES_MAX :: 32

@(private = "file")
Step :: struct {
	op:   Op,
	a, b: i32,
	// `request`'s x, z and facing.
	args: [3]i32,
	text: string,
	line: int,
}

@(private = "file")
auto: struct {
	cheat:   bool,
	// BOF4_CHEAT=hp: leave the stats alone.
	hp_only: bool,
	// BOF4_AUTO_TRACE: log the leader and the autopilot's input every
	// TRACE_EVERY vblanks.
	trace:   bool,
	steps:   [dynamic]Step,
	at:      int,
	// Vblanks the current step has run.
	ticks:   i32,
	timeout: i32,
	ticker:  u32,
	// `pulse off`: confirm is not pulsed in battles and events.
	no_pulse: bool,
	// `pulse qte`: timed hits are pressed on cue.
	qte:      bool,
	// `pulse manual`: no confirm pulses, choices or menu back-outs.
	manual:   bool,
	stuck:   i32,
	// Vblanks the player has had control in a row.
	settled: i32,
	// Map and section a goto started on; for `until field`, with the map
	// block, last vblank.
	place:   [3]u32,
	// The walk's goal tile.
	goal:    [2]i32,
	// Why the current step is not done, for the stuck report.
	why:     string,
	// Per party slot, its battle copy of the record (0 none found yet).
	fighters: [PARTY_SLOT_COUNT]u32,
	// `boss N`: the BOSS file the next battle loads, 0 none.
	boss:     u32,
	file_load: cpu.Func_Proc,
	// Game mode and map last seen, to log changes.
	seen:    [2]u32,
	// Choices seen since the leader last had control: a hash of the string
	// (the same question can come from different addresses) and times shown.
	choices: [CHOICES_MAX]struct {
		key:   u32,
		shown: int,
	},
	choice_count: int,
	// Hash of the latest text box that was not a choice: the question.
	question:     u32,
	// Vblanks the leader has had control for.
	control_t:    int,
	// The choice open now (0 none) and the option to take in it.
	choice: u32,
	option: int,
	tour:    struct {
		frames:  [TOUR_DEPTH]Tour_Frame,
		depth:   int,
		max:     int,
		visited: [dynamic][2]u32,
	},
	// `doors`: the next door, whether the leader is before it, the
	// vblanks spent on it so far, and cells nearer than DOORS_BACK the
	// walk now aims; with `near`, the one door to survey (-1 until chosen).
	doors:   struct {
		next:   int,
		only:   int,
		there:  bool,
		t:      i32,
		nearer: int,
	},
	talk:    struct {
		phase:  Talk_Phase,
		// The NPC slot talked to, vblanks in this phase, whether its talk
		// took control away, and the slots done.
		npc:    u32,
		t:      i32,
		talked: bool,
		done:   [NPC_COUNT]bool,
		// Whether control was lost on the way to the NPC, and how often.
		interrupted: bool,
		interrupts:  int,
		// The stair climbed for (layer, x, z), the stairs tried, and the
		// layer the climb started on.
		stair:   [3]i32,
		stairs:  [TALK_STAIRS][3]i32,
		n_stairs: int,
		from:    u32,
		// The map and section talked on; a talk that moves the party
		// elsewhere ends the command.
		place:  [2]u32,
		begun:  bool,
	},
	// Steps (from x, z, to x, z) the walk found it cannot take, on the
	// place `blocked_at`: a ledge or a drop the grid does not show, or
	// someone standing in the way.
	blocked:    [WALK_BLOCKED_MAX][4]i32,
	n_blocked:  int,
	blocked_at: [3]u32,
	// The step the walk is taking and the vblanks it has taken so far.
	heading:    [4]i32,
	heading_t:  i32,
	// The walk's distance field, per tile, to the goal.
	dist:    [GRID_MAX * GRID_MAX]u16,
	queue:   [GRID_MAX * GRID_MAX]u32,
}

@(private)
autoplay_init :: proc() -> bool {
	cheat_env := os.get_env("BOF4_CHEAT", context.temp_allocator)
	auto.cheat = cheat_env != ""
	auto.hp_only = cheat_env == "hp"
	auto.trace = os.get_env("BOF4_AUTO_TRACE", context.temp_allocator) != ""
	auto.timeout = STEP_TIMEOUT
	path := os.get_env("BOF4_AUTO", context.temp_allocator)
	if path == "" {
		return true
	}
	data, err := os.read_entire_file_from_path(path, context.temp_allocator)
	if err != nil {
		fmt.eprintln("BOF4_AUTO: cannot read", path, err)
		return false
	}
	lines := strings.split_lines(string(data), context.temp_allocator)
	for raw, i in lines {
		line, _, _ := strings.partition(raw, "#")
		line = strings.trim_space(line)
		if line == "" {
			continue
		}
		step, ok := parse_step(line)
		if !ok {
			fmt.eprintfln("BOF4_AUTO: %s:%d: cannot read %q", path, i + 1, line)
			return false
		}
		step.line = i + 1
		append(&auto.steps, step)
	}
	// Ends the script: a run that reaches it passed.
	append(&auto.steps, Step{op = .Quit, line = len(lines)})
	ok: bool
	auto.file_load, ok = cpu.hook(FILE_LOAD, file_load)
	if !ok {
		fmt.eprintf("BOF4_AUTO: file loader %08x not found\n", FILE_LOAD)
	}
	return ok
}

// `boss N` swaps the next battle for boss N as its area's file is read: the
// encounter writes the area until then, so an earlier write does not last.
@(private = "file")
file_load :: proc() {
	file := cpu.state.r[4]
	if auto.boss != 0 && file >= AREAB_FILE && file <= AREAB_LAST {
		cpu.sb(BATTLE_AREA, auto.boss)
		cpu.sb(BATTLE_BOSS, auto.boss)
		cpu.state.r[4] = AREAB_LAST + auto.boss
		auto.boss = 0
	}
	auto.file_load()
}

@(private = "file")
parse_step :: proc(line: string) -> (s: Step, ok: bool) {
	words := strings.fields(line, context.temp_allocator)
	num :: proc(w: []string, i: int, base := 10) -> (i32, bool) {
		if i >= len(w) {
			return 0, false
		}
		v, ok := strconv.parse_int(w[i], base)
		return i32(v), ok
	}
	switch words[0] {
	case "wait":
		s.op = .Wait
		s.a = num(words, 1) or_return
	case "timeout":
		s.op = .Timeout
		s.a = num(words, 1) or_return
	case "press":
		s.op = .Press
		if len(words) < 2 {
			return
		}
		for n in host.PAD_NAMES {
			if n.name == words[1] {
				s.a = i32(n.bit)
			}
		}
		if s.a == 0 {
			return
		}
		s.b = 4
		if len(words) > 2 {
			s.b = num(words, 2) or_return
		}
	case "stick":
		s.op = .Stick
		s.a = num(words, 1) or_return
		s.b = num(words, 2) or_return
	case "goto":
		s.op = .Goto
		s.a = num(words, 1) or_return
		s.b = num(words, 2) or_return
	case "until":
		if len(words) < 2 {
			return
		}
		switch words[1] {
		case "map":
			s.op = .Until_Map
			s.a = num(words, 2, 16) or_return
		case "field":
			s.op = .Until_Field
		case "world":
			s.op = .Until_World
		case:
			return
		}
	case "log":
		s.op = .Log
		s.text = strings.clone(strings.trim_space(line[3:]))
	case "poke":
		s.op = .Poke
		s.a = num(words, 1, 16) or_return
		s.b = num(words, 2) or_return
	case "point":
		s.op = .Point
		s.a = num(words, 1) or_return
		s.b = num(words, 2) or_return
	case "grid":
		s.op = .Grid
	case "snap":
		s.op = .Snap
	case "edit":
		s.op = .Edit
	case "fight":
		s.op = .Fight
		if len(words) > 1 {
			if words[1] != "start" {
				return
			}
			s.a = 1
		}
	case "pulse":
		s.op = .Pulse
		if len(words) < 2 || words[1] != "on" && words[1] != "off" && words[1] != "qte" && words[1] != "manual" {
			return
		}
		s.a = 1 if words[1] == "off" else 2 if words[1] == "qte" else 3 if words[1] == "manual" else 0
	case "clock":
		s.op = .Clock
		s.a = num(words, 1) or_return
		if s.a == 0 {
			return
		}
	case "tour":
		s.op = .Tour
		s.a = 1
		if len(words) > 1 {
			s.a = num(words, 1) or_return
		}
		if s.a < 1 || s.a > TOUR_DEPTH - 1 {
			return
		}
	case "talk":
		s.op = .Talk
	case "request":
		s.op = .Request
		s.a = num(words, 1, 16) or_return
		s.b = num(words, 2) or_return
		for i in 0 ..< 3 {
			s.args[i] = num(words, 3 + i) or_return
		}
	case "doors":
		s.op = .Doors
		if len(words) > 1 {
			if words[1] != "near" {
				return
			}
			s.a = 1
		}
	case "boss":
		s.op = .Boss
		s.a = num(words, 1) or_return
		if s.a < 1 || s.a > BOSS_FILES {
			return
		}
	case "quit":
		s.op = .Quit
	case:
		return
	}
	return s, true
}

// Once per vblank, from config.odin's vblank.
@(private)
autoplay_vblank :: proc() {
	if io.preload_child {
		return
	}
	if auto.cheat {
		cheat()
	}
	// A replay (BOF4_REPLAY) leading up to the script plays out untouched.
	if len(auto.steps) == 0 || host.host_presents() <= host.replay_end {
		return
	}
	auto.ticker += 1
	host.auto_pad, host.auto_stick = 0, {}
	if auto.stuck > 0 {
		// Let the snapshot be drawn, then give up.
		auto.stuck -= 1
		if auto.stuck == 0 {
			cpu.ram_dump_env()
			os.exit(3)
		}
		return
	}
	mode := cpu.lhu(GAME_MODE)
	seen := [2]u32{mode, cpu.lhu(MAP_ID)}
	if seen != auto.seen {
		auto.seen = seen
		fmt.eprintfln("autoplay: mode %d map %04x at present %d", seen[0], seen[1], host.host_presents())
	}
	// Menus (a shop) keep an info box open; only the field's boxes are
	// dialogue, and only while they hold the leader (the pointer outlives
	// the box, and a confirm then talks to whoever the leader faces).
	box := cpu.lw(TEXT_BOX)
	auto.control_t = auto.control_t + 1 if has_control() else 0
	if auto.control_t > SETTLE {
		auto.choice_count = 0
	}
	if box != 0 && cpu.lbu(box) != BOX_STATE_CHOICE {
		auto.question = text_hash(cpu.lw(box + BOX_TEXT))
	}
	// The world map has no text boxes: a box left from before would take
	// a confirm meant for nothing and enter the place again.
	if on_world_map() {
		box = 0
	}
	if auto.manual {
		// The script presses everything.
	} else if haggling() {
		haggle()
	} else if box != 0 && cpu.lbu(box) == BOX_STATE_CHOICE && mode != MODE_BATTLE && !has_control() {
		// A choice holds the leader; with control back the box is stale,
		// and a confirm would talk to whoever the leader faces.
		choose(box)
	} else if drinking() {
		drink()
	} else if mode == MODE_BATTLE || mode == MODE_EVENT || mode == MODE_FIELD && box != 0 && !has_control() {
		auto.choice = 0
		if auto.qte && mode == MODE_BATTLE && timed_acting() {
			if timed_cue_left() == 1 {
				host.auto_pad |= confirm_button()
			}
		} else if !auto.no_pulse && auto.ticker % PULSE < PULSE_ON {
			host.auto_pad |= confirm_button()
		}
	} else if mode == MODE_MENU {
		// A walk can bump a shopkeeper open; leave the shop.
		back_out()
	}
	step := &auto.steps[auto.at]
	done := run_step(step)
	if auto.trace && auto.ticker % TRACE_EVERY == 0 {
		trace_line(step^)
	}
	if done {
		next_step()
		return
	}
	auto.ticks += 1
	if auto.ticks > auto.timeout {
		fmt.eprintfln("autoplay: stuck at line %d (%v) after %d vblanks, map %04x mode %d at present %d: %s", step.line, step.op, auto.ticks, cpu.lhu(MAP_ID), mode, host.host_presents(), auto.why)
		host.snapshot_now()
		auto.stuck = 10
	}
}

@(private = "file")
trace_line :: proc(step: Step) {
	obj := leader_obj()
	pos := obj + OBJ_POS
	fmt.eprintfln(
		"autoplay: trace %d line %d map %04x.%d mode %d leader %.2f,%.2f height %.2f layer %d state %d stick %.2f,%.2f pad %04x: %s",
		host.host_presents(), step.line, cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), cpu.lhu(GAME_MODE),
		f64(i32(cpu.lw(pos))) / 0x10000, f64(i32(cpu.lw(pos + 8))) / 0x10000, f64(i32(cpu.lw(pos + 4))) / 0x10000, cpu.lbu(pos + POS_LAYER), cpu.lbu(obj + OBJ_STATE),
		host.auto_stick.x, host.auto_stick.y, host.auto_pad, auto.why,
	)
}

@(private = "file")
next_step :: proc() {
	auto.at += 1
	auto.ticks, auto.settled = 0, 0
	auto.why = ""
	s := auto.steps[auto.at]
	core.tracef(.Game, "autoplay: line %d %v %d %d", s.line, s.op, s.a, s.b)
}

// Run one vblank of step s; true when it is done.
@(private = "file")
run_step :: proc(s: ^Step) -> bool {
	switch s.op {
	case .Wait:
		return auto.ticks >= s.a
	case .Timeout:
		auto.timeout = s.a
		return true
	case .Press:
		host.auto_pad |= u16(s.a)
		return auto.ticks >= s.b
	case .Stick:
		steer(f64(s.a))
		return auto.ticks >= s.b
	case .Goto:
		// An exit tile is reached when the map or section changes.
		place := [3]u32{cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), 0}
		if auto.ticks == 0 {
			auto.place = place
		}
		return place != auto.place || walk(s.a, s.b)
	case .Until_Map:
		return cpu.lhu(MAP_ID) == u32(s.a)
	case .Until_Field:
		return settle(has_control())
	case .Until_World:
		return settle(on_world_map())
	case .Log:
		pos := leader_obj() + OBJ_POS
		x, z := (i32(cpu.lw(pos)) + 0x8000) >> 16, (i32(cpu.lw(pos + 8)) + 0x8000) >> 16
		fmt.eprintfln("autoplay: %s (map %04x.%d tile %d,%d, present %d)", s.text, cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), x, z, host.host_presents())
		return true
	case .Poke:
		cpu.sb(u32(s.a), u32(s.b))
		fmt.eprintfln("autoplay: poke %08x = %d", u32(s.a), s.b)
		return true
	case .Point:
		host.pointer_move({f32(s.a), f32(s.b)})
		return true
	case .Grid:
		print_grid()
		return true
	case .Snap:
		host.snapshot_now()
		return true
	case .Edit:
		map_editor.toggle = true
		return true
	case .Tour:
		if auto.ticks == 0 && auto.tour.depth == 0 && auto.tour.frames[0].phase == .Plan {
			auto.tour.max = int(s.a)
			clear(&auto.tour.visited)
		}
		return tour_tick()
	case .Talk:
		return talk_tick()
	case .Fight:
		return fight_tick(s)
	case .Pulse:
		auto.no_pulse = s.a == 1 || s.a == 3
		auto.qte = s.a == 2
		auto.manual = s.a == 3
		return true
	case .Request:
		script_request(u32(s.a), u32(s.b), s.args[0], s.args[1], u32(s.args[2]))
		return true
	case .Doors:
		return doors_tick(s.a == 1)
	case .Clock:
		io.clock_set(u64(s.a))
		return true
	case .Boss:
		auto.boss = u32(s.a)
		return true
	case .Quit:
		fmt.eprintfln("autoplay: done at present %d", host.host_presents())
		cpu.ram_dump_env()
		os.exit(0)
	}
	return true
}

// One vblank of `fight`: with one step of the encounter budget left, pace
// back and forth until a battle starts, then wait for control after it.
// s.b is set once the battle has started.
@(private = "file")
fight_tick :: proc(s: ^Step) -> bool {
	if auto.ticks == 0 {
		s.b = 0
	}
	if cpu.lhu(GAME_MODE) == MODE_BATTLE {
		s.b = 1
		auto.why = "in battle"
		return s.a != 0
	}
	if s.b != 0 {
		auto.why = "after battle"
		return settle(has_control())
	}
	if !has_control() {
		auto.why = "no control"
		return false
	}
	auto.why = "no battle (encounters off here?)"
	if cpu.lbu(STEPS_LEFT) != 0xff {
		cpu.sb(STEPS_LEFT, 1)
	}
	steer(f64((auto.ticks / FIGHT_PACE) % 2 * 180))
	return false
}

// One vblank of `doors`: true when every door is done.
@(private = "file")
doors_tick :: proc(near: bool) -> bool {
	dd := &auto.doors
	if auto.ticks == 0 {
		dd^ = {only = -1}
	}
	spots: [DOORS_MAX]Door_Spot
	n := interiors_door_spots(spots[:])
	if n == 0 {
		auto.why = "no doors found"
		return auto.ticks > DOORS_NONE
	}
	if near && dd.only < 0 {
		at := leader_tile()
		best := max(f32)
		for s, i in spots[:n] {
			if d := s.here - {f32(at.x), f32(at.y)}; d.x * d.x + d.y * d.y < best {
				best, dd.only, dd.next = d.x * d.x + d.y * d.y, i, i
			}
		}
	}
	here := [2]u32{cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION)}
	if dd.next >= n || near && dd.next != dd.only {
		// A door may settle while the leader walks to the next.
		for s, i in spots[:n] {
			if near && i != dd.only {
				continue
			}
			if s.settled {
				fmt.eprintfln("autoplay: door %04x.%d to %04x.%d slide %.2f %.2f %.2f", here[0], here[1], s.world[0], s.world[1], s.slide.x, s.slide.y, s.slide.z)
			} else {
				fmt.eprintfln("autoplay: door %04x.%d to %04x.%d not settled", here[0], here[1], s.world[0], s.world[1])
			}
		}
		return true
	}
	s := spots[dd.next]
	done := s.settled
	dd.t += 1
	if !done && !dd.there {
		// From DOORS_BACK cells before the doorway, then nearer, as the
		// ground allows.
		back := f32(DOORS_BACK - dd.nearer)
		front := s.here - s.way * back
		x, z := i32(math.round(front.x)), i32(math.round(front.y))
		auto.why = fmt.tprintf("walking to door %04x.%d at %d,%d", s.world[0], s.world[1], x, z)
		if walk(x, z) {
			dd.there, dd.t = true, 0
		} else if strings.has_prefix(auto.why, "no way") || strings.has_prefix(auto.why, "goal not open") {
			// No waiting out a way that is not there.
			dd.t = DOORS_WALK + 1
		}
		if !dd.there && dd.t > DOORS_WALK {
			dd.nearer, dd.t = dd.nearer + 1, 0
			done = dd.nearer == DOORS_BACK
		}
	} else if !done {
		// The camera looks at the doorway from behind the leader.
		auto.why = fmt.tprintf("facing door %04x.%d", s.world[0], s.world[1])
		cpu.sh(CAMERA_YAW, u32(i32(math.round(s.angle * 4096 / 360))) & 0xfff)
		done = dd.t > DOORS_FACE
	}
	if !done {
		return false
	}
	if !s.settled {
		fmt.eprintfln("autoplay: gave up on door %04x.%d: %s", s.world[0], s.world[1], auto.why)
	}
	dd.next, dd.there, dd.t, dd.nearer = dd.next + 1, false, 0, 0
	return false
}

// One vblank of `until field`: true once the player has had control on a
// settled map for SETTLE vblanks.
@(private = "file")
settle :: proc(ready: bool) -> bool {
	// Control right after a map change can be the old map's, before the load
	// starts. A door's load happens behind the fade, with control still on.
	place := [3]u32{cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), cpu.lw(MAP_BLOCK)}
	still := ready && screen_fade() == 0 && place == auto.place
	auto.place = place
	auto.settled = still ? auto.settled + 1 : 0
	return auto.settled >= SETTLE
}

@(private = "file")
map_place :: proc() -> [2]u32 {
	return {cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION)}
}

@(private = "file")
leader_tile :: proc() -> [2]i32 {
	pos := leader_obj() + OBJ_POS
	return {(i32(cpu.lw(pos)) + 0x8000) >> 16, (i32(cpu.lw(pos + 8)) + 0x8000) >> 16}
}

// One vblank of `tour`: true when every exit has been visited.
@(private = "file")
tour_tick :: proc() -> bool {
	tour := &auto.tour
	t := &tour.frames[tour.depth]
	phase, depth := t.phase, tour.depth
	switch t.phase {
	case .Plan:
		if !has_control() {
			auto.why = "no control"
			return false
		}
		t.place = map_place()
		t.next, t.count = 0, 0
		// The world map has no tiles to walk: only ever a leaf.
		if !slice.contains(tour.visited[:], t.place) && tour.depth < tour.max && t.place[0] & WORLD_MAP_MASK != WORLD_MAP {
			append(&tour.visited, t.place)
			all: [TOUR_MAX][2]i32
			for e in all[:tour_exits(all[:])] {
				if e != t.back || tour.depth == 0 {
					t.exits[t.count] = e
					t.count += 1
				}
			}
			fmt.eprintfln("autoplay: tour of map %04x.%d (depth %d): %d exits", t.place[0], t.place[1], tour.depth, t.count)
		}
		t.phase = .Go
	case .Go:
		if t.next >= t.count {
			if tour.depth == 0 {
				fmt.eprintfln("autoplay: tour done, %d places", len(tour.visited))
				t.phase = .Plan
				return true
			}
			t.phase = .Back
		} else if map_place() != t.place {
			t.phase = .Arrive
		} else if e := t.exits[t.next]; !walk(e.x, e.y) && has_control() && (auto.ticks > TOUR_NO_WAY && strings.has_prefix(auto.why, "no way") || auto.ticks > TOUR_STUCK) {
			fmt.eprintfln("autoplay: tour exit %d of map %04x.%d at %d,%d: %s, skipped", t.next, t.place[0], t.place[1], e.x, e.y, auto.why)
			t.next += 1
			auto.ticks = 0
		}
	case .Arrive:
		if settle(has_control()) {
			e := t.exits[t.next]
			p := map_place()
			at := leader_tile()
			fmt.eprintfln("autoplay: tour exit %d of map %04x.%d at %d,%d leads to map %04x.%d tile %d,%d (present %d)", t.next, t.place[0], t.place[1], e.x, e.y, p[0], p[1], at.x, at.y, host.host_presents())
			host.snapshot_now()
			back: [1][2]i32
			if p[0] & WORLD_MAP_MASK == WORLD_MAP || tour_exits(back[:]) == 0 {
				back[0] = {-1, -1}
			}
			t.phase = .Return
			tour.depth += 1
			tour.frames[tour.depth] = {
				phase = .Plan,
				back  = back[0],
			}
		}
	case .Back:
		if map_place() == tour.frames[tour.depth - 1].place {
			tour.depth -= 1
		} else if t.back.x < 0 {
			auto.why = "no way back, confirming"
			if auto.ticker % PULSE < PULSE_ON {
				host.auto_pad |= confirm_button()
			}
		} else {
			walk(t.back.x, t.back.y)
		}
	case .Return:
		if settle(has_control()) {
			if map_place() != t.place {
				fmt.eprintfln("autoplay: tour exit %d of map %04x.%d came back to map %04x.%d", t.next, t.place[0], t.place[1], cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION))
				t.phase = .Lost
			} else {
				host.snapshot_now()
				t.next += 1
				t.phase = .Go
			}
		}
	case .Lost:
		auto.why = "tour lost its way back"
	}
	if t.phase != phase || tour.depth != depth {
		// Each phase gets the whole step timeout.
		auto.ticks = 0
		auto.settled = 0
		auto.place = {cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), cpu.lw(MAP_BLOCK)}
	}
	return false
}

// One vblank of `talk`: true when every NPC has been talked to (or found
// out of reach).
@(private = "file")
talk_tick :: proc() -> bool {
	tk := &auto.talk
	tk.t += 1
	leader := leader_tile()
	place := [2]u32{cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION)}
	if !tk.begun {
		tk.place, tk.begun = place, true
	} else if place != tk.place && has_control() {
		fmt.eprintfln("autoplay: talk moved the party to map %04x.%d, done", place.x, place.y)
		tk^ = {}
		return true
	}
	if tk.phase != .Chat && tk.phase != .Pick && !has_control() {
		// A talk or menu started on the way (walking into someone): wait
		// it out, backing out of menus, without spending the NPC's time.
		auto.why = "no control"
		back_out()
		if tk.phase == .Walk && !tk.interrupted {
			// The step taken set the talk off: go around it from now on.
			tk.interrupted = true
			tk.interrupts += 1
			if auto.n_blocked < WALK_BLOCKED_MAX {
				auto.blocked[auto.n_blocked] = auto.heading
				auto.n_blocked += 1
			}
		}
		tk.t -= 1
		auto.ticks = 0
		return false
	}
	phase := tk.phase
	defer if tk.phase != phase {
		// Each NPC gets the whole step timeout.
		auto.ticks = 0
	}
	switch tk.phase {
	case .Pick:
		if !has_control() {
			auto.why = "no control"
			back_out()
			return false
		}
		best, best_d := u32(NPC_COUNT), i32(max(i32))
		for i in u32(0) ..< NPC_COUNT {
			if tk.done[i] || !npc_here(i) {
				continue
			}
			at := npc_tile(i)
			if d := abs(at.x - leader.x) + abs(at.y - leader.y); d < best_d {
				best, best_d = i, d
			}
		}
		if best == NPC_COUNT {
			if stair, ok := talk_stair(leader); ok {
				tk.stair, tk.phase, tk.t = stair, .Climb, 0
				tk.from = leader_layer()
				tk.stairs[tk.n_stairs] = stair
				tk.n_stairs += 1
				return false
			}
			fmt.eprintfln("autoplay: talked to everyone on map %04x.%d", cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION))
			tk^ = {}
			return true
		}
		tk.npc, tk.phase, tk.t, tk.talked = best, .Walk, 0, false
		tk.interrupted, tk.interrupts = false, 0
	case .Walk:
		if !npc_here(tk.npc) {
			tk.done[tk.npc], tk.phase = true, .Pick
			return false
		}
		at := npc_tile(tk.npc)
		if tk.interrupted {
			// A talk can give control back between its boxes.
			if auto.control_t < SETTLE {
				return false
			}
			tk.interrupted = false
			if max(abs(at.x - leader.x), abs(at.y - leader.y)) <= 1 {
				fmt.eprintfln("autoplay: talked to npc %d at %d,%d on the way (present %d)", tk.npc, at.x, at.y, host.host_presents())
				tk.done[tk.npc], tk.phase = true, .Pick
				return false
			}
			if tk.interrupts >= TALK_INTERRUPTS {
				fmt.eprintfln("autoplay: npc %d at %d,%d out of reach: %d talks on the way", tk.npc, at.x, at.y, tk.interrupts)
				tk.done[tk.npc], tk.phase = true, .Pick
				return false
			}
		}
		if abs(at.x - leader.x) + abs(at.y - leader.y) == 1 {
			tk.phase, tk.t = .Face, 0
			return false
		}
		// The open side of the NPC nearest the leader.
		pos := leader_obj() + OBJ_POS
		g, ok := grid_of(cpu.lbu(pos + POS_LAYER))
		goal, goal_d := [2]i32{-1, -1}, i32(max(i32))
		for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			n := at + d
			if ok && attr_at(g, n.x, n.y) >> 4 != 0x1 && attr_at(g, n.x, n.y) >> 4 != 0xa {
				if dist := abs(n.x - leader.x) + abs(n.y - leader.y); dist < goal_d {
					goal, goal_d = n, dist
				}
			}
		}
		if goal.x < 0 || tk.t > TOUR_STUCK || !walk(goal.x, goal.y) && tk.t > TOUR_NO_WAY && strings.has_prefix(auto.why, "no way") {
			fmt.eprintfln("autoplay: npc %d at %d,%d out of reach: %s", tk.npc, at.x, at.y, auto.why)
			tk.done[tk.npc], tk.phase = true, .Pick
		}
	case .Face:
		at := npc_tile(tk.npc)
		pos := leader_obj() + OBJ_POS
		px, pz := f64(i32(cpu.lw(pos))) / 0x10000, f64(i32(cpu.lw(pos + 8))) / 0x10000
		steer(math.to_degrees(math.atan2(f64(at.x) - px, -(f64(at.y) - pz))))
		if tk.t > TALK_FACE {
			tk.phase, tk.t = .Chat, 0
		}
	case .Chat:
		if !has_control() {
			tk.talked = true
			tk.t = 0
			back_out()
		} else if tk.talked && tk.t > SETTLE {
			at := npc_tile(tk.npc)
			fmt.eprintfln("autoplay: talked to npc %d at %d,%d (present %d)", tk.npc, at.x, at.y, host.host_presents())
			tk.done[tk.npc], tk.phase = true, .Pick
		} else if !tk.talked && tk.t > TALK_WAIT {
			at := npc_tile(tk.npc)
			fmt.eprintfln("autoplay: npc %d at %d,%d had nothing to say", tk.npc, at.x, at.y)
			tk.done[tk.npc], tk.phase = true, .Pick
		} else if !tk.talked && auto.ticker % PULSE < PULSE_ON {
			host.auto_pad |= confirm_button()
		}
	case .Climb:
		// Walk onto the stair, then push along its direction until the
		// leader is on another layer.
		if leader_layer() != tk.from {
			fmt.eprintfln("autoplay: climbed the stair at %d,%d to layer %d", tk.stair.y, tk.stair.z, leader_layer())
			tk.phase = .Pick
			return false
		}
		if tk.t > TOUR_STUCK {
			fmt.eprintfln("autoplay: stair at %d,%d out of reach: %s", tk.stair.y, tk.stair.z, auto.why)
			tk.phase = .Pick
			return false
		}
		if leader == tk.stair.yz {
			g, _ := grid_of(tk.from)
			dirs := DIRECTIONS
			d := dirs[(attr_at(g, leader.x, leader.y) & 3) * 2]
			steer(math.to_degrees(math.atan2(f64(d.x), -f64(d.y))))
		} else if !walk(tk.stair.y, tk.stair.z) && tk.t > TOUR_NO_WAY && strings.has_prefix(auto.why, "no way") {
			tk.t = TOUR_STUCK + 1
		}
	}
	return false
}

@(private = "file")
leader_layer :: proc() -> u32 {
	return cpu.lbu(leader_obj() + OBJ_POS + POS_LAYER)
}

// The nearest untried stair (kind 0xc cell) on the leader's layer, when an
// NPC not talked to yet is on another layer.
@(private = "file")
talk_stair :: proc(leader: [2]i32) -> (stair: [3]i32, ok: bool) {
	tk := &auto.talk
	layer := leader_layer()
	others := false
	for i in u32(0) ..< NPC_COUNT {
		npc := NPCS + i * NPC_SIZE
		if !tk.done[i] && cpu.lbu(npc) != 0 && cpu.lbu(npc + OBJ_POS + POS_LAYER) != layer {
			others = true
		}
	}
	g, has := grid_of(layer)
	if !others || !has || tk.n_stairs == TALK_STAIRS {
		return {}, false
	}
	best_d := i32(max(i32))
	for z in 0 ..< g.h {
		for x in 0 ..< g.w {
			at := [3]i32{i32(layer), x, z}
			if attr_at(g, x, z) >> 4 != 0xc || slice.contains(tk.stairs[:tk.n_stairs], at) {
				continue
			}
			if d := abs(x - leader.x) + abs(z - leader.y); d < best_d {
				stair, best_d, ok = at, d, true
			}
		}
	}
	return
}

// Whether NPC slot i is in use on the leader's layer.
@(private = "file")
npc_here :: proc(i: u32) -> bool {
	npc := NPCS + i * NPC_SIZE
	return cpu.lbu(npc) != 0 && cpu.lbu(npc + OBJ_POS + POS_LAYER) == cpu.lbu(leader_obj() + OBJ_POS + POS_LAYER)
}

@(private = "file")
npc_tile :: proc(i: u32) -> [2]i32 {
	pos := NPCS + i * NPC_SIZE + OBJ_POS
	return {(i32(cpu.lw(pos)) + 0x8000) >> 16, (i32(cpu.lw(pos + 8)) + 0x8000) >> 16}
}

// Fill out with one tile per group of touching exit tiles the leader can
// walk to, nearest first; returns how many.
@(private = "file")
tour_exits :: proc(out: [][2]i32) -> int {
	pos := leader_obj() + OBJ_POS
	g, ok := grid_of(cpu.lbu(pos + POS_LAYER))
	if !ok || g.w > GRID_MAX || g.h > GRID_MAX {
		return 0
	}
	at := leader_tile()
	if !inside(g, at.x, at.y) {
		return 0
	}
	// Distances from the leader over open tiles (no exit is the goal). A
	// door walked through (interiors.odin door_through) leaves the leader
	// on the room's exit cells: that one stays open, so the way out of it
	// counts.
	auto.goal = is_exit(g, at.x, at.y) ? at : {-1, -1}
	distances(g, at.x, at.y)
	// Each exit tile's group is marked by flood fill; the group keeps its
	// tile nearest the leader.
	Pick :: struct {
		tile: [2]i32,
		d:    u16,
	}
	picks := make([dynamic]Pick, context.temp_allocator)
	done := make([]bool, g.w * g.h, context.temp_allocator)
	stack := make([dynamic][2]i32, context.temp_allocator)
	for z in 0 ..< g.h {
		for x in 0 ..< g.w {
			if done[z * g.w + x] || attr_at(g, x, z) >> 4 != 0xa {
				continue
			}
			best := Pick{{x, z}, max(u16)}
			append(&stack, [2]i32{x, z})
			done[z * g.w + x] = true
			for len(stack) > 0 {
				c := pop(&stack)
				for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
					n := c + d
					if !inside(g, n.x, n.y) {
						continue
					}
					i := n.y * g.w + n.x
					if attr_at(g, n.x, n.y) >> 4 == 0xa {
						if !done[i] {
							done[i] = true
							append(&stack, n)
						}
					} else if dn := auto.dist[i]; dn != max(u16) && dn + 1 < best.d {
						best = {c, dn + 1}
					}
				}
			}
			if best.d != max(u16) {
				append(&picks, best)
			}
		}
	}
	slice.sort_by(picks[:], proc(a, b: Pick) -> bool {return a.d < b.d})
	n := min(len(picks), len(out))
	for i in 0 ..< n {
		out[i] = picks[i].tile
	}
	return n
}

// Answer the open choice: the first option the first time it shows, the
// next the next time (wrapping), moving the cursor with Down.
@(private = "file")
choose :: proc(box: u32) {
	text := cpu.lw(box + BOX_TEXT)
	if text != auto.choice {
		auto.choice = text
		// "Yes|No" alone says little: the question before it tells choices apart.
		key := text_hash(text) ~ auto.question * 31
		shown := 0
		found := false
		for &c in auto.choices[:auto.choice_count] {
			if c.key == key {
				shown = c.shown
				c.shown += 1
				found = true
				break
			}
		}
		if !found && auto.choice_count < CHOICES_MAX {
			auto.choices[auto.choice_count] = {key, 1}
			auto.choice_count += 1
		}
		auto.option = shown % choice_options(text)
		fmt.eprintfln("autoplay: choice \"%s\" shown %d times before, taking option %d", text_line(text), shown, auto.option)
	}
	if auto.ticker % PULSE >= PULSE_ON {
		return
	}
	// The box takes a first press before the cursor moves.
	if cpu.lbu(box + BOX_STEP) != 0 && int(cpu.lbu(box + BOX_CURSOR)) != auto.option {
		host.auto_pad |= host.PAD_DOWN
	} else {
		host.auto_pad |= confirm_button()
	}
}

// FNV-1a of the string at `text`.
@(private = "file")
text_hash :: proc(text: u32) -> u32 {
	h := u32(2166136261)
	for i in u32(0) ..< CHOICE_TEXT_MAX {
		b := cpu.lbu(text + i)
		if b == 0 {
			break
		}
		h = (h ~ u32(b)) * 16777619
	}
	return h
}

// The string at `text` for the log, control codes shown as '|'.
@(private = "file")
text_line :: proc(text: u32) -> string {
	buf: [CHOICE_TEXT_MAX]u8
	n := 0
	for ; n < CHOICE_TEXT_MAX; n += 1 {
		b := cpu.lbu(text + u32(n))
		if b == 0 {
			break
		}
		buf[n] = u8(b) if b >= 0x20 && b < 0x7f else '|'
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// Options in a choice's string: lines split by 0x01, ended by 0.
@(private = "file")
choice_options :: proc(text: u32) -> int {
	n := 1
	for i in u32(0) ..< CHOICE_TEXT_MAX {
		switch cpu.lbu(text + i) {
		case 0:
			return n
		case 1:
			n += 1
		}
	}
	return n
}

// The Sarai tavern's drinking contest (SCENARIO/SCE04 at 0x801f8800; see
// docs/story-and-maps.md). Each drink fills the win bar by 48 (Circle,
// Triangle) or 32 (Square, Cross) less a penalty for repeating the same
// button, and fills one of two losing bars (Square/Triangle or
// Circle/Cross) by as much plus a penalty for repeating that pair. Confirm
// is Cross, so pulsing it loses; alternating Circle and Triangle wins in six
// drinks.
@(private = "file")
SCE04_CALL :: 0x801fa718 // u32, the scenario's entry, when SCE04 is loaded
@(private = "file")
SCE04_ENTRY :: 0x801f8a28
@(private = "file")
CONTEST :: 0x801fa810 // u8 +0 phase, u8 +4 last drink
@(private = "file")
CONTEST_TURN :: 2 // phase: waiting for a drink
@(private = "file")
DRINK_CIRCLE :: 3
@(private = "file")
TRIANGLE_COST :: 5 // gold Triangle needs

@(private = "file")
drinking :: proc() -> bool {
	return cpu.lw(SCE04_CALL) == SCE04_ENTRY && cpu.lbu(CONTEST) == CONTEST_TURN
}

@(private = "file")
drink :: proc() {
	if auto.ticker % PULSE >= PULSE_ON {
		return
	}
	if cpu.lbu(CONTEST + 4) != DRINK_CIRCLE {
		host.auto_pad |= host.PAD_CIRCLE
	} else if cpu.lw(ZENNY) >= TRIANGLE_COST {
		host.auto_pad |= host.PAD_TRIANGLE
	} else {
		host.auto_pad |= host.PAD_SQUARE
	}
}

// The Sarai information broker's guessing game (overlay at 0x801f0800,
// phase table 0x801f26b4; see docs/story-and-maps.md). The player enters
// three-digit offers that add up; once the total reaches the fixed price
// of 123 the broker talks, and an exact 123 earns a reward. Entering the
// rest of the price and confirming finishes it in one try.
@(private = "file")
HAGGLE_PHASES :: 0x801f26b4 // u32 table; [1] is the entry phase handler
@(private = "file")
HAGGLE_ENTRY :: 0x801f1428
@(private = "file")
HAGGLE_TOTAL :: 0x801f26ce // s16, paid so far
@(private = "file")
HAGGLE_OFFER :: 0x801f26d0 // s16, the number being entered
@(private = "file")
HAGGLE :: 0x801f26d4 // u8 +0 phase
@(private = "file")
HAGGLE_ENTERING :: 1
@(private = "file")
HAGGLE_PRICE :: 123

@(private = "file")
haggling :: proc() -> bool {
	return cpu.lw(HAGGLE_PHASES + 4) == HAGGLE_ENTRY && cpu.lbu(HAGGLE) == HAGGLE_ENTERING
}

@(private = "file")
haggle :: proc() {
	rest := HAGGLE_PRICE - i32(i16(cpu.lhu(HAGGLE_TOTAL)))
	cpu.sh(HAGGLE_OFFER, u32(max(rest, 1)))
	if auto.ticker % PULSE < PULSE_ON {
		host.auto_pad |= confirm_button()
	}
}

@(private = "file")
confirm_button :: proc() -> u16 {
	if m := u16(cpu.lhu(CONFIRM_MASK)); m != 0 {
		return m
	}
	return host.PAD_CIRCLE
}

// Back out of a menu a talk opened (a shop): cancel is pulsed while one
// shows, outside the modes the main tick confirms through.
@(private = "file")
back_out :: proc() {
	mode := cpu.lhu(GAME_MODE)
	if mode != MODE_FIELD && mode != MODE_EVENT && mode != MODE_BATTLE && auto.ticker % PULSE < PULSE_ON {
		host.auto_pad |= cancel_button()
	}
}

@(private = "file")
cancel_button :: proc() -> u16 {
	if m := u16(cpu.lhu(CONFIRM_MASK + 2)); m != 0 {
		return m
	}
	return host.PAD_TRIANGLE
}

@(private = "file")
has_control :: proc() -> bool {
	if cpu.lw(SLOT_ENGINE) != FLD_MAIN_ID || cpu.lhu(GAME_MODE) != MODE_FIELD {
		return false
	}
	state := cpu.lbu(leader_obj() + OBJ_STATE)
	return state == STATE_CONTROL || state == STATE_IDLE
}

// The world map is a field mode with the leader in a state of its own.
@(private)
on_world_map :: proc() -> bool {
	return cpu.lhu(GAME_MODE) == MODE_FIELD && cpu.lbu(leader_obj() + OBJ_STATE) == STATE_WORLD
}

// Push the left stick toward world angle `degrees`.
@(private = "file")
steer :: proc(degrees: f64) {
	yaw := f64(cpu.lhu(CAMERA_YAW)) * 360.0 / 4096
	a := math.to_radians(degrees - yaw)
	host.auto_stick = {f32(math.sin(a)), f32(-math.cos(a))}
}

// One vblank of walking to tile (x, z): true on arrival. The way is the
// shortest over the grid's open tiles, recomputed each vblank, so NPCs
// pushing the leader aside do not matter.
@(private = "file")
walk :: proc(x, z: i32) -> bool {
	if !has_control() {
		auto.why = "no control"
		return false
	}
	pos := leader_obj() + OBJ_POS
	px := f64(i32(cpu.lw(pos))) / 0x10000
	pz := f64(i32(cpu.lw(pos + 8))) / 0x10000
	cx, cz := i32(math.floor(px + 0.5)), i32(math.floor(pz + 0.5))
	if cx == x && cz == z {
		// A door that switches at once (interiors.odin door_exit_at) leads
		// on only past its cells' middle: push on through until the place
		// changes.
		if _, way, through := door_exit_at(x, z); through {
			auto.why = fmt.tprintf("through the door at %d,%d", x, z)
			steer(math.to_degrees(math.atan2(f64(way.x), -f64(way.y))))
			return false
		}
		return true
	}
	g, ok := grid_of(cpu.lbu(pos + POS_LAYER))
	auto.goal = {x, z}
	place := [3]u32{cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION), cpu.lw(MAP_BLOCK)}
	if place != auto.blocked_at {
		auto.blocked_at, auto.n_blocked = place, 0
	}
	if !ok || g.w > GRID_MAX || g.h > GRID_MAX || !open(g, x, z) {
		auto.why = fmt.tprintf("goal not open (grid %v, attr %02x)", ok, attr_at(g, x, z))
		return false
	}
	distances(g, x, z)
	here := auto.dist[cz * g.w + cx] if inside(g, cx, cz) else max(u16)
	best := here
	tx, tz := cx, cz
	for dz in i32(-1) ..= 1 {
		for dx in i32(-1) ..= 1 {
			nx, nz := cx + dx, cz + dz
			if (dx == 0 && dz == 0) || !inside(g, nx, nz) {
				continue
			}
			// A diagonal needs both sides open, as the walk cuts the corner.
			if !crosses(g, {cx, cz}, {nx, nz}) {
				continue
			}
			if dx != 0 && dz != 0 && (!crosses(g, {cx, cz}, {cx + dx, cz}) || !crosses(g, {cx + dx, cz}, {nx, nz}) || !crosses(g, {cx, cz}, {cx, cz + dz}) || !crosses(g, {cx, cz + dz}, {nx, nz})) {
				continue
			}
			if blocked({cx, cz, nx, nz}) || pushes_exit(g, cx, cz, dx, dz) {
				continue
			}
			if d := auto.dist[nz * g.w + nx]; d < best {
				best, tx, tz = d, nx, nz
			}
		}
	}
	if best == max(u16) {
		auto.why = fmt.tprintf("no way from %d,%d", cx, cz)
		return false
	}
	auto.why = fmt.tprintf("at %d,%d heading %d,%d", cx, cz, tx, tz)
	step := [4]i32{cx, cz, tx, tz}
	auto.heading_t += 1
	if step != auto.heading {
		auto.heading, auto.heading_t = step, 0
	} else if auto.heading_t > WALK_BLOCKED_T && auto.n_blocked < WALK_BLOCKED_MAX {
		fmt.eprintfln("autoplay: step %d,%d to %d,%d blocked, going around", cx, cz, tx, tz)
		auto.blocked[auto.n_blocked] = step
		auto.n_blocked += 1
		auto.heading_t = 0
	}
	// The game fires an exit when the leader pushes toward it from the next
	// cell (the held direction or one 45 degrees off it). Beside an exit,
	// hold the step's exact direction instead of aiming at the tile's centre.
	if exit_near(g, cx, cz) {
		steer(math.to_degrees(math.atan2(f64(tx - cx), -f64(tz - cz))))
		return false
	}
	steer(math.to_degrees(math.atan2(f64(tx) - px, -(f64(tz) - pz))))
	return false
}

// The eight directions, clockwise from -z.
@(private = "file")
DIRECTIONS :: [8][2]i32{{0, -1}, {1, -1}, {1, 0}, {1, 1}, {0, 1}, {-1, 1}, {-1, 0}, {-1, -1}}

// Whether a push from (x, z) toward (dx, dz) steps onto a non-goal exit.
// The game's step (FLD_MAIN 0x801d1298) takes the first passable of the
// held direction, then 45 degrees clockwise, then counter-clockwise (table
// 0x801e315c), and an exit there fires as the step starts.
@(private = "file")
pushes_exit :: proc(g: Grid, x, z, dx, dz: i32) -> bool {
	dirs := DIRECTIONS
	for d, i in dirs {
		if d != {dx, dz} {
			continue
		}
		for k in ([3]int{0, 1, 7}) {
			n := [2]i32{x, z} + dirs[(i + k) % 8]
			if inside(g, n.x, n.y) && attr_at(g, n.x, n.y) >> 4 != 0x1 && step_allowed(attr_at(g, x, z), attr_at(g, n.x, n.y)) {
				return is_exit(g, n.x, n.y) && auto.goal != n
			}
		}
	}
	return false
}

// Whether any of the eight cells around (x, z) is a non-goal exit.
@(private = "file")
exit_near :: proc(g: Grid, x, z: i32) -> bool {
	for d in DIRECTIONS {
		if is_exit(g, x + d.x, z + d.y) && auto.goal != {x + d.x, z + d.y} {
			return true
		}
	}
	return false
}

@(private = "file")
is_exit :: proc(g: Grid, x, z: i32) -> bool {
	return inside(g, x, z) && attr_at(g, x, z) >> 4 == 0xa
}

@(private = "file")
blocked :: proc(step: [4]i32) -> bool {
	return slice.contains(auto.blocked[:auto.n_blocked], step)
}

@(private = "file")
inside :: proc(g: Grid, x, z: i32) -> bool {
	return x >= 0 && z >= 0 && x < g.w && z < g.h
}

// Whether the walk may cross tile (x, z): not a wall, nor an exit unless
// it is the goal.
@(private = "file")
open :: proc(g: Grid, x, z: i32) -> bool {
	kind := attr_at(g, x, z) >> 4
	return inside(g, x, z) && kind != 0x1 && (kind != 0xa || auto.goal == {x, z})
}

// Whether the walk may step from tile `a` to its neighbour `b`: `b` open and
// the game's rule for the two attributes allows it.
@(private = "file")
crosses :: proc(g: Grid, a, b: [2]i32) -> bool {
	if !inside(g, a.x, a.y) || !open(g, b.x, b.y) {
		return false
	}
	from := attr_at(g, a.x, a.y)
	// Leaving a kind 0xc cell in its direction ((attr & 3) * 2) climbs or
	// descends to another layer, off this grid.
	dirs := DIRECTIONS
	if from >> 4 == 0xc && b - a == dirs[(from & 3) * 2] {
		return false
	}
	return step_allowed(from, attr_at(g, b.x, b.y))
}

// FLD_MAIN's rule (0x801d5c74) for a step from a cell with attribute `a` to
// one with attribute `b`. Kind 2 cells are two levels told apart by bit 0
// (a balcony and the stairs beside it): stepping between levels is blocked.
// Kinds 0x7, 0xa, 0xb, 0xc and 0xe pair with 0x2d, 0x2f, 0x2e, 0x2b and 0x2c
// as one-way or no-cross edges.
@(private = "file")
step_allowed :: proc(a, b: u8) -> bool {
	switch b {
	case 0x10, 0x12, 0x13, 0x30, 0x50, 0xa3, 0xff:
		return false
	case 0xa4:
		if cpu.lhu(FIELD_FLAGS) & 0x200 != 0 {
			return false
		}
	}
	if b >> 4 == 0x4 {
		return false
	}
	PAIRS :: [5][2]u8{{0x2f, 0xa}, {0x2e, 0xb}, {0x2d, 0x7}, {0x2c, 0xe}, {0x2b, 0xc}}
	for p in PAIRS {
		if (a == p[0] && b >> 4 == p[1]) || (a >> 4 == p[1] && b == p[0] && p[1] != 0x7) {
			return false
		}
	}
	switch {
	case a == 0xa3 && b >> 4 == 0x7:
		return false
	case a >> 4 == 0x2 && b >> 4 == 0x2 && (a ~ b) & 1 != 0:
		return false
	case a >> 4 == 0x7 && (b == 0x2d || b == 0xa3):
		return false
	}
	return true
}

// Fill auto.dist with each tile's steps to (x, z) over open tiles, 4-way.
@(private = "file")
distances :: proc(g: Grid, x, z: i32) {
	n := g.w * g.h
	for i in 0 ..< n {
		auto.dist[i] = max(u16)
	}
	auto.dist[z * g.w + x] = 0
	auto.queue[0] = u32(z * g.w + x)
	head, tail := 0, 1
	for head < tail {
		at := i32(auto.queue[head])
		head += 1
		ax, az := at % g.w, at / g.w
		for d in ([4][2]i32{{1, 0}, {-1, 0}, {0, 1}, {0, -1}}) {
			nx, nz := ax + d.x, az + d.y
			i := nz * g.w + nx
			if !crosses(g, {nx, nz}, {ax, az}) || auto.dist[i] != max(u16) || blocked({nx, nz, ax, az}) {
				continue
			}
			auto.dist[i] = auto.dist[at] + 1
			auto.queue[tail] = u32(i)
			tail += 1
		}
	}
}

// BOF4_CHEAT=hp: hits on the party do no damage.
@(private)
autoplay_party_unhurt :: proc() -> bool {
	return auto.hp_only
}

// Keep the party at full HP, and in battle strong (unless hp_only): a battle works on copies
// of the records (recomputing their stats as it starts), found by name.
@(private = "file")
cheat :: proc() {
	battle := cpu.lhu(GAME_MODE) == MODE_BATTLE
	if !battle {
		auto.fighters = {}
	}
	for i in u32(0) ..< PARTY_SLOT_COUNT {
		index := cpu.lbu(PARTY_SLOTS + i)
		if index >= CHAR_COUNT {
			continue
		}
		rec := char_record(index)
		cpu.sh(rec + CHAR_HP, cpu.lhu(rec + RECORD_HP_MAX))
		if !battle {
			continue
		}
		at := auto.fighters[i]
		if at == 0 || !same_name(at, rec) {
			at = find_fighter(rec)
			auto.fighters[i] = at
		}
		if at == 0 {
			continue
		}
		cpu.sh(at + CHAR_HP, cpu.lhu(at + RECORD_HP_MAX))
		if auto.hp_only {
			continue
		}
		for s in u32(0) ..< 3 {
			cpu.sh(at + CHAR_PWR + 2 * s, CHEAT_STAT)
		}
	}
}

@(private = "file")
same_name :: proc(a, b: u32) -> bool {
	return cpu.lw(a) == cpu.lw(b) && cpu.lw(a + 4) == cpu.lw(b + 4)
}

// The battle's copy of record rec, 0 when none.
@(private = "file")
find_fighter :: proc(rec: u32) -> u32 {
	for at := u32(FIGHTERS_FROM); at < FIGHTERS_TO; at += 4 {
		if same_name(at, rec) && cpu.lhu(at + RECORD_HP_MAX) == cpu.lhu(rec + RECORD_HP_MAX) {
			return at
		}
	}
	return 0
}

// Cells either side of the leader in `grid`'s attribute dump.
@(private = "file")
GRID_NEAR :: 3

@(private = "file")
print_grid :: proc() {
	pos := leader_obj() + OBJ_POS
	g, ok := grid_of(cpu.lbu(pos + POS_LAYER))
	if !ok {
		fmt.eprintln("autoplay: no grid")
		return
	}
	lx, lz := (i32(cpu.lw(pos)) + 0x8000) >> 16, (i32(cpu.lw(pos + 8)) + 0x8000) >> 16
	fmt.eprintfln("autoplay: grid %dx%d of map %04x.%d, x across, z down", g.w, g.h, cpu.lhu(MAP_ID), cpu.lbu(MAP_SECTION))
	b := strings.builder_make(context.temp_allocator)
	for z in 0 ..< g.h {
		strings.builder_reset(&b)
		fmt.sbprintf(&b, "%3d ", z)
		for x in 0 ..< g.w {
			a := attr_at(g, x, z)
			c := a & 0xf == 0 ? '.' : rune(a & 0xf < 10 ? 0x30 + a & 0xf : 0x57 + a & 0xf)
			switch a >> 4 {
			case 0x1:
				c = '#'
			case 0xa:
				c = 'E'
			case 0x7, 0xc:
				c = '/'
			}
			if x == lx && z == lz {
				c = '@'
			}
			strings.write_rune(&b, c)
		}
		fmt.eprintln(strings.to_string(b))
	}
	fmt.eprintln("autoplay: attributes around the leader")
	for z in lz - GRID_NEAR ..= lz + GRID_NEAR {
		strings.builder_reset(&b)
		fmt.sbprintf(&b, "%3d", z)
		for x in lx - GRID_NEAR ..= lx + GRID_NEAR {
			if inside(g, x, z) {
				fmt.sbprintf(&b, " %02x", attr_at(g, x, z))
			} else {
				strings.write_string(&b, " --")
			}
		}
		fmt.eprintln(strings.to_string(b))
	}
}
