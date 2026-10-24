// Background machines on Windows: none, as there is no fork(). Callers treat
// a failed preload_fork as "no background load" and carry on.
package psx

import win "core:sys/windows"

preload_fork :: proc() -> (pid: i32, ok: bool) {
	return 0, false
}

preload_exit :: proc() -> ! {
	win.ExitProcess(0)
}

preload_ended :: proc(pid: i32) -> bool {
	return true
}

preload_kill :: proc(pid: i32) {
}

// Zeroed memory of `size` bytes; with no children it is only the parent's.
preload_shared :: proc(size: int) -> rawptr {
	return win.VirtualAlloc(nil, uint(size), win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_READWRITE)
}
