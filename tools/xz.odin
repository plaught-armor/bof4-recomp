// xz decoding for dengeki-patch: xdelta3's LZMA secondary compression
// writes each section as an xz stream it flushes but never finishes (no
// index or footer), so this reads the stream header, the one block's header
// and then LZMA2 chunks until the input ends. Odin's core has no LZMA.
package tools

LZMA_PROB_INIT :: 1024
LZMA_STATES :: 12
LZMA_POS_STATES_MAX :: 16

@(private = "file")
Range_Decoder :: struct {
	in_:   []u8,
	pos:   int,
	range: u32,
	code:  u32,
}

@(private = "file")
rc_byte :: proc(rc: ^Range_Decoder) -> u32 {
	if rc.pos >= len(rc.in_) {
		fail("xz: truncated LZMA data")
	}
	rc.pos += 1
	return u32(rc.in_[rc.pos - 1])
}

@(private = "file")
rc_init :: proc(rc: ^Range_Decoder) {
	rc.range = 0xFFFFFFFF
	rc.code = 0
	for _ in 0 ..< 5 {
		rc.code = rc.code << 8 | rc_byte(rc)
	}
}

@(private = "file")
rc_normalize :: #force_inline proc(rc: ^Range_Decoder) {
	if rc.range < 1 << 24 {
		rc.range <<= 8
		rc.code = rc.code << 8 | rc_byte(rc)
	}
}

@(private = "file")
rc_bit :: proc(rc: ^Range_Decoder, prob: ^u16) -> int {
	bound := (rc.range >> 11) * u32(prob^)
	bit := 0
	if rc.code < bound {
		rc.range = bound
		prob^ += (2048 - prob^) >> 5
	} else {
		rc.range -= bound
		rc.code -= bound
		prob^ -= prob^ >> 5
		bit = 1
	}
	rc_normalize(rc)
	return bit
}

@(private = "file")
rc_direct :: proc(rc: ^Range_Decoder, bits: int) -> u32 {
	v: u32
	for _ in 0 ..< bits {
		rc.range >>= 1
		b: u32 = rc.code >= rc.range ? 1 : 0
		rc.code -= rc.range * b
		v = v << 1 | b
		rc_normalize(rc)
	}
	return v
}

@(private = "file")
rc_tree :: proc(rc: ^Range_Decoder, probs: []u16, bits: uint) -> int {
	m := 1
	for _ in 0 ..< bits {
		m = m << 1 | rc_bit(rc, &probs[m])
	}
	return m - 1 << bits
}

@(private = "file")
rc_reverse :: proc(rc: ^Range_Decoder, probs: []u16, bits: int) -> int {
	m, v := 1, 0
	for i in 0 ..< bits {
		b := rc_bit(rc, &probs[m])
		m = m << 1 | b
		v |= b << uint(i)
	}
	return v
}

@(private = "file")
Len_Probs :: struct {
	choice:  u16,
	choice2: u16,
	low:     [LZMA_POS_STATES_MAX][8]u16,
	mid:     [LZMA_POS_STATES_MAX][8]u16,
	high:    [256]u16,
}

@(private = "file")
Lzma :: struct {
	lc, lp, pb:  uint,
	state:       int,
	rep:         [4]int,
	is_match:    [LZMA_STATES][LZMA_POS_STATES_MAX]u16,
	is_rep:      [LZMA_STATES]u16,
	is_rep0:     [LZMA_STATES]u16,
	is_rep1:     [LZMA_STATES]u16,
	is_rep2:     [LZMA_STATES]u16,
	is_rep0_long: [LZMA_STATES][LZMA_POS_STATES_MAX]u16,
	pos_slot:    [4][64]u16,
	pos_special: [115]u16,
	align:       [16]u16,
	match_len:   Len_Probs,
	rep_len:     Len_Probs,
	literal:     [0x300 << 4]u16, // lc + lp <= 4 in LZMA2
}

@(private = "file")
lzma_reset :: proc(z: ^Lzma) {
	lc, lp, pb := z.lc, z.lp, z.pb
	probs := ([^]u16)(&z.is_match)[:(size_of(Lzma) - offset_of(Lzma, is_match)) / 2]
	for &p in probs {
		p = LZMA_PROB_INIT
	}
	z.lc, z.lp, z.pb = lc, lp, pb
	z.state = 0
	z.rep = 0
}

@(private = "file")
lzma_len :: proc(rc: ^Range_Decoder, l: ^Len_Probs, pos_state: int) -> int {
	if rc_bit(rc, &l.choice) == 0 {
		return 2 + rc_tree(rc, l.low[pos_state][:], 3)
	}
	if rc_bit(rc, &l.choice2) == 0 {
		return 10 + rc_tree(rc, l.mid[pos_state][:], 3)
	}
	return 18 + rc_tree(rc, l.high[:], 8)
}

