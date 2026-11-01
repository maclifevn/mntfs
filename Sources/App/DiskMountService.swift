import DiskArbitration
import Foundation
import IOKit

/// IORegistry identifies this media attachment even when macOS reuses diskN.
/// Never persist registry IDs across boots.
struct VolumeAttachmentIdentity: Hashable, Sendable {
    let device: String
    let registryID: UInt64
    let mediaUUID: String?
    let volumeUUID: String?
    let writable: Bool

    func matches(_ current: Self) -> Bool {
        device == current.device && registryID != 0 && registryID == current.registryID &&
        mediaUUID == current.mediaUUID &&
        (volumeUUID == nil || current.volumeUUID == nil || volumeUUID == current.volumeUUID)
    }
}

enum DiskMountError: LocalizedError {
    case unavailable, targetChanged, busy, writeProtected

    var errorDescription: String? {
        switch self {
        case .unavailable: "Disk Arbitration is unavailable. Try again after restarting MNtfs."
        case .targetChanged: "The selected drive changed or disconnected. Refresh the drive list and try again."
        case .busy: "An operation is already running for this drive. Wait for it to finish."
        case .writeProtected: "The device is write-protected. Its current mount was preserved."
        }
    }
}

@MainActor
protocol DiskMountBackend {
    func identity(for device: String) -> VolumeAttachmentIdentity?
    func mount(_ expected: VolumeAttachmentIdentity) async throws
    func unmount(_ expected: VolumeAttachmentIdentity) async throws
}

@MainActor
final class DiskMountService {
    private let backend: any DiskMountBackend
    private var inFlight: Set<String> = []

    init(backend: (any DiskMountBackend)? = nil) { self.backend = backend ?? NativeDiskMountBackend() }

    private func validate(_ expected: VolumeAttachmentIdentity) throws {
        guard let current = backend.identity(for: expected.device), expected.matches(current) else {
            throw DiskMountError.targetChanged
        }
    }

    func setMounted(_ mounted: Bool, identity: VolumeAttachmentIdentity) async throws {
        guard inFlight.insert(identity.device).inserted else { throw DiskMountError.busy }
        defer { inFlight.remove(identity.device) }
        try validate(identity)
        if mounted { try await backend.mount(identity) }
        else { try await backend.unmount(identity) }
    }

    func remount(_ identity: VolumeAttachmentIdentity, requireWritable: Bool = false) async throws {
        guard inFlight.insert(identity.device).inserted else { throw DiskMountError.busy }
        defer { inFlight.remove(identity.device) }
        try validate(identity)
        if requireWritable {
            guard backend.identity(for: identity.device)?.writable == true else { throw DiskMountError.writeProtected }
        }
        try await backend.unmount(identity)
        // A user can unplug/replug a different disk while the callback waits.
        try validate(identity)
        try await backend.mount(identity)
    }
}

private final class DiskMountContinuation {
    let value: CheckedContinuation<Void, Error>
    init(_ value: CheckedContinuation<Void, Error>) { self.value = value }
}

private func diskMountReply(_ disk: DADisk, _ dissenter: DADissenter?, _ context: UnsafeMutableRawPointer?) {
    guard let context else { return }
    let request = Unmanaged<DiskMountContinuation>.fromOpaque(context).takeRetainedValue()
    if let dissenter {
        let message = DADissenterGetStatusString(dissenter) as String?
        request.value.resume(throwing: NSError(domain: NSOSStatusErrorDomain,
            code: Int(DADissenterGetStatus(dissenter)),
            userInfo: message.map { [NSLocalizedDescriptionKey: $0] }))
    } else { request.value.resume() }
}

@MainActor
final class NativeDiskMountBackend: DiskMountBackend {
    private let session: DASession?

    init() {
        session = DASessionCreate(kCFAllocatorDefault)
        if let session { DASessionSetDispatchQueue(session, .main) }
    }

    nonisolated static func readIdentity(device: String, session: DASession? = nil) -> VolumeAttachmentIdentity? {
        guard device.range(of: "^/dev/disk[0-9]+(s[0-9]+)*$", options: .regularExpression) != nil,
              let session = session ?? DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, device) else { return nil }
        return readIdentity(disk: disk, device: device)
    }

    nonisolated private static func readIdentity(disk: DADisk, device: String) -> VolumeAttachmentIdentity? {
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(media) }
        var id: UInt64 = 0
        guard IORegistryEntryGetRegistryEntryID(media, &id) == KERN_SUCCESS, id != 0,
              let values = DADiskCopyDescription(disk) as? [String: Any],
              let writable = values[kDADiskDescriptionMediaWritableKey as String] as? Bool else { return nil }
        func uuid(_ key: CFString) -> String? {
            guard let value = values[key as String], CFGetTypeID(value as CFTypeRef) == CFUUIDGetTypeID() else { return nil }
            let uuid = value as! CFUUID
            return CFUUIDCreateString(kCFAllocatorDefault, uuid) as String?
        }
        return VolumeAttachmentIdentity(device: device, registryID: id,
            mediaUUID: uuid(kDADiskDescriptionMediaUUIDKey), volumeUUID: uuid(kDADiskDescriptionVolumeUUIDKey),
            writable: writable)
    }

    func identity(for device: String) -> VolumeAttachmentIdentity? {
        guard let session else { return nil }
        return Self.readIdentity(device: device, session: session)
    }

    private func validatedDisk(_ expected: VolumeAttachmentIdentity) throws -> DADisk {
        guard let session else { throw DiskMountError.unavailable }
        guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, expected.device),
              let current = Self.readIdentity(disk: disk, device: expected.device), expected.matches(current) else {
            throw DiskMountError.targetChanged
        }
        return disk
    }

    func mount(_ expected: VolumeAttachmentIdentity) async throws {
        let disk = try validatedDisk(expected)
        defer { withExtendedLifetime(disk) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(DiskMountContinuation(continuation)).toOpaque()
            DADiskMount(disk, nil, DADiskMountOptions(kDADiskMountOptionDefault), diskMountReply, context)
        }
    }

    func unmount(_ expected: VolumeAttachmentIdentity) async throws {
        let disk = try validatedDisk(expected)
        defer { withExtendedLifetime(disk) {} }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let context = Unmanaged.passRetained(DiskMountContinuation(continuation)).toOpaque()
            DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), diskMountReply, context)
        }
    }
}
