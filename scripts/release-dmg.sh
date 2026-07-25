#!/bin/bash
#
#  release-dmg.sh
#  FinvestLens
#
#  Builds a Developer ID–signed, notarized, stapled DMG for direct
#  distribution (the app is not sandboxed, so the Mac App Store is not the
#  route — see docs/deferred.md §4).
#
#  Everything here is repeatable and idempotent except the one credential
#  step, which is deliberately NOT automated: notarization needs an
#  app-specific password, and that is stored once, by you, in your keychain:
#
#      xcrun notarytool store-credentials "hellotham-notary" \
#          --apple-id "you@example.com" --team-id RPL5R637DS
#
#  It prompts for the app-specific password and stores it in the keychain.
#  This script then uses the stored profile by name and never sees the secret.
#
#  Usage:  scripts/release-dmg.sh [--skip-notarize]
#
#  Copyright (C) 2026 Christine Tham
#  SPDX-License-Identifier: GPL-3.0-or-later
#

set -euo pipefail

APP_NAME="finvestlens"
SCHEME="finvestlens"
TEAM_ID="RPL5R637DS"
SIGN_ID="Developer ID Application: Hello Tham Pty. Ltd. (${TEAM_ID})"
NOTARY_PROFILE="${NOTARY_PROFILE:-hellotham-notary}"
VOLUME_NAME="FinvestLens"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/release"
ARCHIVE="$BUILD/$APP_NAME.xcarchive"
EXPORT="$BUILD/export"
STAGE="$BUILD/dmg-stage"

SKIP_NOTARIZE=0
[[ "${1:-}" == "--skip-notarize" ]] && SKIP_NOTARIZE=1

step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
fail() { printf "\n\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# ---------------------------------------------------------------- preflight

step "Preflight"
security find-identity -v -p codesigning | grep -q "$SIGN_ID" \
    || fail "Developer ID certificate not found in the keychain: $SIGN_ID"
echo "  signing identity ✓"

if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    if ! xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
        cat <<EOF

  Notarization credentials are not stored yet. Run this once, in your own
  terminal — it prompts for your app-specific password and keeps it in the
  keychain, so this script never handles the secret:

      xcrun notarytool store-credentials "$NOTARY_PROFILE" \\
          --apple-id "YOUR-APPLE-ID" --team-id $TEAM_ID

  Then run this script again. To build an unnotarized DMG meanwhile:

      scripts/release-dmg.sh --skip-notarize

EOF
        exit 2
    fi
    echo "  notary profile '$NOTARY_PROFILE' ✓"
fi

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
    "$ROOT/$APP_NAME/Info.plist" 2>/dev/null || echo "")
[[ -z "$VERSION" ]] && VERSION=$(xcodebuild -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" -showBuildSettings 2>/dev/null \
    | awk -F' = ' '/ MARKETING_VERSION /{print $2; exit}')
VERSION="${VERSION:-1.0}"
DMG="$BUILD/FinvestLens-$VERSION.dmg"
echo "  version $VERSION"

# ------------------------------------------------------------------ archive

step "Archiving (Release, Developer ID)"
rm -rf "$ARCHIVE" "$EXPORT" "$STAGE"
mkdir -p "$BUILD"
xcodebuild archive \
    -project "$ROOT/$APP_NAME.xcodeproj" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    CODE_SIGN_STYLE=Automatic \
    | grep -E "error:|warning: .*sign|ARCHIVE" || true
[[ -d "$ARCHIVE" ]] || fail "archive failed"

# ------------------------------------------------------------------- export

step "Exporting the signed app"
cat > "$BUILD/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>automatic</string>
    <key>destination</key><string>export</string>
</dict>
</plist>
EOF
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT" \
    -exportOptionsPlist "$BUILD/ExportOptions.plist" \
    -allowProvisioningUpdates \
    | grep -E "error:|EXPORT" || true
APP="$EXPORT/$APP_NAME.app"
[[ -d "$APP" ]] || fail "export failed — no app at $APP"

step "Verifying the signature"
codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'
# Every embedded executable must carry the hardened runtime, or notarization
# rejects the whole submission.
while IFS= read -r binary; do
    flags=$(codesign -d --verbose=2 "$binary" 2>&1 | awk -F= '/^CodeDirectory/{print}')
    case "$flags" in
        *runtime*) ;;
        *) fail "hardened runtime missing on $(basename "$binary")" ;;
    esac
