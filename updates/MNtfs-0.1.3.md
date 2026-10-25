# MNtfs 0.1.3

- Fixed NTFS name support installation on Macs where `/Library/Filesystems` does not exist.
- Ensured the installed name bundle remains readable by Finder and Disk Utility with restrictive file creation permissions.
- Installation failures now show the actual error instead of always reporting that administrator authorization is required.
- Improved temporary installer cleanup and handling of paths containing special characters.
