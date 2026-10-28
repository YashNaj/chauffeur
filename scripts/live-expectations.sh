#!/bin/bash
# The live tests' expected strings, one `file: literal` line each, into the refactor's expectations ledger.
# Every later refactor stage re-runs this; the diff against the committed ledger must be empty (a live expectation
# changing is an output change, and the refactor changes no output). The first line names the commit it was made
# from, so compare from the third line on.
# Usage: scripts/live-expectations.sh
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
out="$root/docs/plans/2026-10-27-refactor-live-expectations.md"
commit="$(git -C "$root" rev-parse --short HEAD)"
cd "$root/Tests/ChauffeurCoreTests/Live"
{
  echo "Literals the live tests expect (contains, hasPrefix, hasSuffix, == \"…\"), one \`file: literal\` per line, made by scripts/live-expectations.sh at $commit."
  echo
  # A string literal is any run of non-quote, non-backslash characters or escaped characters between quotes.
  grep -oE '(contains|hasPrefix|hasSuffix)\("([^"\\]|\\.)*"|== "([^"\\]|\\.)*"' ./*.swift | sed -e 's|^\./||' -e 's/:/: /' \
    | LC_ALL=C sort
} >"$out"
