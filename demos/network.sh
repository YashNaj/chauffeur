#!/bin/bash
# A network task, chauffeur then Xcode's MCP, from the same start state, stacked, sped up 3× with a notice.
# Usage: UDID=<udid> demos/network.sh <task id, e.g. N2>   → docs/media/network-<task>.mp4 and .gif
set -euo pipefail
TASK=${1:?usage: UDID=<udid> demos/network.sh <task id>}
REPO="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$REPO/.build/release/chauffeur"; W=$(mktemp -d)
UDID=${UDID:?set UDID to the simulator to drive}
SPEED=${SPEED:-3}
PROMPT=$(awk -F'\t' -v id="$TASK" '$1==id{print $3}' "$REPO/dogfood/tasks.tsv")
[ -n "$PROMPT" ] || { echo "no task $TASK in dogfood/tasks.tsv" >&2; exit 2; }
# The Network tab's peer, as in dogfood/run.sh's network reset; the server outlives this script.
lsof -nP -iTCP:8765 -sTCP:LISTEN >/dev/null 2>&1 || { nohup python3 -I "$REPO/Tests/FixtureApp/netserver.py" >/dev/null 2>&1 & sleep 1; }
reset() { printf 'demo' | xcrun simctl pbcopy "$UDID" 2>/dev/null || true
          "$BIN" --udid "$UDID" terminate dev.chauffeur.fixture >/dev/null 2>&1 || true
          "$BIN" --udid "$UDID" launch dev.chauffeur.fixture >/dev/null; sleep 2; }
reset; "$REPO/demos/lib/agent-run.sh" "$W/c" chauffeur sonnet "chauffeur 0.2.0 · run 1 of 2 · ${SPEED}× speed" "$PROMPT"
reset; "$REPO/demos/lib/agent-run.sh" "$W/x" xcode sonnet "Xcode 27.1 MCP · run 2 · same start state · ${SPEED}× speed" "$PROMPT"
dur() { ffprobe -v error -show_entries format=duration -of csv=p=0 "$1"; }
C=$(dur "$W/c/out.mp4"); X=$(dur "$W/x/out.mp4")
PAD=$(python3 -I -c "print(max(0.0, $X - $C))")
FONT=/System/Library/Fonts/Helvetica.ttc
# No colons or commas: drawtext reads them as option syntax.
NOTICE="Sped up ${SPEED}x for this recording - real time was chauffeur $(printf '%.0f' "$C") s and Xcode $(printf '%.0f' "$X") s"
ffmpeg -y -loglevel error -i "$W/c/out.mp4" -i "$W/x/out.mp4" -filter_complex \
  "[0:v]tpad=stop_mode=clone:stop_duration=$PAD[a];[a][1:v]vstack=inputs=2[s];[s]setpts=PTS/$SPEED,drawbox=y=ih-44:h=44:color=black@0.75:t=fill,drawtext=fontfile=$FONT:text='$NOTICE':fontcolor=white:fontsize=24:x=(w-text_w)/2:y=h-33,format=yuv420p" \
  -r 30 -c:v libx264 -crf 24 -movflags +faststart "$W/network.mp4"
ffmpeg -y -loglevel error -i "$W/network.mp4" -vf "fps=10,scale=760:-1:flags=lanczos,split[s0][s1];[s0]palettegen=max_colors=128[p];[s1][p]paletteuse=dither=bayer:bayer_scale=5" "$W/network.gif"
mkdir -p "$REPO/docs/media"
cp "$W/network.mp4" "$REPO/docs/media/network-$TASK.mp4"; cp "$W/network.gif" "$REPO/docs/media/network-$TASK.gif"
echo "chauffeur ${C}s, xcode ${X}s, ${SPEED}× · $(du -h "$REPO/docs/media/network-$TASK.gif" | cut -f1) gif · work: $W"
