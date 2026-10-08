#!/bin/bash
# Exports the public tree as a fresh repo with one commit, tagged (M3b spec §2.3): scripts/export-public.sh <dest>
set -euo pipefail
DEST=${1:?usage: scripts/export-public.sh <dest>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -e "$DEST" ] && [ -n "$(ls -A "$DEST" 2>/dev/null)" ]; then echo "export: $DEST exists and is not empty" >&2; exit 1; fi
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/ChauffeurCore/Model.swift")
mkdir -p "$DEST"
python3 -I "$ROOT/scripts/select-public.py" "$ROOT" > "$DEST/.files"
rsync -a --files-from="$DEST/.files" "$ROOT/" "$DEST/"
rm "$DEST/.files"
"$ROOT/scripts/check-public.sh" "$DEST"
(cd "$DEST" && swift build -c release 2>&1 | tail -1 && swift test 2>&1 | grep "Test run with")
# The commit's author and committer are public too: use the GitHub identity, never the local git config.
export GIT_AUTHOR_NAME=YashNaj GIT_AUTHOR_EMAIL=68571013+YashNaj@users.noreply.github.com
export GIT_COMMITTER_NAME=$GIT_AUTHOR_NAME GIT_COMMITTER_EMAIL=$GIT_AUTHOR_EMAIL
(cd "$DEST" && git init -q -b main && git add -A && git commit -qm "chauffeur $VERSION" && git tag "v$VERSION")
META=$(mktemp -d); (cd "$DEST" && git log --format='%an %ae %cn %ce%n%B' > "$META/commit.txt")
"$ROOT/scripts/check-public.sh" "$META"; rm -rf "$META"
echo "export: $DEST at $(cd "$DEST" && git rev-parse HEAD) tagged v$VERSION"
