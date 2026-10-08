#!/bin/bash
# Fails when a file under <dir> contains private material (M3b spec §2.2). Reads binary files too.
# Usage: scripts/check-public.sh <dir>
set -uo pipefail
DIR=${1:?usage: scripts/check-public.sh <dir>}
# Written with [] classes so the pattern does not match itself when the check scans this file.
PATTERN='m[y]ne|/Users/[Y]ash|y[a]shal|g[m]ail\.com|Y[a]sh'"'"'s'
hits=$(grep -rnaiE --exclude-dir=.git --exclude-dir=.build "$PATTERN" "$DIR" | LC_ALL=C cut -c1-200)
[ -z "$hits" ] && { echo "check-public: clean"; exit 0; }
echo "$hits"
echo "check-public: $(wc -l <<<"$hits" | tr -d ' ') private match(es)" >&2
exit 1
