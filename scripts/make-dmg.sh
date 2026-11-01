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
WORK=$(mktemp -d /tmp/mntfs-dmg.XXXXXX)
WORK=$(CDPATH= cd -- "$WORK" && pwd -P)
STAGE="$WORK/stage"
RW="$WORK/install.dmg"
VOL="$WORK/mount"
MOUNT_DEV=""
mkdir "$STAGE"

is_mounted() {
    python3 -c 'import os, sys; sys.exit(0 if os.path.ismount(sys.argv[1]) else 1)' "$VOL"
}

cleanup() {
    if is_mounted; then
        if ! hdiutil detach "${MOUNT_DEV:-$VOL}" -quiet 2>/dev/null; then
            echo "Build image is still mounted; preserving $WORK for cleanup." >&2
            return
        fi
    fi
    rm -rf "$WORK"
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
# A previous installer can have the same volume name. Mount at a private path
# and use the returned whole-device identity; never detach a volume by label.
hdiutil attach "$RW" -readwrite -noverify -noautoopen -nobrowse \
    -mountpoint "$VOL" -plist > "$WORK/attach.plist"
MOUNT_DEV=$(python3 - "$WORK/attach.plist" "$VOL" <<'PY'
import os, plistlib, re, sys
with open(sys.argv[1], 'rb') as source:
    entities = plistlib.load(source)['system-entities']
assert any(os.path.realpath(e.get('mount-point', '')) == os.path.realpath(sys.argv[2])
           for e in entities if e.get('mount-point')), 'Unexpected mount path: ' + repr(entities)
devices = [e['dev-entry'] for e in entities if re.fullmatch(r'/dev/disk[0-9]+', e.get('dev-entry', ''))]
assert len(devices) == 1, 'Ambiguous image device'
print(devices[0])
PY
)

# Custom-icon bit on the volume, plus keep .background hidden.
[ -f "$VOL/.VolumeIcon.icns" ] && SetFile -a C "$VOL" 2>/dev/null || true

echo "==> arrange window"
set +e
osascript 2>&1 <<APPLESCRIPT
tell application "Finder"
    set targetDisk to item (POSIX file "$VOL" as alias)
    tell targetDisk
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
    if hdiutil detach "$MOUNT_DEV" 2>/dev/null; then MOUNT_DEV=""; break; fi
    sleep 1
done
[ -z "$MOUNT_DEV" ] || { echo "Build image is busy; refusing to compress a mounted image." >&2; exit 1; }

echo "==> compress"
rm -f "$DMG"
mkdir -p "$(dirname "$DMG")"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG"
echo "Done: $DMG"
