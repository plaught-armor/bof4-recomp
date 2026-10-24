// Runtime tracing, always compiled in and selected by environment variables:
//
//   BOF4_TRACE=io,irq,sio      channels to log (or "all"); see Trace_Channel
//   BOF4_TRACE_AT=10000-10003  only while the present count is in this range
//   BOF4_TRACE_PC=80171500-80171900  limit block/call/interp lines to a PC range
//   BOF4_TRACE_FILE=path       write there instead of stderr
//   BOF4_WATCH=80116d0c[-80116d10]  log every CPU store into the range (mem)
//
// Each line is "<present> <cycles> <channel> <message>". Call sites guard
// with `if .X in trace.active` so disabled channels cost one bit test and
// the format arguments are never evaluated.
package psx

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

Trace_Channel :: enum u8 {
	Io,     // every hardware register access
	Irq,    // raise, acknowledge, delivery
	Event,  // device scheduler events
	Sio,    // controller/memory card serial bytes
	Timer,  // root counter writes and target/overflow
	Dma,    // channel starts and completions
	Cdrom,  // commands, responses, sector reads
	Gpu,    // GP1 writes and GP0 command opcodes
	Bios,   // A/B/C function calls
	Call,   // every host-level call (target, ra, sp)
	Block,  // every recompiled basic block entered
	Interp, // every interpreted instruction
	Mem,    // stores into the BOF4_WATCH range
	Perf,   // host speed every PERF_PERIOD presents
	Qol,    // decisions taken by quality-of-life hooks
}

trace: struct {
	// Channels live right now: `wanted` gated by the present window.
	active:   bit_set[Trace_Channel],
	wanted:   bit_set[Trace_Channel],
	from, to: u64,
	pc_lo:    u32,
	pc_hi:    u32,
	watch_lo: u32,
	watch_hi: u32,
	// Fast check for the store path: watch range set and Mem active.
	watching: bool,
	out:      ^os.File,
	buf:      strings.Builder,
}

@(private)
TRACE_FLUSH_AT :: 1 << 16

@(private)
parse_hex_range :: proc(spec: string) -> (lo, hi: u64, ok: bool) {
	parts := strings.split(spec, "-", context.temp_allocator)
	lo = strconv.parse_u64(parts[0], 16) or_return
	hi = lo
	if len(parts) > 1 {
		hi = strconv.parse_u64(parts[1], 16) or_return
	}
	return lo, hi, true
}

@(private)
parse_dec_range :: proc(spec: string) -> (lo, hi: u64, ok: bool) {
	parts := strings.split(spec, "-", context.temp_allocator)
	lo = strconv.parse_u64(parts[0], 10) or_return
	hi = max(u64)
	if len(parts) > 1 {
		hi = strconv.parse_u64(parts[1], 10) or_return
	}
	return lo, hi, true
}

@(private)
parse_channels :: proc(spec: string) -> (set: bit_set[Trace_Channel], ok: bool) {
	ok = true
	for name in strings.split(spec, ",", context.temp_allocator) {
		if name == "all" {
			set = ~{}
			continue
		}
		found := false
		for ch in Trace_Channel {
			if strings.equal_fold(name, fmt.tprint(ch)) {
				set += {ch}
				found = true
			}
		}
		if !found {
			fmt.eprintln("BOF4_TRACE: unknown channel", name)
			ok = false
		}
	}
	return
}

// Read the BOF4_TRACE* variables. Returns false on a malformed setting.
trace_init :: proc() -> bool {
	trace.out = os.stderr
	trace.to = max(u64)
	trace.pc_hi = max(u32)
	strings.builder_init(&trace.buf)
	ok := true
	if spec := os.get_env("BOF4_TRACE", context.temp_allocator); spec != "" {
		trace.wanted, ok = parse_channels(spec)
	}
	if spec := os.get_env("BOF4_TRACE_AT", context.temp_allocator); spec != "" {
		lo, hi, good := parse_dec_range(spec)
		if !good {
			fmt.eprintln("BOF4_TRACE_AT: expected <from>[-<to>]:", spec)
			ok = false
		}
		trace.from, trace.to = lo, hi
	}
	if spec := os.get_env("BOF4_TRACE_PC", context.temp_allocator); spec != "" {
		lo, hi, good := parse_hex_range(spec)
		if !good {
			fmt.eprintln("BOF4_TRACE_PC: expected <hex>[-<hex>]:", spec)
			ok = false
		}
		trace.pc_lo, trace.pc_hi = u32(lo), u32(hi)
	}
	if spec := os.get_env("BOF4_WATCH", context.temp_allocator); spec != "" {
		lo, hi, good := parse_hex_range(spec)
		if !good {
			fmt.eprintln("BOF4_WATCH: expected <hex>[-<hex>]:", spec)
			ok = false
		}
		trace.watch_lo, trace.watch_hi = u32(lo) & 0x1fffffff, u32(hi) & 0x1fffffff
		trace.wanted += {.Mem}
	}
	if path := os.get_env("BOF4_TRACE_FILE", context.temp_allocator); path != "" {
		f, err := os.create(path)
		if err != nil {
			fmt.eprintln("BOF4_TRACE_FILE: cannot create", path, err)
			return false
		}
		trace.out = f
	}
	trace_window()
	return ok
}

// Re-evaluate the present window; called once per present.
trace_window :: proc() {
	in_window := host.presents >= trace.from && host.presents <= trace.to
	trace.active = in_window ? trace.wanted : {}
	trace.watching = .Mem in trace.active && trace.watch_hi != 0
	trace_flush()
}

trace_flush :: proc() {
	if strings.builder_len(trace.buf) == 0 {
		return
	}
	_, err := os.write(trace.out, trace.buf.buf[:])
	if err != nil {
		fmt.eprintln("trace: write failed:", err)
		trace.wanted = {}
		trace.active = {}
	}
	strings.builder_reset(&trace.buf)
}

tracef :: proc(ch: Trace_Channel, format: string, args: ..any) {
	fmt.sbprintf(&trace.buf, "%d %d %v ", host.presents, cpu.cycles, ch)
	fmt.sbprintfln(&trace.buf, format, ..args)
	if strings.builder_len(trace.buf) >= TRACE_FLUSH_AT {
		trace_flush()
	}
}

@(private)
trace_pc_ok :: #force_inline proc(pc: u32) -> bool {
	return pc >= trace.pc_lo && pc <= trace.pc_hi
}

// Recompiled code: entered the block at pc.
trace_block :: proc(pc: u32) {
	if !trace_pc_ok(pc) {
		return
	}
	r := &cpu.r
	tracef(.Block, "%08x v0=%x v1=%x a0=%x a1=%x a2=%x a3=%x t0=%x s0=%x sp=%x ra=%x",
		pc, r[2], r[3], r[4], r[5], r[6], r[7], r[8], r[16], r[29], r[31])
}

// Called from the store path only when trace.watching is set.
trace_store :: proc(a, v, size: u32) {
	p := a & 0x1fffffff
	if p + size <= trace.watch_lo || p > trace.watch_hi {
		return
	}
	tracef(.Mem, "store%d [%08x] = %x ra=%x", size * 8, a, v, cpu.r[31])
}
