// Build the Dengeki Store Restoration v1.0 files for the port.
//
// <patch dir> is the "dengeki store v1.0" folder of the fan patch
// (Navarchos, Ratty, FlamePurge), <disc dir> the extracted disc (holds
// BIN/WORLD), <out dir> the port's dengeki/ folder. Writes AREAD068.EMI and
// AREAS052.EMI with the English text. The patch's Windows programs are not
// run: this does what its pipeline does, read from their code:
//
// - resources/*.xdelta are VCDIFF (RFC 3284) deltas with xdelta3's LZMA
//   secondary compression, decoded here (xz.odin).
// - AREAD068: AREAD068.EMI.xdelta, then AREAD068_palette.xdelta on the
//   result (adds a 64-byte colour table entry before the last entry).
// - AREAS052: AREAS052.EMI.xdelta, then dengeki_transfer0.exe's step: a 14th
//   entry (type 3, VRAM texture, 0x1800 bytes) cut from AREAM000.EMI, 0x20
//   and 0x10 rows of 0x14 bytes at 0xa6028 and 0xa7028 (row stride 0x40),
//   each written as 4 zero bytes, the row twice, 0x14 zero bytes.
// - dengeki_transfer1.exe moves the disc's later files in the executable's
//   file table (+1 sector after AREAD068, +3 after AREAS052) to make room;
//   the port serves both files past the disc's end instead
//   (qol/dengeki.odin).
package tools

import "core:hash"

DENGEKI_PATCH_USAGE :: "Usage: bof4tools dengeki-patch <patch dir> <disc dir> <out dir>"

// One half of an instruction code: kind 1 ADD, 2 COPY, 3 RUN, 0 none.
Vc_Inst :: struct {
	kind, size, mode: u8,
}

// The RFC 3284 default instruction code table.
vc_code_table :: proc() -> [256][2]Vc_Inst {
	t: [256][2]Vc_Inst
	n := 0
	add :: proc(t: ^[256][2]Vc_Inst, n: ^int, a: Vc_Inst, b: Vc_Inst = {}) {
		t[n^] = {a, b}
		n^ += 1
	}
	add(&t, &n, {3, 0, 0})
	add(&t, &n, {1, 0, 0})
	for s in u8(1) ..< 18 {
		add(&t, &n, {1, s, 0})
	}
	for m in u8(0) ..< 9 {
		add(&t, &n, {2, 0, m})
		for s in u8(4) ..< 19 {
			add(&t, &n, {2, s, m})
		}
	}
	for m in u8(0) ..< 6 {
		for a in u8(1) ..< 5 {
			for c in u8(4) ..< 7 {
				add(&t, &n, {1, a, 0}, {2, c, m})
			}
		}
	}
	for m in u8(6) ..< 9 {
		for a in u8(1) ..< 5 {
			add(&t, &n, {1, a, 0}, {2, 4, m})
		}
	}
	for m in u8(0) ..< 9 {
		add(&t, &n, {2, 4, m}, {1, 1, 0})
	}
	assert(n == 256)
	return t
}

Vc_Reader :: struct {
	data: []u8,
	pos:  int,
}

vc_byte :: proc(r: ^Vc_Reader) -> int {
	if r.pos >= len(r.data) {
		fail("dengeki_patch: truncated VCDIFF data")
	}
	r.pos += 1
	return int(r.data[r.pos - 1])
}

vc_var :: proc(r: ^Vc_Reader) -> int {
	v := 0
	for {
		c := vc_byte(r)
		v = v << 7 | c & 0x7f
		if c & 0x80 == 0 {
			return v
		}
	}
}

vc_take :: proc(r: ^Vc_Reader, n: int) -> []u8 {
	if n < 0 || r.pos + n > len(r.data) {
		fail("dengeki_patch: truncated VCDIFF data")
	}
	r.pos += n
	return r.data[r.pos - n:r.pos]
}

vc_secondary :: proc(section: []u8) -> []u8 {
	r := Vc_Reader{data = section}
	size := vc_var(&r)
	out := xz_decode(section[r.pos:])
	if len(out) != size {
		fail("dengeki_patch: bad secondary section")
	}
	return out
}

