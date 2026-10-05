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
  read/write instead of refusing. To make that safe it recovers the NTFS
  journal and **deletes the hibernation image** (`hiberfil.sys`), exactly like
  ntfs-3g's `remove_hiberfile` option: Windows loses its fast-boot/hibernation
  snapshot and performs a clean full boot next time, instead of resuming from
  stale state onto a changed disk.
- Runs in the menu bar, starts at login, and **auto-mounts NTFS drives writable
  at boot** — no reopening the app or replugging.
- Shows drives correctly as *Windows NT File System (NTFS)* in Finder and Disk
  Utility (installs a small name bundle in `/Library/Filesystems`, on request).
- Reformat a removable NTFS drive from the app (Erase).
- Check for signed updates from the menu bar; automatic checks run daily.
  Installing an update requires ejecting drives using the MNtfs extension.

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
xcodebuild -project "$PWD/FastNTFS.xcodeproj" -scheme FastNTFS \
    -configuration Release -allowProvisioningUpdates build
```

`scripts/release.sh` produces a Developer-ID-signed, notarized, stapled DMG and
ZIP, plus a signed Sparkle appcast (set `ASC_KEY` / `ASC_KEY_ID` / `ASC_ISSUER`
to your App Store Connect API key). See [RELEASING.md](RELEASING.md) for key setup,
the first manual installation, feed hosting, and later release steps.

## Test the engine (no FSKit needed)

The regression suites run against temporary NTFS images and an in-memory
device; they do not mount or modify connected drives:

```sh
./scripts/test.sh
```

`tests/bench_fntfs.c` measures engine throughput, verifies content after
remount, and counts device calls. Its arguments are `<disposable-image> <MiB>
[chunk-KiB] [device-latency-us]`. Test both 64 KiB and 1 MiB calls: larger
buffers alone can conceal the overhead of repeated metadata I/O. The raw
baseline uses a separate scratch file beside the image. These results measure
the bridge; measure Finder copies on a real drive separately to include FSKit,
USB, and physical media latency.

## How it works

```
Finder / any app → kernel FSKit client → FastNTFSFSModule.appex (Swift)
    → fntfs.c bridge → libntfs-3g → FSBlockDeviceResource (block I/O via fskitd)
```

- One `ntfs_inode` per MFT record; hot files stay in an LRU cache with their
  `$DATA` open, avoiding libntfs-3g's double-instance coherence bugs.
- Device callbacks only ever see sector-aligned I/O; unaligned writes become
  read-modify-write cycles under a single volume lock. Large writes read only
  partial edge sectors and write the complete interior directly; small metadata
  updates stay grouped to minimize device calls.
- A bounded 256 KiB cache avoids repeated small bitmap/MFT reads. Writes reach
  the device immediately and invalidate all overlapping cached reads, including
  on failure. Each mount owns a fresh cache.
- The Windows hidden/system flags on the root directory are kept on disk,
  while the FSKit root is exposed as visible with its reserved root item ID.
- Overwrite renames keep the old target under a temporary name until the move
  fully succeeds, so a failed rename never loses data.

## Limitations (v0.1)

- Symbolic links / reparse points and alternate data streams aren't mapped yet.
- Permissions are synthesized (ownerless volume model, like exFAT).
- Erase requires a stable volume or partition UUID. If macOS cannot provide
  either identifier, MNtfs refuses the operation instead of relying on a reused
  BSD device number, capacity, and partition type.

If a mounted drive is missing from Desktop, check **Finder → Settings →
General → External disks** (and **Hard disks** for internal volumes). Finder
controls this preference independently of the driver. See [Apple's guide to
showing connected devices](https://support.apple.com/guide/mac-help/mchlp1039/mac).

## License

Links `vendor/ntfs-3g` (GPL-2.0-or-later) statically, so MNtfs as a whole is
distributed under **GPL-2.0**.
