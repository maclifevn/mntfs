//
//  BlockDevice.swift
//  FastNTFS — adapts FSBlockDeviceResource to the fntfs C I/O callbacks.
//
//  The C bridge guarantees sector-aligned offsets and lengths, so the calls
//  map 1:1 onto the resource's synchronous read/write accessors.
//

import Foundation
import FSKit

/// The same adapter is exercised with a fault-injecting resource in tests.
protocol BlockResourceIO: AnyObject {
    var blockCount: UInt64 { get }
    var blockSize: UInt64 { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt offset: off_t,
              length: Int) throws -> Int
    func write(from buffer: UnsafeRawBufferPointer, startingAt offset: off_t,
               length: Int) throws -> Int
    func metadataFlush() throws
}

extension FSBlockDeviceResource: BlockResourceIO {}

final class BlockDevice {
    let resource: any BlockResourceIO
    private let statisticsLock = NSLock()
    private var statistics = NTFSIOStatistics()

    var ioStatistics: NTFSIOStatistics {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        return statistics
    }

    enum Operation { case read, write, flush }
    func record(_ operation: Operation, error: Int32? = nil, short: Bool = false) {
        statisticsLock.lock(); defer { statisticsLock.unlock() }
        switch operation {
        case .read:
            statistics.readCalls &+= 1
            if error != nil { statistics.readErrors &+= 1 }
        case .write:
            statistics.writeCalls &+= 1
            if error != nil { statistics.writeErrors &+= 1 }
            if short { statistics.shortWrites &+= 1 }
        case .flush:
            statistics.flushCalls &+= 1
            if error != nil { statistics.flushErrors &+= 1 }
        }
        if let error { statistics.lastError = error }
    }

    init(resource: any BlockResourceIO) {
        self.resource = resource
    }

    var sizeBytes: UInt64 { resource.blockCount * resource.blockSize }
    var sectorSize: UInt32 { UInt32(resource.blockSize) }

    /// Stable opaque pointer for C callbacks. The owner must keep this
    /// object alive for as long as the pointer is in use.
    var opaque: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }
}

func posixCode(_ error: Error) -> Int32 {
    if let p = error as? POSIXError { return p.code.rawValue }
    let ns = error as NSError
    if ns.domain == NSPOSIXErrorDomain, ns.code != 0 { return Int32(ns.code) }
    return EIO
}

/// C thunks — no captured context; the device is recovered from `ctx`.
let devPread: fntfs_pread_cb = { ctx, buf, count, offset in
    guard let ctx else { return -Int64(EINVAL) }
    let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
    do {
        let buffer = UnsafeMutableRawBufferPointer(start: buf, count: Int(count))
        let n = try dev.resource.read(into: buffer, startingAt: offset,
                                      length: Int(count))
        dev.record(.read)
        return Int64(n)
    } catch {
        let code = posixCode(error)
        dev.record(.read, error: code)
        return -Int64(code)
    }
}

let devPwrite: fntfs_pwrite_cb = { ctx, buf, count, offset in
    guard let ctx else { return -Int64(EINVAL) }
    let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
    do {
        let buffer = UnsafeRawBufferPointer(start: buf, count: Int(count))
        let n = try dev.resource.write(from: buffer, startingAt: offset,
                                       length: Int(count))
        dev.record(.write, short: n != Int(count))
        return Int64(n)
    } catch {
        let code = posixCode(error)
        dev.record(.write, error: code)
        return -Int64(code)
    }
}

let devFlush: fntfs_flush_cb = { ctx in
    guard let ctx else { return -EINVAL }
    let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
    do {
        // The public FSKit API flushes the resource's kernel buffer cache.
        // It does not expose F_FULLFSYNC/DKIOCSYNCHRONIZECACHE or promise that
        // a USB controller's volatile cache survives sudden power loss.
        try dev.resource.metadataFlush()
        dev.record(.flush)
        return 0
    } catch {
        let code = posixCode(error)
        dev.record(.flush, error: code)
        return -code
    }
}
