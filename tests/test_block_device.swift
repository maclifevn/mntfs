import Foundation
import FSKit

private final class FaultResource: BlockResourceIO {
    let blockCount: UInt64 = 8
    let blockSize: UInt64 = 512
    var error: Int32?
    var flushes = 0
    var shortWrite = false
    func read(into buffer: UnsafeMutableRawBufferPointer, startingAt: off_t,
              length: Int) throws -> Int {
        if let error { throw POSIXError(POSIXErrorCode(rawValue: error)!) }
        buffer.initializeMemory(as: UInt8.self, repeating: 0x42)
        return length
    }
    func write(from buffer: UnsafeRawBufferPointer, startingAt: off_t,
               length: Int) throws -> Int {
        if let error { throw POSIXError(POSIXErrorCode(rawValue: error)!) }
        return shortWrite ? length / 2 : length
    }
    func metadataFlush() throws {
        flushes += 1
        if let error { throw POSIXError(POSIXErrorCode(rawValue: error)!) }
    }
}

@main
struct BlockDeviceRegression {
    static func main() {
        let resource = FaultResource()
        let device = BlockDevice(resource: resource)
        precondition(devFlush(device.opaque) == 0 && resource.flushes == 1)
        resource.error = EIO
        precondition(devFlush(device.opaque) == -EIO && resource.flushes == 2)
        resource.error = ENXIO
        precondition(devFlush(device.opaque) == -ENXIO)
        var bytes = [UInt8](repeating: 0, count: 512)
        bytes.withUnsafeMutableBytes { buffer in
            precondition(devPread(device.opaque, buffer.baseAddress!, 512, 0) == -Int64(ENXIO))
            precondition(devPwrite(device.opaque, buffer.baseAddress!, 512, 0) == -Int64(ENXIO))
            resource.error = nil
            resource.shortWrite = true
            precondition(devPwrite(device.opaque, buffer.baseAddress!, 512, 0) == 256)
        }
        precondition(devFlush(nil) == -EINVAL)
        precondition(posixCode(NSError(domain: "unknown", code: 1)) == EIO)
        withExtendedLifetime(device) {}
        print("FSKit adapter tests passed (flush invocation, EIO, unplug, short write)")
    }
}
