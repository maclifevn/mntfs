// Regression: NTFS's hidden root must be a visible FSKit root, while hidden
// child files and the Windows flags stored on disk retain their semantics.
import Foundation
import FSKit

private var imageFD: Int32 = -1
private let imageRead: fntfs_pread_cb = { _, buf, count, offset in
    let n = pread(imageFD, buf, Int(count), offset)
    return n < 0 ? -Int64(errno) : Int64(n)
}
private let imageWrite: fntfs_pwrite_cb = { _, buf, count, offset in
    let n = pwrite(imageFD, buf, Int(count), offset)
    return n < 0 ? -Int64(errno) : Int64(n)
}
private let imageFlush: fntfs_flush_cb = { _ in
    fsync(imageFD) == 0 ? 0 : -errno
}

@main
struct VolumeRegression {
    static func main() {
        precondition(CommandLine.arguments.count == 2, "pass a disposable NTFS image")
        imageFD = open(CommandLine.arguments[1], O_RDWR)
        precondition(imageFD >= 0)
        defer { close(imageFD) }
        var stat = stat()
        precondition(fstat(imageFD, &stat) == 0)
        var error: Int32 = 0
        let v = fntfs_mount(nil, imageRead, imageWrite, imageFlush,
                            UInt64(stat.st_size), 512, false, nil, nil, &error)!
        let root = fntfs_root_inum()
        var a = fntfs_attrs()
        precondition(fntfs_getattr(v, root, &a) == 0)
        print("formatted NTFS root Windows flags: \(a.win_attrs)")
        let hidden = UInt32(FNTFS_WINATTR_HIDDEN | FNTFS_WINATTR_SYSTEM)
        precondition(fntfs_setwinattrs(v, root, hidden) == 0)
        precondition(fntfs_getattr(v, root, &a) == 0)
        let rootAttrs = NTFSVolume.fsAttributes(a)
        precondition(rootAttrs.type == .directory)
        precondition(rootAttrs.fileID == .rootDirectory)
        precondition(rootAttrs.flags & UInt32(UF_HIDDEN) == 0)

        var child = fntfs_attrs()
        precondition(fntfs_create(v, root, "hidden-child", false, &child) == 0)
        precondition(fntfs_setwinattrs(v, child.inum, hidden) == 0)
        precondition(fntfs_getattr(v, child.inum, &child) == 0)
        let childAttrs = NTFSVolume.fsAttributes(child)
        precondition(childAttrs.flags & UInt32(UF_HIDDEN) != 0)
        precondition(childAttrs.fileID.rawValue == child.inum)
        precondition(NTFSVolume.itemID(for: root) == rootAttrs.fileID)
        precondition(NTFSVolume.itemID(for: child.inum) == childAttrs.fileID)
        precondition(fntfs_unmount(v) == 0)

        // Conversion affects presentation only; disk flags stay unchanged.
        let ro = fntfs_mount(nil, imageRead, nil, nil, UInt64(stat.st_size),
                             512, true, nil, nil, &error)!
        precondition(fntfs_getattr(ro, root, &a) == 0 && a.win_attrs == hidden)
        precondition(fntfs_getattr(ro, child.inum, &child) == 0 && child.win_attrs == hidden)
        precondition(fntfs_unmount(ro) == 0)
        print("FSKit volume presentation tests passed")
    }
}
