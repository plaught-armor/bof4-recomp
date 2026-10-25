// Message box speed.
//
// The executable's text tick 0x8014c840 runs once per game tick and dispatches
// on the current box's state byte (box pointer at TEXT_BOX, handlers in the
// table at 0x80174630). The states that matter here all react to the confirm
// button's press edge (PAD_PRESSED & CONFIRM_MASK):
//
//   0  printing  : a press reveals the rest of the page at once
//   3  page end  : any press turns the page
//   7  char delay: a press ends the delay and resumes printing
//
// Choice menus and scripted waits use other states and are left alone.
//
// While the box is in one of those states this hook presents a confirm press
// to the original tick: always on printing states with `instant`, and on all
// three while confirm is held with `hold_to_advance`. The press is restored
// afterwards, so nothing else sees it. Everything runs per game tick, so the
// speed does not depend on the presentation rate.
package qol

import "core:fmt"

import "../psx"

import "ps:core"

@(private = "file")
TEXT_TICK :: 0x8014c840

@(private = "file")
PAD_HELD :: 0x80116d38 // u16 buttons held this tick

@(private = "file")
Text_State :: enum u8 {
	Printing   = 0,
	Page_End   = 3,
	Char_Delay = 7,
}

@(private = "file")
text: struct {
	original: psx.Func_Proc,
}

@(private)
text_init :: proc() -> bool {
	original, ok := psx.hook(TEXT_TICK, text_tick)
	if !ok {
		fmt.eprintf("qol: text tick %08x not found\n", TEXT_TICK)
		return false
	}
	text.original = original
	return true
}

@(private = "file")
text_tick :: proc() {
	box := psx.lw(TEXT_BOX)
	if box == 0 || !text_wants_press(Text_State(psx.lbu(box))) {
		text.original()
		return
	}
	if .Game in core.trace.active {
		core.tracef(.Game, "text: box %08x state %d, confirm pressed", box, psx.lbu(box))
	}
	pressed := psx.lhu(PAD_PRESSED)
	psx.sh(PAD_PRESSED, pressed | psx.lhu(CONFIRM_MASK))
	text.original()
	psx.sh(PAD_PRESSED, pressed)
}

@(private = "file")
text_wants_press :: proc(state: Text_State) -> bool {
	held := psx.lhu(PAD_HELD) & psx.lhu(CONFIRM_MASK) != 0
	#partial switch state {
	case .Printing, .Char_Delay:
		return config.text_instant || (config.text_hold_to_advance && held)
	case .Page_End:
		return config.text_hold_to_advance && held
	}
	return false
}
