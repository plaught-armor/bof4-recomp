// Memory cards in both slots, emulated at the BIOS level: the low-level
// sector calls (_card_info, _card_load, _card_read, _card_write) and the
// "bu00:" / "bu10:" file functions operate on raw 128 KiB card images, the
// same format emulators use (*.mcd / *.mcr).
//
// Slot 1 lives at BOF4_MCD (default "bof4_slot1.mcd" in the working
// directory), slot 2 at BOF4_MCD2 (default "bof4_slot2.mcd"). A missing image
// is a blank card, created on the first write. Images are rewritten after
// every change, through a temporary file so a crash mid-write cannot destroy
// existing saves.
package psx

import "core:fmt"
import "core:os"
import "core:strings"

CARD_SIZE :: 128 * 1024
@(private)
FRAME_SIZE :: 128
BLOCK_SIZE :: 8192
@(private)
CARD_BLOCKS :: 16
@(private)
MAX_FDS :: 8
// First file descriptor handed out; 0 and 1 are the BIOS console.
@(private)
FD_BASE :: 2

// Card slots, as the qol layer and the BIOS port byte (slot << 4) name them.
CARD_SLOT_1 :: 0
CARD_SLOT_2 :: 1
@(private)
CARD_SLOTS :: 2

// Directory frame states.
@(private)
DIR_FREE :: 0xa0
@(private)
DIR_FIRST :: 0x51
@(private)
DIR_MIDDLE :: 0x52
@(private)
DIR_LAST :: 0x53
@(private)
DIR_NONE :: 0xffff

// Card event classes and specs (SwCARD, HwCARD).
@(private)
EV_SWCARD :: 0xf0000011
@(private)
EV_HWCARD :: 0xf4000001
@(private)
EV_SPEC_IOE :: 0x0004
@(private)
EV_SPEC_TIMEOUT :: 0x0100

@(private)
Card_Image :: struct {
	data: [CARD_SIZE]u8,
	path: string,
}

@(private)
Card_File :: struct {
	used:  bool,
	slot:  int,
	first: int, // first data block (1..15)
	pos:   u32,
	size:  u32,
}

// Called after every read from a card file, with the file's name, the file
// offset the read began at, and the RAM it filled; the qol package uses it to
// change saves as the game loads them, leaving the card itself untouched.
card_read_hook: proc(name: string, file_pos: u32, buf: u32, length: u32)

@(private)
card: struct {
	images: [CARD_SLOTS]Card_Image,
	files:  [MAX_FDS]Card_File,
	// nextfile state: card, pattern and the directory frame to resume after.
	slot:   int,
	search: string,
	cursor: int,
}

// ---------------------------------------------------------------- image

@(private)
frame_ptr :: proc(img: ^Card_Image, n: int) -> []u8 {
	return img.data[n * FRAME_SIZE:][:FRAME_SIZE]
}

@(private)
frame_checksum :: proc(f: []u8) {
	x: u8 = 0
	for b in f[:FRAME_SIZE - 1] {
		x ~= b
	}
	f[FRAME_SIZE - 1] = x
}

@(private)
put_u16 :: proc(f: []u8, o: int, v: u16) {f[o], f[o + 1] = u8(v), u8(v >> 8)}
@(private)
put_u32 :: proc(f: []u8, o: int, v: u32) {
	put_u16(f, o, u16(v))
	put_u16(f, o + 2, u16(v >> 16))
}
@(private)
get_u16 :: proc(f: []u8, o: int) -> u16 {return u16(f[o]) | u16(f[o + 1]) << 8}
@(private)
get_u32 :: proc(f: []u8, o: int) -> u32 {return u32(get_u16(f, o)) | u32(get_u16(f, o + 2)) << 16}

// Blank formatted card: header, 15 free directory frames, empty broken
// sector list, and the write-test frame.
@(private)
card_format :: proc(img: ^Card_Image) {
	img.data = {}
	hdr := frame_ptr(img, 0)
	hdr[0], hdr[1] = 'M', 'C'
	frame_checksum(hdr)
	for n in 1 ..< CARD_BLOCKS {
		f := frame_ptr(img, n)
		put_u32(f, 0, DIR_FREE)
		put_u16(f, 8, DIR_NONE)
		frame_checksum(f)
	}
	for n in 16 ..< 36 {
		f := frame_ptr(img, n)
		put_u32(f, 0, 0xffffffff)
		put_u16(f, 8, DIR_NONE)
		frame_checksum(f)
	}
	copy(frame_ptr(img, 63), frame_ptr(img, 0))
}

