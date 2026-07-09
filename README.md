# MNtfs — NTFS read/write for macOS

Mount and **write** NTFS drives on macOS with **no kernel extension, no disabled
SIP, and no reduced security**. MNtfs is a menu-bar app whose file-system
extension is built on Apple's [FSKit](https://developer.apple.com/documentation/fskit)
(macOS 15.4+) and the proven NTFS engine from
[libntfs-3g](https://github.com/tuxera/ntfs-3g) — the first FSKit-based NTFS
*write* driver we know of, with no FUSE layer anywhere.

Runs at Full Security on Apple Silicon (developed on macOS 26 / M5).

## Features

- Read **and write** NTFS volumes through Apple's official FSKit plumbing.
- Handles drives left in **Windows Fast Startup / hibernation** — mounts them
  read/write instead of refusing (it discards the stale fast-boot cache, which
  is safe; Windows just does a full boot next time).
- Runs in the menu bar, starts at login, and **auto-mounts NTFS drives writable
  at boot** — no reopening the app or replugging.
- Shows drives correctly as *Windows NT File System (NTFS)* in Finder and Disk
  Utility (installs a small name bundle in `/Library/Filesystems`, on request).
- Reformat a removable NTFS drive from the app (Erase).

## Install (from the DMG)

The signed, notarized `MNtfs-<version>.dmg` runs on any Apple Silicon Mac
(macOS 15.4+) — no developer account needed.

1. Open the DMG, drag **MNtfs** to *Applications*, and launch it.
2. When prompted, allow it to install NTFS name support (one admin password).
3. Enable **FastNTFSFSModule** in *System Settings → General → Login Items &
   Extensions → File System Extensions*.
4. Plug in an NTFS drive — it mounts read/write automatically.

*Erase* also needs *Privacy & Security → Full Disk Access* for MNtfs, because
macOS gates raw disk access behind it.

## Build from source

Requires Xcode 16.3+ and a **paid** Apple Developer team: the FSKit entitlement
`com.apple.developer.fskit.fsmodule` is restricted and needs a real provisioning
profile (free personal teams are refused).

```sh
./scripts/build-vendor.sh     # static libntfs-3g + ntfsprogs (once)
xcodebuild -project FastNTFS.xcodeproj -target FastNTFS \
    -configuration Release -allowProvisioningUpdates build
```

`scripts/release.sh` produces a Developer-ID-signed, notarized, stapled DMG (set
`ASC_KEY` / `ASC_KEY_ID` / `ASC_ISSUER` to your App Store Connect API key).

## Test the engine (no FSKit needed)

The C bridge runs standalone against an NTFS image:

```sh
dd if=/dev/zero of=/tmp/t.img bs=1m count=64
./vendor/ntfs-3g/ntfsprogs/mkntfs -Q -F -L Test /tmp/t.img
clang -O2 -arch arm64 -mmacosx-version-min=15.4 \
    -I vendor/ntfs-3g/include -I vendor/ntfs-3g/include/ntfs-3g \
    tests/test_fntfs.c Sources/FSModule/Bridge/fntfs.c \
    vendor/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a \
    -framework CoreFoundation -o /tmp/test_fntfs
/tmp/test_fntfs /tmp/t.img          # prints "ALL TESTS PASSED"
```

`tests/bench_fntfs.c` builds the same way and prints engine throughput.

## How it works

```
Finder / any app → kernel FSKit client → FastNTFSFSModule.appex (Swift)
    → fntfs.c bridge → libntfs-3g → FSBlockDeviceResource (block I/O via fskitd)
```

- One `ntfs_inode` per MFT record; hot files stay in an LRU cache with their
  `$DATA` open, avoiding libntfs-3g's double-instance coherence bugs.
- Device callbacks only ever see sector-aligned I/O; unaligned writes become
  read-modify-write cycles under a single volume lock.
- Overwrite renames keep the old target under a temporary name until the move
  fully succeeds, so a failed rename never loses data.

## Limitations (v0.1)

- Symbolic links / reparse points and alternate data streams aren't mapped yet.
- Permissions are synthesized (ownerless volume model, like exFAT).

## License

Links `vendor/ntfs-3g` (GPL-2.0-or-later) statically, so MNtfs as a whole is
distributed under **GPL-2.0**.
