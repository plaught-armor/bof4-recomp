// Enemy personalities and moods, on top of the enemy AI tiers (ai.odin).
//
// With `ai_moods`, each kind of enemy has a personality, looked up by the
// name the BWORLD record gives it (combatant +0x9c, 8 bytes): the families
// the series brings back act alike, from the Breath of Fire bestiary and the
// skill lists of the BWORLD records (Goos and vermin are cowards, soldier
// squads fight as a pack, fungi and mages trick, beasts are brutes, giants
// and kings are proud, machines feel nothing). The bosses' records
// (BWORLD/BOSS*.EMI) are named the same way, so a boss with a known nature is
// listed with the rest. A kind not in PERSONALITIES is steady.
//
// Each turn the enemy's mood comes from the fight, first match wins:
//
//   desperate  its HP below `desperate` twelfths, or (pack, devoted, coward,
//              steady) half or more of its side fallen: no buffs or
//              hindrances, its strongest damage skill instead of an attack
//   enraged    a member felled an ally (pack, devoted, brute, steady,
//              proud), or hit it for 1/`rage_hit` of its max HP or more:
//              every action on that member, for RAGE_TURNS of its turns or
//              until the member falls
//   cautious   its HP below `cautious` twelfths, or (coward, devoted,
//              steady) a dragon form on the field: heals allies below
//              CAUTIOUS_HEAL twelfths, one more buff in CHANCE_OF
//   cocky      the front members' HP below `cocky` twelfths of their max
//              while its own is above half: the game's random target, one
//              more buff and hindrance in CHANCE_OF
//
// ai.odin shapes the tier's plan by the mood (plan_of); the tier still
// decides what the enemy can work out, the mood what it wants. When an
// enemy's turn ends in a new mood, a window at the top left says so ("Eye
// Goo is desperate!") for SHOW_FRAMES game frames, as the enemy acts.
package qol

import "core:fmt"

import "ps:psx"

import "ps:core"

@(private)
Mood :: enum u8 {
	Calm,
	Cocky,
	Cautious,
	Enraged,
	Desperate,
}

@(private = "file")
Personality :: enum u8 {
	Steady,
	Brute,
	Coward,
	Devoted,
	Pack,
	Trickster,
	Proud,
	Machine,
}

@(private = "file")
Traits :: struct {
	desperate: u32, // twelfths of max HP, 0 never
	cautious:  u32, // twelfths of max HP, 0 never
	cocky:     u32, // twelfths of the front's max HP, 0 never
	rage_hit:  u32, // a hit of 1/rage_hit of max HP enrages, 0 never
	rage_ally: bool, // a felled ally enrages
	side:      bool, // half its side fallen makes it desperate
	dragon:    bool, // a dragon form makes it cautious
}

@(private = "file")
TRAITS := [Personality]Traits {
	.Steady    = {desperate = 3, cautious = 5, cocky = 4, rage_hit = 3, rage_ally = true, side = true, dragon = true},
	.Brute     = {desperate = 2, cocky = 6, rage_hit = 6, rage_ally = true},
	.Coward    = {desperate = 4, cautious = 9, cocky = 3, side = true, dragon = true},
	.Devoted   = {desperate = 3, cautious = 6, cocky = 3, rage_ally = true, side = true, dragon = true},
	.Pack      = {desperate = 3, cautious = 4, rage_hit = 4, rage_ally = true, side = true},
	.Trickster = {desperate = 3, cautious = 6, cocky = 8, rage_hit = 3},
	.Proud     = {desperate = 2, cocky = 8, rage_hit = 4, rage_ally = true},
	.Machine   = {},
}

