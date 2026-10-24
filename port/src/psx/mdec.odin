// MDEC (0x1f801820/0x1f801824): macroblock decoder for FMV. Decoding happens
// as soon as a decode command has all its input; output words queue up for
// reads and DMA1, which waits when the game asks before data exists.
package psx


@(private)
mdec: struct {
	// Command being assembled: header word, then its parameter words.
	cmd:       u32,
	need:      u32,
	input:     [dynamic]u16,
	table:     [dynamic]u32,
	output:    [dynamic]u32,
	out_pos:   int,
	quant_y:   [64]u8,
	quant_uv:  [64]u8,
	scale:     [64]i16,
	ctrl:      u32,
	// Channel 1 started before its output existed.
	out_waiting: bool,
	// Present count at the last decode command, to tell a movie is playing.
	last_decode: u64,
}

// Vblanks after the last decode during which a movie counts as playing.
@(private)
MOVIE_GRACE :: 30

@(private)
ZIGZAG := [64]u8 {
	0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5,
	12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28,
	35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51,
	58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63,
}

mdec_read_data :: proc() -> u32 {
	if mdec.out_pos >= len(mdec.output) {
		return 0
	}
	v := mdec.output[mdec.out_pos]
	mdec.out_pos += 1
	return v
}

mdec_read_status :: proc() -> u32 {
	s: u32 = 0
	if mdec.out_pos >= len(mdec.output) {
		s |= 1 << 31
	}
	if mdec.need > 0 {
		s |= 1 << 29
	}
	if mdec.ctrl & (1 << 30) != 0 {
		s |= 1 << 28
	}
	if mdec.ctrl & (1 << 29) != 0 && mdec.out_pos < len(mdec.output) {
		s |= 1 << 27
	}
	s |= ((mdec.cmd >> 25) & 0xf) << 23
	s |= 4 << 16
	s |= (mdec.need - 1) & 0xffff
	return s
}

mdec_write_ctrl :: proc(v: u32) {
	if v & (1 << 31) != 0 {
		mdec.need = 0
		mdec.cmd = 0
		clear(&mdec.input)
		clear(&mdec.table)
		clear(&mdec.output)
		mdec.out_pos = 0
		mdec.out_waiting = false
	}
	mdec.ctrl = v & 0x60000000
}

mdec_write_cmd :: proc(v: u32) {
	if mdec.need == 0 {
		mdec_start(v)
		return
	}
	switch mdec.cmd >> 29 {
	case 1:
		append(&mdec.input, u16(v), u16(v >> 16))
	case:
		append(&mdec.table, v)
	}
	mdec.need -= 1
	if mdec.need == 0 {
		mdec_complete()
	}
}

@(private)
mdec_start :: proc(v: u32) {
	mdec.cmd = v
	switch v >> 29 {
	case 1:
		mdec.last_decode = host.presents
		mdec.need = v & 0xffff
		clear(&mdec.input)
		// Output left over from the previous frame (decoded padding) is
		// never read; drop it so this frame starts at the FIFO head.
		clear(&mdec.output)
		mdec.out_pos = 0
	case 2:
		mdec.need = v & 1 != 0 ? 32 : 16
		clear(&mdec.table)
	case 3:
		mdec.need = 32
		clear(&mdec.table)
	case:
		mdec.need = 0
	}
}

@(private)
mdec_complete :: proc() {
	switch mdec.cmd >> 29 {
	case 1:
		mdec_decode()
	case 2:
		for i in 0 ..< 64 {
			mdec.quant_y[i] = u8(mdec.table[i / 4] >> (8 * u32(i % 4)))
		}
		if len(mdec.table) == 32 {
			for i in 0 ..< 64 {
				mdec.quant_uv[i] = u8(mdec.table[16 + i / 4] >> (8 * u32(i % 4)))
			}
		}
	case 3:
		for i in 0 ..< 64 {
			mdec.scale[i] = i16(mdec.table[i / 2] >> (16 * u32(i % 2)))
		}
	}
}

dma_mdec_in :: proc(c: ^Dma_Channel) {
	n := dma_words(c)
	a := c.madr & 0x1ffffc
	for _ in 0 ..< n {
		mdec_write_cmd(r32(a))
		a += 4
	}
}

// Copy decoded words to RAM. Returns false when the output does not exist
// yet; the channel then completes from mdec_decode.
dma_mdec_out :: proc(c: ^Dma_Channel) -> bool {
	n := int(dma_words(c))
	if len(mdec.output) - mdec.out_pos < n {
		mdec.out_waiting = true
		return false
	}
	mdec.out_waiting = false
	a := c.madr & 0x1ffffc
	for _ in 0 ..< n {
		w32(a, mdec.output[mdec.out_pos])
		mdec.out_pos += 1
		a += 4
	}
	return true
}

// ---------------------------------------------------------------- decoding

@(private)
Mdec_Reader :: struct {
	src: []u16,
	pos: int,
}

@(private)
signed10 :: #force_inline proc(v: u16) -> i32 {
	return (i32(v & 0x3ff) ~ 0x200) - 0x200
}

