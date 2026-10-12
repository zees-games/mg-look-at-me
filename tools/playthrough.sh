#!/usr/bin/env bash
# Plays a minute of level 1 under xvfb: a frame at each beat (screenshots/play_*.png) and the
# mix off the master bus (screenshots/play.wav), then prints the recording's levels.
#
#   tools/playthrough.sh
#   tools/playthrough.sh --sheet     # and screenshots/play_sheet.png, every frame on one sheet
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
timeout 180 xvfb-run -a "${GODOT:-godot}" --path . --resolution 1280x720 res://tools/playthrough.tscn
wav=screenshots/play.wav
echo "--- the mix (peak must stay under 0 dBFS; integrated loudness in LUFS)"
sox "$wav" -n stats 2>&1 | grep -E "Pk lev dB|RMS lev dB|Length s"
ffmpeg -hide_banner -nostats -i "$wav" -af ebur128=peak=true -f null - 2>&1 | grep -A12 "Summary" | grep -E "I:|LRA:|Peak:"
if [ "${1:-}" = "--sheet" ]; then
    montage screenshots/play_[0-9]_*.png -tile 4x -geometry 640x360+2+2 screenshots/play_sheet.png
    echo "sheet screenshots/play_sheet.png"
fi
