#!/bin/bash
# Paced, silent audio test: the game plays into a PipeWire null sink (clocked
# in real time like a sound card, heard by no one), pw-record takes the
# sink's monitor, and tools/audio_check.py looks for dropouts in it and
# lists the game's .Perf audio report.
#
# Usage (from port/): ../tools/audio_test.sh OUT_DIR [VAR=value ...]
# The VAR=value pairs go to the game's environment, for example
#   ../tools/audio_test.sh /tmp/a BOF4_AUTO=auto.txt BOF4_REPLAY=rec/input.rec
#     BOF4_CONFIG=rec/bof4.ini BOF4_MCD=rec/bof4_slot1.mcd
# Do not set BOF4_FAST: an unpaced run queues no sound.
# Leaves the bof4_test sink loaded; remove it with
#   pactl unload-module module-null-sink
set -e
out=$1
shift
mkdir -p "$out"
tools=$(dirname "$(realpath "$0")")
if ! pactl list short sinks | grep -q '\bbof4_test\b'; then
	pactl load-module module-null-sink sink_name=bof4_test sink_properties=device.description=bof4_test > /dev/null
fi
pw-record --target bof4_test --rate 44100 --channels 2 --format s16 "$out/played.wav" &
rec=$!
sleep 0.5
status=0
env SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=pulseaudio PULSE_SINK=bof4_test \
	BOF4_TRACE=qol,perf BOF4_AUDIO_DUMP="$out/mixed.raw" "$@" \
	timeout 600 ./bof4 > "$out/log" 2>&1 || status=$?
sleep 0.5
kill -INT $rec
wait $rec || true
python3 -P "$tools/audio_check.py" "$out/played.wav" "$out/log"
exit $status
