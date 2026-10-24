// See-through: what stands between the port's field camera and the leader is
// faded per pixel, by real depth, the way modern third-person games keep the
// player in view (not a PS1 feature).
//
// The PS1 has no depth buffer, so depth is recovered as PGXP's vertex cache
// does it: every GTE projection (RTPS/RTPT) files the screen x, y it produced
// under its view depth (depth_tag), and when a polygon packet reaches the GPU
// its corners are looked up by the x, y the game copied into it
// (depth_fill; where vertices at different depths met at one pixel, the one
// projected with the polygon's other corners). The rasterizer interpolates 1 / depth across the polygon,
// and each pixel's opacity comes from see_alpha:
// - Pixels right in front of the lens are not drawn at all, fading in from
//   SEE_NEAR[0] to SEE_NEAR[1]: what the camera sits in is cut away.
// - A face covers the leader when its plane has the lens on one side and the
//   leader's middle on the other (see_cover): walls turned to the camera in
//   front of him, roofs over him. Only such a face's pixels that hide him
//   are ghosts: those nearer than the leader and inside the cone from the
//   lens to SEE_RADIUS round his middle, so on screen a disc about his
//   sprite, the same size however near the lens the face stands. Ghosts are
//   more opaque the nearer the leader, from SEE_GHOST[0] at the camera to
//   SEE_GHOST[1] at him.
// - Every one of those choices fades over a margin (SEE_FADE, SEE_SOFT)
//   instead of switching: a face whose plane passes close to the leader or
//   the lens is half ghosted, so a face does not pop between solid and ghost
//   as the camera moves. A quad is judged as one face, so its two triangles
//   never disagree.
// - Everything else (the ground, walls beside or past him) is drawn as usual.
// Faces turned away from the lens stay dropped by the game (NCLIP): the
// walls of a building the camera is over do not show, only its roof.
//
// - Sprites (people) have no projected corners. The field camera files each
//   person's packets with the depth of where they stand (see_flat_add), so a
//   person standing nearer the lens than the leader (feet to feet,
//   see_sprite_cover) fades like a wall before him, only further
//   (SEE_SPRITE_GHOST).
// - A filed sprite may carry a share faded out regardless (Flat.clear,
//   See_Cover.clear): a follower fading in at map start is drawn solid and
//   ghosted by that share, instead of the game's additive glow.
// Ghosts are drawn into the GPU's ghost layer and laid over the scene before
// the HUD (gpu_ghost_flush), the nearest one at a pixel the only one shown;
// a solid pixel drawn nearer than a ghost takes the pixel back. Packets
// without projected corners (the party's sprites, shadows, the HUD) are
// drawn as usual; one drawn over a ghost before the flush stands before it
// in the ordering table, so the ghost is laid down under it first.
package psx

import "core:math/linalg"

@(private)
DEPTH_SLOT_BITS :: 17
@(private)
DEPTH_SLOTS :: 1 << DEPTH_SLOT_BITS
// Slots a lookup or tag walks before it gives up.
@(private)
DEPTH_RUN :: 64
// Depths filed at one pixel before a tag there gives up: offscreen vertices
// the GTE clamps to a screen corner pile up at one pixel by the hundred.
@(private)
DEPTH_PILE :: 8
// Vertices at one pixel whose depths differ by at most this part are one.
@(private)
DEPTH_SAME :: 0.02
// Vertices at one pixel a primitive's corner chooses among.
@(private)
DEPTH_CANDIDATES :: 4

// One depth cache slot. A probe reads key and gen, a hit the rest, so a
// slot's fields sit together (24 bytes): one cache line per lookup rather
// than one per field, the table being far larger than L2.
@(private)
Depth_Slot :: struct {
	key, gen:       u32,
	z:              f32,
	// Sixteenths of a pixel past x, y the exact projection lies (negative
	// or past a pixel under the exact view).
	sub:            [2]i8,
	// The first and last projection (by seq) that filed this vertex.
	seq_lo, seq_hi: u32,
}

