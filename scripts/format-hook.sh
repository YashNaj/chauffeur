#!/bin/bash
# Claude Code PostToolUse hook: formats a Swift file right after an agent edits it (M4a spec §4).
# Silent, and never blocks the edit: every path exits 0.
ROOT="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
file=$(python3 -I -c '
import json, sys
try:
    print(json.load(sys.stdin).get("tool_input", {}).get("file_path", ""))
except Exception:
    pass' 2>/dev/null)
case "$file" in "$ROOT"/*.swift) ;; *) exit 0 ;; esac
[ -f "$file" ] || exit 0
xcrun swift-format format -i --configuration "$ROOT/.swift-format" "$file" >/dev/null 2>&1
exit 0
