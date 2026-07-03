#!/bin/sh
# Build static libntfs-3g + ntfsprogs (no FUSE) for the FastNTFS bridge.
set -e
cd "$(dirname "$0")/../vendor/ntfs-3g"
./configure --disable-ntfs-3g --disable-shared --enable-static \
    --disable-plugins --disable-dependency-tracking \
    CC=clang CFLAGS="-O2 -arch arm64 -mmacosx-version-min=15.4"
make -j"$(sysctl -n hw.ncpu)"
echo "OK: libntfs-3g/.libs/libntfs-3g.a + ntfsprogs/{mkntfs,ntfsfix,...}"
