// Glow around additive effects (not a PS1 feature): pixels of the hi-res
// target last written by an additive (abr 1) see-through texel of a 3D
// polygon carry HI_GLOW. Converting the shown area for the window, their
// colours are averaged down to the PS1's resolution, blurred across then
// down (9 binomial taps, BLOOM_TAPS), stretched back bilinearly and added
// to the picture at BLOOM_GAIN. The target itself is left as drawn; only
// the picture shown gets the glow. Integer arithmetic throughout, the same
// as the GPU's (gl_target.odin, BLOOM_CS and CONV_CS), so both give the same
// pixels. Set from the config ([window] bloom_effects).
package psx

import "base:intrinsics"
import "core:simd"

bloom_effects := false

// A hi-res target pixel's glow bit (see the top of this file). Blends and
// fades build their pixels anew, which drops it.
@(private)
HI_GLOW :: 0x0100_0000

// The blur's weights (their sum is 256), 4 PS1 pixels each way, and the
// glow's strength over the picture (256 = as bright as its source).
@(private)
BLOOM_TAPS := [9]u32{1, 8, 28, 56, 70, 56, 28, 8, 1}
@(private)
BLOOM_GAIN :: 160

// The glow of the area being converted at the PS1's resolution, w x h,
// packed as hi-res pixels: averaged (avg), blurred across (across) and
// down (down). x, y is the area's corner in target pixels, k the target's
// shift; lit when a pixel carries HI_GLOW.
@(private)
bloom: struct {
	avg, across, down: [dynamic]u32,
	w, h, x, y, k:     i32,
	lit:               bool,
}

// VRAM tiles of GLOW_TILE x GLOW_TILE pixels that may hold glowing target
// pixels: set wherever one is drawn or copied (bloom_mark), cleared when
// the shown area's averaging finds nothing of the tile's glow left
// (bloom_prepare). Averaging skips the tiles not set, so frames with no
// glow cost next to nothing.
@(private)
GLOW_TILE :: 16
@(private)
glow_tiles: [VRAM_H / GLOW_TILE][VRAM_W / GLOW_TILE]bool

// Set the tile under target t's pixel x, y (wrapped).
@(private)
bloom_mark :: #force_inline proc(t: ^Target, x, y: i32) #no_bounds_check {
	s := u32(t.shift) + 4
	glow_tiles[(y & (t.h - 1)) >> s][(x & (t.w - 1)) >> s] = true
}

@(private)
Lanes :: #simd[4]u32

// A hi-res pixel's channels as lanes r, g, b, 0.
@(private)
lanes :: #force_inline proc(c: u32) -> Lanes {
	return Lanes{c >> 16 & 255, c >> 8 & 255, c & 255, 0}
}

@(private)
pack :: #force_inline proc(v: Lanes) -> u32 {
	a := transmute([4]u32)v
	return a[0] << 16 | a[1] << 8 | a[2]
}

// Work out the glow of the shown target's area x, y, w x h (VRAM pixels);
// false when nothing there glows.
@(private)
bloom_prepare :: proc(x, y, w, h: i32) -> bool {
	b := &bloom
	k := i32(shown_target().shift)
	b.w, b.h, b.x, b.y, b.k = w, h, x << u32(k), y << u32(k), k
	n := int(w * h)
	resize(&b.avg, n)
	resize(&b.across, n)
	resize(&b.down, n)
	b.lit = false
	marked := false
	for ty in y / GLOW_TILE ..= (y + h - 1) / GLOW_TILE {
		for tx in x / GLOW_TILE ..= (x + w - 1) / GLOW_TILE {
			marked ||= glow_tiles[ty & (VRAM_H / GLOW_TILE - 1)][tx & (VRAM_W / GLOW_TILE - 1)]
		}
	}
	if !marked {
		return false
	}
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, bloom.h, band, bands)
			bloom_average(y0, y1)
		}, nil)
	bloom_unmark(x, y, w, h)
	if !b.lit {
		return false
	}
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, bloom.h, band, bands)
			bloom_blur(bloom.avg[:], bloom.across[:], bloom.w, bloom.h, y0, y1, 1, 0)
		}, nil)
	raster_parallel(proc(band, bands: i32, _: rawptr) {
			y0, y1 := band_run(0, bloom.h, band, bands)
			bloom_blur(bloom.across[:], bloom.down[:], bloom.w, bloom.h, y0, y1, 0, 1)
		}, nil)
	return true
}