// Run-length decode and dequantize one 8x8 block, then inverse-transform it.
// Returns false when the input runs out.
@(private)
mdec_block :: proc(rd: ^Mdec_Reader, blk: ^[64]i32, qt: ^[64]u8) -> bool {
	blk^ = {}
	n: u16 = 0xfe00
	for n == 0xfe00 {
		if rd.pos >= len(rd.src) {
			return false
		}
		n = rd.src[rd.pos]
		rd.pos += 1
	}
	q := i32(n >> 10)
	k := 0
	val := signed10(n) * i32(qt[0])
	for {
		if q == 0 {
			val = signed10(n) * 2
		}
		val = clamp(val, -0x400, 0x3ff)
		blk[q > 0 ? int(ZIGZAG[k]) : k] = val
		if rd.pos >= len(rd.src) {
			break
		}
		n = rd.src[rd.pos]
		rd.pos += 1
		k += int(n >> 10) + 1
		if k > 63 {
			break
		}
		val = (signed10(n) * i32(qt[k]) * q + 4) / 8
	}
	mdec_idct(blk)
	return true
}

@(private)
mdec_idct :: proc(blk: ^[64]i32) {
	tmp: [64]i32
	src, dst := blk, &tmp
	for _ in 0 ..< 2 {
		for x in 0 ..< 8 {
			for y in 0 ..< 8 {
				sum: i32 = 0
				for z in 0 ..< 8 {
					sum += src[y + z * 8] * (i32(mdec.scale[x + z * 8]) / 8)
				}
				dst[x + y * 8] = (sum + 0xfff) >> 13
			}
		}
		src, dst = dst, src
	}
}

@(private)
mdec_decode :: proc() {
	depth := (mdec.cmd >> 27) & 3
	rd := Mdec_Reader {
		src = mdec.input[:],
	}
	for {
		if depth >= 2 {
			if !mdec_color_block(&rd, depth) {
				break
			}
		} else if !mdec_mono_block(&rd, depth) {
			break
		}
	}
	if mdec.out_waiting {
		c := &dma.ch[1]
		if dma_mdec_out(c) {
			dma_finish(1)
		}
	}
}

@(private)
mdec_color_block :: proc(rd: ^Mdec_Reader, depth: u32) -> bool {
	cr, cb, y: [64]i32
	if !mdec_block(rd, &cr, &mdec.quant_uv) || !mdec_block(rd, &cb, &mdec.quant_uv) {
		return false
	}
	rgb: [256][3]u8
	offsets := [4][2]int{{0, 0}, {8, 0}, {0, 8}, {8, 8}}
	for o in offsets {
		if !mdec_block(rd, &y, &mdec.quant_y) {
			return false
		}
		mdec_yuv(&rgb, &cr, &cb, &y, o[0], o[1])
	}
	mdec_emit(&rgb, depth)
	return true
}

@(private)
mdec_yuv :: proc(rgb: ^[256][3]u8, cr, cb, yb: ^[64]i32, xx, yy: int) {
	unsigned := mdec.cmd & (1 << 26) == 0
	for y in 0 ..< 8 {
		for x in 0 ..< 8 {
			ci := (x + xx) / 2 + ((y + yy) / 2) * 8
			r := f32(cr[ci])
			b := f32(cb[ci])
			g := -0.3437 * b - 0.7143 * r
			l := f32(yb[x + y * 8])
			px := [3]i32 {
				clamp(i32(l + 1.402 * r), -128, 127),
				clamp(i32(l + g), -128, 127),
				clamp(i32(l + 1.772 * b), -128, 127),
			}
			out := &rgb[(x + xx) + (y + yy) * 16]
			for c in 0 ..< 3 {
				out[c] = unsigned ? u8(px[c] ~ 0x80) : u8(px[c])
			}
		}
	}
}

@(private)
mdec_emit :: proc(rgb: ^[256][3]u8, depth: u32) {
	if depth == 2 {
		// 24-bit: 768 bytes packed little-endian into 192 words.
		bytes := ([^]u8)(&rgb[0][0])[:768]
		for i := 0; i < 768; i += 4 {
			append(&mdec.output, u32(bytes[i]) | u32(bytes[i + 1]) << 8 | u32(bytes[i + 2]) << 16 | u32(bytes[i + 3]) << 24)
		}
		return
	}
	bit15: u32 = mdec.cmd & (1 << 25) != 0 ? 0x8000 : 0
	for i := 0; i < 256; i += 2 {
		lo := u32(rgb[i][0] >> 3) | u32(rgb[i][1] >> 3) << 5 | u32(rgb[i][2] >> 3) << 10 | bit15
		hi := u32(rgb[i + 1][0] >> 3) | u32(rgb[i + 1][1] >> 3) << 5 | u32(rgb[i + 1][2] >> 3) << 10 | bit15
		append(&mdec.output, lo | hi << 16)
	}
}

// Monochrome: one Y block per 8x8 output, 4- or 8-bit.
@(private)
mdec_mono_block :: proc(rd: ^Mdec_Reader, depth: u32) -> bool {
	y: [64]i32
	if !mdec_block(rd, &y, &mdec.quant_y) {
		return false
	}
	unsigned := mdec.cmd & (1 << 26) == 0
	px: [64]u8
	for i in 0 ..< 64 {
		v := clamp(y[i], -128, 127)
		px[i] = unsigned ? u8(v ~ 0x80) : u8(v)
	}
	if depth == 1 {
		for i := 0; i < 64; i += 4 {
			append(&mdec.output, u32(px[i]) | u32(px[i + 1]) << 8 | u32(px[i + 2]) << 16 | u32(px[i + 3]) << 24)
		}
		return true
	}
	for i := 0; i < 64; i += 8 {
		w: u32 = 0
		for k in 0 ..< 8 {
			w |= u32(px[i + k] >> 4) << (4 * u32(k))
		}
		append(&mdec.output, w)
	}
	return true
}

// A movie decoded a frame recently. Its disc stream is paced by the drive and
// must play in real time.
movie_playing :: proc() -> bool {
	return mdec.last_decode != 0 && host.presents - mdec.last_decode < MOVIE_GRACE
}
