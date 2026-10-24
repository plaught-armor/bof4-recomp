// Symmetric coroutines standing in for BIOS threads (OpenTh/ChangeTh).
//
// Recompiled code keeps MIPS call frames on the host stack, so each BIOS
// thread needs its own host stack. The coroutines all run on the host main
// thread, switching stacks with the C library's ucontext calls on Linux
// (coroutine_linux.odin) and with fibers on Windows (coroutine_windows.odin):
// the whole machine lives in one OS thread, so a fork() copy of the process
// (the background room loads, preload.odin) carries every BIOS thread with
// it.
package psx

// Host stack of a coroutine, reserved whole and committed as it is used.
@(private)
CO_STACK :: 8 << 20

Coroutine :: struct {
	ctx:     Co_Context, // the OS's switch state and stack
	entry:   proc(arg: rawptr),
	arg:     rawptr,
	started: bool,
}

// The coroutine for the host main thread's own stack.
co_main_thread: Coroutine

co_current: ^Coroutine = &co_main_thread

// The body of every coroutine but the main thread's, on its own stack.
@(private)
co_run :: proc(co: ^Coroutine) -> ! {
	co.entry(co.arg)
	panic("coroutine returned from its entry")
}

co_create :: proc(entry: proc(arg: rawptr), arg: rawptr) -> ^Coroutine {
	co := new(Coroutine)
	co.entry = entry
	co.arg = arg
	return co
}

// Transfer control from the running coroutine to `to`; returns when some
// coroutine transfers back to the caller.
co_switch :: proc(to: ^Coroutine) {
	from := co_current
	if to == from {
		return
	}
	if !to.started && to != &co_main_thread {
		to.started = true
		co_start(to)
	}
	co_current = to
	co_swap(from, to)
}

// Discard a coroutine that is not running, with its stack.
co_kill :: proc(co: ^Coroutine) {
	assert(co != co_current, "co_kill on the running coroutine")
	co_free(co)
	free(co)
}
