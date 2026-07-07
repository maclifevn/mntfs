# FastNTFS

**NTFS read/write for macOS, built on Apple's FSKit — no kernel extension, no
disabled SIP, no reduced security.**

FastNTFS pairs the battle-tested NTFS engine from
[libntfs-3g](https://github.com/tuxera/ntfs-3g) with macOS 15.4+'s
[FSKit](https://developer.apple.com/documentation/fskit) user-space file-system
framework. The result is a Mac app whose embedded file-system extension mounts
NTFS volumes read/write through the same official plumbing Apple uses for its
own `msdos` and `exfat` modules.

To the best of our knowledge this is the **first FSKit-based NTFS write
driver** — every other free option (macFUSE + ntfs-3g, FUSE-T, Mounty wrappers)
goes through a FUSE translation layer or resurrects Apple's abandoned in-kernel
write support.

## Status — working end to end ✅

Mounts real NTFS volumes read/write through FSKit at **Full Security** (SIP on,
Gatekeeper on, no kernel extension). Verified on macOS 26.5.1 / Apple M5.

| Layer | State |
| --- | --- |
| NTFS engine (`Sources/FSModule/Bridge/fntfs.c`) | ✅ Complete, validated by a full test suite (`tests/test_fntfs.c`): mount, probe, read, write, create, mkdir, rename (file/dir/cross-dir), hard links, truncate, timestamps, Windows attributes, Unicode names, cookie-resumable enumeration, persistence, `ntfsfix`-clean images |
| FSKit extension (Swift) | ✅ Builds, signs, registers with `fskitd`, and **mounts live** via `mount -F -t fastntfs` |
| Real mount (macOS VFS) | ✅ `cp`, `ls -la`, mkdir, Unicode names, nested dirs, 100 MB files — all through Finder/VFS. Data verified byte-identical on copy-out, and cross-read by independent `ntfsls`/`ntfscat` (i.e. Windows/Linux read it too). `ntfsfix` reports the written volume structurally clean. |
| Real throughput (through the full FSKit XPC path, SSD-backed image) | ✅ **~860 MB/s write, ~700 MB/s read** — the driver saturates any real external disk, and is ~20–40× faster than macFUSE + ntfs-3g |
| Engine throughput (in-process, cached image) | ✅ ~3.5 GB/s write, ~17 GB/s read — the engine itself is never the bottleneck |

> Numbers are on an SSD-backed disk image, so they measure the **driver
> ceiling**, not a slow USB stick. On a real external drive the disk is the
> limit, and FastNTFS keeps up with it — on par with Paragon NTFS in practice.

### Requires a paid Apple Developer account (one-time setup)

`com.apple.developer.fskit.fsmodule` is a restricted entitlement, so the
extension needs a real provisioning profile from a **paid** Apple Developer
Program team (free personal teams are refused by Apple). With a paid account,
`./scripts/activate-paid.sh` builds, signs, installs and registers it in one
step. This Mac must also be registered as a device in the developer portal
(the script and Xcode handle profile creation automatically once it is).

## Requirements

- macOS 15.4 or later (FSKit)
- Xcode 16.3 or later
- An Apple Developer Program (paid) team for the provisioning profile

## Build

```sh
./scripts/build-vendor.sh      # builds static libntfs-3g + ntfsprogs (once)
xcodebuild -project FastNTFS.xcodeproj -target FastNTFS \
    -configuration Release -allowProvisioningUpdates build
```

Then:

1. Copy `build/Release/FastNTFS.app` to `/Applications` and launch it once.
2. Enable **FastNTFS** under *System Settings → General → Login Items &
   Extensions → File System Extensions*.
3. Plug in an NTFS disk — or mount manually:

```sh
mount -F -t fastntfs /dev/diskXsY /path/to/mountpoint
```

## Test the engine without FSKit

The NTFS engine is fully exercisable as a plain process against an image file:

```sh
dd if=/dev/zero of=/tmp/t.img bs=1m count=64
./vendor/ntfs-3g/ntfsprogs/mkntfs -F -f -L Test /tmp/t.img
clang -O2 -DHAVE_CONFIG_H -I vendor/ntfs-3g -I vendor/ntfs-3g/include/ntfs-3g \
    Sources/FSModule/Bridge/fntfs.c tests/test_fntfs.c \
    vendor/ntfs-3g/libntfs-3g/.libs/libntfs-3g.a \
    -framework CoreFoundation -o /tmp/test_fntfs
/tmp/test_fntfs /tmp/t.img
```

`tests/bench_fntfs.c` builds the same way and prints engine throughput next to
a raw-I/O baseline.

## Architecture

```
Finder / any app
      │  (VFS)
kernel FSKit client
      │  (XPC)
FastNTFSFSModule.appex        Swift: FSUnaryFileSystem + FSVolume ops
      │  (C bridge, one lock, LRU-cached open files)
fntfs.c  →  libntfs-3g        the proven NTFS engine, no FUSE anywhere
      │  (sector-aligned callbacks, bounce-buffered RMW)
FSBlockDeviceResource         direct block-device I/O via fskitd
```

Design notes:

- **One `ntfs_inode` instance per MFT record, ever.** Regular files used for
  I/O live in a small LRU cache with their `$DATA` attribute open; namespace
  operations evict first. This avoids libntfs-3g's classic double-instance
  coherence bugs while skipping per-call open/close on hot files.
- **Alignment is handled below libntfs-3g.** The device callbacks only ever
  see sector-aligned I/O; unaligned metadata writes become read-modify-write
  cycles under the volume lock.
- **Directory cookies are NTFS index positions.** Resuming with `pos + 1`
  re-enters `ntfs_readdir` exactly after the delivered entry, so enumerations
  are restartable at any point with no state held between calls.
- Windows *hidden* maps to `UF_HIDDEN`, *read-only* clears write bits; system
  metadata files (`$MFT`, …) stay invisible.

## Limitations (v0.1)

- Symbolic links (NTFS reparse points) are not yet exposed.
- Extended attributes / alternate data streams are not yet mapped.
- Permissions are synthesized (ownerless volume model, like exFAT).
- Volume is mounted with journal replay (`NTFS_MNT_RECOVER`); hibernated
  Windows volumes are refused rather than risked.

## License

The `vendor/ntfs-3g` engine is GPL-2.0-or-later; the bridge links it
statically, so this project as a whole is distributed under **GPL-2.0**.
