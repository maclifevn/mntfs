#!/bin/sh
# activate-paid.sh — build, sign, install & enable FastNTFS once you have a
# PAID Apple Developer Program account signed into Xcode.
#
# Prereq: Xcode → Settings → Accounts → your Apple ID shows a paid team.
# Run from the repo root:  ./scripts/activate-paid.sh
set -e
cd "$(dirname "$0")/.."

echo "==> 1/4  Building static libntfs-3g (if needed)"
[ -f vendor/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a ] || ./scripts/build-vendor.sh

echo "==> 2/4  Building + signing app with automatic provisioning"
# -allowProvisioningUpdates lets Xcode mint the FSKit-Module profile that only
# a paid team can create. No manual signing needed here.
xcodebuild -project FastNTFS.xcodeproj -target FastNTFS \
    -configuration Release -allowProvisioningUpdates \
    build

APP="build/Release/MNtfs.app"
echo "==> 3/4  Installing to /Applications"
rm -rf /Applications/MNtfs.app
cp -R "$APP" /Applications/
open /Applications/MNtfs.app

echo "==> 4/4  Registering the file-system extension"
pluginkit -a /Applications/MNtfs.app/Contents/Extensions/FastNTFSFSModule.appex 2>/dev/null || true
pluginkit -e use -i com.fastntfs.FastNTFS.FSModule 2>/dev/null || true

cat <<'EOF'

Done. Final manual step (macOS requires a human click here):
  System Settings → General → Login Items & Extensions
    → File System Extensions → enable "MNtfs"

Then test the mount pipeline end-to-end:
  dd if=/dev/zero of=/tmp/ntfs.img bs=1m count=256
  ./vendor/ntfs-3g/ntfsprogs/mkntfs -F -f -L Mntfs-Test /tmp/ntfs.img
  DISK=$(hdiutil attach -imagekey diskimage-class=CRawDiskImage -nomount /tmp/ntfs.img | awk '{print $1}')
  mkdir -p /tmp/ntfsmnt
  mount -F -t mntfs "$DISK" /tmp/ntfsmnt
  # → copy files in/out of /tmp/ntfsmnt, then measure real throughput
  umount /tmp/ntfsmnt && hdiutil detach "$DISK"

If `mount` succeeds, the whole FSKit path works and we move on to a real-disk
benchmark + hardening. If fskitd still refuses, capture the log with:
  log show --last 2m --predicate 'process == "fskitd"' --info
EOF
