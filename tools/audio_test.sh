#!/bin/bash
# Paced, silent audio test: the game plays into a PipeWire null sink (clocked
# in real time like a sound card, heard by no one), pw-record takes the
# sink's monitor, and `bof4tools audio-check` looks for dropouts in it and
# lists the game's .Perf audio report (tools/build.sh builds bof4tools).
#
# Usage (from port/): ../tools/audio_test.sh OUT_DIR [VAR=value ...]
# The VAR=value pairs go to the game's environment, for example
#   ../tools/audio_test.sh /tmp/a BOF4_AUTO=auto.txt BOF4_REPLAY=rec/input.rec
#     BOF4_CONFIG=rec/bof4.ini BOF4_MCD=rec/bof4_slot1.mcd
# Do not set BOF4_FAST: an unpaced run queues no sound.
# The game draws on the first Vulkan device that will do (its log's
# "vulkan:" line names it). An integrated GPU is too slow for 60 vblanks a
# second in towns, so the queue runs dry for that reason alone; with Mesa,
# MESA_VK_DEVICE_SELECT=<vendor id>:<device id> picks another.
# SDL3 (under sdl2-compat) ignores PULSE_SINK and plays to the default sink,
# so the game goes through the pipewire driver, which honors PIPEWIRE_NODE.
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
pw-record -P stream.capture.sink=true --target bof4_test --rate 44100 --channels 2 --format s16 "$out/played.wav" &
rec=$!
sleep 0.5
status=0
env SDL_VIDEODRIVER=offscreen SDL_AUDIODRIVER=pipewire PIPEWIRE_NODE=bof4_test \
	BOF4_TRACE=game,perf BOF4_AUDIO_DUMP="$out/mixed.wav" "$@" \
	timeout 600 ./bof4 > "$out/log" 2>&1 || status=$?
sleep 0.5
kill -INT $rec
wait $rec || true
"$tools/bof4tools" audio-check "$out/played.wav" "$out/log"
exit $status
