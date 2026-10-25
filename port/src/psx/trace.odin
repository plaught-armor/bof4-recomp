// The trace lines that need the CPU's registers; tracing itself lives in
// ps:core (core/trace.odin).
package psx

import "ps:core"

trace_init :: proc() -> bool {
	return core.trace_init(&host.presents, &cpu.cycles)
}

// Recompiled code: entered the block at pc.
trace_block :: proc(pc: u32) {
	if !core.trace_pc_ok(pc) {
		return
	}
	r := &cpu.r
	core.tracef(.Block, "%08x v0=%x v1=%x a0=%x a1=%x a2=%x a3=%x t0=%x s0=%x sp=%x ra=%x",
		pc, r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[16], r[29], r[31])
}

// Called from the store path only when core.trace.watching is set.
trace_store :: proc(a, v, size: u32) {
	if core.trace_watched(a, size) {
		core.tracef(.Mem, "store%d [%08x] = %x ra=%x", size * 8, a, v, cpu.r[31])
	}
}
