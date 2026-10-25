// Host window presentation and pausing.
//
// The displayed area is drawn into a 640x480 logical canvas, so every PS1
// display mode keeps the console's 4:3 picture. Options set how that canvas
// reaches the window: desktop fullscreen, fit or whole-number scaling,
// and nearest or linear filtering.
//
// Pausing stops emulation between vblanks: the last frame stays on screen,
// dimmed, audio holds, and pacing restarts from the moment play resumes.
// Pause and resume with the Pause or P key or the controller's guide button,
// unless the config bound that key or button to the console pad. Alt+Enter
// and F11 toggle fullscreen. Closing the window quits; Esc is the console
// pad's Circle (input.odin).
package psx

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import sdl "vendor:sdl2"

import "ps:core"

Scale_Mode :: enum u8 {
	Fit,     // largest 4:3 picture the window holds
	Integer, // largest whole multiple of 640x480, for even pixels and lines
}

Filter :: enum u8 {
	Nearest,
	Linear,
}

// Resolution the scene is drawn at, in VRAM pixels' worth (render_scale).
Detail :: enum u8 {
	X1,
	X2,
	X4,
}

Window_Options :: struct {
	fullscreen:      bool,
	scale:           Scale_Mode,
	filter:          Filter,
	detail:          Detail,
	// Pause while the window does not have keyboard focus.
	pause_unfocused: bool,
}

@(private)
window: struct {
	opts:          Window_Options,
	paused:        bool,
	// The pause came from losing focus, so regaining it resumes.
	focus_paused:  bool,
}

// Dimming over the picture while paused (alpha, 0..255).
@(private)
PAUSE_DIM :: 96

// Real time between redraws of the paused picture.
@(private)
PAUSE_REDRAW :: 50 * time.Millisecond

window_apply :: proc(o: Window_Options) -> bool {
	window.opts = o
	if !set_fullscreen(o.fullscreen) {
		return false
	}
	if sdl.RenderSetIntegerScale(host.renderer, o.scale == .Integer) != 0 {
		fmt.eprintln("SDL_RenderSetIntegerScale:", sdl.GetError())
		return false
	}
	if !texture_filter_apply() {
		return false
	}
	render_scale = i32(1) << uint(o.detail)
	if sdl.SetRenderDrawBlendMode(host.renderer, .BLEND) != 0 {
		fmt.eprintln("SDL_SetRenderDrawBlendMode:", sdl.GetError())
		return false
	}
	return true
}

// Set the window textures' filter to the options'.
@(private)
texture_filter_apply :: proc() -> bool {
	mode: sdl.ScaleMode = window.opts.filter == .Linear ? .Linear : .Nearest
	if sdl.SetTextureScaleMode(host.texture, mode) != 0 || sdl.SetTextureScaleMode(host.held, mode) != 0 {
		fmt.eprintln("SDL_SetTextureScaleMode:", sdl.GetError())
		return false
	}
	return true
}

// The options in effect, including fullscreen as last toggled.
window_options :: proc() -> Window_Options {
	return window.opts
}

@(private)
set_fullscreen :: proc(on: bool) -> bool {
	flags := on ? sdl.WINDOW_FULLSCREEN_DESKTOP : sdl.WindowFlags{}
	if sdl.SetWindowFullscreen(host.window, flags) != 0 {
		fmt.eprintln("SDL_SetWindowFullscreen:", sdl.GetError())
		return false
	}
	window.opts.fullscreen = on
	return true
}

// A feature's keys (the qol package's map editor), tried before the window's;
// reports whether the key was used.
key_hook: proc(k: sdl.KeyboardEvent) -> bool

// Window keys: fullscreen, pause and the debug snapshot. Reports whether the key was used.
@(private)
window_key :: proc(k: sdl.KeyboardEvent) -> bool {
	if k.repeat != 0 {
		return false
	}
	sc := k.keysym.scancode
	alt := k.keysym.mod & sdl.KMOD_ALT != {}
	if sc == .F11 || (sc == .RETURN && alt) {
		// A failed toggle leaves the window as it was; the error is printed.
		set_fullscreen(!window.opts.fullscreen)
		return true
	}
	if sc == .F12 && core.input.keys[sc] == {} {
		snapshot_request()
		return true
	}
	if (sc == .PAUSE || sc == .P) && core.input.keys[sc] == {} {
		set_paused(!window.paused, false)
		return true
	}
	return false
}

@(private)
window_button :: proc(b: sdl.GameControllerButton) {
	if b == .GUIDE && core.input.buttons[b] == {} {
		set_paused(!window.paused, false)
	}
}

