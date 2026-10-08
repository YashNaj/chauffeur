#!/bin/bash
# Smoke-tests `chauffeur mcp` against the installed Claude Code: does a real client accept our tool list?
# Usage: scripts/mcp-smoke.sh [path-to-chauffeur]   (default: .build/release/chauffeur). Costs ~$0.01 (haiku).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
BIN="${1:-$REPO/.build/release/chauffeur}"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
printf '{"mcpServers":{"chauffeur":{"command":"%s","args":["mcp"]}}}' "$BIN" > "$WORK/mcp.json"
cd "$WORK"
claude -p "Reply with the word ok." --model haiku --mcp-config "$WORK/mcp.json" --strict-mcp-config \
  --setting-sources local --tools Read --max-budget-usd 0.05 --output-format stream-json --verbose \
  < /dev/null 2> "$WORK/err" | head -1 > "$WORK/init.json"
python3 -I - "$WORK/init.json" <<'PY'
import json, sys
init = json.load(open(sys.argv[1]))
tools = sorted(t for t in init.get("tools", []) if t.startswith("mcp__chauffeur__"))
want = {"snapshot", "act", "screenshot", "logs", "app", "device", "doctor"}
got = {t.split("__")[-1] for t in tools}
print("claude", init.get("claude_code_version", "?"), "· chauffeur tools:", ", ".join(sorted(got)) or "none")
sys.exit(0 if want <= got else 1)
PY
