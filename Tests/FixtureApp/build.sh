#!/bin/bash
# Builds the live-test fixture app for the iOS simulator without an Xcode project; prints the .app path.
set -euo pipefail
cd "$(dirname "$0")"
OUT=../../.build/fixture-app
APP="$OUT/Fixture.app"
rm -rf "$APP" && mkdir -p "$APP"
xcrun -sdk iphonesimulator swiftc -parse-as-library -O \
  -target "$(uname -m)-apple-ios17.0-simulator" FixtureApp.swift -o "$APP/Fixture"
cp Info.plist "$APP/Info.plist"
codesign --force --sign - "$APP" >/dev/null 2>&1
echo "$(cd "$OUT" && pwd)/Fixture.app"
