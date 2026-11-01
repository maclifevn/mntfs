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

    init(readOnly: Bool, safetyFlags: UInt32, io: NTFSIOStatistics, failureError: Int32? = nil) {
        schemaVersion = 1
        self.readOnly = readOnly
        self.safetyFlags = safetyFlags
        self.failureError = failureError
        synchronization = "fskit-resource-buffer"
        hardwareCacheFlush = "not-exposed"
        self.io = io
    }

    var isConsistent: Bool {
        schemaVersion == 1 && safetyFlags & ~UInt32(15) == 0 &&
        (readOnly || safetyFlags == 0) &&
        (failureError.map { $0 > 0 && readOnly } ?? true) &&
        synchronization == "fskit-resource-buffer" && hardwareCacheFlush == "not-exposed" &&
        [io.readCalls, io.writeCalls, io.flushCalls, io.readErrors,
         io.writeErrors, io.flushErrors, io.shortWrites].allSatisfy { $0 >= 0 && $0 < Int.max / 16 } &&
        (io.lastError.map { $0 > 0 } ?? true)
    }

    var readOnlyExplanation: String {
        if let failureError {
            return "Writing stopped after a device or synchronization error (errno \(failureError)). "
                + "New writes remain blocked until eject. Some changes may not have reached the drive. "
                + "Eject it and check it in Windows before allowing further writes."
        }
        var reasons: [String] = []
        if safetyFlags & 1 != 0 { reasons.append("Windows marked this volume dirty") }
        if safetyFlags & 2 != 0 { reasons.append("a Windows hibernation image is present") }
        if safetyFlags & 4 != 0 { reasons.append("the NTFS journal has pending state") }
        if safetyFlags & 8 != 0 { reasons.append("the safety state was not fully verified") }
        if reasons.isEmpty { return "Read-only access was requested or the device is write-protected." }
        return "Kept read-only: " + reasons.joined(separator: "; ") +
            ". Resume Windows and shut down fully. Run chkdsk /f on Windows if repair is needed. MNtfs preserves the journal and hibernation image."
    }
}
