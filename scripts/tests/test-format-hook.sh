#!/bin/bash
# Tests format-hook.sh: bash scripts/tests/test-format-hook.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

P="$T/proj with space"; mkdir -p "$P/Sources" "$T/elsewhere"
cp "$ROOT/.swift-format" "$P/.swift-format"
hook() { printf '{"tool_name":"Edit","tool_input":{"file_path":"%s"}}' "$1" | CLAUDE_PROJECT_DIR="$P" "$ROOT/scripts/format-hook.sh"; }

printf 'let  a=1\n' > "$P/Sources/A.swift"
out=$(hook "$P/Sources/A.swift"); rc=$?
[ $rc -eq 0 ] && [ "$(cat "$P/Sources/A.swift")" = "let a = 1" ] && [ -z "$out" ] \
  && ok "formats a Swift file (path with a space)" || bad "formats a Swift file: rc=$rc out=$out file=$(cat "$P/Sources/A.swift")"

printf 'let  a=1\n' > "$P/notes.md"
hook "$P/notes.md"; [ "$(cat "$P/notes.md")" = "let  a=1" ] && ok "leaves other files alone" || bad "leaves other files alone"

printf 'let  a=1\n' > "$T/elsewhere/B.swift"
hook "$T/elsewhere/B.swift"; [ "$(cat "$T/elsewhere/B.swift")" = "let  a=1" ] && ok "leaves files outside the project alone" || bad "outside the project"

printf 'func f( {\n  let  a=1\n' > "$P/Sources/Broken.swift"; cp "$P/Sources/Broken.swift" "$T/broken.orig"
hook "$P/Sources/Broken.swift"; rc=$?
[ $rc -eq 0 ] && cmp -s "$P/Sources/Broken.swift" "$T/broken.orig" && ok "invalid Swift left unchanged" || bad "invalid Swift left unchanged (rc=$rc)"

hook "$P/Sources/Missing.swift"; [ $? -eq 0 ] && ok "missing file exits 0" || bad "missing file exits 0"
echo 'not json' | CLAUDE_PROJECT_DIR="$P" "$ROOT/scripts/format-hook.sh"; [ $? -eq 0 ] && ok "bad JSON exits 0" || bad "bad JSON exits 0"
exit $fail
