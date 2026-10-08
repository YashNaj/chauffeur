#!/bin/bash
# Updates an existing public clone to the current allowlisted tree as one new commit: scripts/sync-public.sh <clone>
# Same checks as export-public.sh: leak check, build, tests, and the commit's metadata.
set -euo pipefail
DEST=${1:?usage: scripts/sync-public.sh <clone>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[ -d "$DEST/.git" ] || { echo "sync: $DEST is not a git clone" >&2; exit 1; }
[ -z "$(git -C "$DEST" status --porcelain)" ] || { echo "sync: $DEST has uncommitted changes" >&2; exit 1; }
LIST=$(mktemp); trap 'rm -f "$LIST"' EXIT
python3 -I "$ROOT/scripts/select-public.py" "$ROOT" > "$LIST"
# Remove what the allowlist no longer selects, then copy what it does.
(cd "$DEST" && git ls-files) | while read -r f; do grep -qxF "$f" "$LIST" || git -C "$DEST" rm -q -- "$f"; done
rsync -a --files-from="$LIST" "$ROOT/" "$DEST/"
"$ROOT/scripts/check-public.sh" "$DEST"
(cd "$DEST" && swift build -c release 2>&1 | tail -1 && swift test 2>&1 | grep "Test run with")
export GIT_AUTHOR_NAME=YashNaj GIT_AUTHOR_EMAIL=68571013+YashNaj@users.noreply.github.com
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
MSG=${MESSAGE:?set MESSAGE to the public commit message}
(cd "$DEST" && git add -A && git commit -qm "$MSG")
META=$(mktemp -d); (cd "$DEST" && git log -1 --format='%an %ae %cn %ce%n%B' > "$META/commit.txt")
"$ROOT/scripts/check-public.sh" "$META"; rm -rf "$META"
echo "sync: $DEST at $(git -C "$DEST" rev-parse HEAD)"