// By BWORLD record name (AREAB and BOSS files); the rest are steady.
@(private = "file")
PERSONALITIES := [?]struct {
	name: string,
	kind: Personality,
} {
	// Goo family, vermin, small fry and the runaway treasure gangs.
	{"Eye Goo", .Coward},
	{"Mage Goo", .Coward},
	{"Flue Goo", .Coward},
	{"Baby Goo", .Coward},
	{"Rat", .Coward},
	{"Mouse", .Coward},
	{"Rat Pack", .Coward},
	{"Roach", .Coward},
	{"GntRoach", .Coward},
	{"Army Bat", .Coward},
	{"ToxicFly", .Coward},
	{"Gold Fly", .Coward},
	{"Egg Gang", .Coward},
	{"GoldGang", .Coward},
	{"Mimic", .Coward},
	{"Tadpole", .Coward},
	{"Catrpilr", .Coward},
	{"Puspool", .Coward},
	{"Bilbul", .Coward},
	{"Gasser", .Coward},
	{"Mud Pup", .Coward},
	// Healers.
	{"GooNurse", .Devoted},
	{"ZombieDr", .Devoted},
	{"Cadaver", .Devoted},
	{"Cap", .Devoted},
	{"Bolt Trp", .Devoted},
	{"Guardian", .Devoted},
	{"Poppy", .Devoted},
	{"Drake", .Devoted},
	// Soldier squads and troops.
	{"NutTroop", .Pack},
	{"Nut Mage", .Pack},
	{"NutArchr", .Pack},
	{"Troop", .Pack},
	{"Y.Troop", .Pack},
	{"G.Troop", .Pack},
	{"BeeTroop", .Pack},
	{"BoltArch", .Pack},
	{"BoltMage", .Pack},
	{"Patrol", .Pack},
	{"Pikeman", .Pack},
	{"Archer", .Pack},
	{"Sepoy", .Pack},
	{"Legion", .Pack},
	{"Saruga", .Pack},
	{"Yaen", .Pack},
	{"Soldier", .Pack},
	{"Grunt A", .Pack},
	{"Grunt B", .Pack},
	{"Grunt C", .Pack},
	{"EliteTrp", .Pack},
	// Fungi, spirits, thieves, mimics and mages.
	{"Bandit", .Trickster},
	{"Scavengr", .Trickster},
	{"Puppeter", .Trickster},
	{"Copycat", .Trickster},
	{"Decoy", .Trickster},
	{"Mirror", .Trickster},
	{"Mask", .Trickster},
	{"MaskCrab", .Trickster},
	{"Morph", .Trickster},
	{"MorphGoo", .Trickster},
	{"Wizard", .Trickster},
	{"Warlok", .Trickster},
	{"Nmago", .Trickster},
	{"Ghost", .Trickster},
	{"Spectre", .Trickster},
	{"Shade", .Trickster},
	{"Shadow", .Trickster},
	{"Red Cap", .Trickster},
	{"Blue Cap", .Trickster},
	{"Fungoid", .Trickster},
	{"Sporeon", .Trickster},
	{"Mandraga", .Trickster},
	{"Rafresia", .Trickster},
	{"Fragrans", .Trickster},
	{"Lampkin", .Trickster},
	{"Wyd", .Trickster},
	{"Firewyd", .Trickster},
	{"StarGazr", .Trickster},
	{"Istalk", .Trickster},
	{"Squirt", .Trickster},
	{"Tar Baby", .Trickster},
	{"Fantam", .Trickster},
	{"Diviner", .Trickster},
	{"Evoker", .Trickster},
	// Kings, giants and the big ones.
	{"Goo King", .Proud},
	{"GooCount", .Proud},
	{"King Rat", .Proud},
	{"Cyclops", .Proud},
	{"Titan", .Proud},
	{"Rider", .Proud},
	{"Trean", .Proud},
	{"Chopam", .Proud},
	{"Horseman", .Proud},
	{"Kolpum", .Proud},
	{"Karon", .Proud},
	{"Trunked", .Proud},
	{"Orochi", .Proud},
	{"Beihl", .Proud},
	// Kahn and Fou-lu's forms: generals and emperors who look down on the
	// party (Fou-lu's invincible first fight never drops below a share).
	{"Kahn", .Proud},
	{"Fou-lu", .Proud},
	{"Tyrant", .Proud},
	{"Astral", .Proud},
	{"Infinity", .Proud},
	// Bosses with a known story role: Joh is the warrior spirit of commander
	// Rasso and Ymechaf his samurai guardian, Won-qu the loyal guard of
	// Fou-lu's tomb and A-tur his other centuries-old servant, Glebe the
	// creature the Cove worships as its god and feeds sacrifices, Bellwyd
	// Marl's healer on Mt. Yogy, Papan Maman's mate, the sparrow flees a
	// party that only defends, Kham and Khafu are Yohm's beasts, Loam only
	// weakens. Marl is the god of Mt. Yogy, who calls up Klod, a beast, and
	// Bellwyd and calls them again when both fall; Ight is the warrior knight
	// Rasso summons; Umadap, Azeus, Agiel and Yeleb are the four pillars that
	// seal Ershin in her mind and regain HP every turn; Kahbo, on Kham's own
	// skill list, and Kamyu are the beasts at the Fou castle.
	{"Joh", .Proud},
	{"Ymechaf", .Proud},
	{"Glebe", .Proud},
	{"Won-qu", .Devoted},
	{"A-tur", .Devoted},
	{"Bellwyd", .Devoted},
	{"Papan", .Brute},
	{"Sparrow", .Coward},
	{"Kham", .Brute},
	{"Khafu", .Brute},
	{"Loam", .Trickster},
	{"Marl", .Proud},
	{"Klod", .Brute},
	{"Ight", .Proud},
	{"Umadap", .Machine},
	{"Azeus", .Machine},
	{"Agiel", .Machine},
	{"Yeleb", .Machine},
	{"Kahbo", .Brute},
	{"Kamyu", .Brute},
	// Beasts, bugs and the undead that only hit.
	{"Zaurus", .Brute},
	{"Fiend", .Brute},
	{"Scorpion", .Brute},
	{"Zombie", .Brute},
	{"Icebeak", .Brute},
	{"LizardMn", .Brute},
	{"Gecko", .Brute},
	{"Berserkr", .Brute},
	{"Smasher", .Brute},
	{"Krabby", .Brute},
	{"SaltClaw", .Brute},
	{"Sandclaw", .Brute},
	{"FireAnt", .Brute},
	{"Crawler", .Brute},
	{"Gulper", .Brute},
	{"Bollor", .Brute},
	{"Rollob", .Brute},
	{"Bilboa", .Brute},
	{"Bilbao", .Brute},
	{"BlackGoo", .Brute},
	{"Skullen", .Brute},
	{"Lavoid", .Brute},
	{"Snapfly", .Brute},
	{"Stingfly", .Brute},
	{"BloodBat", .Brute},
	{"FireWing", .Brute},
	{"Quisit", .Brute},
	{"Chingol", .Brute},
	{"Gonghead", .Brute},
	{"Gonger", .Brute},
	{"Maman", .Brute},
	{"Skulfish", .Brute},
	{"Angler", .Brute},
	// Constructs.
	{"Bot", .Machine},
	{"ProtoBot", .Machine},
	{"DeathBot", .Machine},
	{"BttlSuit", .Machine},
	{"Generatr", .Machine},
	{"Armor", .Machine},
	{"Warder", .Machine},
	{"Cairn", .Machine},
	{"Ibomb", .Machine},
	{"Bad Coil", .Machine},
	{"Dummy", .Machine},
}

