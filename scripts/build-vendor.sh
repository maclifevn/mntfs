#!/bin/sh
# Build static libntfs-3g + ntfsprogs (no FUSE) for the FastNTFS bridge.
set -e
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT/vendor/ntfs-3g"
./configure --disable-ntfs-3g --disable-shared --enable-static \
    --disable-plugins --disable-dependency-tracking \
    CC=clang CFLAGS="-O2 -arch arm64 -mmacosx-version-min=15.4"
make -j"$(sysctl -n hw.ncpu)"

# The app bundles mkntfs to reformat volumes as NTFS (Erase). Stage it.
cd "$TASK_ROOT"
mkdir -p Sources/App/Resources
cp vendor/ntfs-3g/ntfsprogs/mkntfs Sources/App/Resources/mkntfs
chmod +x Sources/App/Resources/mkntfs

echo "OK: libntfs-3g/.libs/libntfs-3g.a + ntfsprogs/{mkntfs,ntfsfix,...}"
echo "OK: staged Sources/App/Resources/mkntfs for the app's Erase feature"
