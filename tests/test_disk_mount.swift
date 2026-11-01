import Foundation

@MainActor private final class MockDiskBackend: DiskMountBackend {
    var current: VolumeAttachmentIdentity?
    var afterUnmount: (() -> Void)?
    var unmountError: Error?
    var pauseUnmount = false
    var pending: CheckedContinuation<Void, Never>?
    var mounts = 0
    var unmounts = 0
    init(_ current: VolumeAttachmentIdentity) { self.current = current }
    func identity(for device: String) -> VolumeAttachmentIdentity? { current }
    func mount(_ expected: VolumeAttachmentIdentity) async throws { mounts += 1 }
    func unmount(_ expected: VolumeAttachmentIdentity) async throws {
        unmounts += 1
        if let unmountError { throw unmountError }
        if pauseUnmount { await withCheckedContinuation { pending = $0 } }
        afterUnmount?()
    }
}

@main @MainActor struct DiskMountRegression {
    static func main() async throws {
        func identity(_ id: UInt64, writable: Bool = true) -> VolumeAttachmentIdentity {
            VolumeAttachmentIdentity(device: "/dev/disk99s1", registryID: id,
                mediaUUID: "MEDIA", volumeUUID: "VOLUME", writable: writable)
        }
        let selected = identity(10)
        precondition(!selected.matches(identity(11))) // same BSD name + UUIDs, different attachment
        precondition(!identity(0).matches(identity(0)))

        let backend = MockDiskBackend(selected)
        let service = DiskMountService(backend: backend)
        try await service.remount(selected, requireWritable: true)
        precondition(backend.unmounts == 1 && backend.mounts == 1)

        backend.current = identity(11)
        do { try await service.remount(selected); preconditionFailure("Reused disk node accepted") }
        catch DiskMountError.targetChanged {}
        precondition(backend.unmounts == 1 && backend.mounts == 1)

        backend.current = selected
        backend.afterUnmount = { backend.current = identity(11) }
        do { try await service.remount(selected); preconditionFailure("Replacement disk mounted") }
        catch DiskMountError.targetChanged {}
        precondition(backend.unmounts == 2 && backend.mounts == 1)
        backend.afterUnmount = nil

        backend.current = selected
        backend.unmountError = POSIXError(.EBUSY)
        do { try await service.remount(selected); preconditionFailure("Busy unmount ignored") }
        catch { precondition((error as NSError).code == Int(EBUSY)) }
        precondition(backend.mounts == 1)
        backend.unmountError = nil

        backend.current = identity(10, writable: false)
        let before = backend.unmounts
        do { try await service.remount(selected, requireWritable: true); preconditionFailure("Write-protected drive unmounted") }
        catch DiskMountError.writeProtected {}
        precondition(backend.unmounts == before)

        backend.current = selected
        backend.pauseUnmount = true
        let first = Task { try await service.remount(selected) }
        for _ in 0..<10000 { if backend.pending != nil { break }; await Task.yield() }
        precondition(backend.pending != nil)
        do { try await service.setMounted(true, identity: selected); preconditionFailure("Concurrent mount accepted") }
        catch DiskMountError.busy {}
        backend.pending?.resume(); backend.pending = nil
        try await first.value
        precondition(backend.mounts == 2)
        print("Disk mount tests passed (attachment replacement before/after unmount, busy, write protection, serialization; no real disks)")
    }
}
