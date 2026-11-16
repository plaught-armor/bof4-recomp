// Breath of Fire IV (SLUS-01324), statically recompiled from MIPS to Odin.
//
// The executable's code runs as recompiled procedures (package rec) on top of
// an emulated PS1 (package psx): RAM, BIOS HLE, GPU, CD-ROM, pad, timers.
package main

import "core:fmt"
import "core:os"

import "ps:core"
import "ps:core/disc"
import psx "ps:psx"
import "qol"
import "rec"

main :: proc() {
	disc_dir := len(os.args) > 1 ? os.args[1] : "../disc"
	cue := len(os.args) > 2 ? os.args[2] : "../Breath of Fire IV.cue"

	exe_path := fmt.tprintf("%s/SLUS_013.24", disc_dir)
	exe, err := os.read_entire_file(exe_path, context.allocator)
	if err != nil {
		fmt.eprintln("cannot read", exe_path)
		os.exit(1)
	}
	// Mods (ps-recomp docs/porting.md "Mods"): every subdirectory of `mods/`
	// beside bof4.ini with a mod.tsv, or of BOF4_MODS when set ("" none).
	// The port does not compile them, so they run interpreted. The disc's
	// id is what a mod's `disc` field is checked against.
	mods, mods_set := core.env_lookup("MODS")
	if !mods_set {mods = "mods"}
	disc_id := ""
	if d, opened := disc.open(cue); opened {
		disc_id, _ = disc.id(&d)
		disc.close(&d)
	}
	ok := psx.run(
		{
			exe = exe,
			disc = cue,
			title = "Breath of Fire IV",
			funcs = rec.EXE_FUNCS[:],
			overlays = rec.register_overlays,
			// Machine code built from the same recompile (its native_arch and
			// native_out options) in place of the Odin functions; on failure
			// the Odin ones stay.
			native = core.env("NATIVE_FILE"),
			cards = {"bof4_slot1.mcd", "bof4_slot2.mcd"},
			setup = qol.boot,
			hooks = qol.init,
			mods = mods,
			disc_id = disc_id,
		},
	)
	if !ok {
		os.exit(1)
	}
	fmt.eprintln("game returned from its entry point")
}
