// Button names in the game's text that follow the device in use.
//
// The game's help lines name some buttons in plain text: "L1/L2: Scroll page
// up", "L2/R2: Change lure", "START button Pause", "Press the SELECT button".
// When the device in use is not a PlayStation pad, the string is copied with
// those names replaced (Xbox "LB", Nintendo "ZL", or the key bound to the
// button) and the copy is drawn instead. Text reaches the screen two ways:
//
// - TEXT_DRAW draws a string in one call (menus). A call that draws the
//   whole string is given the copy; the pointer it returns (where it
//   stopped) is mapped back into the original.
// - DIALOGUE_DRAW redraws the open message box every frame from its string,
//   up to the number of characters revealed so far, one TEXT_DRAW call per
//   character. The box's string and count are swapped for the copy's during
//   the call; a name is revealed whole, at its first character.
//
// The walk follows each drawer's control codes so operand bytes are never
// read as letters. Names stand alone: L1 / L2 / R1 / R2 not inside a word,
// START and SELECT only before " button" or " to", so words such as "START!"
// stay. A name that changes width moves the next run of column spaces on
// its line by as much, so "START button     Pause" keeps "Pause" in place.
package qol

import "core:fmt"
import "ps:psx"

// Message box draw; the box is at [TEXT_BOX], its string at +12 and the
// characters revealed so far at +29 (u8).
@(private = "file")
DIALOGUE_DRAW :: 0x8014c464
@(private = "file")
BOX_TEXT :: 12
@(private = "file")
BOX_SHOWN :: 29
// Sub-strings the message codes 3 / 4 / 7 draw: character names (at the
// start of a char_record, read up to NAME_SIZE bytes; code 3 takes its index
// from NAME_INDEX) and name slots (32 bytes each).
@(private = "file")
NAME_SIZE :: CHAR_RECORD_SIZE
@(private = "file")
SLOTS_AT :: 0x8011a64c
@(private = "file")
SLOT_SIZE :: 32
@(private = "file")
NAME_INDEX :: CHAR_RECORDS + 1084

// Longest copy; longer strings are drawn as they are.
@(private = "file")
COPY_MAX :: 512
// The copy sits on the emulated stack below the caller's frame, above the
// argument slots the drawers read.
@(private = "file")
COPY_AT :: 32
@(private = "file")
COPY_FRAME :: COPY_AT + COPY_MAX + 8
@(private = "file")
CODE_END :: 0
@(private = "file")
CODE_NEWLINE :: 1
@(private = "file")
SPACE :: 32
@(private = "file")
SPACE_W :: 8

@(private = "file")
Drawer :: enum u8 {
	Text,
	Dialogue,
}

// Bytes below this are control codes; the rest draw (32 is a space).
@(private = "file")
CODE_LIMIT := [Drawer]u8 {
	.Text     = 33,
	.Dialogue = 29,
}

// Operand bytes after each control code. TEXT_DRAW (jump table 0x80138948):
// 4 / 7 sub-strings, 5 colour, 0x12 / 0x13 / 0x15 icons take one, 9 and 0x19
// sub-strings two. DIALOGUE_DRAW (jump table 0x80138a40): 4 / 5 / 7 / 21 and
// the skips 10 / 12 / 15 / 16 / 20 / 28 take one, 9 / 23 / 24 / 25 two, 26
// one or four (code_size); 18 / 19 / 21 / 27 draw like characters.
@(private = "file")
OPERANDS := [Drawer][33]u8 {
	.Text = {4 = 1, 5 = 1, 7 = 1, 9 = 2, 0x12 = 1, 0x13 = 1, 0x15 = 1, 0x19 = 2},
	.Dialogue = {
		4 = 1, 5 = 1, 7 = 1, 9 = 2, 10 = 1, 12 = 1, 15 = 1, 16 = 1, 20 = 1, 21 = 1,
		23 = 2, 24 = 2, 25 = 2, 26 = 1, 28 = 1,
	},
}