done < <(find "$APP" \( -name "*.appex" -o -name "*.app" \) -print)
echo "  hardened runtime on every executable ✓"

# ------------------------------------------------------- notarize the app

# The app is notarized and stapled *before* the DMG is built. Stapling only
# the DMG leaves the copy in /Applications without a local ticket, so a first
# launch on an offline Mac has nothing to check against.
if [[ $SKIP_NOTARIZE -eq 0 ]]; then
    step "Notarizing the app (waits on Apple)"
    ditto -c -k --keepParent "$APP" "$BUILD/app.zip"
    xcrun notarytool submit "$BUILD/app.zip" \
        --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 \
        | tee "$BUILD/notarize-app.log" | sed 's/^/  /'
    grep -q "status: Accepted" "$BUILD/notarize-app.log" || {
        id=$(awk '/id:/{print $2; exit}' "$BUILD/notarize-app.log")
        echo "      xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
        fail "app notarization failed"
    }
    xcrun stapler staple "$APP" | sed 's/^/  /'
    rm -f "$BUILD/app.zip"
fi

# ---------------------------------------------------------------------- dmg

step "Building the disk image"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FinvestLens.app"
ln -s /Applications "$STAGE/Applications"
# A short read-me so a first-time user knows what they have.
cat > "$STAGE/Read Me.txt" <<EOF
FinvestLens $VERSION

Drag FinvestLens to the Applications folder, then open it from there.

FinvestLens is free software under the GNU General Public License v3.0.
Source: https://github.com/hellotham/finvestlens
EOF

rm -f "$DMG"
hdiutil create \
    -volname "$VOLUME_NAME" \
    -srcfolder "$STAGE" \
    -ov -format UDZO -imagekey zlib-level=9 \
    "$DMG" | sed 's/^/  /'

step "Signing the disk image"
codesign --force --sign "$SIGN_ID" --timestamp "$DMG"
codesign --verify --verbose=2 "$DMG" 2>&1 | sed 's/^/  /'

# ---------------------------------------------------------------- notarize

if [[ $SKIP_NOTARIZE -eq 1 ]]; then
    step "Skipping notarization (--skip-notarize)"
    echo "  $DMG"
    echo "  NOT notarized — Gatekeeper will refuse this on another Mac."
    exit 0
fi

step "Notarizing the disk image (waits on Apple)"
xcrun notarytool submit "$DMG" \
    --keychain-profile "$NOTARY_PROFILE" \
    --wait 2>&1 | tee "$BUILD/notarize.log" | sed 's/^/  /'
grep -q "status: Accepted" "$BUILD/notarize.log" || {
    id=$(awk '/id:/{print $2; exit}' "$BUILD/notarize.log")
    echo
    echo "  Notarization did not pass. Full log:"
    echo "      xcrun notarytool log $id --keychain-profile $NOTARY_PROFILE"
    fail "notarization failed"
}

step "Stapling"
xcrun stapler staple "$DMG" | sed 's/^/  /'
xcrun stapler validate "$DMG" | sed 's/^/  /'

step "Gatekeeper check"
spctl --assess --type open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/  /'
# And the app as a user actually receives it, mounted from the image.
MOUNT=$(hdiutil attach "$DMG" -nobrowse -readonly | awk -F'\t' '/Volumes/{print $NF}')
xcrun stapler validate "$MOUNT/FinvestLens.app" 2>&1 | sed 's/^/  /'
spctl --assess --type execute -vv "$MOUNT/FinvestLens.app" 2>&1 | sed 's/^/  /'
hdiutil detach "$MOUNT" -quiet

step "Done"
echo "  $DMG"
ls -lh "$DMG" | awk '{print "  " $5}'
