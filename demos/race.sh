#!/bin/bash
# The race: one task, chauffeur then Xcode 27's MCP, from the same start state, stacked. Usage: UDID=<udid> demos/race.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$REPO/.build/release/chauffeur"; W=$(mktemp -d)
PROMPT=$(awk -F'\t' '$1=="F4"{print $3}' "$REPO/dogfood/tasks.tsv")
reset() { "$BIN" --udid "$UDID" terminate dev.chauffeur.fixture >/dev/null 2>&1 || true
          "$BIN" --udid "$UDID" launch dev.chauffeur.fixture >/dev/null; sleep 2; }
reset; "$REPO/demos/lib/agent-run.sh" "$W/c" chauffeur sonnet "chauffeur · run 1 of 2 · real time" "$PROMPT"
reset; "$REPO/demos/lib/agent-run.sh" "$W/x" xcode sonnet "Xcode 27 MCP · run 2 · same start state" "$PROMPT"
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
C=$(dur "$W/c/out.mp4"); X=$(dur "$W/x/out.mp4")
PAD=$(python3 -I -c "print(max(0.0, $X - $C))")
ffmpeg -y -loglevel error -i "$W/c/out.mp4" -i "$W/x/out.mp4" -filter_complex \
  "[0:v]tpad=stop_mode=clone:stop_duration=$PAD[a];[a][1:v]vstack=inputs=2,format=yuv420p" \
  -c:v libx264 -crf 24 -movflags +faststart "$W/race.mp4"
mkdir -p "$REPO/docs/media"; cp "$W/race.mp4" "$REPO/docs/media/race.mp4"
echo "chauffeur ${C}s, xcode ${X}s · work: $W"