@(private = "file")
Name :: struct {
	text: string,
	bit:  u16,
	// Only before " button" or " to".
	word: bool,
}

@(private = "file")
NAMES := [?]Name {
	{"L1", psx.PAD_L1, false},
	{"L2", psx.PAD_L2, false},
	{"R1", psx.PAD_R1, false},
	{"R2", psx.PAD_R2, false},
	{"START", psx.PAD_START, true},
	{"SELECT", psx.PAD_SELECT, true},
}

@(private)
button_text: struct {
	text:     psx.Func_Proc,
	dialogue: psx.Func_Proc,
	// Set while the port draws its own text.
	raw:      bool,
}

// The rewritten string and, per byte, the offset in the original it stands
// for.
@(private = "file")
Copy :: struct {
	bytes:   [COPY_MAX]u8,
	from:    [COPY_MAX]u16,
	n:       int,
	drawer:  Drawer,
	// Pixels the names on this line have added since its last column gap.
	drift:   int,
	// Elements (TEXT_DRAW) or characters (DIALOGUE_DRAW) of the original
	// and of the copy so far. A dialogue copy ends once the original's
	// `reveal` are covered, at `shown` of its own.
	drawn:   int,
	put:     int,
	reveal:  int,
	shown:   int,
	changed: bool,
	// Offset in the original just after the last name replaced.
	name_end: int,
}

@(private)
button_text_init :: proc() -> bool {
	text, text_ok := psx.hook(TEXT_DRAW, text_draw)
	dialogue, dialogue_ok := psx.hook(DIALOGUE_DRAW, dialogue_draw)
	if !text_ok || !dialogue_ok {
		fmt.eprintf("qol: text draw %08x / %08x not found\n", TEXT_DRAW, DIALOGUE_DRAW)
		return false
	}
	button_text.text = text
	button_text.dialogue = dialogue
	return true
}

@(private = "file")
rewrites :: proc() -> bool {
	return !button_text.raw && psx.input_device() != .PlayStation
}

@(private = "file")
text_draw :: proc() {
	c := &psx.cpu
	if !rewrites() {
		button_text.text()
		return
	}
	src := psx.lw(c.r[29] + 16)
	out := Copy {
		drawer = .Text,
	}
	// a3 is how many elements to draw: only whole strings are rewritten.
	if !rewrite(src, &out) || out.drawn > int(c.r[7] & 0xff) {
		button_text.text()
		return
	}
	sp := c.r[29]
	copy_at := place_copy(&out)
	psx.sw(c.r[29] + 16, copy_at)
	button_text.text()
	c.r[29] = sp
	if stop := c.r[2]; stop >= copy_at && stop < copy_at + u32(out.n) {
		c.r[2] = src + u32(out.from[stop - copy_at])
	}
}

@(private = "file")
dialogue_draw :: proc() {
	c := &psx.cpu
	box := psx.lw(TEXT_BOX)
	src := psx.lw(box + BOX_TEXT)
	shown := psx.lbu(box + BOX_SHOWN)
	if !rewrites() || shown == 0 {
		button_text.dialogue()
		return
	}
	out := Copy {
		drawer = .Dialogue,
		reveal = int(shown),
	}
	if !rewrite(src, &out) || out.shown > 0xff {
		button_text.dialogue()
		return
	}
	sp := c.r[29]
	copy_at := place_copy(&out)
	psx.sw(box + BOX_TEXT, copy_at)
	psx.sb(box + BOX_SHOWN, u32(out.shown))
	button_text.dialogue()
	c.r[29] = sp
	psx.sw(box + BOX_TEXT, src)
	psx.sb(box + BOX_SHOWN, shown)
}

// Write the copy below the stack pointer and lower it past the copy;
// returns where the copy is.
@(private = "file")
place_copy :: proc(out: ^Copy) -> u32 {
	c := &psx.cpu
	frame := (c.r[29] - COPY_FRAME) &~ 7
	copy_at := frame + COPY_AT
	for i in 0 ..< out.n {
		psx.sb(copy_at + u32(i), u32(out.bytes[i]))
	}
	c.r[29] = frame
	return copy_at
}