@(private = "file")
ENEMY_NAME :: 0x9c // 8 bytes, NUL-padded
@(private = "file")
ENEMY_NAME_LEN :: 8
@(private = "file")
CHAR :: 0xa4 // u8, DRAGON_FORM and up a dragon form
@(private = "file")
DRAGON_FORM :: 7
@(private = "file")
FRONT :: 3
@(private = "file")
SLOTS :: 6
@(private = "file")
TWELFTHS :: 12
// Cautious heals allies below this many twelfths of their max HP.
@(private)
CAUTIOUS_HEAL :: 8
// Enraged lasts this many of the enemy's turns.
@(private = "file")
RAGE_TURNS :: 3
@(private)
NO_CULPRIT :: 255

@(private = "file")
MOOD_TEXT := [Mood]string {
	.Calm      = "",
	.Cocky     = "gets cocky",
	.Cautious  = "grows wary",
	.Enraged   = "is enraged!",
	.Desperate = "is desperate!",
}
@(private = "file")
MOOD_COLOUR := [Mood]int {
	.Calm      = MENU_WHITE,
	.Cocky     = MENU_YELLOW,
	.Cautious  = MENU_GREEN,
	.Enraged   = MENU_RED,
	.Desperate = MENU_RED,
}
@(private = "file")
SHOW_FRAMES :: 60
@(private = "file")
BOX_X :: 8
@(private = "file")
BOX_Y :: 8
@(private = "file")
BOX_PAD :: 8
@(private = "file")
GAME_MODE_BATTLE :: 5

