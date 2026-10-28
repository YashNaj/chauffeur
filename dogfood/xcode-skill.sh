#!/bin/bash
# Prints Xcode's device-interaction skill. It's Apple's text, so it's exported from the installed Xcode at run time
# instead of being copied into this repo. Usage: dogfood/xcode-skill.sh
# The export is cached per Xcode build under $RESULTS (or $TMPDIR), because `mcpbridge run-agent skills export`
# once hung for 76 minutes (Xcode 27.1, 2026-10-27): each attempt gets 60 s and three tries.
set -euo pipefail
BUILD=$(xcodebuild -version 2>/dev/null | awk '/Build/{print $3}')
CACHE="${RESULTS:-${TMPDIR%/}}/xcode-skill.$BUILD.md"
if [ ! -s "$CACHE" ]; then
  D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
  for attempt in 1 2 3; do
    if perl -e 'alarm 60; exec @ARGV' xcrun mcpbridge run-agent skills export "$D" >/dev/null 2>&1 \
       && [ -s "$D/device-interaction/SKILL.md" ]; then
      cp "$D/device-interaction/SKILL.md" "$CACHE"; break
    fi
    echo "xcode-skill: export attempt $attempt failed or timed out" >&2
  done
  [ -s "$CACHE" ] || { echo "xcode-skill: could not export Xcode's device-interaction skill" >&2; exit 1; }
fi
cat "$CACHE"
