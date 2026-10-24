// PNG writer for the debug pictures (snapshots, sprite dumps, floor maps):
// Odin's core reads PNG but cannot write it, and has no deflate compressor.
//
// Each row takes the filter (none, sub, up, average, Paeth) whose output has
// the smallest sum of absolute bytes, the usual PNG heuristic. The filtered
// rows go out as one zlib stream of fixed-Huffman deflate blocks: LZ77 over
// a 32 KB window, a hash of the next 3 bytes heading a chain of earlier
// positions, the longest of the first CHAIN tried kept, and a match
// put off by one byte when the next position has a longer one (lazy
// matching). Debug pictures are flat colour and repeated tiles, which long
// matches carry; the dynamic Huffman tables would save little more.
package png

import "base:intrinsics"
import "core:hash"
import "core:os"

@(private = "file")
WINDOW :: 32768

@(private = "file")
HASH_BITS :: 15

// Earlier positions tried per match.
@(private = "file")
CHAIN :: 16

@(private = "file")
MIN_MATCH :: 3

@(private = "file")
MAX_MATCH :: 258

@(private = "file")
LEN_BASE := [29]u16{3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258}

@(private = "file")
LEN_EXTRA := [29]u8{0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0}

@(private = "file")
DIST_BASE := [30]u16{1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577}

@(private = "file")
DIST_EXTRA := [30]u8{0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13}

// Lookups built on the first write: the fixed Huffman code of each literal
// and length symbol (bit-reversed, as deflate sends codes first bit first),
// the length code of each match length and the distance code of each
// distance.
@(private = "file")
tables: struct {
	built:     bool,
	lit_code:  [288]u16,
	lit_bits:  [288]u8,
	len_index: [MAX_MATCH + 1]u8,
	dist_low:  [256]u8, // distance code of distances 1..256, by distance - 1
	dist_high: [256]u8, // of distances 257..32768, by (distance - 1) >> 7
}

@(private = "file")
reverse :: proc(code: u16, bits: u8) -> u16 {
	r: u16
	for i in 0 ..< bits {
		r = r << 1 | (code >> i) & 1
	}
	return r
}

@(private = "file")
build_tables :: proc() {
	t := &tables
	for s in 0 ..< 288 {
		code, bits: u16
		switch {
		case s < 144:
			code, bits = u16(0x30 + s), 8
		case s < 256:
			code, bits = u16(0x190 + s - 144), 9
		case s < 280:
			code, bits = u16(s - 256), 7
		case:
			code, bits = u16(0xc0 + s - 280), 8
		}
		t.lit_code[s] = reverse(code, u8(bits))
		t.lit_bits[s] = u8(bits)
	}
	for i in 0 ..< len(LEN_BASE) {
		hi := i + 1 < len(LEN_BASE) ? int(LEN_BASE[i + 1]) : MAX_MATCH + 1
		for n in int(LEN_BASE[i]) ..< hi {
			t.len_index[n] = u8(i)
		}
	}
	for i in 0 ..< len(DIST_BASE) {
		hi := i + 1 < len(DIST_BASE) ? int(DIST_BASE[i + 1]) : WINDOW + 1
		for d in int(DIST_BASE[i]) ..< hi {
			if d <= 256 {
				t.dist_low[d - 1] = u8(i)
			} else {
				t.dist_high[(d - 1) >> 7] = u8(i)
			}
		}
	}
	t.built = true
}

// Deflate's bit order: the first bit sent is the lowest of the first byte.
@(private = "file")
Bits :: struct {
	out:  ^[dynamic]u8,
	acc:  u64,
	used: u32,
}

@(private = "file")
put :: #force_inline proc(b: ^Bits, value: u32, bits: u8) {
	b.acc |= u64(value) << b.used
	b.used += u32(bits)
	for b.used >= 8 {
		append(b.out, u8(b.acc))
		b.acc >>= 8
		b.used -= 8
	}
}