@(private = "file")
moods: struct {
	// Per enemy slot, for this battle.
	slots: [SLOTS]struct {
		known:   bool,
		kind:    Personality,
		culprit: u8, // the member it is enraged at, NO_CULPRIT for none
		rage:    u8, // its turns left enraged
		mood:    Mood, // as its last turn ended
		name:    [ENEMY_NAME_LEN]u8,
		len:     int,
	},
	// The mood shown and until which game frame.
	shown:      Mood,
	shown_slot: u32,
	shown_till: u32,
	// Per enemy slot, whether it stood this battle.
	fought:  [SLOTS]bool,
}

@(private = "file")
personality :: proc(slot: u32) -> Personality {
	s := &moods.slots[slot]
	if s.known {
		return s.kind
	}
	name: [ENEMY_NAME_LEN]u8
	n := 0
	for ; n < ENEMY_NAME_LEN; n += 1 {
		name[n] = u8(psx.lbu(enemy_combatant(slot) + ENEMY_NAME + u32(n)))
		if name[n] == 0 {
			break
		}
	}
	s.name, s.len = name, n
	s.kind = .Steady
	for p in PERSONALITIES {
		if p.name == string(name[:n]) {
			s.kind = p.kind
			break
		}
	}
	s.known, s.culprit = true, NO_CULPRIT
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy slot %d %s is %v", slot, string(name[:n]), s.kind)
	}
	return s.kind
}

// Out of battle, forget the battle's moods.
@(private)
moods_tick :: proc() {
	moods = {}
}

// The mood of the enemy in `slot`, and the member it is enraged at
// (NO_CULPRIT unless enraged).
@(private)
mood_of :: proc(slot: u32) -> (Mood, u32) {
	if !config.battle_ai_moods || slot >= SLOTS {
		return .Calm, NO_CULPRIT
	}
	t := TRAITS[personality(slot)]
	s := &moods.slots[slot]
	e := enemy_combatant(slot)
	hp, hp_max := u64(psx.lw(e + COMBATANT_HP)), u64(max(psx.lw(e + COMBATANT_HP_MAX), 1))
	fought, fallen: u32
	for k in u32(0) ..< SLOTS {
		other := enemy_combatant(k)
		if psx.lw(other + COMBATANT_HP) != 0 {
			moods.fought[k] = true
		}
		if moods.fought[k] {
			fought += 1
			fallen += 1 if psx.lw(other + COMBATANT_HP) == 0 else 0
		}
	}
	if hp * TWELFTHS < hp_max * u64(t.desperate) || t.side && fought > 1 && fallen * 2 >= fought {
		return .Desperate, NO_CULPRIT
	}
	if s.rage != 0 && s.culprit < FRONT && psx.lw(party_combatant(u32(s.culprit)) + COMBATANT_HP) != 0 {
		return .Enraged, u32(s.culprit)
	}
	dragon := false
	front_hp, front_max: u64
	for member in u32(0) ..< FRONT {
		p := party_combatant(member)
		dragon ||= psx.lw(p + COMBATANT_HP) != 0 && psx.lbu(p + CHAR) >= DRAGON_FORM
		front_hp += u64(psx.lw(p + COMBATANT_HP))
		front_max += u64(psx.lw(p + COMBATANT_HP_MAX))
	}
	if hp * TWELFTHS < hp_max * u64(t.cautious) || t.dragon && dragon {
		return .Cautious, NO_CULPRIT
	}
	if hp * 2 > hp_max && front_hp * TWELFTHS < front_max * u64(t.cocky) {
		return .Cocky, NO_CULPRIT
	}
	return .Calm, NO_CULPRIT
}

