# Symlinks, reparse points and streams

## Symbolic links

POSIX symlink creation writes a WSL `IO_REPARSE_TAG_LX_SYMLINK` reparse point.
The exact UTF-8 target is preserved, including absolute paths, Unicode and
dangling targets. Windows Explorer does not treat WSL links as ordinary
Windows symlinks; WSL and MNtfs understand this format.

MNtfs also reads native Windows relative symlinks and legacy Interix links.
Relative Windows backslashes become POSIX separators. Native absolute Windows
links and junctions use NTFS-3G's current-volume interpretation: when the target
is found on this volume, MNtfs returns a relative path from the link's parent.
No host `/Volumes` path is guessed. Drive letters are not mapped across other
mounted drives. Unresolved/cross-volume targets return `ENOTSUP`.

Unknown reparse tags, including cloud-specific placeholders, are not hydrated
or treated as ordinary writable file data. Their original reparse bytes remain
accessible through the read-only `com.maclife.mntfs.reparse-data` attribute.
This attribute includes the reparse tag/header. Writing/deleting it from macOS
is refused. Removing the file itself still follows ordinary file deletion
semantics.

## Alternate data streams

Each ordinary macOS xattr name maps literally to an NTFS named `$DATA` stream.
For example, `Zone.Identifier` is the Windows stream of the same name:

```sh
xattr -p Zone.Identifier '/Volumes/Example/document.docx'
xattr -w com.example.note 'Reviewed' '/Volumes/Example/document.docx'
xattr -d com.example.note '/Volumes/Example/document.docx'
```

Streams on files and directories are supported. Empty streams remain distinct
from missing streams. Create-only, replace-only and delete policies preserve
their usual `EEXIST`/`ENOATTR` behavior. Named streams never replace the unnamed
file contents. Replacement failures attempt an in-memory rollback of the old
value. A device/writeback error permanently blocks further device writes for
that mount, including rollback writes, and sync/unmount retain the failure.
Already-partial writes cannot be promised atomic recovery. This is not a
transaction journal or a power-loss guarantee.

Attribute names retain their exact Unicode spelling: NFC and NFD names do not
alias. Names must be nonempty, contain no slash, and fit macOS's 127-byte limit;
values are limited to 16 MiB. Streams outside these limits stay on disk. Large
streams return `E2BIG` on access, and unrepresentable names are omitted from the
macOS list. The driver does not provide Windows `file:stream` path syntax or
translate AFP_AfpInfo/AFP_Resource to Apple metadata formats.

Two attribute names are reserved for module status and inspection:

- `com.maclife.mntfs.volume-state` is a virtual root attribute containing a
  versioned JSON snapshot of effective mount mode, mount-time safety flags and
  live I/O counters. It is not a persisted NTFS stream or a full consistency
  scan. On macOS before 26.4 this also lets the app show effective read-only
  mode when the kernel mount flag cannot be requested through public FSKit APIs.
- `com.maclife.mntfs.reparse-data` exposes raw reparse data read-only.

Foreign streams using these exact reserved names are preserved but shadowed by
the virtual attributes in macOS. All stream writes are refused on read-only
volumes.

## Diagnostics

Use **Diagnostics…** in the menu bar or volume window. **Copy Report** copies
JSON; **Save JSON…** writes only to the location you select. Reports include
app/OS version, platform support, extension registration/live evidence, signature
verification, effective mount state and I/O counters. Registration without a live
module response is reported as unknown activation rather than a healthy mount.
Raw tool output, drive labels, device IDs, UUIDs, local paths and network identity
are excluded. No report is sent automatically.