// Load both card images, or start from blank ones where none exists yet.
memcard_init :: proc() -> bool {
	return card_load(&card.images[CARD_SLOT_1], "BOF4_MCD", "bof4_slot1.mcd") &&
		card_load(&card.images[CARD_SLOT_2], "BOF4_MCD2", "bof4_slot2.mcd")
}

@(private)
card_load :: proc(img: ^Card_Image, env, default_path: string) -> bool {
	img.path = os.get_env(env, context.allocator)
	if img.path == "" {
		img.path = default_path
	}
	data, err := os.read_entire_file(img.path, context.temp_allocator)
	if err != nil {
		card_format(img)
		fmt.eprintfln("memcard: %s not found, using a blank card", img.path)
		return true
	}
	if len(data) != CARD_SIZE {
		fmt.eprintfln("memcard: %s is %d bytes, expected %d", img.path, len(data), CARD_SIZE)
		return false
	}
	copy(img.data[:], data)
	return true
}

@(private)
card_save :: proc(img: ^Card_Image) -> bool {
	tmp := fmt.tprintf("%s.tmp", img.path)
	if err := os.write_entire_file(tmp, img.data[:]); err != nil {
		fmt.eprintfln("memcard: cannot write %s: %v", tmp, err)
		return false
	}
	if err := os.rename(tmp, img.path); err != nil {
		fmt.eprintfln("memcard: cannot replace %s: %v", img.path, err)
		return false
	}
	return true
}

// ---------------------------------------------------------------- low level

@(private)
card_event :: proc(spec: u32) {
	deliver_event(EV_SWCARD, spec)
	deliver_event(EV_HWCARD, spec)
}

// Port byte from _card_info/_card_load/_card_read/_card_write: 0x00 slot 1,
// 0x10 slot 2.
@(private)
card_port :: proc(port: u32) -> (img: ^Card_Image, ok: bool) {
	slot := int(port >> 4) & 0xf
	if slot >= CARD_SLOTS {
		return nil, false
	}
	return &card.images[slot], true
}

card_info :: proc(port: u32) {
	_, ok := card_port(port)
	card_event(ok ? EV_SPEC_IOE : EV_SPEC_TIMEOUT)
}

// _card_read/_card_write: one 128-byte frame; completion by event.
card_sector :: proc(port, sector, buf: u32, write: bool) -> u32 {
	img, ok := card_port(port)
	if !ok || sector >= CARD_SIZE / FRAME_SIZE {
		card_event(EV_SPEC_TIMEOUT)
		return 1
	}
	f := frame_ptr(img, int(sector))
	if write {
		copy(f, mem_slice(buf, FRAME_SIZE))
		card_save(img)
	} else {
		copy(mem_slice(buf, FRAME_SIZE), f)
	}
	card_event(EV_SPEC_IOE)
	return 1
}

// ---------------------------------------------------------------- directory

@(private)
dir_state :: proc(img: ^Card_Image, block: int) -> u32 {return get_u32(frame_ptr(img, block), 0)}

@(private)
dir_name :: proc(img: ^Card_Image, block: int) -> string {
	f := frame_ptr(img, block)[0x0a:][:21]
	n := 0
	for n < 20 && f[n] != 0 {
		n += 1
	}
	return string(f[:n])
}

// Data blocks of the file starting at `first`, in order.
@(private)
file_chain :: proc(img: ^Card_Image, first: int) -> (blocks: [CARD_BLOCKS]int, n: int) {
	b := first
	for n < CARD_BLOCKS - 1 && b >= 1 && b < CARD_BLOCKS {
		blocks[n] = b
		n += 1
		next := get_u16(frame_ptr(img, b), 8)
		if next == DIR_NONE {
			break
		}
		b = int(next) + 1
	}
	return
}

