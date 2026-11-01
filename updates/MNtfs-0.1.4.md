# MNtfs 0.1.4

- Keep dirty, hibernated, damaged-journal and Windows Fast Startup volumes read-only, preserving their journal and hibernation image.
- Detect NTFS 2.0 restart pages even when the journal reports a clean state.
- Use FSKit's synchronous resource flush, propagate synchronization errors, and retain errors through unmount and unload.
- Block further writes after device or synchronization failure; expose the first failure in live status and retain it even after the backend recovers.
- Verify extension enablement with FSKit for the current app copy; show a normal app menu while the manager window is open.
- Validate media-attachment identity before and after mount/remount operations; leave busy drives mounted and avoid repeated automatic unmount loops.
- Coalesce drive refreshes and reject stale snapshots. Keep scan errors distinct from an empty drive list; sample disks are limited to developer previews.
- Add local diagnostics with live mount evidence, safety reasons and I/O counters. Reports can be copied or saved as JSON without drive names, paths, UUIDs or network identity.
- Add symbolic links using WSL reparse points, native Windows relative symlink reading, supported current-volume junctions and Interix link reading.
- Map NTFS alternate data streams to macOS extended attributes, preserving Unicode spelling and existing values on transient replacement failures.
- Preserve unsupported reparse points and expose their raw data read-only; prevent ordinary content writes to these items.
- Add regression coverage for unsafe mount preservation, sync followed by abrupt process exit, I/O failures, metadata interoperability and diagnostics privacy.

FSKit's public flush API does not certify protection against physical power loss.
Cross-volume links and cloud placeholders are not resolved. Stream access uses
macOS xattr names up to 127 bytes and values up to 16 MiB; larger streams remain
on disk. Eject drives before disconnecting them.
