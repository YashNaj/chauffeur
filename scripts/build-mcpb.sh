#!/bin/bash
# Builds chauffeur.mcpb (an MCP bundle for the MCP Registry and MCPB clients): scripts/build-mcpb.sh <out-dir>
# Prints the bundle's path and SHA-256; server.json's fileSha256 must match the file attached to the release.
set -euo pipefail
OUT=${1:?usage: scripts/build-mcpb.sh <out-dir>}
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(sed -n 's/.*static let version = "\(.*\)".*/\1/p' "$ROOT/Sources/ChauffeurCore/Model.swift")
TOP=$(mktemp -d); trap 'rm -rf "$TOP"' EXIT; STAGE=$TOP
# A shipped binary must not carry the build machine's paths: remap source paths (#file, debug info) to "chauffeur",
# build into the stage, and strip the debug-object references. Then refuse any absolute path that survives.
BUILD="$STAGE/build"
(cd "$ROOT" && swift build -c release --scratch-path "$BUILD" \
  -Xswiftc -file-prefix-map -Xswiftc "$ROOT=chauffeur" -Xcc "-ffile-prefix-map=$ROOT=chauffeur" 2>&1 | tail -1)
mkdir -p "$STAGE/bundle/server" "$OUT"
cp "$BUILD/release/chauffeur" "$STAGE/bundle/server/chauffeur"
strip -S "$STAGE/bundle/server/chauffeur"
codesign --force --sign - "$STAGE/bundle/server/chauffeur" 2>/dev/null
if LEFT=$(grep -aoE "($ROOT|$STAGE|/Users/[^/]+/|/private/(tmp|var)/|/var/folders/)" "$STAGE/bundle/server/chauffeur" | sort -u) && [ -n "$LEFT" ]; then
  echo "build-mcpb: the binary still carries local paths:" >&2; echo "$LEFT" >&2; exit 1
fi
rm -rf "$BUILD"; STAGE="$STAGE/bundle"
cp "$ROOT/LICENSE" "$ROOT/NOTICE" "$STAGE/"
sed "s/\"VERSION\"/\"$VERSION\"/" "$ROOT/scripts/mcpb/manifest.json" > "$STAGE/manifest.json"
npx -y @anthropic-ai/mcpb validate "$STAGE/manifest.json" >/dev/null
"$ROOT/scripts/check-public.sh" "$STAGE"
npx -y @anthropic-ai/mcpb pack "$STAGE" "$OUT/chauffeur.mcpb" >/dev/null
echo "$OUT/chauffeur.mcpb $(shasum -a 256 "$OUT/chauffeur.mcpb" | cut -d' ' -f1)"
