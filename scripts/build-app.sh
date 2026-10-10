#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIGURATION="${CONFIGURATION:-release}"
SIGN_IDENTITY="${SIGN_IDENTITY:--}"
mkdir -p .build
STAGING="$(mktemp -d "$PWD/.build/package.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/Agent Awake.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$APP/Contents/Library/LaunchDaemons"
if [ "${UNIVERSAL:-0}" = "1" ]; then
    # SwiftPM's multi-arch --arch mode requires full Xcode. Build each target
    # independently and merge so Command Line Tools can also package releases.
    for ARCH in arm64 x86_64; do
        swift build -c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0"
        BIN="$(swift build -c "$CONFIGURATION" --triple "$ARCH-apple-macosx14.0" --show-bin-path)"
        mkdir -p "$STAGING/$ARCH"
        for NAME in AgentAwake agent-awake-hook agent-awake-helper; do
            cp "$BIN/$NAME" "$STAGING/$ARCH/$NAME"
        done
    done
    lipo -create "$STAGING/arm64/AgentAwake" "$STAGING/x86_64/AgentAwake" -output "$APP/Contents/MacOS/AgentAwake"
    for NAME in agent-awake-hook agent-awake-helper; do
        lipo -create "$STAGING/arm64/$NAME" "$STAGING/x86_64/$NAME" -output "$APP/Contents/Helpers/$NAME"
    done
else
    swift build -c "$CONFIGURATION"
    BIN="$(swift build -c "$CONFIGURATION" --show-bin-path)"
    cp "$BIN/AgentAwake" "$APP/Contents/MacOS/AgentAwake"
    cp "$BIN/agent-awake-hook" "$APP/Contents/Helpers/agent-awake-hook"
    cp "$BIN/agent-awake-helper" "$APP/Contents/Helpers/agent-awake-helper"
fi
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
# launchd may supply a relative argv[0]. Verify bundle discovery uses the real executable.
/bin/bash -c 'exec -a Contents/Helpers/agent-awake-helper "$1" --check-bundle' _ "$APP/Contents/Helpers/agent-awake-helper"
plutil -lint "$APP/Contents/Info.plist" "$APP/Contents/Library/LaunchDaemons/com.irshatharis.AgentAwake.helper.plist"
mkdir -p dist
if [ -d 'dist/Agent Awake.app' ]; then mv 'dist/Agent Awake.app' "$STAGING/previous.app"; fi
mv "$APP" 'dist/Agent Awake.app'
echo "Built $PWD/dist/Agent Awake.app"