@(private = "file")
literal :: #force_inline proc(b: ^Bits, s: int) {
	put(b, u32(tables.lit_code[s]), tables.lit_bits[s])
}

@(private = "file")
match :: #force_inline proc(b: ^Bits, length, dist: int) {
	t := &tables
	li := int(t.len_index[length])
	literal(b, 257 + li)
	if LEN_EXTRA[li] > 0 {
		put(b, u32(length - int(LEN_BASE[li])), LEN_EXTRA[li])
	}
	di := int(dist <= 256 ? t.dist_low[dist - 1] : t.dist_high[(dist - 1) >> 7])
	// Distance codes are all 5 bits in the fixed code.
	put(b, u32(reverse(u16(di), 5)), 5)
	if DIST_EXTRA[di] > 0 {
		put(b, u32(dist - int(DIST_BASE[di])), DIST_EXTRA[di])
	}
}

@(private = "file")
hash3 :: #force_inline proc(data: []u8, i: int) -> u32 {
	v := u32(data[i]) | u32(data[i + 1]) << 8 | u32(data[i + 2]) << 16
	return (v * 2654435761) >> (32 - HASH_BITS)
}

// Length of the common run of data[a:] and data[b:], at most `limit`.
@(private = "file")
common :: #force_inline proc(data: []u8, a, b, limit: int) -> int #no_bounds_check {
	n := 0
	for n + 8 <= limit {
		x := (^u64le)(&data[a + n])^ ~ (^u64le)(&data[b + n])^
		if x != 0 {
			return n + int(intrinsics.count_trailing_zeros(u64(x)) >> 3)
		}
		n += 8
	}
	for n < limit && data[a + n] == data[b + n] {
		n += 1
	}
	return n
}

// The longest earlier match for position i: (length, distance), length 0
// when none reaches MIN_MATCH.
@(private = "file")
longest :: proc(data: []u8, i: int, head, prev: []i32) -> (best, dist: int) #no_bounds_check {
	limit := min(MAX_MATCH, len(data) - i)
	if limit < MIN_MATCH {
		return 0, 0
	}
	at := int(head[hash3(data, i)])
	for tries := 0; at >= 0 && i - at <= WINDOW && tries < CHAIN; tries += 1 {
		if data[at + best] == data[i + best] {
			if n := common(data, at, i, limit); n > best {
				best, dist = n, i - at
				if n == limit {
					break
				}
			}
		}
		at = int(prev[at % WINDOW])
	}
	if best < MIN_MATCH {
		return 0, 0
	}
	return
}

@(private = "file")
insert :: #force_inline proc(data: []u8, i: int, head, prev: []i32) #no_bounds_check {
	if i + MIN_MATCH <= len(data) {
		h := hash3(data, i)
		prev[i % WINDOW] = head[h]
		head[h] = i32(i)
	}
}

// A zlib stream of `data` (one final fixed-Huffman block) appended to out.
@(private = "file")
deflate :: proc(out: ^[dynamic]u8, data: []u8) {
	if !tables.built {
		build_tables()
	}
	head := make([]i32, 1 << HASH_BITS, context.temp_allocator)
	prev := make([]i32, WINDOW, context.temp_allocator)
	for &h in head {
		h = -1
	}
	append(out, 0x78, 0x01) // deflate, 32 KB window, fastest-level check bits
	b := Bits{out = out}
	put(&b, 1, 1) // final block
	put(&b, 1, 2) // fixed Huffman codes
	i := 0
	for i < len(data) {
		length, dist := longest(data, i, head, prev)
		if length > 0 && i + 1 < len(data) {
			// Lazy: a longer match one byte on wins over this one.
			insert(data, i, head, prev)
			next, next_dist := longest(data, i + 1, head, prev)
			if next > length {
				literal(&b, int(data[i]))
				i += 1
				length, dist = next, next_dist
			} else {
				match(&b, length, dist)
				for k in i + 1 ..< i + length {
					insert(data, k, head, prev)
				}
				i += length
				continue
			}
		}
		if length > 0 {
			match(&b, length, dist)
			for k in i ..< i + length {
				insert(data, k, head, prev)
			}
			i += length
		} else {
			insert(data, i, head, prev)
			literal(&b, int(data[i]))
			i += 1
		}
	}
	literal(&b, 256) // end of block
	if b.used > 0 {
		append(out, u8(b.acc))
	}
	adler := hash.adler32(data)
	append(out, u8(adler >> 24), u8(adler >> 16), u8(adler >> 8), u8(adler))
}

