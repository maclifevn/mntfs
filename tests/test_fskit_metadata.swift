import Foundation
import FSKit

private final class ImageResource: BlockResourceIO {
    let fd: Int32
    let blockSize: UInt64 = 512
    let blockCount: UInt64
    var failFlush = false
    init(_ path: String) {
        fd = open(path, O_RDWR)
        precondition(fd >= 0)
        var st = stat(); precondition(fstat(fd, &st) == 0)
        blockCount = UInt64(st.st_size) / blockSize
    }
    deinit { close(fd) }
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t,
              length: Int) throws -> Int {
        let n = pread(fd, buffer.baseAddress, length, offset)
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return n
    }
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t,
               length: Int) throws -> Int {
        let n = pwrite(fd, buffer.baseAddress, length, offset)
        guard n >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
        return n
    }
    func metadataFlush() throws {
        if failFlush { throw POSIXError(.EIO) }
        guard fsync(fd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno)!) }
    }
}

@main
struct FSKitMetadataRegression {
    static func main() throws {
        precondition(CommandLine.arguments.count == 2)
        let resource = ImageResource(CommandLine.arguments[1])
        let device = BlockDevice(resource: resource)
        var error: Int32 = 0

        // A volume kept read-only only by a hibernation image reopens writable
        // at mount (MNtfs 0.1.1 policy); a request not covering it changes nothing.
        let prep = fntfs_mount(device.opaque, devPread, devPwrite, devFlush,
            device.sizeBytes, 512, false, nil, nil, &error)!
        var hib = fntfs_attrs()
        var header = [UInt8](repeating: 0, count: 4096); header[0...3] = [0x68, 0x69, 0x62, 0x72] // "hibr"
        precondition(fntfs_create(prep, fntfs_root_inum(), "hiberfil.sys", false, &hib) == 0)
        precondition(fntfs_write(prep, hib.inum, header, 4096, 0) == 4096)
        precondition(fntfs_unmount(prep) == 0)
        // A requested read-only mount is never changed.
        let requestedRO = fntfs_mount(device.opaque, devPread, nil, nil,
            device.sizeBytes, 512, true, nil, nil, &error)!
        let roVolume = NTFSVolume(device: device, readOnly: true, vol: requestedRO, name: "Test", serial: 1)
        roVolume.enableWriting(discarding: UInt32(FNTFS_VSTATE_DISCARDABLE))
        if #available(macOS 26.4, *) { precondition(roVolume.requestedMountOptions.contains(.readOnly)) }
        precondition(roVolume.shutdownVolume() == 0)
        precondition(NTFSVolume.requestsReadOnly(["-o", "nodev,noowners,rdonly,nofollow"]))
        precondition(!NTFSVolume.requestsReadOnly(["-o", "nodev,noowners,nosuid,nofollow"]))
        let held = fntfs_mount(device.opaque, devPread, devPwrite, devFlush,
            device.sizeBytes, 512, false, nil, nil, &error)!
        precondition(fntfs_is_readonly(held) && fntfs_mount_state(held) == UInt32(FNTFS_VSTATE_HIBERNATED))
        let hibernatedVolume = NTFSVolume(device: device, readOnly: true, vol: held, name: "Test", serial: 1)
        hibernatedVolume.enableWriting(discarding: UInt32(FNTFS_VSTATE_LOG_DIRTY)) // does not cover the state: no change
        if #available(macOS 26.4, *) { precondition(hibernatedVolume.requestedMountOptions.contains(.readOnly)) }
        // Check through a separate read-only handle: an FSKit lookup would add
        // a live item, and the volume rightly refuses to swap handles then.
        let peek = fntfs_mount(device.opaque, devPread, nil, nil, device.sizeBytes, 512, true, nil, nil, &error)!
        var still = fntfs_attrs()
        precondition(fntfs_lookup(peek, fntfs_root_inum(), "hiberfil.sys", &still) == 0,
                     "image must survive a non-covering request")
        precondition(fntfs_unmount(peek) == 0)
        hibernatedVolume.enableWriting(discarding: UInt32(FNTFS_VSTATE_HIBERNATED))
        if #available(macOS 26.4, *) { precondition(hibernatedVolume.requestedMountOptions.isEmpty) }
        hibernatedVolume.getXattr(named: FSFileName(string: NTFSMountStatus.attributeName),
                           of: NTFSItem(inum: fntfs_root_inum(), type: .directory)) { data, err in
            let status = try! JSONDecoder().decode(NTFSMountStatus.self, from: data!)
            precondition(err == nil && status.isConsistent && !status.readOnly && status.safetyFlags == 0)
            precondition(status.discardedWindowState == UInt32(FNTFS_VSTATE_HIBERNATED))
        }
        precondition(hibernatedVolume.shutdownVolume() == 0)

        let handle = fntfs_mount(device.opaque, devPread, devPwrite, devFlush,
            device.sizeBytes, 512, false, nil, nil, &error)!
        var gone = fntfs_attrs()
        precondition(fntfs_lookup(handle, fntfs_root_inum(), "hiberfil.sys", &gone) == -ENOENT)
        let volume = NTFSVolume(device: device, readOnly: false, vol: handle, name: "Test", serial: 1)
        let root = NTFSItem(inum: fntfs_root_inum(), type: .directory)
        let attributes = FSItem.SetAttributesRequest()
        attributes.invalidateAllProperties()
        var created: FSItem?
        volume.createSymbolicLink(named: FSFileName(string: "link"), inDirectory: root,
            attributes: attributes, linkContents: FSFileName(string: "missing/Đích")) { item, _, err in
            precondition(err == nil && item != nil); created = item
        }
        precondition(volume.supportedVolumeCapabilities.supportsSymbolicLinks)
        volume.readSymbolicLink(created!) { target, err in
            precondition(err == nil && target?.string == "missing/Đích")
        }
        let key = FSFileName(string: "Zone.Identifier"), value = Data("ZoneId=3".utf8)
        volume.setXattr(named: key, to: value, on: created!, policy: .mustCreate) { precondition($0 == nil) }
        volume.getXattr(named: key, of: created!) { data, err in precondition(err == nil && data == value) }
        volume.listXattrs(of: created!) { names, err in
            precondition(err == nil)
            precondition(names!.contains { $0.string == "Zone.Identifier" })
            precondition(names!.contains { $0.string == NTFSMountStatus.reparseAttributeName })
        }
        volume.getXattr(named: FSFileName(string: NTFSMountStatus.attributeName), of: root) { data, err in
            precondition(err == nil)
            let status = try! JSONDecoder().decode(NTFSMountStatus.self, from: data!)
            precondition(status.isConsistent && !status.readOnly && status.safetyFlags == 0)
            precondition(status.io.writeCalls > 0 && status.hardwareCacheFlush == "not-exposed")
        }
        volume.setXattr(named: FSFileName(string: NTFSMountStatus.attributeName), to: value,
            on: root, policy: .alwaysSet) { precondition(($0 as NSError?)?.code == Int(EPERM)) }
        volume.setXattr(named: FSFileName(string: NTFSMountStatus.reparseAttributeName), to: value,
            on: created!, policy: .alwaysSet) { precondition(($0 as NSError?)?.code == Int(EPERM)) }
        volume.synchronize(flags: .wait) { precondition($0 == nil) }
        resource.failFlush = true
        volume.synchronize(flags: .wait) { precondition(($0 as NSError?)?.code == Int(EIO)) }
        precondition(device.ioStatistics.flushErrors > 0 && device.ioStatistics.lastError == EIO)
        resource.failFlush = false
        volume.synchronize(flags: .wait) { precondition(($0 as NSError?)?.code == Int(EIO)) }
        volume.getXattr(named: FSFileName(string: NTFSMountStatus.attributeName), of: root) { data, err in
            precondition(err == nil)
            let status = try! JSONDecoder().decode(NTFSMountStatus.self, from: data!)
            precondition(status.isConsistent && status.readOnly && status.failureError == EIO)
            precondition(status.readOnlyExplanation.contains("Writing stopped"))
        }
        volume.setXattr(named: key, to: value, on: created!, policy: .alwaysSet) {
            precondition(($0 as NSError?)?.code == Int(EROFS))
        }
        if #available(macOS 26.4, *) { precondition(volume.requestedMountOptions.contains(.readOnly)) }
        precondition(volume.shutdownVolume() == -EIO)
        precondition(volume.shutdownVolume() == -EIO, "unload must retain the earlier unmount error")
        volume.synchronize(flags: .wait) { precondition(($0 as NSError?)?.code == Int(EIO)) }
        resource.failFlush = false

        let ro = fntfs_mount(device.opaque, devPread, nil, nil, device.sizeBytes, 512, true, nil, nil, &error)!
        let readOnly = NTFSVolume(device: device, readOnly: true, vol: ro, name: "Test", serial: 1)
        if #available(macOS 26.4, *) { precondition(readOnly.requestedMountOptions.contains(.readOnly)) }
        readOnly.setXattr(named: key, to: value, on: root, policy: .alwaysSet) {
            precondition(($0 as NSError?)?.code == Int(EROFS))
        }
        precondition(readOnly.shutdownVolume() == 0)
        print("FSKit metadata tests passed (symlink callbacks, ADS, virtual status, flush errors, reserved attributes, read-only)")
    }
}
