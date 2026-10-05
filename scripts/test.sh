#!/bin/sh
# Build standalone regressions and run only against temporary NTFS images.
set -eu
TASK_ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
cd "$TASK_ROOT"
TASK_TMP=$(mktemp -d /tmp/mntfs-tests.XXXXXX)
trap 'rm -rf "$TASK_TMP"' EXIT
CLANG_MODULE_CACHE_PATH="$TASK_TMP/module-cache"
export CLANG_MODULE_CACHE_PATH
LIB="$TASK_ROOT/vendor/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a"
MKNTFS="$TASK_ROOT/vendor/ntfs-3g/ntfsprogs/mkntfs"
[ -f "$LIB" ] && [ -x "$MKNTFS" ] || {
    echo "Run ./scripts/build-vendor.sh first."
    exit 1
}

compile_c() {
    clang -O2 -arch arm64 -mmacosx-version-min=15.4 \
        -I vendor/ntfs-3g/include -I vendor/ntfs-3g/include/ntfs-3g \
        "$@" "$LIB" -framework CoreFoundation
}
make_image() {
    mkfile -n 64m "$1"
    "$MKNTFS" -Q -F -L Regression "$1" > "$TASK_TMP/mkntfs.log" 2>&1
}

compile_c -DFNTFS_TESTING tests/test_fntfs.c Sources/FSModule/Bridge/fntfs.c \
    -o "$TASK_TMP/test_fntfs"
make_image "$TASK_TMP/engine.img"
"$TASK_TMP/test_fntfs" "$TASK_TMP/engine.img"

compile_c -DFNTFS_TESTING -DSECTOR=4096 tests/test_fntfs.c Sources/FSModule/Bridge/fntfs.c \
    -o "$TASK_TMP/test_fntfs_4k"
make_image "$TASK_TMP/engine-4k.img"
"$TASK_TMP/test_fntfs_4k" "$TASK_TMP/engine-4k.img"

compile_c tests/test_device_io.c -o "$TASK_TMP/test_device_io"
"$TASK_TMP/test_device_io"

clang -O2 -arch arm64 -mmacosx-version-min=15.4 \
    -I vendor/ntfs-3g/include -I vendor/ntfs-3g/include/ntfs-3g \
    -c Sources/FSModule/Bridge/fntfs.c -o "$TASK_TMP/fntfs.o"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.4 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    -import-objc-header Sources/FSModule/BridgingHeader.h \
    Sources/FSModule/NTFSVolume.swift Sources/FSModule/NTFSItem.swift \
    Sources/FSModule/BlockDevice.swift tests/test_volume.swift \
    "$TASK_TMP/fntfs.o" "$LIB" -framework CoreFoundation -o "$TASK_TMP/test_volume"
make_image "$TASK_TMP/volume.img"
"$TASK_TMP/test_volume" "$TASK_TMP/volume.img"

xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.4 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    Sources/App/ContentView.swift Sources/App/UpdateSafety.swift \
    tests/test_erase.swift -o "$TASK_TMP/test_erase"
"$TASK_TMP/test_erase"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos15.4 \
    -module-cache-path "$CLANG_MODULE_CACHE_PATH" \
    Sources/App/UpdateSafety.swift tests/test_updates.swift -o "$TASK_TMP/test_updates"
"$TASK_TMP/test_updates"
python3 tests/test_update_archive.py
echo "All regression suites passed."