@(private)
find_file :: proc(img: ^Card_Image, name: string) -> int {
	for b in 1 ..< CARD_BLOCKS {
		if dir_state(img, b) == DIR_FIRST && dir_name(img, b) == name {
			return b
		}
	}
	return -1
}

// "bu00:NAME" -> slot 1, NAME; "bu10:NAME" -> slot 2. Other devices give
// ok=false.
@(private)
card_filename :: proc(path: string) -> (slot: int, name: string, ok: bool) {
	switch {
	case strings.has_prefix(path, "bu00:"):
		return CARD_SLOT_1, path[5:], true
	case strings.has_prefix(path, "bu10:"):
		return CARD_SLOT_2, path[5:], true
	}
	return 0, "", false
}

@(private)
wildcard_match :: proc(pattern, name: string) -> bool {
	for i in 0 ..< len(pattern) {
		switch pattern[i] {
		case '*':
			return true
		case '?':
			if i >= len(name) {
				return false
			}
		case:
			if i >= len(name) || name[i] != pattern[i] {
				return false
			}
		}
	}
	return len(pattern) == len(name)
}

// Allocate a chain of `count` free blocks named `name`; returns the first.
@(private)
create_file :: proc(img: ^Card_Image, name: string, count: int) -> int {
	free: [CARD_BLOCKS]int
	n := 0
	for b in 1 ..< CARD_BLOCKS {
		if dir_state(img, b) & 0xf0 == DIR_FREE && n < count {
			free[n] = b
			n += 1
		}
	}
	if count < 1 || n < count || len(name) > 20 {
		return -1
	}
	for k in 0 ..< count {
		f := frame_ptr(img, free[k])
		for &x in f {
			x = 0
		}
		state: u32 = k == 0 ? DIR_FIRST : (k == count - 1 ? DIR_LAST : DIR_MIDDLE)
		put_u32(f, 0, state)
		if k == 0 {
			put_u32(f, 4, u32(count * BLOCK_SIZE))
			copy(f[0x0a:], name)
		}
		put_u16(f, 8, k == count - 1 ? DIR_NONE : u16(free[k + 1] - 1))
		frame_checksum(f)
	}
	return free[0]
}

@(private)
delete_file :: proc(img: ^Card_Image, name: string) -> bool {
	first := find_file(img, name)
	if first < 0 {
		return false
	}
	blocks, n := file_chain(img, first)
	for b in blocks[:n] {
		f := frame_ptr(img, b)
		put_u32(f, 0, (get_u32(f, 0) & 0x0f) | DIR_FREE) // 0x5x -> 0xax: deleted
		frame_checksum(f)
	}
	return card_save(img)
}

// Host-side save: make `name` on the card in `slot` hold exactly `data`
// (padded with zeros to whole blocks), replacing any file of that name, and
// write the image. For saves made outside the game's own card code.
card_write_file :: proc(slot: int, name: string, data: []u8) -> bool {
	if slot < 0 || slot >= CARD_SLOTS || len(data) == 0 {
		return false
	}
	img := &card.images[slot]
	count := (len(data) + BLOCK_SIZE - 1) / BLOCK_SIZE
	first := find_file(img, name)
	if first >= 0 && int(get_u32(frame_ptr(img, first), 4)) != count * BLOCK_SIZE {
		delete_file(img, name) or_return
		first = -1
	}
	if first < 0 {
		first = create_file(img, name, count)
	}
	if first < 0 {
		fmt.eprintfln("memcard: no room for %s (%d blocks) on %s", name, count, img.path)
		return false
	}
	blocks, n := file_chain(img, first)
	for b, k in blocks[:n] {
		dst := img.data[b * BLOCK_SIZE:][:BLOCK_SIZE]
		src := data[min(k * BLOCK_SIZE, len(data)):]
		copy(dst, src)
		if len(src) < BLOCK_SIZE {
			for &x in dst[len(src):] {
				x = 0
			}
		}
	}
	return card_save(img)
}

// ---------------------------------------------------------------- file API

