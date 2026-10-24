// Put a raw Breath of Fire IV save into a PS1 memory card image (.mcd).
//
// A raw save is the 0x1880-byte file the game writes: 0x180-byte card
// header, then the game region; byte 0x184f is the XOR of every byte before
// it. The Windows release stores saves in exactly this form (BOF4-NN.DAT),
// so its saves load in the port, as do saves extracted from other card
// images.
//
// The save is stored as BASLUS-01324BOF4<NN>US, NN = save number - 1, the
// name the US game's load screen lists as that number. A missing card image
// is created blank; an existing save of the same number is replaced.
package tools

import "core:fmt"
import "core:os"
import "core:strings"

SAVE_TO_MCD_USAGE :: "Usage: bof4tools save-to-mcd <save.dat> <card.mcd> <save number 1-15>"

CARD_SIZE :: 128 * 1024
FRAME :: 128
CARD_BLOCK :: 0x2000
CARD_BLOCKS :: 16
SAVE_SIZE :: 0x1880
SAVE_CHECKSUM :: 0x184F
DIR_FREE :: 0xA0
DIR_FIRST :: 0x51
DIR_NONE :: 0xFFFF

xor_bytes :: proc(data: []u8) -> u8 {
	x: u8
	for b in data {
		x ~= b
	}
	return x
}

// Writes frame n's checksum byte.
seal :: proc(card: []u8, n: int) {
	f := n * FRAME
	card[f + FRAME - 1] = xor_bytes(card[f:f + FRAME - 1])
}

put_dir :: proc(card: []u8, n: int, state, size: u32) {
	put_u32(card, n * FRAME, state)
	put_u32(card, n * FRAME + 4, size)
	put_u16(card, n * FRAME + 8, DIR_NONE)
}

blank_card :: proc() -> []u8 {
	card := make([]u8, CARD_SIZE)
	copy(card, "MC")
	seal(card, 0)
	for n in 1 ..< CARD_BLOCKS {
		put_dir(card, n, DIR_FREE, 0)
		seal(card, n)
	}
	for n in 16 ..< 36 {
		put_dir(card, n, 0xFFFFFFFF, 0)
		seal(card, n)
	}
	copy(card[63 * FRAME:64 * FRAME], card[0:FRAME])
	return card
}

dir_name :: proc(card: []u8, n: int) -> string {
	name := string(card[n * FRAME + 0x0A:n * FRAME + 0x1E])
	if nul := strings.index_byte(name, 0); nul >= 0 {
		name = name[:nul]
	}
	return name
}

// The block to hold `name`: its current block, or the first free one.
free_block :: proc(card: []u8, name: string) -> int {
	for n in 1 ..< CARD_BLOCKS {
		if u32le(card, n * FRAME) == DIR_FIRST && dir_name(card, n) == name {
			if u32le(card, n * FRAME + 4) != CARD_BLOCK {
				fail("%s already exists with more than one block", name)
			}
			return n
		}
	}
	for n in 1 ..< CARD_BLOCKS {
		if u32le(card, n * FRAME) & 0xF0 == DIR_FREE {
			return n
		}
	}
	fail("card is full")
}

save_to_mcd_main :: proc(args: []string) {
	usage(args, SAVE_TO_MCD_USAGE, 3)
	save := read_file(args[0])
	number := parse_int(args[2])
	if number < 1 || number > 15 {
		fail("save number must be 1-15")
	}
	if len(save) != SAVE_SIZE {
		fail("save is %d bytes, expected %d", len(save), SAVE_SIZE)
	}
	if xor_bytes(save[:SAVE_CHECKSUM]) != save[SAVE_CHECKSUM] {
		fail("save checksum does not match; file is damaged or not a BoF4 save")
	}
	path := args[1]
	card := os.exists(path) ? read_file(path) : blank_card()
	if len(card) != CARD_SIZE || string(card[0:2]) != "MC" {
		fail("%s is not a 128 KiB raw card image", path)
	}
	name := fmt.aprintf("BASLUS-01324BOF4%02dUS", number - 1)
	n := free_block(card, name)
	frame := card[n * FRAME:(n + 1) * FRAME]
	for &b in frame {
		b = 0
	}
	put_dir(card, n, DIR_FIRST, CARD_BLOCK)
	copy(frame[0x0A:], name)
	seal(card, n)
	block := card[n * CARD_BLOCK:(n + 1) * CARD_BLOCK]
	copy(block, save)
	for &b in block[SAVE_SIZE:] {
		b = 0
	}
	tmp := concat(path, ".tmp")
	write_file(tmp, card)
	if err := os.rename(tmp, path); err != nil {
		fail("%s: %v", path, err)
	}
	print("%s: block %d holds %s", path, n, name)
}
