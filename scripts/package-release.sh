#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/check.sh
UNIVERSAL=1 scripts/build-app.sh
APP='dist/Agent Awake.app'
for EXECUTABLE in "$APP/Contents/MacOS/AgentAwake" "$APP/Contents/Helpers/agent-awake-hook" "$APP/Contents/Helpers/agent-awake-helper"; do
    lipo "$EXECUTABLE" -verify_arch arm64 x86_64
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCHIVE="Agent-Awake-${VERSION}-macos-universal.zip"
ditto -c -k --sequesterRsrc --keepParent "$APP" "dist/$ARCHIVE"
(cd dist && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
echo "Release archive: $PWD/dist/$ARCHIVE"
echo 'This archive is not notarized unless separately submitted to Apple and stapled.'