// The enemy in `slot` decided its turn: a new mood shows, its rage cools.
@(private)
mood_turn :: proc(slot: u32) {
	if !config.battle_ai_moods || slot >= SLOTS {
		return
	}
	s := &moods.slots[slot]
	mood, _ := mood_of(slot)
	if .Game in core.trace.active {
		core.tracef(.Game, "moods: slot %d turn ends %v (was %v), HP %d/%d", slot, mood, s.mood, psx.lw(enemy_combatant(slot) + COMBATANT_HP), psx.lw(enemy_combatant(slot) + COMBATANT_HP_MAX))
	}
	if mood != s.mood {
		s.mood = mood
		if mood != .Calm {
			moods.shown, moods.shown_slot, moods.shown_till = mood, slot, psx.lw(GAME_FRAME) + SHOW_FRAMES
		}
	}
	if s.rage != 0 {
		s.rage -= 1
	}
}

@(private)
moods_draws :: proc() -> bool {
	return config.battle_ai_moods && psx.lhu(GAME_MODE) == GAME_MODE_BATTLE && psx.lw(GAME_FRAME) < moods.shown_till
}

@(private)
moods_draw :: proc() {
	s := &moods.slots[moods.shown_slot]
	buf: [32]u8
	text := fmt.bprintf(buf[:], "%s %s", string(s.name[:s.len]), MOOD_TEXT[moods.shown])
	menu_window(BOX_X, BOX_Y, menu_text_width(text) + 2 * BOX_PAD, 2 * BOX_PAD + MENU_LINE_H)
	menu_text(BOX_X + BOX_PAD, BOX_Y + BOX_PAD, text, MOOD_COLOUR[moods.shown])
}

// Before HP_APPLY takes `dealt` from `target`'s HP, as `actor` hit it: a
// felled ally or a big hit enrages.
@(private)
mood_hit :: proc(actor, target: u32, dealt: i32) {
	if !config.battle_ai_moods || dealt <= 0 || actor >= FRONT || target < ENEMY_IDS || target - ENEMY_IDS >= SLOTS {
		return
	}
	slot := target - ENEMY_IDS
	e := enemy_combatant(slot)
	hp := psx.lw(e + COMBATANT_HP)
	if hp == 0 {
		return
	}
	if u32(dealt) >= hp {
		for k in u32(0) ..< SLOTS {
			if k != slot && psx.lw(enemy_combatant(k) + COMBATANT_HP) != 0 && TRAITS[personality(k)].rage_ally {
				enrage(k, actor)
			}
		}
		return
	}
	if t := TRAITS[personality(slot)]; t.rage_hit != 0 && u64(dealt) * u64(t.rage_hit) >= u64(psx.lw(e + COMBATANT_HP_MAX)) {
		enrage(slot, actor)
	}
}

@(private = "file")
enrage :: proc(slot, member: u32) {
	moods.slots[slot].culprit = u8(member)
	moods.slots[slot].rage = RAGE_TURNS
	if .Game in core.trace.active {
		core.tracef(.Game, "ai: enemy slot %d enraged at member %d", slot, member)
	}
}
