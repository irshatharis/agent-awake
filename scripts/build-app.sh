#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
mkdir -p .build
STAGING="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Agent Awake.app"
swift build -c "$CONFIGURATION"
BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
cp "$BIN/AgentAwake" "$APP/Contents/MacOS/AgentAwake"
cp "$BIN/agent-awake-hook" "$APP/Contents/Helpers/agent-awake-hook"
cp "$BIN/agent-awake-helper" "$APP/Contents/Helpers/agent-awake-helper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/com.irshatharis.AgentAwake.helper.plist "$APP/Contents/Library/LaunchDaemons/"
ICONSET="$PWD/.build/AppIcon.iconset"
mkdir -p "$ICONSET"
swift scripts/make-icon.swift "$PWD/.build/icon-1024.png"
for SIZE in 16 32 128 256 512; do
    sips -z "$SIZE" "$SIZE" .build/icon-1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z "$DOUBLE" "$DOUBLE" .build/icon-1024.png --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
SIGN_ARGS=(--force --sign "$SIGN_IDENTITY" --options runtime)
if [ "$SIGN_IDENTITY" != "-" ]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" --identifier com.irshatharis.AgentAwake.hook "$APP/Contents/Helpers/agent-awake-hook"
codesign "${SIGN_ARGS[@]}" --identifier com.irshatharis.AgentAwake.helper "$APP/Contents/Helpers/agent-awake-helper"
codesign "${SIGN_ARGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/com.irshatharis.AgentAwake.helper.plist"
mkdir -p dist
if [ -d 'dist/Agent Awake.app' ]; then mv 'dist/Agent Awake.app' "$STAGING/previous.app"; fi
mv "$APP" 'dist/Agent Awake.app'
echo "Built $PWD/dist/Agent Awake.app"