// B(32h) open(name, mode): bit 0 read, bit 1 write, bit 9 create with
// mode>>16 blocks. Returns a descriptor or -1.
card_open :: proc(path: string, mode: u32) -> u32 {
	slot, name, ok := card_filename(path)
	if !ok {
		return 0xffffffff
	}
	img := &card.images[slot]
	first := find_file(img, name)
	if mode & 0x200 != 0 {
		if first >= 0 {
			return 0xffffffff
		}
		first = create_file(img, name, int(mode >> 16))
		if first < 0 || !card_save(img) {
			return 0xffffffff
		}
	}
	if first < 0 {
		return 0xffffffff
	}
	for &fl, i in card.files {
		if !fl.used {
			fl = {used = true, slot = slot, first = first, size = get_u32(frame_ptr(img, first), 4)}
			return u32(FD_BASE + i)
		}
	}
	fmt.eprintln("memcard: out of file descriptors")
	return 0xffffffff
}

@(private)
card_fd :: proc(fd: u32) -> ^Card_File {
	i := int(fd) - FD_BASE
	if i < 0 || i >= MAX_FDS || !card.files[i].used {
		return nil
	}
	return &card.files[i]
}

card_close :: proc(fd: u32) -> u32 {
	fl := card_fd(fd)
	if fl == nil {
		return 0xffffffff
	}
	fl^ = {}
	return fd
}

card_seek :: proc(fd, offset, whence: u32) -> u32 {
	fl := card_fd(fd)
	if fl == nil {
		return 0xffffffff
	}
	fl.pos = whence == 1 ? fl.pos + offset : offset
	return fl.pos
}

// B(34h)/B(35h): whole frames, clipped to the file. Async opens complete
// immediately; the SwCARD event tells the game.
card_rw :: proc(fd, buf, length: u32, write: bool) -> u32 {
	fl := card_fd(fd)
	if fl == nil || fl.pos >= fl.size {
		return 0xffffffff
	}
	img := &card.images[fl.slot]
	n := min(length, fl.size - fl.pos)
	blocks, count := file_chain(img, fl.first)
	done: u32 = 0
	for done < n {
		k := int((fl.pos + done) / BLOCK_SIZE)
		if k >= count {
			break
		}
		off := blocks[k] * BLOCK_SIZE + int((fl.pos + done) % BLOCK_SIZE)
		chunk := min(n - done, BLOCK_SIZE - (fl.pos + done) % BLOCK_SIZE)
		if write {
			copy(img.data[off:][:chunk], mem_slice(buf + done, chunk))
		} else {
			copy(mem_slice(buf + done, chunk), img.data[off:][:chunk])
		}
		done += chunk
	}
	if !write && card_read_hook != nil && done > 0 {
		card_read_hook(dir_name(img, fl.first), fl.pos, buf, done)
	}
	fl.pos += done
	if write && !card_save(img) {
		card_event(EV_SPEC_TIMEOUT)
		return 0xffffffff
	}
	card_event(EV_SPEC_IOE)
	return done
}

// Fill a BIOS DIRENTRY: name[20], attr, size, next, head, system[4].
@(private)
write_direntry :: proc(img: ^Card_Image, dst: u32, block: int) {
	bios_memset(dst, 0, 40)
	name := dir_name(img, block)
	copy(mem_slice(dst, u32(len(name))), name)
	w32(dst + 0x14, 0x50)
	w32(dst + 0x18, get_u32(frame_ptr(img, block), 4))
	w32(dst + 0x20, u32(block))
}

// B(42h)/B(43h) firstfile/nextfile. Returns dst, or 0 when no more match.
card_nextfile :: proc(dst: u32, first: bool, pattern: string = "") -> u32 {
	if first {
		delete(card.search)
		card.search = ""
		slot, name, ok := card_filename(pattern)
		if !ok {
			return 0
		}
		card.slot = slot
		card.search = strings.clone(name)
		card.cursor = 0
	}
	img := &card.images[card.slot]
	for b in card.cursor + 1 ..< CARD_BLOCKS {
		if dir_state(img, b) == DIR_FIRST && wildcard_match(card.search, dir_name(img, b)) {
			card.cursor = b
			write_direntry(img, dst, b)
			return dst
		}
	}
	card.cursor = CARD_BLOCKS
	return 0
}

// B(45h) erase(name): 1 on success.
card_erase :: proc(path: string) -> u32 {
	slot, name, ok := card_filename(path)
	return ok && delete_file(&card.images[slot], name) ? 1 : 0
}