// Projected vertices since the last ordering-table walk: open addressing, a slot counting only when its gen is
// `now`.
@(private)
Depth_Cache :: struct {
	slots:    [DEPTH_SLOTS]Depth_Slot,
	now:      u32,
	// Projections filed since the last walk.
	seq:      u32,
}

@(private)
depth_cache: Depth_Cache

// What a frozen-time pass changed in the depth cache, to undo at restore
// instead of copying the whole cache both ways: each slot's fields before
// the pass first wrote it (marked in `kept`, so a slot is kept once and the
// log never holds more than DEPTH_SLOTS), and the walk counters.
@(private)
Depth_Undo :: struct {
	kept:      [DEPTH_SLOTS / 64]u64,
	slot:      [DEPTH_SLOTS]u32,
	old:       [DEPTH_SLOTS]Depth_Slot,
	n:         u32,
	now, seq:  u32,
}

// Start logging depth cache changes into u (a pass begins).
@(private)
depth_undo_begin :: proc(u: ^Depth_Undo) {
	assert(u.n == 0, "depth undo log not empty")
	u.now, u.seq = depth_cache.now, depth_cache.seq
}

// Put back every slot and counter u logged, leaving u empty.
@(private)
depth_undo_end :: proc(u: ^Depth_Undo) #no_bounds_check {
	c := &depth_cache
	for i in 0 ..< u.n {
		s := u.slot[i]
		c.slots[s] = u.old[i]
		u.kept[s >> 6] &~= 1 << (s & 63)
	}
	u.n = 0
	c.now, c.seq = u.now, u.seq
}

// Slot s is about to change: inside a pass, log it first.
@(private)
depth_keep :: #force_inline proc(s: u32) #no_bounds_check {
	if pass_checkpoint == nil {
		return
	}
	u := &pass_checkpoint.depths
	bit := u64(1) << (s & 63)
	if u.kept[s >> 6] & bit != 0 {
		return
	}
	u.kept[s >> 6] |= bit
	u.slot[u.n] = s
	u.old[u.n] = depth_cache.slots[s]
	u.n += 1
}

// Opacity at the camera's and at the leader's end of the tube.
@(private)
SEE_GHOST :: [2]f32{0.3, 0.45}
// The same for a sprite: a person is small, and one right before the leader
// must not hide him.
@(private)
SEE_SPRITE_GHOST :: [2]f32{0.25, 0.4}
// View units (128 a grid cell): the radius of the ghosted cone at the
// leader and the width of its soft edge there (both shrink toward the lens);
// the stretch before the leader left solid; how far behind a face's plane
// the leader must be for it to cover him; the depths over which the lens's
// cut fades in.
@(private)
SEE_RADIUS :: 160
@(private)
SEE_SOFT :: 64
// The share of SEE_RADIUS the cone keeps at the lens, so it never closes.
@(private)
SEE_CONE_MIN :: 0.05
@(private)
SEE_GAP :: 64
@(private)
SEE_BEHIND :: 8
// View units over which a face's cover fades in as its plane moves away from
// the leader or the lens.
@(private)
SEE_FADE :: 48
@(private)
SEE_NEAR :: [2]f32{64, 160}
// View units below the leader's feet (shrinking toward the lens as the cone
// does) where the cone is cut off, softly between the two: what lies past
// his feet on screen does not hide him (the top of an awning he stands
// behind is ghosted where it crosses his boots, not in a disc beyond them).
@(private)
SEE_FLOOR :: [2]f32{8, 40}
// Vblanks a see_through setting stays good for after its stamp.
@(private)
SEE_VBLANKS :: 2

// Runs of sprite packets kept at once.
@(private)
MAX_FLATS :: 128
// Runs of screen packets kept at once (screen_add).
@(private)
MAX_SCREENS :: 4

