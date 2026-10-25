// Smooth motion for screens the field pass does not cover: an in-between
// picture made by blending the ordering table's prims between two game
// frames, in screen space.
//
// At each game frame's DrawOTagEnv the ordering table is walked and every
// prim's vertices and colors are noted. Prims are allocated in the same
// order every frame (from double-buffered pools, plus fixed ones), so the new
// frame's prims, sorted by address, are paired with the previous frame's by
// a diff over that order: equal command and texture words pair; an inserted
// or removed prim is skipped; a prim replaced by one with the same command,
// CLUT and texture page (a sprite changing animation cel) also pairs.
//
// For each extra picture a frozen-time pass moves each paired prim's vertices
// and colors part of the way back toward its partner's, draws the table and
// restores memory. Prims without a partner, or that moved further than
// TWEEN_CUT, draw as the new frame has them. Like the field pass, one extra
// covers each frame the display repeats; screens drawn every vblank get none.
package qol

import "core:slice"

import "ps:psx"
import cpu "ps:psx/cpu"
import host "ps:psx/host"
import render "ps:psx/render"

import "ps:core"

@(private = "file")
MAX_PRIMS :: 8192
// Longest ordering table walk, in packets.
@(private = "file")
MAX_PACKETS :: 16384
@(private = "file")
MAX_VERTS :: 4
@(private = "file")
OT_END :: 0xffffff
// Prims within this many places in allocation order are searched for a
// partner after an insertion or removal.
@(private = "file")
LOOKAHEAD :: 8
// Largest screen move, in pixels per game frame, that is blended; anything
// further is a cut.
@(private = "file")
TWEEN_CUT :: 64
@(private = "file")
MAX_PERIOD :: 4
#assert(MAX_PERIOD - 1 <= render.EXTRA_FRAMES)
// Most parts in a run of prims treated as one sprite (see tween_sprites);
// longer runs (background tiles sharing a texture page) are never moved as
// one piece.
@(private = "file")
MAX_SPRITE_PARTS :: 32
// Bits of a prim address sorted per order_by_address pass; two passes cover
// the KSEG0 offset of any ordering table node (24 bits, plus 4).
@(private = "file")
ADDR_DIGIT :: 13

// Word offsets of a GP0 command's parts.
@(private = "file")
Layout :: struct {
	size:   u8,
	verts:  u8,
	colors: u8,
	vert:   [MAX_VERTS]u8,
	color:  [MAX_VERTS]u8,
	// Bit w set: word w is texture or size data, part of the pairing key.
	keyed:  u16,
	// Word holding the CLUT (high half) and the one holding the texture page;
	// 0 when untextured.
	clut:   u8,
	page:   u8,
}

@(private = "file")
Prim_List :: struct {
	count:    int,
	overflow: bool,
	vblank:   u64,
	addr:     [MAX_PRIMS]u32, // the prim's first command word
	layout:   [MAX_PRIMS]Layout,
	key:      [MAX_PRIMS]u64, // command and texture words
	loose:    [MAX_PRIMS]u64, // command, CLUT and texture page
	xy:       [MAX_PRIMS][MAX_VERTS][2]i32,
	rgb:      [MAX_PRIMS][MAX_VERTS][3]i32,
	order:    [MAX_PRIMS]u16, // prim indices sorted by address
}

@(private = "file")
tween: struct {
	lists:   [2]Prim_List,
	cur:     int, // lists index of the newest frame
	// Index of each new prim's partner in the previous frame's list, or -1.
	partner: [MAX_PRIMS]i16,
	// Previous frame's prims already given a partner.
	used:    [MAX_PRIMS]bool,
	// New prims that replaced an old one of the same command, CLUT and
	// texture page (a sprite part changing cel).
	recel:   [MAX_PRIMS]bool,
	// Previous frame's allocation rank the diff stood at when each new prim
	// was reached, or -1.
	hint:    [MAX_PRIMS]i32,
	// Rank of each previous prim in its allocation order.
	rank:    [MAX_PRIMS]u16,
	// New prims moved as part of a whole sprite, and by how far it moved.
	rigid:   [MAX_PRIMS]bool,
	shift:   [MAX_PRIMS][2]i32,
	// Partner's vertex for each of a new prim's vertices (mesh_pair).
	perm:    [MAX_PRIMS][MAX_VERTS]u8,
	// Scratch for order_by_address: the first pass's order, and a count
	// (then start) per digit.
	half:    [MAX_PRIMS]u16,
	digits:  [1 << ADDR_DIGIT]i32,
}

