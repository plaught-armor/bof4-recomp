// Breath of Fire IV (SLUS-01324), statically recompiled from MIPS to Odin.
//
// The executable's code runs as recompiled procedures (package rec) on top of
// an emulated PS1 (package psx): RAM, BIOS HLE, GPU, CD-ROM, pad, timers.
package main

import "core:fmt"
import "core:os"

import "psx"
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
	pc, gp, sp, ok := psx.load_exe(exe)
	if !ok {
		fmt.eprintln("not a PS-X EXE:", exe_path)
		os.exit(1)
	}
	if !psx.cdrom_open(cue) {
		os.exit(1)
	}
	if !psx.trace_init() {
		os.exit(1)
	}
	if !qol.boot() {
		os.exit(1)
	}
	if !psx.platform_init("Breath of Fire IV") {
		os.exit(1)
	}

	psx.register_funcs(rec.EXE_FUNCS[:])
	rec.register_overlays()
	if !qol.init() {
		os.exit(1)
	}
	psx.events_init()
	psx.spu_init()
	psx.xa_init()
	psx.timers_init()
	psx.dma_init()
	psx.bios_init()
	if !psx.memcard_init() {
		os.exit(1)
	}

	psx.cpu.r[28] = gp
	psx.cpu.r[29] = sp
	psx.cpu.r[30] = sp
	psx.cop0.sr = 0x40000401
	psx.call(pc)
	fmt.eprintln("game returned from its entry point")
}
