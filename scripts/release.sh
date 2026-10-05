#!/bin/sh
# release.sh — build, Developer ID sign, notarize, and package MNtfs into a
# stapled DMG/ZIP and signed Sparkle feed from the command line.
# Usage: release.sh [VERSION] [RELEASE_NOTES] [--bootstrap]
#
# Requires (once):
#   - A local "Developer ID Application" cert in the login keychain.
#   - signing/FSModule_DeveloperID.provisionprofile  (Developer ID + FSKit)
#   - signing/{app,ext}.entitlements.plist
#   - A notarytool Keychain profile or an App Store Connect API key.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"

DEVID="${MNTFS_DEVID:-Developer ID Application: Anh Tuan Vu Nguyen (CF5PGH3KGK)}"
# App Store Connect API credentials — supply via the environment, never commit:
#   ASC_KEY      path to your AuthKey_XXXXXX.p8
#   ASC_KEY_ID   the key's ID
#   ASC_ISSUER   your team's Issuer ID
NOTARY_PROFILE="${MNTFS_NOTARY_PROFILE:-}"
if [ -z "$NOTARY_PROFILE" ]; then
    KEY="${ASC_KEY:?set ASC_KEY or MNTFS_NOTARY_PROFILE}"
    KID="${ASC_KEY_ID:?set ASC_KEY_ID to your App Store Connect Key ID}"
    ISS="${ASC_ISSUER:?set ASC_ISSUER to your App Store Connect Issuer ID}"
fi
notarize() {
    if [ -n "$NOTARY_PROFILE" ]; then
        xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait
    else
        xcrun notarytool submit "$1" --key "$KEY" --key-id "$KID" --issuer "$ISS" --wait
    fi
}
VERSION="${1:-}"
NOTES="${2:-}"
BOOTSTRAP="${3:-}"
SPARKLE_BIN="${MNTFS_SPARKLE_BIN:-$TASK_ROOT/build/SourcePackages/artifacts/sparkle/Sparkle/bin}"
OUTPUT="${MNTFS_DIST_DIR:-dist}"

APP="build/Release/MNtfs.app"
APPEX="$APP/Contents/Extensions/FastNTFSFSModule.appex"

echo "==> 1/7  Build (Release)"
xcodebuild -project "$TASK_ROOT/FastNTFS.xcodeproj" -scheme FastNTFS -configuration Release \
    -destination 'generic/platform=macOS' \
    -clonedSourcePackagesDirPath "$TASK_ROOT/build/SourcePackages" \
    -packageCachePath "$TASK_ROOT/build/PackageCache" \
    -derivedDataPath "$TASK_ROOT/build/DerivedData" \
    CONFIGURATION_BUILD_DIR="$TASK_ROOT/build/Release" \
    CODE_SIGNING_ALLOWED=NO build >/tmp/mntfs-build.log 2>&1 \
    || { tail -20 /tmp/mntfs-build.log; exit 1; }

BUILT_VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")
VERSION="${VERSION:-$BUILT_VERSION}"
[ "$VERSION" = "$BUILT_VERSION" ] || {
    echo "Version mismatch: requested $VERSION, app is $BUILT_VERSION. Update MARKETING_VERSION before releasing."
    exit 1
}
DMG="$OUTPUT/MNtfs-$VERSION.dmg"
ZIP="$OUTPUT/MNtfs-$VERSION.zip"
NOTES="${NOTES:-release-notes/$VERSION.md}"
[ -f "$NOTES" ] || { echo "Missing release notes: $NOTES"; exit 1; }
mkdir -p "$OUTPUT"

echo "==> 2/7  Sign inside-out (Developer ID + hardened runtime)"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
# Re-sign every nested executable under our team; preserve Sparkle's downloader
# sandbox entitlements. Do not use --deep to sign an app with mixed entitlements.
for helper in \
    "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
    "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
    "$FRAMEWORK/Versions/B/Autoupdate" \
    "$FRAMEWORK/Versions/B/Updater.app" \
    "$FRAMEWORK"; do
    [ -e "$helper" ] || { echo "Missing Sparkle helper: $helper"; exit 1; }
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements \
        --sign "$DEVID" "$helper"
done
codesign --force --options runtime --timestamp --sign "$DEVID" \
    "$APP/Contents/Resources/mkntfs"
cp signing/FSModule_DeveloperID.provisionprofile "$APPEX/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp \
    --entitlements signing/ext.entitlements.plist --sign "$DEVID" "$APPEX"
codesign --force --options runtime --timestamp \
    --entitlements signing/app.entitlements.plist --sign "$DEVID" "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign --verify --strict --verbose=2 "$APPEX"

echo "==> 3/7  Notarize the app"
ditto -c -k --keepParent "$APP" /tmp/MNtfs-app.zip
notarize /tmp/MNtfs-app.zip
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl -a -vvv --type execute "$APP"
# Recreate the distribution ZIP after stapling: the submitted ZIP has no ticket.
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> 4/7  Build DMG (drag-to-Applications, custom background)"
# Staple the app first so it launches offline on a fresh Mac (the ticket
# was issued when notarization Accepted in step 3).
sh scripts/make-dmg.sh "$APP" "$DMG" dmg/background.tiff "MNtfs $VERSION-arm64"

echo "==> 5/7  Sign, notarize + staple the DMG"
codesign --force --timestamp --sign "$DEVID" "$DMG"
codesign --verify --strict --verbose=2 "$DMG"
notarize "$DMG"
xcrun stapler staple "$DMG"

echo "==> 6/7  Verify"
# No pipes here: with `set -e`, piping into head/tail would hide a failing
# spctl/stapler behind the pipe's exit status and let a bad DMG ship.
spctl -a -vvv -t open --context context:primary-signature "$DMG"
xcrun stapler validate "$DMG"

echo "==> 7/7  Generate and verify signed Sparkle feed"
# Test archives are accepted only by the standalone QA flow, never releases.
unset MNTFS_ALLOW_UNNOTARIZED_TEST_ARCHIVE
MNTFS_SPARKLE_BIN="$SPARKLE_BIN" bash scripts/build-update-feed.sh \
    "$VERSION" "$ZIP" "$NOTES" "$OUTPUT" "$BOOTSTRAP"
echo "Done: $DMG, $ZIP, $OUTPUT/updates/appcast.xml (local; publish assets before feed)"
