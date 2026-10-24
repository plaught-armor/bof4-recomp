// XA-ADPCM: real-time audio sectors (read with mode bit 6 set) are decoded
// here into a ring of stereo frames, then resampled to 44100 Hz and passed
// through the CD-ROM volume matrix as the SPU's CD audio input.
package psx

@(private)
XA_RING :: 1 << 15

@(private)
xa: struct {
	ring:       [XA_RING][2]i16,
	// Frames written and read; the difference is the fill level.
	head, tail: u32,
	// Prediction history per channel: old, older.
	hist:       [2][2]i32,
	rate:       u32,
	// Resampler phase in output-rate units, and the two frames it is between.
	phase:      u32,
	prev, cur:  [2]i32,
	// Setfilter (command 0x0d) file and channel.
	file, chan: u8,
	// Demute/Mute (commands 0x0c/0x0b).
	muted:      bool,
	// CD-ROM volume matrix: L->L, L->R, R->R, R->L. Writes land in
	// `pending` and take effect when the game sets the apply bit.
	pending:    [4]u8,
	atv:        [4]u8,
	adpcm_mute: bool,
}

xa_init :: proc() {
	spu_sync()
	xa.rate = 37800
	xa.pending = {0x80, 0, 0x80, 0}
	xa.atv = xa.pending
}

xa_set_filter :: proc(file, chan: u8) {
	xa.file, xa.chan = file, chan
}

xa_set_muted :: proc(muted: bool) {
	spu_sync()
	xa.muted = muted
}

// Volume register writes: i is the matrix slot; apply copies them live.
xa_set_volume :: proc(i: int, v: u8) {
	xa.pending[i] = v
}

xa_apply :: proc(v: u8) {
	spu_sync()
	if .Cdrom in trace.active {
		tracef(.Cdrom, "xa volume apply %02x pending %x", v, xa.pending)
	}
	xa.adpcm_mute = v & 1 != 0
	if v & 0x20 != 0 {
		xa.atv = xa.pending
	}
}

// Decode one 2352-byte real-time audio sector.
xa_sector :: proc(s: []u8) {
	file, chan, coding := s[16], s[17], s[19]
	if cd.mode & 0x08 != 0 && (file != xa.file || chan != xa.chan) {
		return
	}
	spu_sync()
	if .Cdrom in trace.active {
		tracef(.Cdrom, "xa file %d chan %d coding %02x fill %d", file, chan, coding, xa.head - xa.tail)
	}
	if xa.adpcm_mute {
		return
	}
	stereo := coding & 0x01 != 0
	eight := coding & 0x10 != 0
	xa.rate = coding & 0x04 != 0 ? 18900 : 37800
	units := eight ? 4 : 8
	for g in 0 ..< 18 {
		group := s[24 + g * 128:][:128]
		if stereo {
			for u := 0; u < units; u += 2 {
				l := xa_unit(group, u, eight, 0)
				r := xa_unit(group, u + 1, eight, 1)
				for i in 0 ..< 28 {
					xa_push({l[i], r[i]})
				}
			}
		} else {
			for u in 0 ..< units {
				m := xa_unit(group, u, eight, 0)
				for i in 0 ..< 28 {
					xa_push({m[i], m[i]})
				}
			}
		}
	}
}

@(private)
xa_push :: proc(f: [2]i16) {
	if xa.head - xa.tail >= XA_RING {
		xa.tail += 1 // overrun: drop the oldest frame
	}
	xa.ring[xa.head & (XA_RING - 1)] = f
	xa.head += 1
}

@(private)
xa_unit :: proc(group: []u8, u: int, eight: bool, ch: int) -> (out: [28]i16) {
	hdr := group[4 + u]
	shift := u32(hdr & 0xf)
	if shift > 12 {
		shift = 9
	}
	f := int(hdr >> 4) & 3
	h := &xa.hist[ch]
	for j in 0 ..< 28 {
		raw: i32
		if eight {
			raw = i32(i16(u16(group[16 + j * 4 + u]) << 8))
		} else {
			b := group[16 + j * 4 + u / 2]
			raw = i32(i16(u16((b >> (4 * u32(u & 1))) & 0xf) << 12))
		}
		v := (raw >> shift) + ((h[0] * ADPCM_POS[f] + h[1] * ADPCM_NEG[f] + 32) >> 6)
		v = clamp(v, -0x8000, 0x7fff)
		h[1], h[0] = h[0], v
		out[j] = i16(v)
	}
	return
}

// One 44100 Hz frame of CD audio after the volume matrix.
xa_sample :: proc() -> [2]i32 {
	xa.phase += xa.rate
	for xa.phase >= 44100 {
		xa.phase -= 44100
		xa.prev = xa.cur
		if xa.head == xa.tail {
			xa.cur = {}
		} else {
			f := xa.ring[xa.tail & (XA_RING - 1)]
			xa.tail += 1
			xa.cur = {i32(f[0]), i32(f[1])}
		}
	}
	if xa.muted {
		return {}
	}
	t := i32(xa.phase)
	l := xa.prev[0] + (xa.cur[0] - xa.prev[0]) * t / 44100
	r := xa.prev[1] + (xa.cur[1] - xa.prev[1]) * t / 44100
	a := xa.atv
	return {
		clamp((l * i32(a[0]) + r * i32(a[3])) >> 7, -0x8000, 0x7fff),
		clamp((r * i32(a[2]) + l * i32(a[1])) >> 7, -0x8000, 0x7fff),
	}
}