// Vertices of a triangle and of a quad (drawn as a Z: top left, top right,
// bottom left, bottom right) in order around the edge.
@(private = "file")
RING_3 :: [MAX_VERTS]u8{0, 1, 2, 0}
@(private = "file")
RING_4 :: [MAX_VERTS]u8{0, 1, 3, 2}

// Note the prims of the ordering table at ot. Call at each game frame's
// DrawOTagEnv, outside passes.
@(private)
tween_record :: proc(ot: u32) {
	tween.cur ~= 1
	l := &tween.lists[tween.cur]
	l.count = 0
	l.overflow = false
	l.vblank = cpu.vblanks()
	node := ot & 0xffffff
	for _ in 0 ..< MAX_PACKETS {
		if node == OT_END {
			break
		}
		header := cpu.lw(0x80000000 | node)
		packet_record(l, 0x80000000 | (node + 4), header >> 24)
		node = header & 0xffffff
	}
	order_by_address(l)
}

// Fill l.order with the prim indices sorted by address, equal addresses in
// index order: two stable counting passes over ADDR_DIGIT bits each.
@(private = "file")
order_by_address :: proc(l: ^Prim_List) #no_bounds_check {
	assert(l.count <= MAX_PRIMS, "prim list overflow")
	MASK :: 1 << ADDR_DIGIT - 1
	for pass in 0 ..< 2 {
		shift := u32(pass * ADDR_DIGIT)
		slice.zero(tween.digits[:])
		for i in 0 ..< l.count {
			tween.digits[(l.addr[i] >> shift) & MASK] += 1
		}
		at: i32 = 0
		for &d in tween.digits {
			at, d = at + d, at
		}
		for k in 0 ..< l.count {
			i := pass == 0 ? u16(k) : tween.half[k]
			d := &tween.digits[(l.addr[i] >> shift) & MASK]
			if pass == 0 {
				tween.half[d^] = i
			} else {
				l.order[d^] = i
			}
			d^ += 1
		}
	}
}

// Draw the in-between picture of the two noted frames into the DRAWENV env's
// area and keep it as the extra frame. `send` is the original DrawOTagEnv;
// the CPU must hold its arguments.
@(private)
tween_draw :: proc(send: cpu.Func_Proc, cp: ^psx.Checkpoint) {
	cur, prev := &tween.lists[tween.cur], &tween.lists[tween.cur ~ 1]
	period := cur.vblank - prev.vblank
	if prev.vblank == 0 || period < 2 || period > MAX_PERIOD || cur.overflow || prev.overflow {
		return
	}
	paired, moving := tween_pair(cur, prev)
	sprites := tween_sprites(cur, prev)
	if .Game in core.trace.active {
		core.tracef(.Game, "tween: %d of %d prims paired, %d moving, %d sprites changing cel, period %d", paired, cur.count, moving, sprites, period)
	}
	if moving + sprites == 0 {
		return
	}
	for step in 1 ..< period {
		if !tween_pass(send, cp, 1 - f64(step) / f64(period), int(step - 1)) {
			return
		}
	}
}

// Draw the paired prims `back` of the way from the sent frame toward the
// previous one, as extra picture `step`. False when the GPU is busy.
@(private = "file")
tween_pass :: proc(send: cpu.Func_Proc, cp: ^psx.Checkpoint, back: f64, step: int) -> bool {
	cur, prev := &tween.lists[tween.cur], &tween.lists[tween.cur ~ 1]
	main := cpu.state
	if !psx.checkpoint_save(cp) {
		if .Game in core.trace.active {
			core.tracef(.Game, "tween: GPU busy, frame skipped")
		}
		return false
	}
	defer psx.checkpoint_restore(cp)
	for i in 0 ..< cur.count {
		if tween.rigid[i] {
			prim_shift(cur, i, tween.shift[i], back)
		} else if tween.partner[i] >= 0 {
			prim_blend(cur, i, prev, int(tween.partner[i]), back)
		}
	}
	send()
	env := main.r[5]
	host.capture_extra_frame(i32(i16(cpu.lh(env))), i32(i16(cpu.lh(env + 2))), step)
	return true
}

