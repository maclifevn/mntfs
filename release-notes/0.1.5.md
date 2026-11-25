# MNtfs 0.1.5

- Drives that Windows left in Fast Startup or hibernation state can be written again, as in 0.1.1. Version 0.1.4 kept them read-only even with the extension enabled.
- To make such a drive writable, MNtfs resets the NTFS journal Windows left open (it does not replay it). If `hiberfil.sys` is on the drive, MNtfs deletes it, and the hibernated Windows session is lost. The app tells you when it has done this.
- After writing to such a drive on the Mac, connect it to Windows only after Windows has started. Turning off Fast Startup and using Safely Remove in Windows avoids the issue.
- Dirty or unverifiable volumes still mount read-only. A read-only mount request never changes anything on the drive.
- Read-only drives now show the actual reason instead of "the safety state was not fully verified".
- The journal is reset and flushed before `hiberfil.sys` is deleted. If either step fails, the drive stays read-only.
- Mounting large drives is faster: internal safety checks no longer read the whole allocation bitmap.