// The packets lo..<hi draw a sprite standing at view depth z (0 for none
// filed: the party, which see-through never fades) and at view-space point
// `at` (its depth 0 for none), whose plane the depth buffer takes; a front
// one (the party walking in through an instant door) a waiting door cover
// does not lay over; `clear` is the share of it faded out regardless; `sub`
// its anchor's sub-pixel part (gte anchor_sub), which its corners take.
@(private)
Flat :: struct {
	lo, hi: u32,
	z:      f32,
	at:     [3]f32,
	stamp:  u64,
	front:  bool,
	clear:  f32,
	sub:    [2]i8,
}

@(private)
flats: struct {
	list: [MAX_FLATS]Flat,
	n:    int,
}

// Set by the field camera for the view it just built.
see_through: struct {
	on:     bool,
	stamp:  u64,
	// The projection: GTE H and screen offset.
	h:      f32,
	of:     [2]f32,
	// The leader's middle and world up, in view space.
	target: [3]f32,
	up:     [3]f32,
	// The view depth of where the leader stands, against which a sprite's
	// (where it stands) is judged.
	feet:   f32,
	// How far the leader's middle stands above his feet.
	rise:   f32,
	// Whether the map is a room (not a town), where black fill between the
	// leader and the lens is left out.
	room:   bool,
}

// How a face stands to the leader: how much it is in the way (0 not, 1 its
// plane well between him and the lens); whether it is a sprite; the share of
// it faded out on top of that (a sprite's Flat.clear).
See_Cover :: struct {
	weight: f32,
	sprite: bool,
	clear:  f32,
}

// Set while the ordering-table walk draws with see_through; `direct` once
// the ghost layer has been laid down (bucket 0), so ghosts blend straight
// into VRAM.
@(private)
see: struct {
	active, direct: bool,
	// From see_through: the map is a room.
	room:           bool,
	// From see_through: |target|^2 and the share of the way to the leader
	// past which nothing is faded.
	reach2, stop:   f32,
	// World up's part across the line to the leader (its length the sine
	// of the camera's tilt from looking straight down, so the floor cut
	// fades out as the camera looks down on him) and his feet's distance
	// along it under his middle, at the leader: see_cover_alpha's floor.
	across:         [3]f32,
	drop:           f32,
	// The walk's depth buffer key (z_walk_begin), with a hi-res target.
	z_key:          u32,
}

// Turn see-through on for the view just built: the GTE's projection, the
// leader's middle `target` and world `up` in view space, the view depth
// `feet` of where he stands and how far his middle `rise`s above that;
// `room` when the map is not a town.
see_through_set :: proc(target, up: [3]f32, feet, rise: f32, room: bool) {
	see_through = {
		on     = true,
		stamp  = vblanks(),
		h      = f32(gte.h),
		of     = [2]f32{f32(gte.ofx), f32(gte.ofy)} / 0x10000,
		target = target,
		up     = up,
		feet   = feet,
		rise   = rise,
		room   = room,
	}
}

// File the packets lo..<hi as a sprite standing at view depth z (0 for
// none) and view-space point `at`, for the frame drawn next (Flat).
see_flat_add :: proc(lo, hi: u32, z: f32, at: [3]f32, sub: [2]i8, front := false, clear: f32 = 0) {
	if hi <= lo || (z <= 0 && at.z <= 0 && sub == {}) {
		return
	}
	f := Flat {
		lo    = lo & 0x1fffff,
		hi    = hi & 0x1fffff,
		z     = max(z, 0),
		at    = at,
		stamp = vblanks(),
		front = front,
		clear = clear,
		sub   = sub,
	}
	now := f.stamp
	kept := 0
	for q in flats.list[:flats.n] {
		if now - q.stamp <= PORTAL_VBLANKS && (q.hi <= f.lo || q.lo >= f.hi) {
			flats.list[kept] = q
			kept += 1
		}
	}
	flats.n = kept
	if flats.n == MAX_FLATS {
		return
	}
	flats.list[flats.n] = f
	flats.n += 1
}

// Packets drawn flat on the screen (a speaker's portrait), filed by
// screen_add.
@(private)
screens: struct {
	list: [MAX_SCREENS]struct {
		lo, hi: u32,
		stamp:  u64,
	},
	n:    int,
}

