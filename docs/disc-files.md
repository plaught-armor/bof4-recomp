# Disc files

## File table

The game does not open files by name. The executable holds a table of LBAs
(start sectors), one u32 per file, at `FILE_TABLE` 0x80172c10, and code loads
"file N". `tools/file_table.py` matches each index to its ISO path:

```sh
python3 -I tools/file_table.py "Breath of Fire IV (Track 1).bin" disc/SLUS_013.24
```

`tools/file_table.tsv` is that output (1009 files: index, LBA, path). Folders:
`BATTLE/` (battle system, AB* enemy sets, BDEMO), `BMAGIC/` (one container per
spell/skill effect), `BWORLD/` (battle backgrounds and bosses), `PLAYER/`,
`SCENARIO/`, `SYSTEM/` (FLD_MAIN, GAME, CAMP, SAVE, menus), `WORLD/` (field
maps, `AREA<letter><nnn>.EMI`), movies (`.STR`) and XA audio.

The port can tell which file the game starts reading: `psx.read_start_hook`
gets the LBA, which a lookup in the table turns back into a file index (used
by `qol/cinematics.odin`).

## The opening movie

`XA/ZBOF4.STR` (LBA 259934, 13807 raw sectors) is the only movie: 1380
frames of 320x240 at 15 a second (92 s), with XA audio on channel 1 (1725
sectors). Video sectors are Mode 2 data sectors (submode 0x48, not the video
bit) whose data begins with the STR header `60 01 01 80`, then u16 chunk
number, u16 chunk count (9) and u32 frame number at +8 (the first frame is 1).
`psx.movie_position` keeps the LBA and frame number of the last one the drive
read, which `qol/subtitles.odin` times its lines by. Extract it with
`dd bs=2352 skip=259934 count=13807` from the Track 1 image; ffmpeg plays it
with `-f psxstr`.

Its voice lines are Japanese with no subtitles in the US release (whisper
large-v3 transcription, video seconds):

| Seconds | Japanese | Port subtitle |
|---|---|---|
| 30.0-37.2 | 信じてましたよ 最初から | I believed in you, right from the start. |
| 37.2-45.7 | お前は何をしようとしている | What are you trying to do? |
| 45.7-48.5 | どこへ行こうというんだ | Where do you think you're going? |
| 60.0-65.3 | うつろわざる者 (the game's Japanese subtitle, on the title card) | The one who never changes... |
| 65.3-69.6 | そうだというのか | Is that what you're saying? |
| 69.6-71.1 | 違う | No! |
| 71.1-75.3 | 人は…人はそんなに汚れてはいない | People... People are not so corrupt! |
| 81.4-86.0 | あなたは誰だ | Who are you? |

## EMI containers

Almost every game file is an EMI container (little-endian):

| Offset | Content |
|---|---|
| 0x00 | u32 entry count |
| 0x04 | u32, always 1 |
| 0x08 | `"MATH_TBL"` |
| 0x10 | entries, 16 bytes each: u32 size, u32 load address (>= 0x80000000 = code overlay) or data kind, u32 info (global overlay id for code), u16 type, padding |
| 0x800 | entry data, each entry padded to a 2 KiB boundary |

Code entries are what `tools/emi_extract.py` writes to `overlays/` (see
[overlays.md](overlays.md)).

### Textures

Entry type 3 is a VRAM texture block, stored in square tiles of 32x32
halfwords (2048 bytes, rows of 64 bytes), tile after tile across, then the
next band of 32 rows. The entry's kind says where it goes: byte 3 is the
first tile column (x = byte 3 * 32 halfwords) and byte 1 the tiles across.
A field map's sprite sheets are kind 0x0c000e00: from VRAM 384,0, 14 tiles
(448 halfwords) across. The texels are 4 or 8 bits per pixel, as the
texture page that draws them says. Colour tables (CLUTs) are
in the entry with kind 0x80036400, 256 colours each; which CLUT belongs to
which texture is not stored with it (the map's geometry picks it), so viewing
one takes trying CLUTs.

Example: `WORLD/AREAE030.EMI` (map 081e, the sand flier cutscene) entry 5
with CLUT 2 is a dusk desert sky panorama in 64x32 tiles. No daytime desert
sky has been found yet.

## Field map files

Map ids (see [story-and-maps.md](story-and-maps.md)) name the file: area bit
0x1000 M, 0x0200 S, 0x0400 D, 0x0800 E, low byte the file number, so map 0805
is `WORLD/AREAE005.EMI` and map 1000 is `WORLD/AREAM000.EMI`. Each carries the map's geometry, collision, textures and
its code overlay (slot 0x801f0800).

## RTEST.EMI (developer text viewer)

`SYSTEM/RTEST.EMI` (file 0x244) is a leftover dialogue ("kaiwa") viewer:
entry 0 a VRAM block (kind 0x0a000208), entry 1 code for 0x8018d800 (overlay
id 0x294 = 660), the slot GAME.EMI's main loop loads to. It is a whole main
loop of its own: it dispatches on the mode byte 0x80114873 through its table
0x8018eb20, like GAME does, but its header is the id followed by its menu
strings (slot table at 0x8018d8b4), so it is not a drop-in for GAME. Nothing
loads it: the boot loads GAME by the constant 0x23f (0x8013ad80) and no code
holds 0x244.

Its menu picks a text bank (`M SHOP`, `CAPTION`, `ENEMY`, `BATTLE`, `SGAMEN`,
`FIELD`, `AREA` with a type letter M/S/D/B/E and number, `COMMON`) and a
message number (`KAIWA NO.%03X`), loads the bank's file (0x243 MSHOP.EMI,
0x246 SGAMEN.EMI, 0x247 SGAMENX.EMI, ...) through the loader 0x8013b6f4 and
shows the message with SHOW_MESSAGE 0x8014c090. Pad options set the box's
back colour (`JOY-RU BACK COLOR`) and text speed (`JOY-RL MOJI SPEED`). It
holds the party names (Scias, Ursula, Ershin, Fou-Lu) for name codes. No
gameplay content.

## Saves

A save is 0x1880 bytes: 0x180-byte memory card header, then the game region.
Byte 0x184f is the XOR of every byte before it. On a card it is stored as
`BASLUS-01324BOF4<NN>US` (NN = save number - 1). The Windows release stores
saves in exactly this form (`BOF4-NN.DAT`).

```sh
# put a raw save into a memory card image as save number 3
python3 -I tools/save_to_mcd.py BOF4-02.DAT bof4_slot1.mcd 3
```

Known save fields (offsets in the file):

| Offset | Size | Content |
|---|---|---|
| 0x180 + 0xe75 | u8 | map section to resume in |
| 0x180 + 0xe76 | u16 | map id |
| 0x180 + 0xe78 | u16, u16 | leader tile x, z |
| 0x184f | u8 | checksum |

`qol/warp.odin` rewrites these as a save loads (`BOF4_WARP`, see
[debugging.md](debugging.md)).

The port keeps memory cards as raw 128 KiB `.mcd` images: slot 1
`bof4_slot1.mcd`, slot 2 `bof4_slot2.mcd` in the working directory, or
`BOF4_MCD` / `BOF4_MCD2`.
