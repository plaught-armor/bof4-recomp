// The checkout's tools in one program: preparing a checkout from the disc
// (setup and the steps it runs) and the inspection tools the docs refer to.
// Build it with tools/build.sh (tools\build.bat on Windows); setup.sh and
// setup.bat at the top of the checkout do.
//
// Usage: bof4tools <tool> [arguments]; bof4tools alone lists the tools.
package tools

import "core:crypto/legacy/sha1"
import "core:encoding/endian"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strconv"
import "core:strings"

Tool :: struct {
	name:  string,
	usage: string,
	run:   proc(args: []string),
}

TOOLS := [?]Tool {
	{"setup", SETUP_USAGE, setup_main},
	{"disc-extract", DISC_EXTRACT_USAGE, disc_extract_main},
	{"emi-extract", EMI_EXTRACT_USAGE, emi_extract_main},
	{"file-table", FILE_TABLE_USAGE, file_table_main},
	{"save-to-mcd", SAVE_TO_MCD_USAGE, save_to_mcd_main},
	{"dengeki-patch", DENGEKI_PATCH_USAGE, dengeki_patch_main},
	{"dis", DIS_USAGE, dis_main},
	{"address-map", ADDRESS_MAP_USAGE, address_map_main},
	{"field-state", FIELD_STATE_USAGE, field_state_main},
	{"story-flags", STORY_FLAGS_USAGE, story_flags_main},
	{"exit-graph", EXIT_GRAPH_USAGE, exit_graph_main},
	{"map-block", MAP_BLOCK_USAGE, map_block_main},
	{"floors-png", FLOORS_PNG_USAGE, floors_png_main},
	{"add-layer-1000", ADD_LAYER_1000_USAGE, add_layer_1000_main},
	{"audio-check", AUDIO_CHECK_USAGE, audio_check_main},
}

// Standard output, buffered: some tools print hundreds of thousands of
// lines. Flushed when main returns and by fail.
out: strings.Builder

main :: proc() {
	if len(os.args) >= 2 {
		for t in TOOLS {
			if t.name == os.args[1] {
				t.run(os.args[2:])
				flush()
				return
			}
		}
	}
	fmt.eprintln("Usage: bof4tools <tool> [arguments]\n\nTools:")
	for t in TOOLS {
		fmt.eprintfln("  %s", t.name)
	}
	fmt.eprintln("\nbof4tools <tool> with no arguments prints its usage.")
	os.exit(2)
}

flush :: proc() {
	os.write_string(os.stdout, strings.to_string(out))
	strings.builder_reset(&out)
}

print :: proc(format: string, args: ..any) {
	fmt.sbprintf(&out, format, ..args)
	strings.write_byte(&out, '\n')
}

// Prints the message to standard error and exits with status 1.
fail :: proc(format: string, args: ..any) -> ! {
	flush()
	fmt.eprintfln(format, ..args)
	os.exit(1)
}

// The tool's usage when its argument count is not `want` (any count from
// want to want_max when that is given).
usage :: proc(args: []string, text: string, want: int, want_max := -1) {
	n := len(args)
	if n < want || n > max(want, want_max) {
		fail("%s", text)
	}
}

read_file :: proc(path: string) -> []u8 {
	data, err := os.read_entire_file(path, context.allocator)
	if err != nil {
		fail("%s: %v", path, err)
	}
	return data
}

write_file :: proc(path: string, data: []u8) {
	if err := os.write_entire_file(path, data); err != nil {
		fail("%s: %v", path, err)
	}
}

make_dirs :: proc(path: string) {
	if err := os.make_directory_all(path); err != nil && err != .Exist {
		fail("%s: %v", path, err)
	}
}

join :: proc(parts: ..string) -> string {
	p, _ := filepath.join(parts, context.allocator)
	return p
}

concat :: proc(parts: ..string) -> string {
	return strings.concatenate(parts)
}

parse_hex :: proc(s: string) -> u32 {
	s := s
	if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
		s = s[2:]
	}
	v, ok := strconv.parse_u64_of_base(s, 16)
	if !ok || v > 0xffffffff {
		fail("not a hex number: %s", s)
	}
	return u32(v)
}

parse_int :: proc(s: string) -> int {
	v, ok := strconv.parse_int(s, 10)
	if !ok {
		fail("not a number: %s", s)
	}
	return v
}

u16le :: #force_inline proc(d: []u8, at: int) -> u16 {
	v, _ := endian.get_u16(d[at:], .Little)
	return v
}

i16le :: #force_inline proc(d: []u8, at: int) -> i16 {
	return i16(u16le(d, at))
}

u32le :: #force_inline proc(d: []u8, at: int) -> u32 {
	v, _ := endian.get_u32(d[at:], .Little)
	return v
}

put_u16 :: #force_inline proc(d: []u8, at: int, v: u16) {
	endian.put_u16(d[at:], .Little, v)
}

put_u32 :: #force_inline proc(d: []u8, at: int, v: u32) {
	endian.put_u32(d[at:], .Little, v)
}

append_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

hex_string :: proc(digest: []u8) -> string {
	b := strings.builder_make()
	for x in digest {
		fmt.sbprintf(&b, "%02x", x)
	}
	return strings.to_string(b)
}

sha1_hex :: proc(data: []u8) -> string {
	ctx: sha1.Context
	digest: [sha1.DIGEST_SIZE]u8
	sha1.init(&ctx)
	sha1.update(&ctx, data)
	sha1.final(&ctx, digest[:])
	return hex_string(digest[:])
}

// The files under `root` as paths relative to it, joined with '/': the
// directories in path order and each one's files in name order, the order
// of Python's sorted(os.walk(root)) the tools were first written with.
walk_sorted :: proc(root: string) -> []string {
	dirs: [dynamic]string
	walk_dirs(root, "", &dirs)
	slice.sort_by(dirs[:], proc(a, b: string) -> bool {
		return dir_key(a) < dir_key(b)
	})
	files: [dynamic]string
	for dir in dirs {
		infos, err := os.read_all_directory_by_path(dir == "" ? root : join(root, dir), context.allocator)
		if err != nil {
			fail("%s: %v", join(root, dir), err)
		}
		names: [dynamic]string
		for fi in infos {
			if fi.type != .Directory {
				append(&names, fi.name)
			}
		}
		slice.sort(names[:])
		for name in names {
			append(&files, dir == "" ? name : concat(dir, "/", name))
		}
	}
	return files[:]
}

@(private = "file")
dir_key :: proc(rel: string) -> string {
	return rel == "" ? "" : concat("/", rel)
}

@(private = "file")
walk_dirs :: proc(root, rel: string, dirs: ^[dynamic]string) {
	append(dirs, rel)
	infos, err := os.read_all_directory_by_path(rel == "" ? root : join(root, rel), context.allocator)
	if err != nil {
		fail("%s: %v", join(root, rel), err)
	}
	for fi in infos {
		if fi.type == .Directory {
			walk_dirs(root, rel == "" ? fi.name : concat(rel, "/", fi.name), dirs)
		}
	}
}