// Clear the tiles wholly inside area x, y, w x h (VRAM pixels) whose
// blocks all averaged to 0. Their glowing pixels only ever leave (a pixel
// drawn or copied glowing marks its tile again), so they stay 0.
@(private)
bloom_unmark :: proc(x, y, w, h: i32) #no_bounds_check {
	b := &bloom
	for ty in (y + GLOW_TILE - 1) / GLOW_TILE ..< (y + h) / GLOW_TILE {
		for tx in (x + GLOW_TILE - 1) / GLOW_TILE ..< (x + w) / GLOW_TILE {
			tile := &glow_tiles[ty & (VRAM_H / GLOW_TILE - 1)][tx & (VRAM_W / GLOW_TILE - 1)]
			if !tile^ {
				continue
			}
			lit := false
			for cy in ty * GLOW_TILE - y ..< (ty + 1) * GLOW_TILE - y {
				for c in b.avg[cy * w + tx * GLOW_TILE - x:][:GLOW_TILE] {
					lit ||= c != 0
				}
			}
			tile^ = lit
		}
	}
}

// Average each PS1 pixel's block of glowing target pixels, rows y0 ..< y1.
@(private)
bloom_average :: proc(y0, y1: i32) #no_bounds_check {
	b := &bloom
	t := shown_target()
	k := u32(b.k)
	s := i32(1) << k
	half := Lanes(u32(1) << (2 * k) >> 1)
	lit := false
	for cy in y0 ..< y1 {
		row := (b.y >> k + cy) & (VRAM_H - 1) / GLOW_TILE
		for cx in 0 ..< b.w {
			if !glow_tiles[row][(b.x >> k + cx) & (VRAM_W - 1) / GLOW_TILE] {
				b.avg[cy * b.w + cx] = 0
				continue
			}
			sum: Lanes
			for dy in 0 ..< s {
				line := t.rgb[((b.y + cy << k + dy) & (t.h - 1)) * t.w:][:t.w]
				for dx in 0 ..< s {
					c := line[(b.x + cx << k + dx) & (t.w - 1)]
					if c & HI_GLOW != 0 {
						sum += lanes(c)
					}
				}
			}
			out := pack(simd.shr(sum + half, Lanes(2 * k)))
			lit ||= out != 0
			b.avg[cy * b.w + cx] = out
		}
	}
	if lit {
		intrinsics.atomic_store(&b.lit, true)
	}
}

// Blur src into dst (both w x h) along (dx, dy), rows y0 ..< y1; taps past
// the edge take the edge pixel.
@(private)
bloom_blur :: proc(src, dst: []u32, w, h, y0, y1, dx, dy: i32) #no_bounds_check {
	for cy in y0 ..< y1 {
		for cx in 0 ..< w {
			acc: Lanes
			for tap, i in BLOOM_TAPS {
				o := i32(i) - 4
				sx := clamp(cx + o * dx, 0, w - 1)
				sy := clamp(cy + o * dy, 0, h - 1)
				acc += lanes(src[sy * w + sx]) * tap
			}
			dst[cy * w + cx] = pack(simd.shr(acc + 128, Lanes(8)))
		}
	}
}

// Where target pixel p (from the area's edge) falls between PS1 pixels:
// the two it mixes (clamped to the area's n) and the second's weight in
// 256ths.
@(private)
bloom_split :: #force_inline proc(p, n, k: i32) -> (lo, hi, f: i32) {
	s := i32(1) << u32(k)
	q := 2 * p + 1 - s
	lo = (q + 2 * s) / (2 * s) - 1
	f = (q - lo * 2 * s) * 128 / s
	return max(lo, 0), min(lo + 1, n - 1), f
}

// Image d (w x h, the area at the PS1's resolution) stretched bilinearly
// to target pixel px, row of the area (target shift k), as lanes.
@(private)
bloom_sample :: #force_inline proc(d: []u32, w, h, k, px, row: i32) -> Lanes #no_bounds_check {
	x0, x1, fx := bloom_split(px, w, k)
	y0, y1, fy := bloom_split(row, h, k)
	wx0, wx1, wy0, wy1 := Lanes(u32(256 - fx)), Lanes(u32(fx)), Lanes(u32(256 - fy)), Lanes(u32(fy))
	top := lanes(d[y0 * w + x0]) * wx0 + lanes(d[y0 * w + x1]) * wx1
	bottom := lanes(d[y1 * w + x0]) * wx0 + lanes(d[y1 * w + x1]) * wx1
	return simd.shr(top * wy0 + bottom * wy1 + 32768, Lanes(16))
}

// Target pixel c of the area's column px, row row, with the glow added.
@(private)
bloom_add :: #force_inline proc(c: u32, px, row: i32) -> u32 {
	b := &bloom
	g := bloom_sample(b.down[:], b.w, b.h, b.k, px, row)
	return pack(simd.min(lanes(c) + simd.shr(g * BLOOM_GAIN + 128, Lanes(8)), Lanes(255)))
}
