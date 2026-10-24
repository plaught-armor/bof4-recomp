// SPU reverb: the hardware's comb/all-pass network running at 22050 Hz over
// a work area in sound RAM from mBASE (0x1a2) to the end. Register names
// follow the nocash documentation; addresses are in 8-byte units.
package psx

@(private)
Reverb_Reg :: enum u32 {
	dAPF1 = 0x1c0, dAPF2 = 0x1c2, vIIR = 0x1c4,
	vCOMB1 = 0x1c6, vCOMB2 = 0x1c8, vCOMB3 = 0x1ca, vCOMB4 = 0x1cc,
	vWALL = 0x1ce, vAPF1 = 0x1d0, vAPF2 = 0x1d2,
	mLSAME = 0x1d4, mRSAME = 0x1d6, mLCOMB1 = 0x1d8, mRCOMB1 = 0x1da,
	mLCOMB2 = 0x1dc, mRCOMB2 = 0x1de, dLSAME = 0x1e0, dRSAME = 0x1e2,
	mLDIFF = 0x1e4, mRDIFF = 0x1e6, mLCOMB3 = 0x1e8, mRCOMB3 = 0x1ea,
	mLCOMB4 = 0x1ec, mRCOMB4 = 0x1ee, dLDIFF = 0x1f0, dRDIFF = 0x1f2,
	mLAPF1 = 0x1f4, mRAPF1 = 0x1f6, mLAPF2 = 0x1f8, mRAPF2 = 0x1fa,
	vLIN = 0x1fc, vRIN = 0x1fe,
}

@(private)
SPUCNT_REVERB :: 0x0080

@(private)
reverb: struct {
	// Current work-area position in bytes.
	pos: u32,
	// 44100 Hz sample parity: the network runs on every other sample.
	odd: bool,
	out: [2]i32,
}

@(private)
rv :: #force_inline proc(r: Reverb_Reg) -> i32 #no_bounds_check {
	return i32(i16(spu.regs[u32(r) >> 1]))
}

// Byte address of work-area entry `r` (plus a byte adjustment) relative to
// the current position, wrapped inside [mBASE*8, 0x80000).
@(private)
rv_addr :: proc(r: Reverb_Reg, adjust: i32) -> u32 #no_bounds_check {
	base := reg(0x1a2) * 8
	size := i64(SPU_RAM_SIZE - base)
	if size == 0 {
		return base
	}
	rel := (i64(reverb.pos) - i64(base) + i64(spu.regs[u32(r) >> 1]) * 8 + i64(adjust)) % size
	if rel < 0 {
		rel += size
	}
	return (base + u32(rel)) & ~u32(1)
}

@(private)
rv_load :: proc(r: Reverb_Reg, adjust: i32 = 0) -> i32 #no_bounds_check {
	a := rv_addr(r, adjust)
	return i32(i16(u16(spu.ram[a]) | u16(spu.ram[a + 1]) << 8))
}

@(private)
rv_store :: proc(r: Reverb_Reg, v: i32) #no_bounds_check {
	if reg(SPU_CNT) & SPUCNT_REVERB == 0 {
		return
	}
	a := rv_addr(r, 0)
	s := clamp(v, -0x8000, 0x7fff)
	spu_irq_check(a, 2)
	spu.ram[a] = u8(s)
	spu.ram[a + 1] = u8(s >> 8)
}

@(private)
mul :: #force_inline proc(a, b: i32) -> i32 {
	return a * b >> 15
}

// One channel of the network. Registers come in left/right pairs, so `side`
// (0 or 2 bytes) selects within each pair.
@(private)
reverb_side :: proc(input: i32, side: u32) -> i32 #no_bounds_check {
	R :: proc(r: Reverb_Reg, side: u32) -> Reverb_Reg {return Reverb_Reg(u32(r) + side)}
	other := 2 - side
	wall, iir := rv(.vWALL), rv(.vIIR)
	same := R(.mLSAME, side)
	rv_store(same, mul(input + mul(rv_load(R(.dLSAME, side)), wall) - rv_load(same, -2), iir) + rv_load(same, -2))
	diff := R(.mLDIFF, side)
	rv_store(diff, mul(input + mul(rv_load(R(.dLDIFF, other)), wall) - rv_load(diff, -2), iir) + rv_load(diff, -2))
	out := mul(rv(.vCOMB1), rv_load(R(.mLCOMB1, side))) + mul(rv(.vCOMB2), rv_load(R(.mLCOMB2, side)))
	out += mul(rv(.vCOMB3), rv_load(R(.mLCOMB3, side))) + mul(rv(.vCOMB4), rv_load(R(.mLCOMB4, side)))
	apf1, apf2 := R(.mLAPF1, side), R(.mLAPF2, side)
	d1 := -i32(u32(spu.regs[u32(Reverb_Reg.dAPF1) >> 1]) * 8)
	d2 := -i32(u32(spu.regs[u32(Reverb_Reg.dAPF2) >> 1]) * 8)
	out = clamp(out, -0x8000, 0x7fff)
	out -= mul(rv(.vAPF1), rv_load(apf1, d1))
	rv_store(apf1, out)
	out = clamp(mul(out, rv(.vAPF1)) + rv_load(apf1, d1), -0x8000, 0x7fff)
	out -= mul(rv(.vAPF2), rv_load(apf2, d2))
	rv_store(apf2, out)
	return clamp(mul(out, rv(.vAPF2)) + rv_load(apf2, d2), -0x8000, 0x7fff)
}

// Feed one 44100 Hz input frame; returns the wet output (after vLOUT/vROUT).
reverb_tick :: proc(input: [2]i32) -> [2]i32 {
	reverb.odd = !reverb.odd
	if reverb.odd {
		l := reverb_side(mul(clamp(input[0], -0x8000, 0x7fff), rv(.vLIN)), 0)
		r := reverb_side(mul(clamp(input[1], -0x8000, 0x7fff), rv(.vRIN)), 2)
		reverb.out = {mul(l, i32(i16(spu.regs[0x184 >> 1]))), mul(r, i32(i16(spu.regs[0x186 >> 1])))}
		base := reg(0x1a2) * 8
		reverb.pos = max(base, (reverb.pos + 2) & 0x7fffe)
	}
	return reverb.out
}