// Pair cur's prims with prev's (tween.partner). Returns how many paired and
// how many of those moved or changed color within the cut limit.
@(private = "file")
tween_pair :: proc(cur, prev: ^Prim_List) -> (paired, moving: int) {
	for i in 0 ..< cur.count {
		tween.partner[i] = -1
		tween.recel[i] = false
		tween.hint[i] = -1
		tween.perm[i] = {0, 1, 2, 3}
	}
	for j in 0 ..< prev.count {
		tween.used[j] = false
	}
	i, j := 0, 0
	for _ in 0 ..< 2 * (cur.count + prev.count) {
		for j < prev.count && tween.used[prev.order[j]] {
			j += 1
		}
		if i >= cur.count || j >= prev.count {
			break
		}
		a, b := int(cur.order[i]), int(prev.order[j])
		tween.hint[a] = i32(j)
		if cur.key[a] != prev.key[b] {
			if k := rank_find(prev, j + 1, cur.key[a]); k >= 0 {
				j = k // prev's prims before k were removed
				continue
			}
			if rank_find(cur, i + 1, prev.key[b]) >= 0 {
				i += 1 // a was inserted
				continue
			}
			// a replaced b: a sprite part changing cel. The parts of a
			// sprite may change order with it, so take the nearest part of
			// the same shape.
			b = nearest_part(cur, a, prev, j)
			tween.recel[a] = cur.loose[a] == prev.loose[int(prev.order[j])]
		}
		i += 1
		if b < 0 {
			continue
		}
		tween.used[b] = true
		change, ok := prim_change(cur, a, prev, b)
		if ok {
			tween.partner[a] = i16(b)
			paired += 1
			moving += change ? 1 : 0
		}
	}
	return
}

// Sprites changing cel. A run of prims in allocation order sharing command,
// CLUT and texture page is one sprite's parts. When one of its parts changed
// cel, the new cel's parts have no true counterpart in the old one (parts
// differ in number, size and place), and blending them one by one tears the
// sprite apart. Instead the whole sprite moves in one piece by the move most
// of its kept parts agree on (sprite_vote). Its bounding box is no guide: a
// sword swinging out moves the box's middle while the body stands still.
// With no kept part the sprite draws as the new frame has it. Runs of
// untextured polygons are meshes instead
// (mesh_pair). Fills tween.rigid and tween.shift; returns how many sprites
// move in one piece.
@(private = "file")
tween_sprites :: proc(cur, prev: ^Prim_List) -> (moving: int) {
	for i in 0 ..< cur.count {
		tween.rigid[i] = false
	}
	for r in 0 ..< prev.count {
		tween.rank[prev.order[r]] = u16(r)
	}
	start := 0
	for _ in 0 ..< cur.count {
		if start >= cur.count {
			break
		}
		end := run_end(cur, start)
		lay := &cur.layout[cur.order[start]]
		if end - start <= MAX_SPRITE_PARTS && lay.clut == 0 && lay.verts >= 3 {
			mesh_pair(cur, prev, start, end)
		} else if end - start <= MAX_SPRITE_PARTS && sprite_shift(cur, prev, start, end) {
			moving += 1
		}
		start = end
	}
	return
}

// Decide how the sprite at ranks [start, end) of cur's allocation order is
// drawn: unchanged when no part changed cel; otherwise moved in one piece
// (true), or as the new frame has it when its old cel is not found.
@(private = "file")
sprite_shift :: proc(cur, prev: ^Prim_List, start, end: int) -> bool {
	recel := false
	for r in start ..< end {
		recel ||= tween.recel[cur.order[r]]
	}
	if !recel {
		return false
	}
	lo, hi, found := prev_run(cur, prev, start, end)
	for r in start ..< end {
		tween.partner[cur.order[r]] = -1
	}
	if !found {
		return false
	}
	// Doubled, as prim_shift takes it.
	d := 2 * sprite_vote(cur, prev, start, end, lo, hi)
	if d == {} || abs(d.x) > 2 * TWEEN_CUT || abs(d.y) > 2 * TWEEN_CUT {
		return false
	}
	for r in start ..< end {
		tween.rigid[cur.order[r]] = true
		tween.shift[cur.order[r]] = d
	}
	return true
}

// The run of prev's allocation order [lo, hi) that the run [start, end) of
// cur's came from: the one holding a part's partner, or the place the diff
// stood at; found is false when that run is another kind or too long.
@(private = "file")
prev_run :: proc(cur, prev: ^Prim_List, start, end: int) -> (lo, hi: int, found: bool) {
	hint := -1
	for r in start ..< end {
		a := int(cur.order[r])
		if tween.partner[a] >= 0 {
			hint = int(tween.rank[tween.partner[a]])
			break
		}
		if hint < 0 {
			hint = int(tween.hint[a])
		}
	}
	loose := cur.loose[cur.order[start]]
	if hint < 0 || hint >= prev.count || prev.loose[prev.order[hint]] != loose {
		return
	}
	lo = hint
	for _ in 0 ..< MAX_SPRITE_PARTS {
		if lo == 0 || prev.loose[prev.order[lo - 1]] != loose {
			break
		}
		lo -= 1
	}
	hi = run_end(prev, lo)
	return lo, hi, hi - lo <= MAX_SPRITE_PARTS
}