@(private = "file")
paeth :: #force_inline proc(a, b, c: u8) -> u8 {
	p := int(a) + int(b) - int(c)
	pa, pb, pc := abs(p - int(a)), abs(p - int(b)), abs(p - int(c))
	if pa <= pb && pa <= pc {
		return a
	}
	return pb <= pc ? b : c
}

// Row y of pix filtered by `kind` into row (1 + stride bytes, the kind
// first); returns the sum of the output bytes taken as signed.
@(private = "file")
filter :: proc(row, pix: []u8, y, stride, channels, kind: int) -> int #no_bounds_check {
	cur := pix[y * stride:][:stride]
	row[0] = u8(kind)
	out := row[1:]
	sum := 0
	for x in 0 ..< stride {
		a := x >= channels ? cur[x - channels] : 0
		b := y > 0 ? pix[(y - 1) * stride + x] : 0
		c := x >= channels && y > 0 ? pix[(y - 1) * stride + x - channels] : 0
		pred: u8
		switch kind {
		case 1:
			pred = a
		case 2:
			pred = b
		case 3:
			pred = u8((int(a) + int(b)) >> 1)
		case 4:
			pred = paeth(a, b, c)
		}
		v := cur[x] - pred
		out[x] = v
		sum += abs(int(i8(v)))
	}
	return sum
}

@(private = "file")
chunk :: proc(out: ^[dynamic]u8, kind: string, data: []u8) {
	n := u32(len(data))
	append(out, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	start := len(out)
	append(out, kind)
	append(out, ..data)
	crc := hash.crc32(out[start:])
	append(out, u8(crc >> 24), u8(crc >> 16), u8(crc >> 8), u8(crc))
}

// Write pix (w x h, `channels` bytes a pixel: 3 RGB or 4 RGBA, rows top
// first) to `path` as a PNG. Returns false when the file cannot be written.
write :: proc(path: string, pix: []u8, w, h, channels: int) -> bool {
	assert(channels == 3 || channels == 4, "png: RGB or RGBA only")
	stride := w * channels
	assert(len(pix) >= stride * h, "png: picture smaller than its size")
	filtered := make([]u8, (stride + 1) * h, context.temp_allocator)
	trial := make([]u8, stride + 1, context.temp_allocator)
	for y in 0 ..< h {
		row := filtered[y * (stride + 1):][:stride + 1]
		best := filter(row, pix, y, stride, channels, 0)
		for kind in 1 ..= 4 {
			if s := filter(trial, pix, y, stride, channels, kind); s < best {
				best = s
				copy(row, trial)
			}
		}
	}
	z := make([dynamic]u8, 0, len(filtered) / 4 + 1024, context.temp_allocator)
	deflate(&z, filtered)
	out := make([dynamic]u8, 0, len(z) + 64, context.temp_allocator)
	append(&out, "\x89PNG\r\n\x1a\n")
	ihdr := [13]u8{
		u8(w >> 24), u8(w >> 16), u8(w >> 8), u8(w),
		u8(h >> 24), u8(h >> 16), u8(h >> 8), u8(h),
		8, channels == 4 ? 6 : 2, 0, 0, 0, // 8 bits, RGBA or RGB, deflate, adaptive filters, no interlace
	}
	chunk(&out, "IHDR", ihdr[:])
	chunk(&out, "IDAT", z[:])
	chunk(&out, "IEND", nil)
	return os.write_entire_file(path, out[:]) == nil
}
