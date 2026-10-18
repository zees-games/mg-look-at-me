#!/usr/bin/env bash
# Render the game and look at it.
#
#   tools/shot.sh                               # the lobby, first person, flashlight on
#   tools/shot.sh --view=witch --level=8        # five metres from a witch, looking at her
#   tools/shot.sh --view=third --level=3        # third person
#   tools/shot.sh --view=cover                  # the loading cover, before it lifts
#   tools/shot.sh --view=above --level=16 --floor=1 --res=1600x1600   # a plan of one floor, labelled
#   tools/shot.sh --level=2 --room=r3 --yaw=90  # standing in a room
#   tools/shot.sh --caught=1 --out=res://screenshots/caught.png   # the moment of being caught
#   tools/shot.sh --view=prompt --houses=asylum,house             # the prompt after a house change and back
#   tools/shot.sh --view=above --houses=asylum --level=17 --floor=1   # a level of another house
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
args=(); view="eyes"; out=""; res="1280x720"
for arg in "$@"; do
    case "$arg" in
        --view=*) view="${arg#*=}"; args+=("$arg") ;;
        --out=*) out="${arg#*=}" ;;
        --res=*) res="${arg#*=}" ;;
        *) args+=("$arg") ;;
    esac
done
[ -n "$out" ] || out="res://screenshots/${view}.png"
exec xvfb-run -a "${GODOT:-godot}" --path . --resolution "$res" res://tools/shot.tscn -- "--out=$out" "--view=$view" "${args[@]}"