// File the packets lo..<hi as drawn flat on the screen, for the frame drawn
// next: they take no depth. Such a quad would otherwise take one from a
// sprite run (Flat) filed a few frames before at the same packet addresses
// (the packet pool is reused every other frame), or from the depth cache,
// which files projections by pixel, when a world corner projected onto one
// of its corners; the depth buffer or see-through then hid it.
screen_add :: proc(lo, hi: u32) {
	if hi <= lo {
		return
	}
	lo, hi := lo & 0x1fffff, hi & 0x1fffff
	now := vblanks()
	kept := 0
	for q in screens.list[:screens.n] {
		if now - q.stamp <= PORTAL_VBLANKS && (q.hi <= lo || q.lo >= hi) {
			screens.list[kept] = q
			kept += 1
		}
	}
	screens.n = kept
	if screens.n == MAX_SCREENS {
		return
	}
	screens.list[screens.n] = {lo, hi, now}
	screens.n += 1
}

// Whether the packet at address a was filed by screen_add.
@(private)
on_screen :: proc(a: u32) -> bool {
	now := vblanks()
	for q in screens.list[:screens.n] {
		if a >= q.lo && a < q.hi && now - q.stamp <= PORTAL_VBLANKS {
			return true
		}
	}
	return false
}

// The sprite the packet at address a draws, if filed.
@(private)
see_flat :: proc(a: u32) -> (Flat, bool) {
	now := vblanks()
	for f in flats.list[:flats.n] {
		if a >= f.lo && a < f.hi && now - f.stamp <= PORTAL_VBLANKS {
			return f, true
		}
	}
	return {}, false
}

@(private)
depth_key :: #force_inline proc(x, y: i32) -> u32 {
	return u32(x & 0x7ff) | u32(y & 0x7ff) << 11 | 1 << 31
}

@(private)
depth_slot :: #force_inline proc(key: u32) -> u32 {
	return (key * 2654435761) >> (32 - DEPTH_SLOT_BITS)
}

// File a projected vertex: screen x, y (as packets hold them) at view depth z,
// exactly sub sixteenths of a pixel further. Vertices at one pixel with
// depths apart are filed side by side; one projected again widens the run of
// projections (seq) it was filed in.
@(private)
depth_tag :: proc(x, y: i32, z: i64, sub: [2]i8) #no_bounds_check {
	c := &depth_cache
	c.seq += 1
	zf := f32(max(z, 1))
	key := depth_key(x, y)
	s := depth_slot(key)
	same := 0
	for _ in 0 ..< DEPTH_RUN {
		e := &c.slots[s]
		if e.gen != c.now {
			depth_keep(s)
			e^ = {key, c.now, zf, sub, c.seq, c.seq}
			return
		}
		if e.key == key && abs(e.z - zf) <= e.z * DEPTH_SAME {
			depth_keep(s)
			e.z, e.sub, e.seq_hi = zf, sub, c.seq
			return
		}
		if e.key == key {
			same += 1
			if same == DEPTH_PILE {
				return
			}
		}
		s = (s + 1) & (DEPTH_SLOTS - 1)
	}
}

// The slots of the vertices projected to x, y this frame, at most
// DEPTH_CANDIDATES.
@(private)
depth_candidates :: proc(x, y: i32, out: ^[DEPTH_CANDIDATES]u32) -> (n: int) #no_bounds_check {
	c := &depth_cache
	key := depth_key(x, y)
	s := depth_slot(key)
	for _ in 0 ..< DEPTH_RUN {
		e := &c.slots[s]
		if e.gen != c.now {
			break
		}
		if e.key == key {
			out[n] = s
			n += 1
			if n == DEPTH_CANDIDATES {
				break
			}
		}
		s = (s + 1) & (DEPTH_SLOTS - 1)
	}
	return
}

