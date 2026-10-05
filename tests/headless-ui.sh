#!/usr/bin/env bash
# Run this through Oriel scripts/headless.sh; all clicks stay on private Xvfb.
set -euo pipefail
./zig-out/bin/hollershare >artifacts/ui.log 2>&1 &
app_pid=$!
trap 'kill "$app_pid" 2>/dev/null || true' EXIT
sleep 3
window=$(xdotool search --name "^HollerShare$" | head -1)
xdotool windowsize "$window" 980 860
sleep 1
# Toggle visibility and open the real GTK file picker.
xdotool mousemove --window "$window" 850 44 click 1
sleep 1
import -window root artifacts/hidden-ui.png
xdotool mousemove --window "$window" 190 615 click 1
sleep 2
dialog=$(xdotool search --name "Choose a file to share" | head -1)
xdotool windowfocus --sync "$dialog"
xdotool key ctrl+l
sleep 1
import -window root artifacts/picker-location.png
xdotool key ctrl+a
xdotool type --clearmodifiers --delay 0 "$PWD/README.md"
import -window root artifacts/picker-path.png
xdotool key Return
sleep 2
xdotool key Return
sleep 2
import -window root artifacts/selected-ui.png

