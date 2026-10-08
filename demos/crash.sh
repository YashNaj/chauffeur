#!/bin/bash
# Crash detective: find why the app crashes, fix it, prove it. Works on a scratch copy of the test app.
# Usage: UDID=<udid> demos/crash.sh
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"; BIN="$REPO/.build/release/chauffeur"; W=$(mktemp -d)
# The agent's fixed copy must not outlive the demo: the live tests need Crash to crash.
trap '"$BIN" --udid "$UDID" install "$(bash "$REPO/Tests/FixtureApp/build.sh" | tail -1)" >/dev/null' EXIT
cp -R "$REPO/Tests/FixtureApp" "$W/FixtureApp"
APP=$(bash "$W/FixtureApp/build.sh" | tail -1)
"$BIN" --udid "$UDID" install "$APP" >/dev/null
"$BIN" --udid "$UDID" launch dev.chauffeur.fixture >/dev/null
"$REPO/demos/lib/agent-run.sh" "$W" code sonnet "chauffeur + Claude Code · Sonnet" \
  "The Fixture app's source is in ./FixtureApp. Tap Crash in the running app, find out why it crashes, fix the source, rebuild with ./FixtureApp/build.sh, install and launch it with chauffeur, and prove that Crash no longer crashes."
mkdir -p "$REPO/docs/media"
cp "$W/out.mp4" "$REPO/docs/media/crash.mp4"
echo "work: $W"
