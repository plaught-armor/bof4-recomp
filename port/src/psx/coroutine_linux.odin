// Coroutine switching on Linux: the C library's ucontext calls, on stacks
// mapped with the raw syscall.
package psx

import "base:runtime"
import "core:sys/linux"

// glibc's ucontext_t on x86-64 is 968 bytes; uc_link and uc_stack sit at
// the offsets below.
@(private)
UCONTEXT_SIZE :: 1024
@(private)
UC_LINK :: 8
@(private)
UC_STACK_SP :: 16
@(private)
UC_STACK_SIZE :: 32

@(private)
Ucontext :: struct #align (16) {
	raw: [UCONTEXT_SIZE]u8,
}

@(private)
Co_Context :: struct {
	uc:    Ucontext,
	stack: rawptr,
}

foreign import libc "system:c"

@(private)
@(default_calling_convention = "c")
foreign libc {
	getcontext :: proc(ucp: ^Ucontext) -> i32 ---
	makecontext :: proc(ucp: ^Ucontext, func: proc "c" (), argc: i32, #c_vararg args: ..any) ---
	swapcontext :: proc(oucp, ucp: ^Ucontext) -> i32 ---
}

// The coroutine whose stack co_body starts on: makecontext passes no
// pointer portably.
@(private)
co_starting: ^Coroutine

@(private)
co_body :: proc "c" () {
	context = runtime.default_context()
	co_run(co_starting)
}

// Give `co` its stack and a context that enters co_body on it.
@(private)
co_start :: proc(co: ^Coroutine) {
	stack, err := linux.mmap(0, CO_STACK, {.READ, .WRITE}, {.PRIVATE, .ANONYMOUS})
	assert(err == .NONE, "coroutine stack")
	co.ctx.stack = stack
	getcontext(&co.ctx.uc)
	(^rawptr)(&co.ctx.uc.raw[UC_LINK])^ = nil
	(^rawptr)(&co.ctx.uc.raw[UC_STACK_SP])^ = stack
	(^uint)(&co.ctx.uc.raw[UC_STACK_SIZE])^ = CO_STACK
	co_starting = co
	makecontext(&co.ctx.uc, co_body, 0)
}

@(private)
co_swap :: proc(from, to: ^Coroutine) {
	swapcontext(&from.ctx.uc, &to.ctx.uc)
}

@(private)
co_free :: proc(co: ^Coroutine) {
	if co.ctx.stack != nil {
		linux.munmap(co.ctx.stack, CO_STACK)
	}
}