// Copy the string at src into out with the button names replaced; false
// when no name changed or the copy does not fit. Text copies run to the
// string's end; dialogue copies to where `reveal` characters are drawn.
@(private = "file")
rewrite :: proc(src: u32, out: ^Copy) -> bool {
	i := 0
	for {
		if out.drawer == .Dialogue && out.drawn >= out.reveal {
			return out.changed && put(out, CODE_END, i)
		}
		b := u8(psx.lbu(src + u32(i)))
		// Names and gaps are revealed whole; a sub-string a character at a
		// time.
		whole := true
		switch {
		case b == CODE_END && out.drawer == .Text:
			return out.changed && put(out, CODE_END, i)
		case b == SPACE && psx.lbu(src + u32(i) + 1) == SPACE:
			i = put_gap(out, src, i) or_return
		case b == CODE_NEWLINE:
			out.drift = 0
			fallthrough
		case b < CODE_LIMIT[out.drawer]:
			size, chars := code_size(out.drawer, src, i, b)
			for k in 0 ..< size {
				put(out, u8(psx.lbu(src + u32(i + k))), i + k) or_return
			}
			out.drawn += chars
			out.put += chars
			whole = false
			i += size
		case:
			name, used, key, found := name_at(src, i)
			switch {
			case used != "":
				i = put_name(out, src, i, name, used, key) or_return
				out.changed = true
				out.name_end = i
			case found && drop_name(out, src, i, name):
				i = out.name_end
				out.changed = true
			case:
				put(out, b, i) or_return
				out.drawn += 1
				out.put += 1
				i += 1
			}
		}
		if out.drawer == .Dialogue && out.drawn >= out.reveal {
			out.shown = whole ? out.put : out.put - (out.drawn - out.reveal)
		}
	}
}

// Bytes of the control code at i, and what it adds to the count: one
// element for TEXT_DRAW, its characters for DIALOGUE_DRAW.
@(private = "file")
code_size :: proc(drawer: Drawer, src: u32, i: int, b: u8) -> (size, chars: int) {
	size = 1 + int(OPERANDS[drawer][b])
	if drawer == .Text {
		return size, 1
	}
	switch b {
	case CODE_NEWLINE:
		return size, 0
	case 3:
		return size, string_chars(char_record(psx.lbu(NAME_INDEX)), NAME_SIZE)
	case 4:
		return size, string_chars(char_record(psx.lbu(src + u32(i) + 1)), NAME_SIZE)
	case 7:
		return size, string_chars(SLOTS_AT + psx.lbu(src + u32(i) + 1) * SLOT_SIZE, SLOT_SIZE)
	case 18, 19, 21, 27:
		return size, 1
	case 26:
		// One operand, or four unless it is 255 or already in place.
		op := psx.lbu(src + u32(i) + 1)
		if op != 0xff && psx.lbu(NAME_INDEX + (op >> 4)) != op {
			size += 3
		}
	}
	return size, 0
}

// Characters of a sub-string up to its end.
@(private = "file")
string_chars :: proc(at, size: u32) -> (n: int) {
	for k in u32(0) ..< size {
		b := psx.lbu(at + k)
		if b == CODE_END {
			break
		}
		if b >= u32(CODE_LIMIT[.Dialogue]) {
			n += 1
		}
	}
	return n
}

@(private = "file")
put :: proc(out: ^Copy, b: u8, from: int) -> bool {
	if out.n == COPY_MAX {
		return false
	}
	out.bytes[out.n] = b
	out.from[out.n] = u16(from)
	out.n += 1
	return true
}

// A run of two or more spaces at i, widened or narrowed by the line's drift;
// returns the offset after it.
@(private = "file")
put_gap :: proc(out: ^Copy, src: u32, i: int) -> (next: int, ok: bool) {
	run := 0
	for psx.lbu(src + u32(i + run)) == SPACE {
		run += 1
	}
	shift := (out.drift + (out.drift >= 0 ? SPACE_W / 2 : -SPACE_W / 2)) / SPACE_W
	out.drift = 0
	spaces := max(run - shift, 1)
	for k in 0 ..< spaces {
		put(out, SPACE, i + min(k, run - 1)) or_return
	}
	out.drawn += run
	out.put += spaces
	return i + run, true
}