// Untextured polygons in a run are faces of one small mesh (the battle
// menu's turning cursor gem). The game sorts them by depth, so they swap
// order as the mesh turns, and pairing by order pairs a face with another
// one and collapses it. Re-pair the run's faces with the previous frame's
// by nearest center instead.
@(private = "file")
mesh_pair :: proc(cur, prev: ^Prim_List, start, end: int) {
	lo, hi, found := prev_run(cur, prev, start, end)
	if !found || hi - lo != end - start {
		return
	}
	taken: [MAX_SPRITE_PARTS]bool
	for r in start ..< end {
		a := int(cur.order[r])
		best, best_d := -1, i32(max(i32))
		for q in lo ..< hi {
			b := int(prev.order[q])
			d := face_center(cur, a) - face_center(prev, b)
			if !taken[q - lo] && abs(d.x) + abs(d.y) < best_d {
				best, best_d = q, abs(d.x) + abs(d.y)
			}
		}
		tween.partner[a] = -1
		if best < 0 {
			continue
		}
		taken[best - lo] = true
		b := int(prev.order[best])
		if _, ok := prim_change(cur, a, prev, b); ok {
			tween.partner[a] = i16(b)
			tween.perm[a] = face_turn(cur, a, prev, b)
		}
	}
}

// Match the vertices of face a of cur with those of face b of prev: a mesh
// turning a quarter turn between frames carries each corner to where the
// next one was, so the turn around the edge with the least total move is
// taken. Returns b's vertex for each of a's.
@(private = "file")
face_turn :: proc(cur: ^Prim_List, a: int, prev: ^Prim_List, b: int) -> (perm: [MAX_VERTS]u8) {
	n := int(cur.layout[a].verts)
	ring := n == 4 ? RING_4 : RING_3
	best := i32(max(i32))
	for t in 0 ..< n {
		cost: i32
		for k in 0 ..< n {
			d := cur.xy[a][ring[k]] - prev.xy[b][ring[(k + t) % n]]
			cost += d.x * d.x + d.y * d.y
		}
		if cost < best {
			best = cost
			for k in 0 ..< n {
				perm[ring[k]] = ring[(k + t) % n]
			}
		}
	}
	return
}

// Sum of prim p's vertices: its center scaled by the vertex count.
@(private = "file")
face_center :: proc(l: ^Prim_List, p: int) -> (c: [2]i32) {
	for v in 0 ..< l.layout[p].verts {
		c += l.xy[p][v]
	}
	return
}

// First rank after `from` in l's allocation order whose prim differs in
// command, CLUT or texture page.
@(private = "file")
run_end :: proc(l: ^Prim_List, from: int) -> int {
	loose := l.loose[l.order[from]]
	end := from + 1
	for end < l.count && l.loose[l.order[end]] == loose {
		end += 1
	}
	return end
}

// How far the sprite at ranks [start, end) of cur's allocation order moved
// from its old cel at prev's [lo, hi): each part showing the same texture
// rect in the same shape as an old part (a head or body kept between cels)
// votes for its move from the nearest such part, and the move with most
// votes wins, the smallest on a tie. Zero when no part was kept.
@(private = "file")
sprite_vote :: proc(cur, prev: ^Prim_List, start, end, lo, hi: int) -> [2]i32 {
	moves: [MAX_SPRITE_PARTS][2]i32
	votes: [MAX_SPRITE_PARTS]int
	n := 0
	for r in start ..< end {
		a := int(cur.order[r])
		m, ok := kept_part(cur, a, prev, lo, hi)
		if !ok {
			continue
		}
		k := 0
		for k < n && moves[k] != m {
			k += 1
		}
		if k == n {
			moves[n] = m
			n += 1
		}
		votes[k] += 1
	}
	best := -1
	for k in 0 ..< n {
		if best < 0 || votes[k] > votes[best] ||
		   votes[k] == votes[best] && taxi(moves[k]) < taxi(moves[best]) {
			best = k
		}
	}
	return best < 0 ? {} : moves[best]
}

