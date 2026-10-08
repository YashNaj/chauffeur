#!/bin/bash
# Fails when a commit in <rev-range> carries private material or an AI co-author trailer (M4a spec §2).
# Usage: scripts/check-commits.sh <rev-range>     e.g. scripts/check-commits.sh origin/main..HEAD
set -uo pipefail
RANGE=${1:?usage: scripts/check-commits.sh <rev-range>}
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
commits=$(git rev-list "$RANGE" 2>/dev/null) || { echo "check-commits: git can't resolve $RANGE" >&2; exit 2; }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
found=0
for c in $commits; do
  git log -1 --format='%an <%ae>%n%cn <%ce>%n%B' "$c" > "$T/$c"
  if grep -qiE '^co-authored-by:.*(claude|anthropic|openai|copilot|cursor)' "$T/$c"; then
    echo "$c: AI co-author trailer"
    found=1
  fi
done
if ! leaks=$("$SCRIPTS/check-public.sh" "$T"); then
  sed "s|^$T/||" <<<"$leaks"
  found=1
fi
[ $found -eq 0 ] && echo "check-commits: $(wc -w <<<"$commits" | tr -d ' ') commit(s) clean"
exit $found
