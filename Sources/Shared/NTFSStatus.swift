import Foundation

struct NTFSIOStatistics: Codable, Hashable, Sendable {
    var readCalls = 0
    var writeCalls = 0
    var flushCalls = 0
    var readErrors = 0
    var writeErrors = 0
    var flushErrors = 0
    var shortWrites = 0
    var lastError: Int32?
}

/// A live, read-only root xattr. Never persisted as an NTFS stream. The flags
/// match FNTFS_VSTATE_* in fntfs.h and describe the state at mount time only.
struct NTFSMountStatus: Codable, Hashable, Sendable {
    static let attributeName = "com.maclife.mntfs.volume-state"
    static let reparseAttributeName = "com.maclife.mntfs.reparse-data"
    let schemaVersion: Int
    let readOnly: Bool
    let safetyFlags: UInt32
    let failureError: Int32?
    let synchronization: String
    let hardwareCacheFlush: String
    let io: NTFSIOStatistics
    /// Windows state MNtfs discarded when it mounted the volume: 4 = journal
    /// reset, 2 = hiberfil.sys deleted. Absent from older extensions.
    let discardedWindowState: UInt32?

    init(readOnly: Bool, safetyFlags: UInt32, io: NTFSIOStatistics, failureError: Int32? = nil,
         discardedWindowState: UInt32 = 0) {
        schemaVersion = 1
        self.readOnly = readOnly
        self.safetyFlags = safetyFlags
        self.failureError = failureError
        self.discardedWindowState = discardedWindowState == 0 ? nil : discardedWindowState
        synchronization = "fskit-resource-buffer"
        hardwareCacheFlush = "not-exposed"
        self.io = io
    }

    var isConsistent: Bool {
        schemaVersion == 1 && safetyFlags & ~UInt32(31) == 0 &&
        (readOnly || safetyFlags == 0) &&
        (failureError.map { $0 > 0 && readOnly } ?? true) &&
        synchronization == "fskit-resource-buffer" && hardwareCacheFlush == "not-exposed" &&
        [io.readCalls, io.writeCalls, io.flushCalls, io.readErrors,
         io.writeErrors, io.flushErrors, io.shortWrites].allSatisfy { $0 >= 0 && $0 < Int.max / 16 } &&
        (io.lastError.map { $0 > 0 } ?? true) &&
        (discardedWindowState.map { $0 != 0 && $0 & ~UInt32(6) == 0 } ?? true)
    }

    /// What MNtfs changed to make a Windows Fast Startup / hibernation drive
    /// writable, or nil when it changed nothing.
    var discardedExplanation: String? {
        guard let flags = discardedWindowState, flags != 0 else { return nil }
        var done: [String] = []
        if flags & 4 != 0 { done.append("reset the NTFS journal Windows left open") }
        if flags & 2 != 0 { done.append("deleted hiberfil.sys (the hibernated Windows session)") }
        return "To allow writing, MNtfs " + done.joined(separator: " and ") + " when it mounted this drive."
    }

    var readOnlyExplanation: String {
        if let failureError {
            return "Writing stopped after a device or synchronization error (errno \(failureError)). "
                + "New writes remain blocked until eject. Some changes may not have reached the drive. "
                + "Eject it and check it in Windows before allowing further writes."
        }
        var reasons: [String] = []
        if safetyFlags & 1 != 0 { reasons.append("Windows marked this volume as needing repair") }
        if safetyFlags & 2 != 0 { reasons.append("a Windows hibernation image is present") }
        if safetyFlags & 4 != 0 {
            reasons.append("Windows left the NTFS journal open (Fast Startup, or the drive was unplugged without Safely Remove)")
        }
        if safetyFlags & 8 != 0 { reasons.append("MNtfs could not verify, or finish clearing, the Windows safety state") }
        let discarded = discardedExplanation.map { " " + $0 } ?? ""
        // Bit 16: macOS asked for a read-only mount (write-protected device or
        // a read-only request). MNtfs then changes nothing; the other bits are
        // what it found.
        if safetyFlags & 16 != 0 {
            let base = "Read-only access was requested or the device is write-protected."
            return reasons.isEmpty ? base
                : base + " The drive also reports: " + reasons.joined(separator: "; ") + "."
        }
        if reasons.isEmpty { return "Read-only access was requested or the device is write-protected." + discarded }
        var text = "Kept read-only: " + reasons.joined(separator: "; ") + "." + discarded
        if safetyFlags & 1 != 0 {
            text += " Run chkdsk /f on this drive in Windows, then eject it safely."
        } else {
            text += " Shut Windows down fully (turn off Fast Startup), use Safely Remove before unplugging, and run chkdsk /f on Windows if it reports problems."
        }
        return text
    }
}