// The move of prim a of cur from the nearest prim of prev's ranks [lo, hi)
// with the same command and texture words and the same shape.
@(private = "file")
kept_part :: proc(cur: ^Prim_List, a: int, prev: ^Prim_List, lo, hi: int) -> (move: [2]i32, ok: bool) {
	best := i32(max(i32))
	for r in lo ..< hi {
		b := int(prev.order[r])
		if prev.key[b] != cur.key[a] {
			continue
		}
		d := cur.xy[a][0] - prev.xy[b][0]
		same := true
		for v in 1 ..< cur.layout[a].verts {
			same &&= cur.xy[a][v] - prev.xy[b][v] == d
		}
		if same && taxi(d) < best {
			move, best, ok = d, taxi(d), true
		}
	}
	return
}

@(private = "file")
taxi :: #force_inline proc(d: [2]i32) -> i32 {
	return abs(d.x) + abs(d.y)
}

// The unused prim of prev within LOOKAHEAD places of rank `from` that has
// prim a's command, CLUT, texture page and shape, nearest to it; -1 if none.
@(private = "file")
nearest_part :: proc(cur: ^Prim_List, a: int, prev: ^Prim_List, from: int) -> int {
	best, best_d := -1, i32(max(i32))
	for r in from ..< min(from + LOOKAHEAD, prev.count) {
		b := int(prev.order[r])
		if tween.used[b] || prev.loose[b] != cur.loose[a] {
			continue
		}
		v0, w0 := cur.xy[a][0], prev.xy[b][0]
		same := true
		for v in 1 ..< cur.layout[a].verts {
			same &&= cur.xy[a][v] - v0 == prev.xy[b][v] - w0
		}
		d := abs(v0.x - w0.x) + abs(v0.y - w0.y)
		if same && d < best_d {
			best, best_d = b, d
		}
	}
	return best
}

// Rank in [from, from + LOOKAHEAD) of l's allocation order whose prim has
// key, or -1.
@(private = "file")
rank_find :: proc(l: ^Prim_List, from: int, key: u64) -> int {
	for r in from ..< min(from + LOOKAHEAD, l.count) {
		if l.key[l.order[r]] == key {
			return r
		}
	}
	return -1
}

// Whether prim a of cur differs from prim b of prev in position or color,
// and whether its move is within the cut limit.
@(private = "file")
prim_change :: proc(cur: ^Prim_List, a: int, prev: ^Prim_List, b: int) -> (change, ok: bool) {
	for v in 0 ..< cur.layout[a].verts {
		d := cur.xy[a][v] - prev.xy[b][v]
		if abs(d.x) > TWEEN_CUT || abs(d.y) > TWEEN_CUT {
			return false, false
		}
		change ||= d != {}
	}
	for c in 0 ..< cur.layout[a].colors {
		change ||= cur.rgb[a][c] != prev.rgb[b][c]
	}
	return change, true
}

// Write prim a of cur into RAM moved `back` of the way toward prim b of prev.
@(private = "file")
prim_blend :: proc(cur: ^Prim_List, a: int, prev: ^Prim_List, b: int, back: f64) {
	lay := &cur.layout[a]
	perm := &tween.perm[a]
	for v in 0 ..< lay.verts {
		p := blend2(cur.xy[a][v], prev.xy[b][perm[v]], back)
		cpu.sw(cur.addr[a] + u32(lay.vert[v]) * 4, u32(u16(i16(p.x))) | u32(u16(i16(p.y))) << 16)
	}
	for c in 0 ..< lay.colors {
		at := cur.addr[a] + u32(lay.color[c]) * 4
		word := cpu.lw(at) & 0xff000000
		for ch in 0 ..< 3 {
			n := cur.rgb[a][c][ch]
			from := lay.colors == lay.verts ? perm[c] : u8(c)
			v := n - i32(f64(n - prev.rgb[b][from][ch]) * back)
			word |= u32(clamp(v, 0, 0xff)) << (u32(ch) * 8)
		}
		cpu.sw(at, word)
	}
}

// Write prim a of cur into RAM moved `back` of the way back along d, d being
// doubled (sprite_shift).
@(private = "file")
prim_shift :: proc(cur: ^Prim_List, a: int, d: [2]i32, back: f64) {
	lay := &cur.layout[a]
	for v in 0 ..< lay.verts {
		p := cur.xy[a][v] - {i32(f64(d.x) * back / 2), i32(f64(d.y) * back / 2)}
		cpu.sw(cur.addr[a] + u32(lay.vert[v]) * 4, u32(u16(i16(p.x))) | u32(u16(i16(p.y))) << 16)
	}
}