@(private)
window_event :: proc(w: sdl.WindowEvent) {
	#partial switch w.event {
	case .FOCUS_LOST:
		mouse_focus(false, w.timestamp)
		if window.opts.pause_unfocused && !host.unpaced && !window.paused {
			set_paused(true, true)
		}
	case .FOCUS_GAINED:
		mouse_focus(true, w.timestamp)
		if window.focus_paused {
			set_paused(false, false)
		}
	}
}

@(private)
set_paused :: proc(on: bool, from_focus: bool) {
	window.paused = on
	window.focus_paused = on && from_focus
	if on {
		rumble_stop()
		mouse_release()
	}
	if core.audio.dev != 0 {
		sdl.PauseAudioDevice(core.audio.dev, sdl.bool(on))
	}
	if .Perf in core.trace.active {
		core.tracef(.Perf, "paused %v", on)
	}
}

// Hold emulation while paused, redrawing the dimmed picture; returns at once
// when not paused. Pacing restarts from the resume.
@(private)
pause_wait :: proc() {
	if !window.paused {
		return
	}
	draw()
	if host.dump_window {
		dump_window_picture("pause")
	}
	for window.paused && !host.quit {
		runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
		draw()
		time.sleep(PAUSE_REDRAW)
		poll_events()
	}
	pacing_rebase()
}

// Draw the current texture (or a held picture, and after the hold that
// picture fading out over it) with the window options, the pause dimming
// and the on-screen display. With vsync on a 120 or 240 Hz display the
// picture is presented once for each of the vblank's refreshes.
@(private)
draw :: proc() {
	compose()
	osd_draw()
	if host.dump_window && !window.paused && core.dump_due(host.presents) {
		dump_window_picture("window")
	}
	snapshot_take()
	if !preload_child && core.capture_wanted(host.presents) {
		if pix, w, h, ok := window_pixels(); ok {
			core.capture_frame(pix, w, h, host.presents)
		}
	}
	sdl.RenderPresent(host.renderer)
	gl_shown()
	for _ in 1 ..< (host.vsync ? host.vsync_shows : 1) {
		// The back buffer is undefined after a present: draw it again.
		compose()
		osd_draw()
		sdl.RenderPresent(host.renderer)
		gl_shown()
	}
}

// The window's picture under the on-screen display.
@(private)
compose :: proc() {
	sdl.SetRenderDrawColor(host.renderer, 0, 0, 0, 255)
	sdl.RenderClear(host.renderer)
	if host.holding {
		sdl.SetTextureAlphaMod(host.held, 255)
		sdl.RenderCopy(host.renderer, host.held, &host.held_area, nil)
	} else if display.enabled && display.w > 0 && display.h > 0 {
		fw, fh := frame_size()
		src := sdl.Rect{0, 0, fw, fh}
		sdl.SetTextureAlphaMod(host.texture, 255)
		sdl.RenderCopy(host.renderer, host.texture, &src, nil)
		if host.fade > 0 {
			// Eased both ends (smoothstep), so neither picture pops.
			t := f32(host.fade) / (HOLD_FADE + 1)
			sdl.SetTextureAlphaMod(host.held, u8(255 * t * t * (3 - 2 * t)))
			sdl.RenderCopy(host.renderer, host.held, &host.held_area, nil)
		}
	}
	if window.paused {
		sdl.SetRenderDrawColor(host.renderer, 0, 0, 0, PAUSE_DIM)
		sdl.RenderFillRect(host.renderer, nil)
	}
}

// Debug aid for BOF4_DUMP_WINDOW: save the window's back buffer, as drawn
// with every option, to <BOF4_DUMP>/<kind>_<presents>.ppm.
@(private)
dump_window_picture :: proc(kind: string) {
	pix, w, h, ok := window_pixels()
	if !ok {
		return
	}
	core.dump_ppm(kind, host.presents, int(w), int(h), pix)
}

// The window's back buffer as tightly packed RGB888, in temp memory.
@(private)
window_pixels :: proc() -> (pix: []u8, w, h: i32, ok: bool) {
	if sdl.GetRendererOutputSize(host.renderer, &w, &h) != 0 {
		fmt.eprintln("SDL_GetRendererOutputSize:", sdl.GetError())
		return
	}
	pix = make([]u8, int(w * h * 3), context.temp_allocator)
	if sdl.RenderReadPixels(host.renderer, nil, u32(sdl.PixelFormatEnum.RGB24), raw_data(pix), w * 3) != 0 {
		fmt.eprintln("SDL_RenderReadPixels:", sdl.GetError())
		return
	}
	return pix, w, h, true
}
