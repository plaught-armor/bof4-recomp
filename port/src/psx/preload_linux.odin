// Background machines on Linux: fork().
package psx

import "core:sys/posix"

foreign import libc "system:c"

@(private = "file")
PR_SET_PDEATHSIG :: 1

@(private = "file")
@(default_calling_convention = "c")
foreign libc {
	prctl :: proc(option: i32, #c_vararg args: ..any) -> i32 ---
}

// Fork a child. In the parent, returns its pid; in the child, 0. ok is
// false when the fork failed.
preload_fork :: proc() -> (pid: i32, ok: bool) {
	raster_sync()
	// The child mixes on its own thread alone, from where the parent's mix
	// stands.
	spu_sync()
	parent := posix.getpid()
	p := posix.fork()
	if p < 0 {
		return 0, false
	}
	if p == 0 {
		// End with the parent: a load left running when the game quits.
		prctl(PR_SET_PDEATHSIG, i32(posix.Signal.SIGKILL))
		if posix.getppid() != parent {
			posix._exit(0)
		}
		preload_child = true
		gl_fork_child()
		host.audio_dev = 0
		host.audio_dump = nil
		// The input record is the parent's: the child's own pad reads would
		// land in it out of order.
		record_close()
	}
	return i32(p), true
}

// End the child at once, running no exit handlers of the parent's (window,
// sound, files).
preload_exit :: proc() -> ! {
	posix._exit(0)
}

// Whether the child `pid` has ended; reaps it when it has.
preload_ended :: proc(pid: i32) -> bool {
	status: i32
	return posix.waitpid(posix.pid_t(pid), &status, {.NOHANG}) != 0
}

// Stop the child `pid` and reap it.
preload_kill :: proc(pid: i32) {
	posix.kill(posix.pid_t(pid), .SIGKILL)
	status: i32
	posix.waitpid(posix.pid_t(pid), &status, {})
}

// Memory of `size` bytes the parent and every later child share, zeroed.
preload_shared :: proc(size: int) -> rawptr {
	p := posix.mmap(nil, uint(size), {.READ, .WRITE}, {.SHARED, .ANONYMOUS}, -1, 0)
	return p == posix.MAP_FAILED ? nil : p
}
