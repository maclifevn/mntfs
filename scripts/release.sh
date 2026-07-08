#!/bin/sh
# release.sh — build, Developer ID sign, notarize, and package MNtfs into a
# stapled DMG entirely from the command line (no Xcode Organizer needed).
#
# Requires (once):
#   - A local "Developer ID Application" cert in the login keychain.
#   - signing/FSModule_DeveloperID.provisionprofile  (Developer ID + FSKit)
#   - signing/{app,ext}.entitlements.plist
#   - An App Store Connect API key for notarization.
set -e
cd "$(dirname "$0")/.."

DEVID="${MNTFS_DEVID:-Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)}"
KEY="${ASC_KEY:-/Users/maclife/Downloads/AuthKey_REDACTED.p8}"
KID="${ASC_KEY_ID:-REDACTED}"
ISS="${ASC_ISSUER:-REDACTED}"
VERSION="${1:-0.1.0}"

APP="build/Release/MNtfs.app"
APPEX="$APP/Contents/Extensions/FastNTFSFSModule.appex"
DMG="dist/MNtfs-$VERSION.dmg"

echo "==> 1/6  Build (Release)"
xcodebuild -project FastNTFS.xcodeproj -target FastNTFS -configuration Release \
    -allowProvisioningUpdates build >/tmp/mntfs-build.log 2>&1 \
    || { tail -20 /tmp/mntfs-build.log; exit 1; }

echo "==> 2/6  Sign inside-out (Developer ID + hardened runtime)"
codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/Resources/mkntfs"
cp signing/FSModule_DeveloperID.provisionprofile "$APPEX/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp \
    --entitlements signing/ext.entitlements.plist --sign "$DEVID" "$APPEX"
codesign --force --options runtime --timestamp \
    --entitlements signing/app.entitlements.plist --sign "$DEVID" "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$APPEX"

echo "==> 3/6  Notarize the app"
ditto -c -k --keepParent "$APP" /tmp/MNtfs-app.zip
xcrun notarytool submit /tmp/MNtfs-app.zip \
    --key "$KEY" --key-id "$KID" --issuer "$ISS" --wait
xcrun stapler staple "$APP"

echo "==> 4/6  Build DMG"
rm -rf /tmp/dmg-final; mkdir -p /tmp/dmg-final
cp -R "$APP" /tmp/dmg-final/
ln -s /Applications /tmp/dmg-final/Applications
cp dist/README-dmg.txt "/tmp/dmg-final/Đọc trước.txt" 2>/dev/null || true
mkdir -p dist; rm -f "$DMG"
hdiutil create -volname "MNtfs" -srcfolder /tmp/dmg-final -ov -format UDZO "$DMG"

echo "==> 5/6  Notarize + staple the DMG"
xcrun notarytool submit "$DMG" --key "$KEY" --key-id "$KID" --issuer "$ISS" --wait
xcrun stapler staple "$DMG"

echo "==> 6/6  Verify"
spctl -a -vvv -t open --context context:primary-signature "$DMG" 2>&1 | head -2
xcrun stapler validate "$DMG" 2>&1 | tail -1
echo "Done: $DMG"
