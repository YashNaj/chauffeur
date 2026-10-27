#!/bin/bash
# Signs a chauffeur binary ad hoc with the hardened runtime, then checks the signature: the runtime flag is set and
# there is no get-task-allow entitlement. Key commands refuse to run from a binary that fails either (M5a spec §5).
# Usage: scripts/sign.sh [path]   (default: .build/release/chauffeur)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
path=${1:-$ROOT/.build/release/chauffeur}
[ -f "$path" ] || { echo "sign: no binary at $path" >&2; exit 1; }
codesign --force --sign - --options runtime "$path" 2>/dev/null || { echo "sign: codesign failed on $path" >&2; exit 1; }
# Read each answer whole: grep -q exits early, and under pipefail codesign's SIGPIPE would fail the check.
details=$(codesign -d -vv "$path" 2>&1)
grep -q 'flags=.*runtime' <<<"$details" || { echo "sign: $path is not signed with the hardened runtime" >&2; exit 1; }
entitlements=$(codesign -d --entitlements - "$path" 2>/dev/null || true)
if grep -q get-task-allow <<<"$entitlements"; then
  echo "sign: $path still carries get-task-allow" >&2; exit 1
fi
echo "signed $path: hardened runtime, no get-task-allow"
