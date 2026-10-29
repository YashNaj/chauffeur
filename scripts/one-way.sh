#!/bin/bash
# Counts the ways the tree does each thing; the numbers in every refactor PR body, before and after.
# Usage: scripts/one-way.sh [root]
set -uo pipefail
cd "${1:-$(dirname "$0")/..}"
src=$(find Sources -name '*.swift' -o -name '*.[hm]')
bridge=$(find Sources/ChauffeurBridge -type f ! -name 'CHInternal.[hm]')
code() { xargs grep -HE "$1" 2>/dev/null | grep -vE '^[^:]*:[[:space:]]*//' || true; }   # matching lines, comments out
files() { code "$1" | cut -d: -f1 | sort -u | wc -l | tr -d ' '; }                       # files with a match
uses() { code "$1" | cut -d: -f2- | grep -oE "$1" | wc -l | tr -d ' '; }                  # occurrences
echo "sources-lines: $(echo "$src" | xargs cat | wc -l | tr -d ' ')"
echo "sources-files: $(echo "$src" | wc -l | tr -d ' ')"
echo "over-300: $(echo "$src" | xargs wc -l | awk '$2 != "total" && $1 > 300 {print $2}' | xargs -n1 basename 2>/dev/null | paste -sd, -)"
echo "usage-literals: $(echo "$src" | grep -v 'Engine/Commands.swift' | uses '"usage: chauffeur')"
echo "session-seams: $(grep -cE '(var|let) (commandHook|relaunch|telemetryOverride|crashReportWaitMs)\b' Sources/ChauffeurCore/Engine/Session.swift)"
echo "outcome-changed: $(echo "$src" | files 'outcome = \.changed')"
echo "outcome-list: $(echo "$src" | files 'NOT DELIVERED[^A-Za-z]{1,6}(or )?`?UNVERIFIED')"
echo "exit-code-line: $(echo "$src" | files '3 no verified effect|exit codes:')"
echo "bridge-dlopen: $(echo "$bridge" | uses 'dlopen\(')"
echo "bridge-dlsym: $(echo "$bridge" | uses 'dlsym\(')"
echo "bridge-semaphore: $(echo "$bridge" | uses 'dispatch_semaphore_create\(')"
echo "bridge-error: $(echo "$bridge" | uses 'errorWithDomain:')"
echo "bridge-kvc: $(echo "$bridge" | uses 'valueForKey:')"
echo "hid-owners: $(echo "$src" | uses 'CHHIDClient\(')"
echo "quote-callers: $(echo "$src" | uses 'Perception\.quote\(|\.escape\(')"