vcdiff :: proc(source, patch: []u8) -> []u8 {
	codes := vc_code_table()
	r := Vc_Reader{data = patch}
	if string(vc_take(&r, 4)) != "\xd6\xc3\xc4\x00" {
		fail("dengeki_patch: not a VCDIFF file")
	}
	flags := vc_byte(&r)
	if flags & 1 != 0 {
		vc_byte(&r) // secondary compressor id (2, LZMA)
	}
	if flags & 2 != 0 {
		fail("dengeki_patch: custom code tables are not supported")
	}
	if flags & 4 != 0 {
		vc_take(&r, vc_var(&r)) // xdelta3 application header (file names)
	}
	out: [dynamic]u8
	for r.pos < len(r.data) {
		win := vc_byte(&r)
		seg: []u8
		if win & 3 != 0 {
			length, at := vc_var(&r), vc_var(&r)
			from := win & 1 != 0 ? source : out[:]
			if at + length > len(from) {
				fail("dengeki_patch: source segment out of range")
			}
			seg = from[at:at + length]
		}
		vc_var(&r) // delta encoding length
		target_len := vc_var(&r)
		compressed := vc_byte(&r)
		lens := [3]int{vc_var(&r), vc_var(&r), vc_var(&r)}
		adler: []u8
		if win & 4 != 0 {
			adler = vc_take(&r, 4) // xdelta3 extension
		}
		sections: [3][]u8
		for &s, k in sections {
			s = vc_take(&r, lens[k])
			if compressed & (1 << uint(k)) != 0 {
				s = vc_secondary(s)
			}
		}
		d, i, a := Vc_Reader{data = sections[0]}, Vc_Reader{data = sections[1]}, Vc_Reader{data = sections[2]}
		near: [4]int
		same: [768]int
		next_near := 0
		target: [dynamic]u8
		for i.pos < len(i.data) {
			for inst in codes[vc_byte(&i)] {
				if inst.kind == 0 {
					continue
				}
				size := int(inst.size)
				if size == 0 {
					size = vc_var(&i)
				}
				switch inst.kind {
				case 1:
					append(&target, ..vc_take(&d, size))
				case 3:
					b := u8(vc_byte(&d))
					for _ in 0 ..< size {
						append(&target, b)
					}
				case:
					here := len(seg) + len(target)
					mode := int(inst.mode)
					at: int
					switch {
					case mode == 0:
						at = vc_var(&a)
					case mode == 1:
						at = here - vc_var(&a)
					case mode < 6:
						at = near[mode - 2] + vc_var(&a)
					case:
						at = same[(mode - 6) * 256 + vc_byte(&a)]
					}
					near[next_near] = at
					next_near = (next_near + 1) % 4
					same[at % 768] = at
					for k in at ..< at + size {
						if k < 0 || k - len(seg) >= len(target) {
							fail("dengeki_patch: copy out of range")
						}
						append(&target, k < len(seg) ? seg[k] : target[k - len(seg)])
					}
				}
			}
		}
		if len(target) != target_len {
			fail("dengeki_patch: bad window length")
		}
		if adler != nil {
			want := u32(adler[0]) << 24 | u32(adler[1]) << 16 | u32(adler[2]) << 8 | u32(adler[3])
			if hash.adler32(target[:]) != want {
				fail("dengeki_patch: checksum mismatch (not the US disc?)")
			}
		}
		append(&out, ..target[:])
		delete(target)
	}
	return out[:]
}

// dengeki_transfer0.exe: append entry 14 to the store's EMI.
add_texture :: proc(store, m000: []u8) -> []u8 {
	out: [dynamic]u8
	append(&out, ..store[:0xe0])
	for v in ([]u32{0x1800, 0x1e080200, 0, 0x2e2e0003}) {
		append_u32(&out, v)
	}
	append(&out, ..store[0xf0:0x800])
	at := 0x800
	for i in 0 ..< 13 {
		size := int(u32le(store, (i + 1) * 16) + 0x7ff) &~ 0x7ff
		append(&out, ..store[at:min(at + size, len(store))])
		at += size
	}
	zero: [0x800]u8
	for part in ([][3]int{{0xa6028, 0x20, 0x800}, {0xa7028, 0x10, 0x400}}) {
		start, rows, pad := part[0], part[1], part[2]
		for k in 0 ..< rows {
			row := m000[start + k * 0x40:][:0x14]
			append(&out, ..zero[:4])
			append(&out, ..row)
			append(&out, ..row)
			append(&out, ..zero[:0x14])
		}
		append(&out, ..zero[:pad])
	}
	out[0] = 14
	return out[:]
}

dengeki_patch_main :: proc(args: []string) {
	usage(args, DENGEKI_PATCH_USAGE, 3)
	res := join(args[0], "resources")
	world := join(args[1], "BIN", "WORLD")
	out_dir := args[2]
	d068 := vcdiff(read_file(join(world, "AREAD068.EMI")), read_file(join(res, "AREAD068.EMI.xdelta")))
	d068 = vcdiff(d068, read_file(join(res, "AREAD068_palette.xdelta")))
	s052 := vcdiff(read_file(join(world, "AREAS052.EMI")), read_file(join(res, "AREAS052.EMI.xdelta")))
	s052 = add_texture(s052, read_file(join(world, "AREAM000.EMI")))
	make_dirs(out_dir)
	for f in ([]struct {
			name: string,
			data: []u8,
		}{{"AREAD068.EMI", d068}, {"AREAS052.EMI", s052}}) {
		path := join(out_dir, f.name)
		write_file(path, f.data)
		print("%s %d", path, len(f.data))
	}
}