// The name for the device in use: `used` replaces `name.text`, and a key
// is pressed, not a button.
@(private = "file")
put_name :: proc(out: ^Copy, src: u32, i: int, name: Name, used: string, key: bool) -> (next: int, ok: bool) {
	end := i + len(name.text)
	for k in 0 ..< len(used) {
		put(out, used[k], k == 0 ? i : end) or_return
	}
	out.drift += text_width(used) - text_width(name.text)
	out.drawn += len(name.text)
	out.put += len(used)
	BUTTON :: " button"
	if key && has_text(src, end, BUTTON) {
		KEY := " key"
		for k in 0 ..< len(KEY) {
			put(out, KEY[k], end) or_return
		}
		out.drift += text_width(KEY) - text_width(BUTTON)
		out.drawn += len(BUTTON)
		out.put += len(KEY)
		end += len(BUTTON)
	}
	return end, true
}

// Leave out a name with nothing bound to it that is half of a pair whose
// other half is, with the slash between: "Whl-Up/L2" draws "Whl-Up".
@(private = "file")
drop_name :: proc(out: ^Copy, src: u32, i: int, name: Name) -> bool {
	end := i + len(name.text)
	width := text_width(name.text) + text_width("/")
	switch {
	case out.name_end == i - 1 && out.n > 0 && out.bytes[out.n - 1] == '/':
		out.n -= 1
		out.put -= 1
	case psx.lbu(src + u32(end)) == '/':
		if _, used, _, _ := name_at(src, end + 1); used == "" {
			return false
		}
		end += 1
	case:
		return false
	}
	out.drift -= width
	out.drawn += end - i
	out.name_end = end
	return true
}

// The button name at i (found), what to draw for it and whether that is a
// key; used is "" when it stays or nothing is bound to it.
@(private = "file")
name_at :: proc(src: u32, i: int) -> (name: Name, used: string, key, found: bool) {
	if is_alnum(psx.lbu(src + u32(i) - 1)) {
		return
	}
	for n in NAMES {
		end := i + len(n.text)
		if !has_text(src, i, n.text) || is_alnum(psx.lbu(src + u32(end))) {
			continue
		}
		if n.word && !has_text(src, end, " button") && !has_text(src, end, " to ") {
			continue
		}
		used, key = device_name(n.bit)
		if used == n.text {
			return {}, "", false, false
		}
		return n, used, key, true
	}
	return
}

// What the device in use calls the console button `bit`, and whether that
// is a keyboard key; "" when nothing is bound to it.
@(private = "file")
device_name :: proc(bit: u16) -> (name: string, key: bool) {
	device := psx.input_device()
	if device == .Keyboard {
		sources: [1]string
		if psx.key_sources(bit, sources[:]) == 0 {
			return "", false
		}
		_, mouse := psx.mouse_source_from_name(sources[0])
		return short_name(sources[0]), !mouse
	}
	if c, ok := psx.pad_source(bit); ok {
		return PAD_CONTROL_NAMES[device][c], false
	}
	return "", false
}

@(private = "file")
has_text :: proc(src: u32, i: int, text: string) -> bool {
	for k in 0 ..< len(text) {
		if psx.lbu(src + u32(i + k)) != u32(text[k]) {
			return false
		}
	}
	return true
}

@(private = "file")
is_alnum :: proc(b: u32) -> bool {
	return b >= '0' && b <= '9' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z'
}

@(private = "file")
text_width :: proc(text: string) -> (w: int) {
	for i in 0 ..< len(text) {
		w += text[i] == SPACE ? SPACE_W : int(psx.lbu(FONT_WIDTHS + u32(text[i])) & 0xf)
	}
	return w
}
