#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "${PREVIEW:-0}" = "1" ]; then
    if [ "${SIGN_IDENTITY:--}" != "-" ] || [ -n "${NOTARY_PROFILE:-}" ]; then
        echo 'Preview builds must use ad-hoc signing without notarization credentials.' >&2
        exit 1
    fi
else
    if [[ "${SIGN_IDENTITY:-}" != 'Developer ID Application: '* ]] || [ -z "${NOTARY_PROFILE:-}" ]; then
        echo 'Set SIGN_IDENTITY to a Developer ID Application identity and NOTARY_PROFILE to a Keychain profile.' >&2
        echo 'For an unnotarized preview, explicitly set PREVIEW=1.' >&2
        exit 1
    fi
    xcrun --find notarytool >/dev/null
    xcrun --find stapler >/dev/null
fi
scripts/check.sh
UNIVERSAL=1 scripts/build-app.sh
APP='dist/Agent Awake.app'
for EXECUTABLE in "$APP/Contents/MacOS/AgentAwake" "$APP/Contents/Helpers/agent-awake-hook" "$APP/Contents/Helpers/agent-awake-helper"; do
    lipo "$EXECUTABLE" -verify_arch arm64 x86_64
done
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
IMAGE="Agent-Awake-${VERSION}-macos-universal.dmg"
STAGING="$(mktemp -d "$PWD/.build/dmg.XXXXXX")"
trap 'rm -rf "$STAGING"' EXIT

notarize() {
    local artifact="$1" label="$2"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$STAGING/notary-result.json"
    if ! python3 -c 'import json, sys; sys.exit(json.load(open(sys.argv[1]))["status"] != "Accepted")' "$STAGING/notary-result.json"; then
        local submission_id
        submission_id="$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["id"])' "$STAGING/notary-result.json")"
        xcrun notarytool log "$submission_id" --keychain-profile "$NOTARY_PROFILE" "dist/notarization-${label}.json"
        echo "Apple rejected the $label. See dist/notarization-${label}.json." >&2
        exit 1
    fi
}

if [ "${PREVIEW:-0}" != "1" ]; then
    # Notarize and staple the app first so it also opens when copied off the DMG offline.
    mkdir "$STAGING/app"
    ditto "$APP" "$STAGING/app/Agent Awake.app"
    hdiutil create -volname 'Agent Awake' -srcfolder "$STAGING/app" -format UDZO "$STAGING/notarize-app.dmg" >/dev/null
    notarize "$STAGING/notarize-app.dmg" app
    xcrun stapler staple "$APP"
    xcrun stapler validate "$APP"
    spctl --assess --type execute --verbose=2 "$APP"
fi

mkdir "$STAGING/image"
ditto "$APP" "$STAGING/image/Agent Awake.app"
ln -s /Applications "$STAGING/image/Applications"
hdiutil create -volname 'Agent Awake' -srcfolder "$STAGING/image" -format UDZO "$STAGING/$IMAGE" >/dev/null
if [ "${PREVIEW:-0}" != "1" ]; then
    codesign --sign "$SIGN_IDENTITY" --timestamp "$STAGING/$IMAGE"
    notarize "$STAGING/$IMAGE" dmg
    xcrun stapler staple "$STAGING/$IMAGE"
    xcrun stapler validate "$STAGING/$IMAGE"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$STAGING/$IMAGE"
fi
codesign --verify --deep --strict "$APP"
hdiutil verify "$STAGING/$IMAGE" >/dev/null
mv -f "$STAGING/$IMAGE" "dist/$IMAGE"
(cd dist && shasum -a 256 "$IMAGE" > SHA256SUMS.txt)
echo "Release DMG: $PWD/dist/$IMAGE"
if [ "${PREVIEW:-0}" = "1" ]; then
    echo 'Preview only: ad-hoc signed, not Apple-notarized. macOS may block the first launch.'
else
    echo 'Developer ID signed and Apple-notarized. App and DMG tickets are stapled and verified.'
fi
