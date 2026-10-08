#!/bin/bash
# Project lint (M4a spec §5): the rules whose breach causes a real bug or mess here. Usage: scripts/check-code.sh [root]
# A line opts out with a trailing  // check-code: allow <rule> — <reason>
set -uo pipefail
SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${1:-$SCRIPTS/..}" && pwd)"
found=0

# report <rule> <message>: reads grep -n lines (path:line:text), skips comment lines and allowed lines.
report() {
  local rule=$1 msg=$2 file line text
  while IFS=: read -r file line text; do
    [[ $text =~ ^[[:space:]]*(//|/\*|\*) ]] && continue
    [[ $text =~ check-code:\ allow\ $rule\ (—|-)\ *[^[:space:]] ]] && continue
    echo "${file#"$ROOT"/}:$line: $rule: $msg"
    found=1
  done
}

# grep_sources <dir> <pattern> [exclude-dir]: grep -n over .swift, .m and .h files.
grep_sources() {
  local dir=$1 pattern=$2 exclude=${3:-}
  [ -d "$ROOT/$dir" ] || return 0
  if [ -n "$exclude" ]; then
    find "$ROOT/$dir" \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -not -path "$ROOT/$exclude/*" -print0
  else
    find "$ROOT/$dir" \( -name '*.swift' -o -name '*.m' -o -name '*.h' \) -print0
  fi | xargs -0 grep -nE "$pattern" /dev/null
}

report bridge "private API belongs in Sources/ChauffeurBridge" \
  < <(grep_sources Sources 'dlopen|dlsym|NSClassFromString|objc_msgSend|@_silgen_name|PrivateFrameworks' Sources/ChauffeurBridge)
report try-bang "a crash here takes the agent's session down; handle the error" \
  < <(grep_sources Sources 'try!')
report print "output goes through the CLI target; print corrupts the MCP stream" \
  < <(grep_sources Sources/ChauffeurCore '(^|[^[:alnum:]_.])print\(')

length_limit() {
  local dir=$1 max=$2 f n
  [ -d "$ROOT/$dir" ] || return 0
  while IFS= read -r -d '' f; do
    n=$(wc -l < "$f" | tr -d ' ')
    if [ "$n" -gt "$max" ]; then
      echo "${f#"$ROOT"/}:$n: file-length: $n lines, over the $max-line limit for $dir; split it"
      found=1
    fi
  done < <(find "$ROOT/$dir" -name '*.swift' -print0)
}
length_limit Sources 400
length_limit Tests 600

if ! leaks=$("$SCRIPTS/check-public.sh" "$ROOT"); then
  LC_ALL=C sed -E "s|^$ROOT/||; s|^([^:]+:[0-9]+):.*|\1: leak: private material|" <<<"$leaks"
  found=1
fi

[ $found -eq 0 ] && echo "check-code: clean"
exit $found