@(private = "file")
blend2 :: proc(to, from: [2]i32, back: f64) -> [2]i32 {
	return {to.x - i32(f64(to.x - from.x) * back), to.y - i32(f64(to.y - from.y) * back)}
}

// Note the commands of one packet of `words` words at addr.
@(private = "file")
packet_record :: proc(l: ^Prim_List, addr: u32, words: u32) {
	pos := u32(0)
	for _ in 0 ..< words {
		if pos >= words {
			return
		}
		n := command_record(l, addr + pos * 4, words - pos)
		if n == 0 {
			return
		}
		pos += n
	}
}

// Note one GP0 command; returns its length in words, 0 when it does not fit
// or has no fixed length (polylines, which end the packet's walk).
@(private = "file")
command_record :: proc(l: ^Prim_List, addr: u32, room: u32) -> u32 {
	op := cpu.lw(addr) >> 24
	lay := command_layout(op)
	size := u32(lay.size)
	if size == 0 || size > room || lay.verts == 0 {
		return size <= room ? size : 0
	}
	if l.count == MAX_PRIMS {
		l.overflow = true
		return size
	}
	i := l.count
	l.count += 1
	l.addr[i] = addr
	l.layout[i] = lay
	key := u64(14695981039346656037) ~ u64(op)
	loose := key
	for w in 1 ..< size {
		word := cpu.lw(addr + w * 4)
		if lay.keyed & (1 << w) != 0 {
			key = (key ~ u64(word)) * 1099511628211
		}
		if w == u32(lay.clut) || w == u32(lay.page) || (lay.keyed & (1 << w) != 0 && lay.clut == 0) {
			loose = (loose ~ u64(word >> 16)) * 1099511628211
		}
	}
	l.key[i], l.loose[i] = key, loose
	for v in 0 ..< lay.verts {
		word := cpu.lw(addr + u32(lay.vert[v]) * 4)
		l.xy[i][v] = {i32(i16(word)), i32(i16(word >> 16))}
	}
	for c in 0 ..< lay.colors {
		word := cpu.lw(addr + u32(lay.color[c]) * 4)
		l.rgb[i][c] = {i32(word & 0xff), i32(word >> 8 & 0xff), i32(word >> 16 & 0xff)}
	}
	return size
}

// Layout of the GP0 command op. Commands without vertices have verts 0;
// polylines size 0.
@(private = "file")
command_layout :: proc(op: u32) -> (lay: Layout) {
	lay.size, lay.colors = 1, 1
	switch op >> 5 {
	case 1:
		polygon_layout(op, &lay)
	case 2: // line
		if op & 0x08 != 0 {
			lay.size = 0
			return
		}
		lay.verts, lay.vert = 2, {1, op & 0x10 != 0 ? 3 : 2, 0, 0}
		if op & 0x10 != 0 {
			lay.colors, lay.color[1] = 2, 2
		}
		lay.size = lay.vert[1] + 1
	case 3: // rectangle
		lay.verts, lay.vert[0], lay.size = 1, 1, 2
		if op & 0x04 != 0 {
			lay.clut, lay.keyed, lay.size = 2, 1 << 2, 3
		}
		if (op >> 3) & 3 == 0 {
			lay.keyed |= 1 << lay.size // width and height
			lay.size += 1
		}
	case 4: // VRAM to VRAM copy
		lay.colors, lay.size = 0, 4
	case 5: // CPU to VRAM: inline data of any length
		lay.colors, lay.size = 0, 0
	case 6: // VRAM to CPU
		lay.colors, lay.size = 0, 3
	case:
		lay.colors = 0
		if op == 0x02 {
			lay.size = 3 // fill
		}
	}
	return
}

@(private = "file")
polygon_layout :: proc(op: u32, lay: ^Layout) {
	gouraud, tex := op & 0x10 != 0, op & 0x04 != 0
	lay.verts = op & 0x08 != 0 ? 4 : 3
	if gouraud {
		lay.colors = lay.verts
	}
	pos := u8(1)
	for v in 0 ..< lay.verts {
		if v > 0 && gouraud {
			lay.color[v] = pos
			pos += 1
		}
		lay.vert[v] = pos
		pos += 1
		if tex {
			lay.keyed |= 1 << pos
			pos += 1
		}
	}
	if tex {
		lay.clut = lay.vert[0] + 1
		lay.page = lay.vert[1] + 1
	}
	lay.size = pos
}
