//
//  BlockDevice.swift
//  FastNTFS — adapts FSBlockDeviceResource to the fntfs C I/O callbacks.
//
//  The C bridge guarantees sector-aligned offsets and lengths, so the calls
//  map 1:1 onto the resource's synchronous read/write accessors.
//

import Foundation
import FSKit

final class BlockDevice {
    let resource: FSBlockDeviceResource

    init(resource: FSBlockDeviceResource) {
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
        return Int64(n)
    } catch {
        return -Int64(posixCode(error))
    }
}

let devPwrite: fntfs_pwrite_cb = { ctx, buf, count, offset in
    guard let ctx else { return -Int64(EINVAL) }
    let dev = Unmanaged<BlockDevice>.fromOpaque(ctx).takeUnretainedValue()
    do {
        let buffer = UnsafeRawBufferPointer(start: buf, count: Int(count))
        let n = try dev.resource.write(from: buffer, startingAt: offset,
                                       length: Int(count))
        return Int64(n)
    } catch {
        return -Int64(posixCode(error))
    }
}

let devFlush: fntfs_flush_cb = { _ in
    // Writes go straight to the device through fskitd; no extra cache to drop.
    return 0
}
