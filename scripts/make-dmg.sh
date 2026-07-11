#!/bin/sh
# make-dmg.sh — build a nice drag-to-install DMG for MNtfs.
#
#   make-dmg.sh <App.app> <output.dmg> <background.tiff> <VolumeName>
#
# Produces a compressed (UDZO) DMG with a custom background, a Drag-to-
# Applications layout, and a volume icon taken from the app. Codesigning /
# notarization of the DMG happens in release.sh, not here.
set -e

APP="$1"
DMG="$2"
BG="$3"
VOLNAME="$4"
: "${APP:?usage: make-dmg.sh <App.app> <out.dmg> <bg.tiff> <VolumeName>}"
: "${DMG:?}" "${BG:?}" "${VOLNAME:?}"

WIN_W=660
WIN_H=430
ICON_APP_X=170
ICON_APPS_X=490
ICON_Y=200
ICON_SIZE=128

APPNAME=$(basename "$APP")                 # e.g. MNtfs.app
STAGE=$(mktemp -d /tmp/mntfs-dmg.XXXXXX)
RW=$(mktemp -u /tmp/mntfs-rw.XXXXXX).dmg

cleanup() {
    [ -n "$MOUNT_DEV" ] && hdiutil detach "$MOUNT_DEV" -quiet 2>/dev/null || true
    rm -rf "$STAGE" "$RW"
}
trap cleanup EXIT

echo "==> stage"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
mkdir "$STAGE/.background"
cp "$BG" "$STAGE/.background/background.tiff"
# Volume icon from the app's own icon.
ICNS="$APP/Contents/Resources/$(/usr/libexec/PlistBuddy -c 'Print CFBundleIconFile' "$APP/Contents/Info.plist" 2>/dev/null | sed 's/\.icns$//').icns"
[ -f "$ICNS" ] && cp "$ICNS" "$STAGE/.VolumeIcon.icns"

echo "==> create read-write image"
# Size: staged content + 40% slack, minimum 40 MiB.
KB=$(du -sk "$STAGE" | awk '{print $1}')
MB=$(( KB / 1024 * 14 / 10 + 40 ))
hdiutil create -srcfolder "$STAGE" -volname "$VOLNAME" -fs HFS+ \
    -format UDRW -size "${MB}m" "$RW" -quiet

echo "==> mount"
# NOT -quiet: quiet suppresses the device/mount listing we need to parse.
ATTACH=$(hdiutil attach "$RW" -readwrite -noverify -noautoopen)
MOUNT_DEV=$(echo "$ATTACH" | grep 'Apple_HFS' | awk '{print $1}')
VOL="/Volumes/$VOLNAME"
[ -d "$VOL" ] || VOL=$(echo "$ATTACH" | grep 'Apple_HFS' | sed -n 's/.*\(\/Volumes\/.*\)$/\1/p' | head -1)
[ -n "$MOUNT_DEV" ] && [ -d "$VOL" ] || { echo "mount failed"; exit 1; }

# Custom-icon bit on the volume, plus keep .background hidden.
[ -f "$VOL/.VolumeIcon.icns" ] && SetFile -a C "$VOL" 2>/dev/null || true

echo "==> arrange window"
set +e
osascript 2>&1 <<APPLESCRIPT
tell application "Finder"
    tell disk "$VOLNAME"
        open
        delay 0.5
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {220, 140, 220 + $WIN_W, 140 + $WIN_H}
        set opts to the icon view options of container window
        set arrangement of opts to not arranged
        set icon size of opts to $ICON_SIZE
        set text size of opts to 13
        set background picture of opts to file ".background:background.tiff"
        set position of item "$APPNAME" of container window to {$ICON_APP_X, $ICON_Y}
        set position of item "Applications" of container window to {$ICON_APPS_X, $ICON_Y}
        update without registering applications
        delay 2
        close
    end tell
end tell
APPLESCRIPT
echo "    (osascript rc=$?)"
set -e

sync; sync
# .DS_Store is written lazily; give Finder a moment, then detach (retry: the
# volume is briefly busy right after Finder closes the window).
for i in 1 2 3 4 5 6; do
    if hdiutil detach "$VOL" 2>/dev/null; then MOUNT_DEV=""; break; fi
    sleep 1
done
[ -z "$MOUNT_DEV" ] || { hdiutil detach "$MOUNT_DEV" -force; MOUNT_DEV=""; }

echo "==> compress"
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Done: $DMG"
