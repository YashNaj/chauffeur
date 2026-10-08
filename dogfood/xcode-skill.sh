#!/bin/bash
# Prints Xcode's device-interaction skill. It's Apple's text, so it's exported from the installed Xcode at run time
# instead of being copied into this repo. Usage: dogfood/xcode-skill.sh
set -euo pipefail
D=$(mktemp -d); trap 'rm -rf "$D"' EXIT
xcrun mcpbridge run-agent skills export "$D" >/dev/null
cat "$D/device-interaction/SKILL.md"
