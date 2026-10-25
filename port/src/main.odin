// Breath of Fire IV (SLUS-01324), statically recompiled from MIPS to Odin.
//
// The executable's code runs as recompiled procedures (package rec) on top of
// an emulated PS1 (package psx): RAM, BIOS HLE, GPU, CD-ROM, pad, timers.
package main

import "core:fmt"
import "core:os"

import bios "ps:psx/bios"
import cpu "ps:psx/cpu"
import host "ps:psx/host"
import io "ps:psx/io"
import spu "ps:psx/spu"
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
	pc, gp, sp, ok := cpu.load_exe(exe)
	if !ok {
		fmt.eprintln("not a PS-X EXE:", exe_path)
		os.exit(1)
	}
	if !spu.cdrom_open(cue) {
		os.exit(1)
	}
	if !cpu.trace_init() {
		os.exit(1)
	}
	if !qol.boot() {
		os.exit(1)
	}
	if !host.platform_init("Breath of Fire IV") {
		os.exit(1)
	}

	cpu.register_funcs(rec.EXE_FUNCS[:])
	rec.register_overlays()
	if !qol.init() {
		os.exit(1)
	}
	io.events_init()
	spu.spu_init()
	spu.xa_init()
	io.timers_init()
	io.dma_init()
	bios.bios_init()
	bios.card_files = {"bof4_slot1.mcd", "bof4_slot2.mcd"}
	if !bios.memcard_init() {
		os.exit(1)
	}

	cpu.state.r[28] = gp
	cpu.state.r[29] = sp
	cpu.state.r[30] = sp
	cpu.cop0.sr = 0x40000401
	cpu.call(pc)
	fmt.eprintln("game returned from its entry point")
}
