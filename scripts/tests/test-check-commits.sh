#!/bin/bash
# Tests check-commits.sh: bash scripts/tests/test-check-commits.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fail=0
ok() { echo "ok - $1"; }
bad() { echo "FAIL - $1"; fail=1; }

commit() { git -c user.name="$1" -c user.email="$2" commit -q --allow-empty -m "$3"; }
cd "$T" && git init -q && commit dev 1+dev@users.noreply.github.com base

commit dev 1+dev@users.noreply.github.com "clean change"
out=$("$ROOT/scripts/check-commits.sh" HEAD~1..HEAD); rc=$?
[ $rc -eq 0 ] && grep -q "1 commit(s) clean" <<<"$out" && ok "noreply commit passes" || bad "noreply commit passes (rc=$rc): $out"

commit dev "someone@g""mail.com" "leaky author"
out=$("$ROOT/scripts/check-commits.sh" HEAD~1..HEAD); rc=$?
[ $rc -eq 1 ] && grep -q "$(git rev-parse HEAD)" <<<"$out" && ok "personal email fails" || bad "personal email fails (rc=$rc): $out"

commit dev 1+dev@users.noreply.github.com "$(printf 'change\n\nCo-Authored-By: %s <noreply@anthropic.com>' "Clau""de")"
out=$("$ROOT/scripts/check-commits.sh" HEAD~1..HEAD); rc=$?
[ $rc -eq 1 ] && grep -q "AI co-author trailer" <<<"$out" && ok "AI trailer fails" || bad "AI trailer fails (rc=$rc): $out"

commit dev 1+dev@users.noreply.github.com "$(printf 'pairing\n\nCo-Authored-By: Sam <1+sam@users.noreply.github.com>')"
out=$("$ROOT/scripts/check-commits.sh" HEAD~1..HEAD); rc=$?
[ $rc -eq 0 ] && ok "human co-author passes" || bad "human co-author passes (rc=$rc): $out"

out=$("$ROOT/scripts/check-commits.sh" nosuchref..HEAD 2>&1); rc=$?
[ $rc -eq 2 ] && ok "bad range exits 2" || bad "bad range exits 2 (rc=$rc): $out"
exit $fail
