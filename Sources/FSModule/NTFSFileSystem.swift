//
//  NTFSFileSystem.swift
//  FastNTFS — FSUnaryFileSystem: probe, load, and check NTFS block devices.
//

import Foundation
import FSKit
import os

let log = Logger(subsystem: "com.fastntfs.FSModule", category: "fs")

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

final class NTFSFileSystem: FSUnaryFileSystem, FSUnaryFileSystemOperations {

    static let shared = NTFSFileSystem()

    private var activeVolume: NTFSVolume?
    private var activeDevice: BlockDevice?

    /// The block resource this module instance is working with. FSKit runs a
    /// separate extension process per resource, so within a process this
    /// identifies the one device being probed/loaded/checked. Guarded by a lock
    /// because probe and the check task can run on different threads.
    private let resourceLock = NSLock()
    private var _lastResource: FSBlockDeviceResource?
    fileprivate var lastResource: FSBlockDeviceResource? {
        get { resourceLock.lock(); defer { resourceLock.unlock() }; return _lastResource }
        set { resourceLock.lock(); defer { resourceLock.unlock() }; _lastResource = newValue }
    }

    func probeResource(resource: FSResource,
                       replyHandler reply: @escaping (FSProbeResult?, Error?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(FSProbeResult.notRecognized, nil)
            return
        }
        lastResource = block
        let dev = BlockDevice(resource: block)
        var name = [CChar](repeating: 0, count: 256)
        var serial: UInt64 = 0
        let pr = fntfs_probe(dev.opaque, devPread, dev.sizeBytes,
                             dev.sectorSize, &name, &serial)
        withExtendedLifetime(dev) {}

        switch Int(pr) {
        case FNTFS_PROBE_USABLE:
            let label = String(cString: name)
            log.info("probe \(block.bsdName, privacy: .public): NTFS '\(label, privacy: .public)'")
            reply(FSProbeResult.usable(
                name: label,
                containerID: FSContainerIdentifier(
                    uuid: NTFSVolume.uuid(fromSerial: serial))), nil)
        case FNTFS_PROBE_RECOGNIZED:
            log.info("probe \(block.bsdName, privacy: .public): NTFS but not mountable")
            reply(FSProbeResult.usableButLimited(
                name: String(cString: name),
                containerID: FSContainerIdentifier(
                    uuid: NTFSVolume.uuid(fromSerial: serial))), nil)
        default:
            reply(FSProbeResult.notRecognized, nil)
        }
    }

    func loadResource(resource: FSResource, options: FSTaskOptions,
                      replyHandler reply: @escaping (FSVolume?, Error?) -> Void) {
        guard let block = resource as? FSBlockDeviceResource else {
            reply(nil, posixError(ENOTSUP))
            return
        }
        lastResource = block
        let readOnly = options.taskOptions.contains("--rdonly")
            || !block.isWritable

        let dev = BlockDevice(resource: block)
        var name = [CChar](repeating: 0, count: 256)
        var serial: UInt64 = 0
        var err: Int32 = 0
        guard let v = fntfs_mount(dev.opaque, devPread,
                                  readOnly ? nil : devPwrite,
                                  devFlush, dev.sizeBytes, dev.sectorSize,
                                  readOnly, &name, &serial, &err) else {
            NSLog("FastNTFS: fntfs_mount FAILED errno=\(err)")
            log.error("mount \(block.bsdName, privacy: .public) failed: errno \(err)")
            reply(nil, posixError(err == 0 ? EIO : err))
            return
        }

        let label = String(cString: name)
        log.info("mounted \(block.bsdName, privacy: .public) '\(label, privacy: .public)' readOnly=\(readOnly)")
        let volume = NTFSVolume(device: dev, readOnly: readOnly, vol: v,
                                name: label, serial: serial)
        activeVolume = volume
        activeDevice = dev
        containerStatus = .ready   // FSKit itself transitions .ready → .active
        reply(volume, nil)
    }

    func unloadResource(resource: FSResource, options: FSTaskOptions,
                        replyHandler reply: @escaping (Error?) -> Void) {
        activeVolume?.shutdownVolume()
        activeVolume = nil
        activeDevice = nil
        reply(nil)
    }

    func didFinishLoading() {
        log.info("FastNTFS module loaded")
    }
}

// MARK: - fsck / format entry points

extension NTFSFileSystem: FSManageableResourceMaintenanceOperations {

    func startCheck(task: FSTask, options: FSTaskOptions) throws -> Progress {
        guard let block = lastResource else {
            throw posixError(EINVAL)
        }
        let progress = Progress(totalUnitCount: 100)
        DispatchQueue.global().async {
            let dev = BlockDevice(resource: block)
            var name = [CChar](repeating: 0, count: 256)
            var serial: UInt64 = 0
            let pr = fntfs_probe(dev.opaque, devPread, dev.sizeBytes,
                                 dev.sectorSize, &name, &serial)
            withExtendedLifetime(dev) {}
            progress.completedUnitCount = 100
            if pr == FNTFS_PROBE_USABLE {
                task.logMessage("FastNTFS: volume is consistent")
                task.didComplete(error: nil)
            } else {
                task.logMessage("FastNTFS: volume is dirty or unsupported")
                task.didComplete(error: posixError(EINVAL))
            }
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(ENOTSUP)
    }
}
