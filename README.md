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
- Preserves drives left in **Windows Fast Startup / hibernation**: the dirty
  flag, hibernation image and journal are inspected before allowing writes.
  Unsafe or unknown state mounts read-only. MNtfs never resets `$LogFile` or
  deletes `hiberfil.sys`. Resume Windows and shut it down fully; run `chkdsk /f`
  on Windows when repair is needed. The state check is not a full filesystem
  verification or journal replay.
- Runs in the menu bar, starts at login, and **auto-mounts NTFS drives writable
  at boot** when their safety checks pass — no reopening the app or replugging.
- Verify extension enablement through FSKit, including the installed app copy.
  The manager window has a normal application menu and Dock icon while open.
- Mount/remount through Disk Arbitration with media-attachment identity checks
  before and after unmount. Busy volumes are left mounted; automatic takeover
  makes one attempt after the extension is confirmed enabled.
- Stop new writes after a device/writeback failure and retain the first error
  until eject. The live status shows the reason even when kernel mount flags
  still describe the original read/write mount.
- Coalesce drive-list refreshes, discard stale snapshots and preserve the last
  known list on scan failure. Sample disks appear only in the developer preview.
- Shows drives correctly as *Windows NT File System (NTFS)* in Finder and Disk
  Utility (installs a small name bundle in `/Library/Filesystems`, on request).
- Reformat a removable NTFS drive from the app (Erase).
- Check for signed updates from the menu bar; automatic checks run daily.
  Installing an update requires ejecting drives using the MNtfs extension.
- Create/read symbolic links; read Windows symlinks and supported junctions.
- Read, list, set and remove NTFS alternate data streams through macOS extended
  attributes, including create-only and replace-only semantics.
- Collect local diagnostics from the menu bar or volume window; copy or save a
  JSON report with mount-time safety state, extension evidence and I/O counters.
  Drive names, paths, UUIDs and network identity are omitted; nothing is uploaded.

## Install (from the DMG)

The signed, notarized `MNtfs-<version>.dmg` runs on any Apple Silicon Mac
(macOS 15.4+) — no developer account needed.

1. Open the DMG, drag **MNtfs** to *Applications*, and launch it.
2. When prompted, allow it to install NTFS name support (one admin password).
3. Enable **FastNTFSFSModule** in *System Settings → General → Login Items &
   Extensions → File System Extensions*.
4. Plug in an NTFS drive — clean volumes mount read/write automatically;
   unsafe or unknown state stays read-only with guidance in the app.

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

## Test without mounting a drive

The regression suites run against temporary NTFS images and an in-memory
device; they do not mount or modify connected drives:

```sh
./scripts/test.sh
```

The suite covers mount-state preservation, process exit immediately after sync,
the persistent write-error barrier, FSKit callback adapters, symlinks/junctions,
streams, privacy-safe diagnostics, attachment replacement and refresh races.
See [DURABILITY.md](DURABILITY.md) for the exact
synchronization contract and the limits of simulated failure tests.

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

- New POSIX symlinks use WSL reparse points. Windows symlinks, supported
  current-volume junctions and Interix links are readable. Cross-volume targets,
  cloud placeholders and other reparse tags are not resolved; their raw data is
  available read-only and their ordinary file contents cannot be overwritten.
- Streams use literal xattr names (including Unicode spelling) with a 127-byte
  name limit and 16 MiB value limit. Larger/unrepresentable streams are preserved
  on disk. There is no AFP_AfpInfo/AFP_Resource translation or `file:stream` path
  syntax. See [METADATA.md](METADATA.md) for the mapping and examples.
- Permissions are synthesized (ownerless volume model, like exFAT).
- FSKit's public flush API does not certify physical power-loss protection.
  The bridge does not provide active transactional journaling; eject drives
  before disconnecting them. See [DURABILITY.md](DURABILITY.md).
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