// Give the corners of a primitive their view depths and sub-pixel parts
// (0 depth where none was projected). Where two vertices projected to one
// pixel, a corner takes the one filed nearest in projection order to the
// other corners: the game projects a face's corners together, so the
// combination whose runs of projections lie closest together wins, the later
// on a tie. One wrong depth bends a perspective-mapped texture across the
// face.
@(private)
depth_fill :: proc(vs: []Vertex) #no_bounds_check {
	assert(len(vs) <= 4, "primitive with more than 4 corners")
	c := &depth_cache
	cands: [4][DEPTH_CANDIDATES]u32
	count: [4]int
	combos := 1
	for &v, k in vs {
		count[k] = depth_candidates(v.x - gpu.off_x, v.y - gpu.off_y, &cands[k])
		combos *= max(count[k], 1)
	}
	pick: [4]int
	if combos > 1 {
		// Each candidate is filed after the ones before it at its pixel, so
		// the last is the latest; walk combinations from the latest down.
		best := max(u32)
		for combo in 0 ..< combos {
			at: [4]int
			lo, hi := u32(0), max(u32)
			r := combo
			for k in 0 ..< len(vs) {
				if count[k] == 0 {
					continue
				}
				at[k] = count[k] - 1 - r % count[k]
				r /= count[k]
				s := cands[k][at[k]]
				lo = max(lo, c.slots[s].seq_lo)
				hi = min(hi, c.slots[s].seq_hi)
			}
			gap := lo > hi ? lo - hi : 0
			if gap < best {
				best, pick = gap, at
			}
		}
	} else {
		for k in 0 ..< len(vs) {
			pick[k] = count[k] - 1
		}
	}
	for &v, k in vs {
		if count[k] == 0 {
			continue
		}
		e := &c.slots[cands[k][pick[k]]]
		v.z = e.z
		v.sx += i32(e.sub[0])
		v.sy += i32(e.sub[1])
	}
}

// Start an ordering-table walk: see-through applies when set lately.
@(private)
see_begin :: proc() {
	s := &see_through
	see = {}
	if !s.on || vblanks() - s.stamp > SEE_VBLANKS || s.h <= 0 {
		return
	}
	reach2 := linalg.dot(s.target, s.target)
	if reach2 < 1 {
		return
	}
	across := s.up - s.target * (linalg.dot(s.up, s.target) / reach2)
	see = {
		active = true,
		room   = s.room,
		reach2 = reach2,
		stop   = 1 - SEE_GAP / linalg.sqrt(reach2),
		across = across,
		drop   = s.rise * linalg.dot(across, across),
	}
	if target_count == 2 {
		see.z_key = z_walk_begin()
	}
}

// End a walk: the vertices filed for it are spent.
@(private)
see_end :: proc() {
	see = {}
	depth_cache.now += 1
	depth_cache.seq = 0
	world_walk_end()
}

// The view-space point at packet screen position x, y and view depth z.
@(private)
see_point :: #force_inline proc(x, y, z: f32) -> [3]f32 {
	s := &see_through
	return unproject(x, y, z, s.h, s.of)
}

// The view-space point the GTE projected to screen position x, y at view
// depth z, with H `h` and screen offset `of`. Nearer than H / 2 its divide
// overflows and stops at 0x1ffff (gte_divide), so the point lies about twice
// its view x, y from the offset, whatever its depth; taken as H / z, such
// corners (of a face running up to the lens) put the face's plane anywhere,
// and its cover flipped between frames.
@(private)
unproject :: #force_inline proc(x, y, z, h: f32, of: [2]f32) -> [3]f32 {
	k := max(z, h * DIVIDE_MAX) / h
	return {(x - of.x) * k, (y - of.y) * k, z}
}

// The inverse of the GTE divide's largest quotient, 0x1ffff / 0x10000.
@(private)
DIVIDE_MAX :: f32(0x10000) / 0x1ffff