// Decodes one LZMA2 chunk of `size` bytes onto `out`, which is also the
// dictionary.
@(private = "file")
lzma_chunk :: proc(z: ^Lzma, rc: ^Range_Decoder, out: ^[dynamic]u8, size: int) {
	end := len(out) + size
	for len(out) < end {
		pos := len(out)
		pos_state := pos & (1 << z.pb - 1)
		if rc_bit(rc, &z.is_match[z.state][pos_state]) == 0 {
			prev := pos > 0 ? int(out[pos - 1]) : 0
			lit := ((pos & (1 << z.lp - 1)) << z.lc) + prev >> (8 - z.lc)
			probs := z.literal[0x300 * lit:][:0x300]
			symbol := 1
			if z.state >= 7 {
				match := int(out[pos - z.rep[0] - 1])
				for symbol < 0x100 {
					match_bit := match >> 7 & 1
					match <<= 1
					b := rc_bit(rc, &probs[(1 + match_bit) << 8 + symbol])
					symbol = symbol << 1 | b
					if match_bit != b {
						break
					}
				}
			}
			for symbol < 0x100 {
				symbol = symbol << 1 | rc_bit(rc, &probs[symbol])
			}
			append(out, u8(symbol))
			z.state = z.state < 4 ? 0 : z.state < 10 ? z.state - 3 : z.state - 6
			continue
		}
		length: int
		if rc_bit(rc, &z.is_rep[z.state]) == 0 {
			z.rep[3], z.rep[2], z.rep[1] = z.rep[2], z.rep[1], z.rep[0]
			length = lzma_len(rc, &z.match_len, pos_state)
			z.state = z.state < 7 ? 7 : 10
			slot := rc_tree(rc, z.pos_slot[min(length - 2, 3)][:], 6)
			dist := slot
			if slot >= 4 {
				direct := slot >> 1 - 1
				dist = (2 | slot & 1) << uint(direct)
				if slot < 14 {
					dist += rc_reverse(rc, z.pos_special[dist - slot:], direct)
				} else {
					dist += int(rc_direct(rc, direct - 4)) << 4
					dist += rc_reverse(rc, z.align[:], 4)
				}
			}
			if dist == 0xFFFFFFFF {
				fail("xz: unexpected end marker")
			}
			z.rep[0] = dist
		} else {
			if rc_bit(rc, &z.is_rep0[z.state]) == 0 {
				if rc_bit(rc, &z.is_rep0_long[z.state][pos_state]) == 0 {
					z.state = z.state < 7 ? 9 : 11
					if z.rep[0] >= pos {
						fail("xz: distance past the start")
					}
					append(out, out[pos - z.rep[0] - 1])
					continue
				}
			} else {
				dist: int
				if rc_bit(rc, &z.is_rep1[z.state]) == 0 {
					dist = z.rep[1]
				} else {
					if rc_bit(rc, &z.is_rep2[z.state]) == 0 {
						dist = z.rep[2]
					} else {
						dist = z.rep[3]
						z.rep[3] = z.rep[2]
					}
					z.rep[2] = z.rep[1]
				}
				z.rep[1] = z.rep[0]
				z.rep[0] = dist
			}
			length = lzma_len(rc, &z.rep_len, pos_state)
			z.state = z.state < 7 ? 8 : 11
		}
		if z.rep[0] >= pos {
			fail("xz: distance past the start")
		}
		for _ in 0 ..< min(length, end - len(out)) {
			append(out, out[len(out) - z.rep[0] - 1])
		}
	}
}

// The data of an unfinished xz stream holding one LZMA2 block.
xz_decode :: proc(data: []u8) -> []u8 {
	if len(data) < 13 || string(data[0:6]) != "\xfd7zXZ\x00" {
		fail("xz: not an xz stream")
	}
	pos := 12 + (int(data[12]) + 1) * 4 // stream header, block header
	z := new(Lzma)
	defer free(z)
	rc := Range_Decoder{in_ = data}
	out: [dynamic]u8
	for pos < len(data) {
		control := int(data[pos])
		if control == 0 {
			break
		}
		if pos + 3 > len(data) {
			fail("xz: truncated LZMA2 chunk")
		}
		unpacked := int(data[pos + 1]) << 8 | int(data[pos + 2]) + 1
		pos += 3
		if control == 1 || control == 2 { 	// uncompressed
			if pos + unpacked > len(data) {
				fail("xz: truncated LZMA2 chunk")
			}
			append(&out, ..data[pos:pos + unpacked])
			pos += unpacked
			continue
		}
		if control < 0x80 || pos + 2 > len(data) {
			fail("xz: bad LZMA2 chunk")
		}
		unpacked += (control & 0x1f) << 16
		packed := int(data[pos]) << 8 | int(data[pos + 1]) + 1
		pos += 2
		reset := control >> 5 & 3
		if reset >= 2 {
			props := uint(data[pos])
			pos += 1
			z.lc, z.lp, z.pb = props % 9, props / 9 % 5, props / 45
			if z.lc + z.lp > 4 || z.pb > 4 {
				fail("xz: bad LZMA properties")
			}
		}
		if reset >= 1 {
			lzma_reset(z)
		}
		if pos + packed > len(data) {
			fail("xz: truncated LZMA2 chunk")
		}
		rc.in_ = data[:pos + packed]
		rc.pos = pos
		rc_init(&rc)
		lzma_chunk(z, &rc, &out, unpacked)
		pos += packed
	}
	return out[:]
}
