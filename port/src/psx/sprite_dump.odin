// Debug aid: with BOF4_SPRITES=<dir>, every distinct texture rectangle that a
// 4- or 8-bit textured polygon or rectangle draws is written to <dir> as a
// PNG in the colours of the CLUT it is drawn with (index 0 transparent), at
// draw time, while VRAM holds it. Names: <tex x>_<tex y>_<clut x>_<clut y>_
// <u>_<v>_<w>x<h>.png. Duplicates (same pixels) are skipped. Used to collect
// the game's sprites, coloured, as reference and training art.
package psx

import "core:fmt"
import "core:hash"
import "core:os"
import "core:strings"

import stbi "vendor:stb/image"

@(private = "file")
SPRITE_MIN :: 8 // smaller rectangles (font, sparks) are skipped
@(private = "file")
SPRITE_LIMIT :: 20000

@(private = "file")
sprites: struct {
	dir:  string,
	seen: map[u64]bool,
}

@(private)
sprite_dump_init :: proc() {
	sprites.dir = os.get_env("BOF4_SPRITES", context.allocator)
}

@(private)
sprite_dump :: proc(vs: []Vertex, m: ^Prim_Mode) {
	if sprites.dir == "" || !m.textured || gpu.tp > 1 {
		return
	}
	u0, v0, u1, v1 := i32(255), i32(255), i32(0), i32(0)
	for v in vs {
		u0, v0 = min(u0, v.u), min(v0, v.v)
		u1, v1 = max(u1, v.u), max(v1, v.v)
	}
	sprite_rect(u0, v0, u1 - u0, v1 - v0, m)
}

@(private)
sprite_rect :: proc(u0, v0, w, h: i32, m: ^Prim_Mode) {
	if sprites.dir == "" || !m.textured || gpu.tp > 1 || w < SPRITE_MIN || h < SPRITE_MIN ||
	   len(sprites.seen) >= SPRITE_LIMIT {
		return
	}
	rgba := make([]u8, w * h * 4, context.temp_allocator)
	opaque := 0
	for y in 0 ..< h {
		for x in 0 ..< w {
			u, v := (u0 + x) & 0xff, (v0 + y) & 0xff
			c: u16
			if gpu.tp == 0 {
				word := vram_at(gpu.tex_x + (u >> 2), gpu.tex_y + v)^
				c = vram_at(m.clut_x + i32((word >> (u32(u & 3) * 4)) & 0xf), m.clut_y)^
			} else {
				word := vram_at(gpu.tex_x + (u >> 1), gpu.tex_y + v)^
				c = vram_at(m.clut_x + i32((word >> (u32(u & 1) * 8)) & 0xff), m.clut_y)^
			}
			p := rgba[(y * w + x) * 4:]
			if c != 0 {
				p[0], p[1], p[2], p[3] = u8(c & 31) << 3, u8((c >> 5) & 31) << 3, u8((c >> 10) & 31) << 3, 255
				opaque += 1
			}
		}
	}
	if opaque == 0 {
		return
	}
	key := hash.fnv64a(rgba) ~ u64(w) << 48 ~ u64(h) << 32
	if key in sprites.seen {
		return
	}
	sprites.seen[key] = true
	path := fmt.tprintf("%s/%d_%d_%d_%d_%d_%d_%dx%d.png", sprites.dir, gpu.tex_x, gpu.tex_y, m.clut_x, m.clut_y, u0, v0, w, h)
	if stbi.write_png(strings.clone_to_cstring(path, context.temp_allocator), w, h, 4, raw_data(rgba), w * 4) == 0 {
		fmt.eprintln("BOF4_SPRITES: png write failed:", path)
	}
}
