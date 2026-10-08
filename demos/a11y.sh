#!/bin/bash
# Accessibility audit of Settings › General, prompt only. Usage: UDID=<udid> demos/a11y.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$REPO/.build/release/chauffeur"; W=$(mktemp -d)
"$BIN" --udid "$UDID" terminate com.apple.Preferences >/dev/null 2>&1 || true
"$BIN" --udid "$UDID" button home >/dev/null || true  # NO EFFECT (exit 3) when already home
"$REPO/demos/lib/agent-run.sh" "$W" chauffeur sonnet "chauffeur · accessibility audit" \
  "Open Settings › General and audit that screen for accessibility problems a VoiceOver user would hit: buttons without a label, tap targets smaller than 44 by 44 points, and text that is cut off. Use snapshots with coordinates (snapshot all) and a screenshot if you need one. Report each finding with the element, its size, and why it matters. Don't change any setting."
echo "work: $W"