// How the polygon through `corners` (packet screen x, y and view depth z, 3
// or 4 in GPU order) covers the leader: its plane has him behind it, the lens
// before.
@(private)
see_cover :: proc(corners: [][3]f32) -> See_Cover {
	p: [4][3]f32
	mid: [3]f32
	for c, i in corners {
		p[i] = see_point(c.x, c.y, c.z)
		mid += p[i]
	}
	mid /= f32(len(corners))
	// A quad's corners run 0 1 / 2 3: its normal is across the diagonals.
	n := len(corners) == 4 ? linalg.cross(p[3] - p[0], p[2] - p[1]) : linalg.cross(p[1] - p[0], p[2] - p[0])
	n = linalg.normalize0(n)
	lens := -linalg.dot(n, mid)
	leader := linalg.dot(n, see_through.target - mid)
	if lens * leader >= 0 {
		return {}
	}
	return {weight = smooth(SEE_BEHIND, SEE_BEHIND + SEE_FADE, abs(leader)) * smooth(0, SEE_FADE, abs(lens))}
}

// A black face narrower than this (view units; a cell is 128) between the
// leader and the lens is kept: a rope or a rail, not a wall's fill (Sarai's
// clotheslines are 24..39 across, room 0204's wall tops 43 and up).
@(private)
SEE_BLACK_THIN :: 40

// Whether the polygon through `corners` (as see_cover's) has a side shorter
// than SEE_BLACK_THIN.
@(private)
see_thin :: proc(corners: [][3]f32) -> bool {
	side := max(f32)
	p: [4][3]f32
	for c, i in corners {
		p[i] = see_point(c.x, c.y, c.z)
	}
	// A quad's corners run 0 1 / 2 3, round its edge 0 1 3 2.
	order := len(corners) == 4 ? [4]int{0, 1, 3, 2} : [4]int{0, 1, 2, 0}
	n := len(corners)
	for k in 0 ..< n {
		side = min(side, linalg.length(p[order[(k + 1) % n]] - p[order[k]]))
	}
	return side < SEE_BLACK_THIN
}

// How a sprite standing at view depth z covers the leader: like a wall
// before him when it stands nearer the lens than he does. Ground to ground:
// against his middle, raised toward a lens looking down, a person just
// behind him would count as in front.
@(private)
see_sprite_cover :: proc(z: f32) -> See_Cover {
	leader := see_through.feet - z
	if leader <= 0 {
		return {sprite = true}
	}
	return {weight = smooth(SEE_BEHIND, SEE_BEHIND + SEE_FADE, leader) * smooth(0, SEE_FADE, z), sprite = true}
}

// Opacity of a pixel at packet screen position x, y and view depth z, on a
// face covering the leader as `cover` says.
@(private)
see_alpha :: proc(x, y, z: f32, cover: See_Cover) -> f32 #no_bounds_check {
	return see_cover_alpha(x, y, z, cover) * (1 - cover.clear)
}

@(private = "file")
see_cover_alpha :: proc(x, y, z: f32, cover: See_Cover) -> f32 #no_bounds_check {
	near := smooth(SEE_NEAR[0], SEE_NEAR[1], z)
	if cover.weight <= 0 || near <= 0 {
		return near
	}
	s := &see_through
	p := see_point(x, y, z)
	t := linalg.dot(p, s.target) / see.reach2
	if t >= see.stop {
		return near
	}
	t = max(t, 0)
	d := linalg.length(p - s.target * t)
	r := max(t, SEE_CONE_MIN)
	// How far below the line from the lens to his feet.
	below := -linalg.dot(p - s.target * t, see.across) - see.drop * r
	inside :=
		cover.weight *
		(1 - smooth((SEE_RADIUS - SEE_SOFT) * r, SEE_RADIUS * r, d)) *
		(1 - smooth(SEE_FLOOR[0] * r, SEE_FLOOR[1] * r, below))
	g := cover.sprite ? SEE_SPRITE_GHOST : SEE_GHOST
	ghost := g[0] + (g[1] - g[0]) * t / see.stop
	return min(near, 1 - inside * (1 - ghost))
}

@(private)
smooth :: #force_inline proc(lo, hi, v: f32) -> f32 {
	t := clamp((v - lo) / (hi - lo), 0, 1)
	return t * t * (3 - 2 * t)
}
