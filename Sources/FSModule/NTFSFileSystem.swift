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
            // Honest scope: this inspects the volume's consistency *state*
            // (dirty flag, hibernation image, unreplayed $LogFile) without
            // modifying anything. It is not a full chkdsk-style repair.
            let dev = BlockDevice(resource: block)
            var state: UInt32 = 0
            let rc = fntfs_check_state(dev.opaque, devPread, dev.sizeBytes,
                                       dev.sectorSize, &state)
            withExtendedLifetime(dev) {}
            progress.completedUnitCount = 100
            guard rc == 0 else {
                task.logMessage("MNtfs: cannot read the volume as NTFS (errno \(-rc))")
                task.didComplete(error: posixError(-rc))
                return
            }
            if state == 0 {
                task.logMessage("MNtfs: volume state is clean (note: this checks the dirty flag, hibernation state and journal — it is not a full chkdsk)")
                task.didComplete(error: nil)
                return
            }
            if state & UInt32(FNTFS_VSTATE_DIRTY) != 0 {
                task.logMessage("MNtfs: the volume dirty flag is set — Windows did not shut it down cleanly")
            }
            if state & UInt32(FNTFS_VSTATE_HIBERNATED) != 0 {
                task.logMessage("MNtfs: a Windows hibernation / Fast Startup image is present")
            }
            if state & UInt32(FNTFS_VSTATE_LOG_DIRTY) != 0 {
                task.logMessage("MNtfs: the NTFS journal ($LogFile) has unreplayed state")
            }
            task.logMessage("MNtfs: run `chkdsk /f` on Windows for a full repair, or let MNtfs mount it read-write to recover the journal and remove the hibernation image")
            task.didComplete(error: posixError(EBUSY))
        }
        return progress
    }

    func startFormat(task: FSTask, options: FSTaskOptions) throws -> Progress {
        throw posixError(ENOTSUP)
    }
}
