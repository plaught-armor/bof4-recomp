// English subtitles for the opening movie (not a game feature).
//
// The opening movie (XA/ZBOF4.STR, 1380 frames at 15 a second) has Japanese
// voice lines that the US release left without subtitles. While it plays,
// each line shows in English at the bottom of the picture, timed by the
// frame number in the movie's video sectors as the drive reads them
// (psx.movie_position). The translations are this port's own. "The one who
// never changes" is utsurowazaru mono, the game's Japanese subtitle, which
// the movie's title card shows.
package qol

import "ps:psx"

// ZBOF4.STR on the disc: its first sector and length in sectors.
@(private = "file")
OPENING_LBA :: 259934
@(private = "file")
OPENING_SECTORS :: 13807

// Movie frames per second.
@(private = "file")
MOVIE_FPS :: 15

@(private = "file")
Subtitle :: struct {
	from, to: f32, // seconds into the movie
	text:     string,
}

@(private = "file")
OPENING_LINES := [?]Subtitle {
	{30.0, 37.2, "I believed in you, right from the start."},
	{37.2, 45.7, "What are you trying to do?"},
	{45.7, 48.5, "Where do you think you're going?"},
	{60.0, 65.3, "The one who never changes..."},
	{65.3, 69.6, "Is that what you're saying?"},
	{69.6, 71.1, "No!"},
	{71.1, 75.3, "People... People are not so corrupt!"},
	{81.4, 86.0, "Who are you?"},
}

// The top of the label's text, in the 640x480 canvas.
@(private = "file")
SUBTITLE_Y :: 448

@(private = "file")
subtitles: struct {
	shown: bool, // the label holds a subtitle
}

@(private)
subtitles_vblank :: proc() {
	text := ""
	lba, frame := psx.movie_position()
	if config.text_subtitles && psx.movie_playing() && lba >= OPENING_LBA && lba < OPENING_LBA + OPENING_SECTORS {
		// Frame numbers start at 1.
		t := f32(max(frame, 1) - 1) / MOVIE_FPS
		for l in OPENING_LINES {
			if t >= l.from && t < l.to {
				text = l.text
				break
			}
		}
	}
	if text == "" && !subtitles.shown {
		return
	}
	psx.osd_set_label(text, (psx.WINDOW_W - len(text) * 8) / 2, SUBTITLE_Y)
	subtitles.shown = text != ""
}
