#!/bin/bash
# "It won't lie to you": a disabled button and a change the tree can't see. Usage: UDID=<udid> demos/honest.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$REPO/.build/release/chauffeur"; W=$(mktemp -d)
"$BIN" --udid "$UDID" terminate com.apple.Preferences >/dev/null 2>&1 || true
xcrun simctl ui "$UDID" appearance light
"$BIN" --udid "$UDID" terminate dev.chauffeur.fixture >/dev/null 2>&1 || true
"$BIN" --udid "$UDID" launch dev.chauffeur.fixture >/dev/null
"$REPO/demos/lib/agent-run.sh" "$W" chauffeur sonnet "chauffeur · Sonnet" \
  "In the Fixture app, go to the Form tab and tap Submit. Then turn on Dark Mode in the Settings app. Tell me exactly what happened each time."
mkdir -p "$REPO/docs/media"
cp "$W/out.mp4" "$REPO/docs/media/honest.mp4"
ffmpeg -y -loglevel error -i "$REPO/docs/media/honest.mp4" \
  -vf "fps=10,scale=900:-1:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse" "$REPO/docs/media/honest.gif"
echo "work: $W"
