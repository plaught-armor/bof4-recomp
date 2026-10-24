// Coroutine switching on Windows: fibers. The main thread becomes a fiber
// on its first switch.
package psx

import "base:runtime"
import win "core:sys/windows"

@(private)
Co_Context :: struct {
	fiber: rawptr,
}

@(private)
co_body :: proc "system" (param: rawptr) {
	context = runtime.default_context()
	co_run((^Coroutine)(param))
}

@(private)
co_start :: proc(co: ^Coroutine) {
	co.ctx.fiber = win.CreateFiber(CO_STACK, co_body, co)
	assert(co.ctx.fiber != nil, "coroutine fiber")
}

@(private)
co_swap :: proc(from, to: ^Coroutine) {
	if from.ctx.fiber == nil {
		from.ctx.fiber = win.ConvertThreadToFiber(nil)
		assert(from.ctx.fiber != nil, "main thread fiber")
	}
	win.SwitchToFiber(to.ctx.fiber)
}

@(private)
co_free :: proc(co: ^Coroutine) {
	if co.ctx.fiber != nil {
		win.DeleteFiber(co.ctx.fiber)
	}
}
