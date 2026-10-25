// Background machines (not a PS1 feature): fork() copies the whole process,
// so a child carries the machine exactly as it stood, BIOS threads and all
// (ps:core coroutines keep them in one OS thread for this). The qol package
// forks a child to play the game on ahead out of sight, e.g. to load a room
// the party has not visited yet, and the child hands back what it found in
// memory shared with the parent, then exits. The parent plays on meanwhile.
//
// A child shows nothing, plays no sound and reads no input: its vblanks only
// count presents and run vblank_hook, and the pad and sticks read as
// released. It draws on its own thread alone (the raster pool's threads are
// not copied by fork), and never writes the replay or dump files.
//
// Linux forks (preload_linux.odin). Windows has no fork: preload_fork always
// fails there (preload_windows.odin), so rooms load when the party enters
// them, as on the PS1.
package psx

// True in a forked child.
preload_child: bool

// A child's vblank: count it and let the qol package follow the game.
@(private)
preload_frame :: proc() {
	host.presents += 1
	if hold_picture > 0 {
		hold_picture -= 1
	}
	if vblank_hook != nil {
		vblank_hook()
	}
}
