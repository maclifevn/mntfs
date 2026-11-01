# Synchronization and failure handling

MNtfs checks the dirty bit, hibernation image and NTFS journal through a
read-only device before requesting write access. Unsafe or unknown state
keeps the volume read-only. No journal reset or hibernation-image removal is
performed. The check is a mount-state check, not a full consistency scan.

`fntfs_sync` writes regular-file and system metadata, then calls the backend
flush callback. Unmount also synchronizes, and preserves the first error.
The FSKit adapter calls the synchronous public `metadataFlush()` API and
propagates its errors. Reads and writes use direct resource I/O throughout;
no overlapping ranges mix direct I/O with metadata-cache writes.

The first failed device write, short write, device-disappearance/read I/O
failure, or failed metadata writeback/flush latches that mount against further
writes. Expected namespace errors such as `EEXIST` and `ENOENT` do not latch it.
The guard runs beneath libntfs-3g, including its internal rollback and close
writes. Sync and unmount continue to return the original failure after the
backend recovers; they must not acknowledge unsynchronized data as saved.
Reads remain best-effort and bypass the device read cache after the failure.
The live status xattr exposes the effective read-only state and first errno.
This is a write-admission barrier, not an atomic rollback of an already partial
write or a promise that the kernel mount flags change on an active volume.
Eject and inspect the device before using a fresh mount for further writes.

FSKit does not expose its device descriptor or a public equivalent of
`F_FULLFSYNC` / `DKIOCSYNCHRONIZECACHE`. Its documented resource-buffer flush
does **not** establish that a drive's volatile hardware cache has reached
nonvolatile media. MNtfs does not claim power-loss protection. NTFS-3G through
this bridge does not provide active transactional journal replay, either.
Always eject before disconnecting a drive.

## Automated verification

`./scripts/test.sh` uses only temporary images and memory-backed resources:

- Dirty, hibernated and damaged-journal fixtures fall back to read-only;
  mutators return `EROFS`, no write callback occurs, and every image byte is
  compared with its pre-mount snapshot.
- After successful sync, a child exits without unmounting. A fresh mount
  verifies the complete payload and logical file size.
- Injected flush failures and device disappearance reach sync/unmount callers.
- Write, short-write, read-disappearance and flush faults keep every subsequent
  mutation blocked, retain the first error, and issue no backend writes or
  flushes during cleanup even after the simulated backend recovers.
- The production FSKit callback adapter is exercised with a resource that
  throws I/O errors, models disconnection and returns short writes.
- Sector alignment and read-cache invalidation are covered at 512 and 4096
  bytes, including failed writes that already changed part of the device.

App tests simulate replacement media with the same BSD name and UUIDs but a
different IORegistry entry. Remount validates this attachment both before
unmount and after its asynchronous completion; a busy or write-protected
volume is preserved. No force-unmount is used by mount/remount controls.
Notification bursts are coalesced: fifty additional refresh requests while a
scan is in flight produce one follow-up scan, and the older snapshot is not
published. Inventory failure preserves the previous list with a visible error;
an empty successful inventory is shown without sample disks.

The device-call benchmark on a disposable image (32 MiB, 64 KiB calls,
100 microseconds simulated device latency) used 5 reads and 1546 writes both
before and after the write barrier. This checks added I/O overhead, not physical
USB/SSD throughput. Physical replug/remount and Windows `chkdsk` acceptance are
still required before making release-level reliability claims.

These tests model process crashes and I/O failures; they do not simulate a
physical controller losing power. Physical power-cut validation requires a
dedicated disposable drive, Windows consistency checks and repeated content
verification. It has not been performed by the automated suite.

On macOS 26.4+, the module also requests the kernel's read-only mount flag.
Earlier FSKit versions still reject writes in the module and C bridge; the
MNtfs app reads the module's status attribute to report the effective mode.

## Next stability and performance gates

1. Validate cold-login takeover, busy-volume refusal and physical replug on
   disposable GPT/MBR media with both 512-byte and 4096-byte sectors. Repeat
   on macOS 15.4, 26 and 27; mock identity tests do not certify DA callback
   behavior, driver selection or USB-controller behavior on hardware.
2. Run create/overwrite/rename/delete and metadata workloads, verify hashes
   after eject/remount, then retain Windows `chkdsk` results. Any partial-write
   or synchronization failure requires inspection rather than automatic RW
   recovery. Physical power-cut testing remains a separate destructive fixture
   exercise, not an ordinary regression test.
3. Replace the remaining per-volume `diskutil info` scan work with native
   Disk Arbitration descriptions/events once the attachment matrix passes.
   The current coalescer and read-only-command deadlines already bound overlap;
   native inventory should be measured for latency and process-count savings.
4. Record five-run sequential and small-file medians on real media with raw,
   Apple NTFS and exFAT baselines. Consider larger caches or kernel-offloaded
   I/O only after profiling establishes the bottleneck and the consistency
   gates pass. Synthetic image throughput is not a USB-speed claim.
