//
//  NTFSVolume.swift
//  FastNTFS — FSVolume implementation bridging FSKit to libntfs-3g.
//
//  All FSKit operations funnel into the fntfs C bridge, which serializes
//  access internally. Methods here run synchronously on FSKit's calling
//  threads and reply when done.
//

import Foundation
import FSKit

private func posixError(_ code: Int32) -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(code))
}

final class NTFSVolume: FSVolume {
    private let device: BlockDevice
    private let readOnly: Bool
    private var vol: OpaquePointer?

    /// FSItem identity table: one NTFSItem instance per live inode.
    private var items: [UInt64: NTFSItem] = [:]
    private let itemsLock = NSLock()

    /// Bumped on every namespace mutation; doubles as directory verifier.
    private var generation: UInt64 = 1

    // Ownerless volume: expose everything to the mounting user.
    private let uid: UInt32 = 99  // unknown
    private let gid: UInt32 = 99

    init(device: BlockDevice, readOnly: Bool, vol: OpaquePointer,
         name: String, serial: UInt64) {
        self.device = device
        self.readOnly = readOnly
        self.vol = vol
        super.init(
            volumeID: FSVolume.Identifier(uuid: Self.uuid(fromSerial: serial)),
            volumeName: FSFileName(string: name.isEmpty ? "NTFS Volume" : name)
        )
    }

    /// Deterministic UUID derived from the NTFS boot-sector serial number.
    static func uuid(fromSerial serial: UInt64) -> UUID {
        var b = [UInt8](repeating: 0, count: 16)
        let tag: [UInt8] = Array("FASTNTFS".utf8)
        for i in 0..<8 { b[i] = tag[i] }
        for i in 0..<8 { b[8 + i] = UInt8((serial >> (8 * i)) & 0xff) }
        b[6] = (b[6] & 0x0f) | 0x40  // version 4 shape
        b[8] = (b[8] & 0x3f) | 0x80  // RFC 4122 variant
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
                           b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    // MARK: - Item table

    private func item(inum: UInt64, type: FSItem.ItemType) -> NTFSItem {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        if let existing = items[inum] {
            existing.type = type
            return existing
        }
        let it = NTFSItem(inum: inum, type: type)
        items[inum] = it
        return it
    }

    private func forget(_ it: NTFSItem) {
        itemsLock.lock()
        if items[it.inum] === it {
            items.removeValue(forKey: it.inum)
        }
        itemsLock.unlock()
        if let v = vol { fntfs_forget(v, it.inum) }
    }

    private func bumpGeneration() -> UInt64 {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        generation += 1
        return generation
    }

    // MARK: - Attribute conversion

    private static func itemType(_ raw: Int32) -> FSItem.ItemType {
        switch Int(raw) {
        case FNTFS_TYPE_DIR: return .directory
        case FNTFS_TYPE_SYMLINK: return .symlink
        default: return .file
        }
    }

    private func fsAttributes(_ a: fntfs_attrs) -> FSItem.Attributes {
        let out = FSItem.Attributes()
        out.invalidateAllProperties()
        let type = Self.itemType(a.type)
        out.type = type
        out.fileID = FSItem.Identifier(rawValue: a.inum) ?? .invalid
        out.uid = uid
        out.gid = gid
        out.linkCount = a.nlink

        var mode: UInt32 = (type == .directory) ? 0o777 : 0o666
        if a.win_attrs & UInt32(FNTFS_WINATTR_READONLY) != 0 {
            mode &= ~UInt32(0o222)
        }
        out.mode = mode

        var flags: UInt32 = 0
        if a.win_attrs & UInt32(FNTFS_WINATTR_HIDDEN) != 0 {
            flags |= UInt32(UF_HIDDEN)
        }
        out.flags = flags

        out.size = a.size
        out.allocSize = a.alloc_size
        out.modifyTime = timespec(tv_sec: Int(a.mtime_sec), tv_nsec: Int(a.mtime_nsec))
        out.changeTime = timespec(tv_sec: Int(a.ctime_sec), tv_nsec: Int(a.ctime_nsec))
        out.accessTime = timespec(tv_sec: Int(a.atime_sec), tv_nsec: Int(a.atime_nsec))
        out.birthTime = timespec(tv_sec: Int(a.crtime_sec), tv_nsec: Int(a.crtime_nsec))
        return out
    }

    private func requireVolume() throws -> OpaquePointer {
        guard let v = vol else { throw posixError(ENXIO) }
        return v
    }

    /// Volume pointer for a mutating operation. Rejects writes early with EROFS
    /// on a read-only mount instead of letting them travel down to the bridge.
    private func requireWritableVolume() throws -> OpaquePointer {
        let v = try requireVolume()
        if readOnly { throw posixError(EROFS) }
        return v
    }

    private func requireItem(_ item: FSItem) throws -> NTFSItem {
        guard let it = item as? NTFSItem else { throw posixError(EINVAL) }
        return it
    }

    private func utf8Name(_ name: FSFileName) throws -> String {
        guard let s = name.string, !s.isEmpty, !s.contains("/") else {
            throw posixError(EINVAL)
        }
        return s
    }

    /// Flush all dirty state and release the on-disk volume.
    func shutdownVolume() {
        if let v = vol {
            fntfs_unmount(v)
            vol = nil
        }
    }
}

// MARK: - PathConf

extension NTFSVolume: FSVolume.PathConfOperations {
    var maximumLinkCount: Int { 1023 }
    var maximumNameLength: Int { 255 }
    var restrictsOwnershipChanges: Bool { false }
    var truncatesLongNames: Bool { false }
    var maximumFileSizeInBits: Int { 64 }
}

// MARK: - Core operations

extension NTFSVolume: FSVolume.Operations {

    var supportedVolumeCapabilities: FSVolume.SupportedCapabilities {
        let caps = FSVolume.SupportedCapabilities()
        caps.supportsPersistentObjectIDs = true
        caps.supportsHardLinks = true
        caps.supportsSymbolicLinks = false
        caps.supportsJournal = true
        caps.supportsActiveJournal = false
        caps.supportsSparseFiles = true
        caps.supports2TBFiles = true
        caps.supports64BitObjectIDs = true
        caps.supportsHiddenFiles = true
        caps.doesNotSupportSettingFilePermissions = true
        caps.caseFormat = .insensitiveCasePreserving
        return caps
    }

    var volumeStatistics: FSStatFSResult {
        // Must equal the Info.plist FSShortName ("mntfs"). "ntfs" is reserved
        // by Apple's system NTFS plugin and gets our module rejected.
        let res = FSStatFSResult(fileSystemTypeName: "mntfs")
        guard let v = vol else { return res }
        var sf = fntfs_statfs_t()
        if fntfs_statfs(v, &sf) == 0 {
            res.blockSize = Int(sf.cluster_size)
            res.ioSize = 1 << 20
            res.totalBytes = sf.total_bytes
            res.freeBytes = sf.free_bytes
            res.availableBytes = sf.free_bytes
            res.usedBytes = sf.total_bytes - sf.free_bytes
            res.totalFiles = sf.total_files
            res.freeFiles = 0
        }
        return res
    }

    func activate(options: FSTaskOptions,
                  replyHandler reply: @escaping (FSItem?, Error?) -> Void) {
        do {
            _ = try requireVolume()
            let root = item(inum: fntfs_root_inum(), type: .directory)
            reply(root, nil)
        } catch {
            reply(nil, error)
        }
    }

    func deactivate(options: FSDeactivateOptions = [],
                    replyHandler reply: @escaping (Error?) -> Void) {
        itemsLock.lock()
        items.removeAll()
        itemsLock.unlock()
        reply(nil)
    }

    func mount(options: FSTaskOptions,
               replyHandler reply: @escaping (Error?) -> Void) {
        reply(nil)
    }

    func unmount(replyHandler reply: @escaping () -> Void) {
        shutdownVolume()
        reply()
    }

    func synchronize(flags: FSSyncFlags,
                     replyHandler reply: @escaping (Error?) -> Void) {
        guard let v = vol else { reply(nil); return }
        let err = fntfs_sync(v)
        reply(err == 0 ? nil : posixError(-err))
    }

    func getAttributes(_ desiredAttributes: FSItem.GetAttributesRequest,
                       of item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            let v = try requireVolume()
            let it = try requireItem(item)
            var a = fntfs_attrs()
            let err = fntfs_getattr(v, it.inum, &a)
            guard err == 0 else { reply(nil, posixError(-err)); return }
            reply(fsAttributes(a), nil)
        } catch {
            reply(nil, error)
        }
    }

    func setAttributes(_ newAttributes: FSItem.SetAttributesRequest,
                       on item: FSItem,
                       replyHandler reply: @escaping (FSItem.Attributes?, Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let it = try requireItem(item)

            try applyAttributes(v, it.inum, isFile: it.type == .file, newAttributes)

            var a = fntfs_attrs()
            let err = fntfs_getattr(v, it.inum, &a)
            guard err == 0 else { reply(nil, posixError(-err)); return }
            reply(fsAttributes(a), nil)
        } catch {
            reply(nil, error)
        }
    }

    /// Apply the settable attributes (size, times, hidden flag) to `inum`,
    /// marking each as consumed. Throws a POSIX error on failure. Shared by
    /// setAttributes and createItem (so a create honours its initial attrs).
    private func applyAttributes(_ v: OpaquePointer, _ inum: UInt64,
                                 isFile: Bool,
                                 _ req: FSItem.SetAttributesRequest) throws {
        if req.isValid(.size), isFile {
            let err = fntfs_truncate(v, inum, req.size)
            guard err == 0 else { throw posixError(-err) }
            req.consumedAttributes.insert(.size)
        }

        var times = fntfs_attrs()
        var mask: UInt32 = 0
        if req.isValid(.modifyTime) {
            times.mtime_sec = Int64(req.modifyTime.tv_sec)
            times.mtime_nsec = Int32(req.modifyTime.tv_nsec)
            mask |= UInt32(FNTFS_SET_MTIME)
        }
        if req.isValid(.accessTime) {
            times.atime_sec = Int64(req.accessTime.tv_sec)
            times.atime_nsec = Int32(req.accessTime.tv_nsec)
            mask |= UInt32(FNTFS_SET_ATIME)
        }
        if req.isValid(.birthTime) {
            times.crtime_sec = Int64(req.birthTime.tv_sec)
            times.crtime_nsec = Int32(req.birthTime.tv_nsec)
            mask |= UInt32(FNTFS_SET_CRTIME)
        }
        if mask != 0 {
            let err = fntfs_settimes(v, inum, &times, mask)
            guard err == 0 else { throw posixError(-err) }
            if mask & UInt32(FNTFS_SET_MTIME) != 0 { req.consumedAttributes.insert(.modifyTime) }
            if mask & UInt32(FNTFS_SET_ATIME) != 0 { req.consumedAttributes.insert(.accessTime) }
            if mask & UInt32(FNTFS_SET_CRTIME) != 0 { req.consumedAttributes.insert(.birthTime) }
        }

        if req.isValid(.flags) {
            var a = fntfs_attrs()
            var err = fntfs_getattr(v, inum, &a)
            if err == 0 {
                var wa = a.win_attrs
                if req.flags & UInt32(UF_HIDDEN) != 0 {
                    wa |= UInt32(FNTFS_WINATTR_HIDDEN)
                } else {
                    wa &= ~UInt32(FNTFS_WINATTR_HIDDEN)
                }
                if wa != a.win_attrs { err = fntfs_setwinattrs(v, inum, wa) }
            }
            guard err == 0 else { throw posixError(-err) }
            req.consumedAttributes.insert(.flags)
        }
    }

    func lookupItem(named name: FSFileName, inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            let v = try requireVolume()
            let dir = try requireItem(directory)
            let nm = try utf8Name(name)
            var a = fntfs_attrs()
            let err = fntfs_lookup(v, dir.inum, nm, &a)
            guard err == 0 else { reply(nil, nil, posixError(-err)); return }
            let it = item(inum: a.inum, type: Self.itemType(a.type))
            reply(it, name, nil)
        } catch {
            reply(nil, nil, error)
        }
    }

    func reclaimItem(_ item: FSItem,
                     replyHandler reply: @escaping (Error?) -> Void) {
        if let it = item as? NTFSItem {
            forget(it)
        }
        reply(nil)
    }

    func readSymbolicLink(_ item: FSItem,
                          replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        reply(nil, posixError(ENOTSUP))
    }

    func createItem(named name: FSFileName, type: FSItem.ItemType,
                    inDirectory directory: FSItem,
                    attributes newAttributes: FSItem.SetAttributesRequest,
                    replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let dir = try requireItem(directory)
            let nm = try utf8Name(name)
            guard type == .file || type == .directory else {
                throw posixError(ENOTSUP)
            }
            var a = fntfs_attrs()
            let err = fntfs_create(v, dir.inum, nm, type == .directory, &a)
            guard err == 0 else { reply(nil, nil, posixError(-err)); return }
            // Honour the requested initial attributes (times/size/flags).
            // Best-effort: the item exists regardless, so don't fail the create
            // if only the attribute pass hits a problem.
            try? applyAttributes(v, a.inum, isFile: type == .file, newAttributes)
            _ = bumpGeneration()
            let it = item(inum: a.inum, type: Self.itemType(a.type))
            reply(it, name, nil)
        } catch {
            reply(nil, nil, error)
        }
    }

    func createSymbolicLink(named name: FSFileName, inDirectory directory: FSItem,
                            attributes newAttributes: FSItem.SetAttributesRequest,
                            linkContents contents: FSFileName,
                            replyHandler reply: @escaping (FSItem?, FSFileName?, Error?) -> Void) {
        reply(nil, nil, posixError(ENOTSUP))
    }

    func createLink(to item: FSItem, named name: FSFileName,
                    inDirectory directory: FSItem,
                    replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let it = try requireItem(item)
            let dir = try requireItem(directory)
            let nm = try utf8Name(name)
            let err = fntfs_link(v, it.inum, dir.inum, nm)
            guard err == 0 else { reply(nil, posixError(-err)); return }
            _ = bumpGeneration()
            reply(name, nil)
        } catch {
            reply(nil, error)
        }
    }

    func removeItem(_ item: FSItem, named name: FSFileName,
                    fromDirectory directory: FSItem,
                    replyHandler reply: @escaping (Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let it = try requireItem(item)
            let dir = try requireItem(directory)
            let nm = try utf8Name(name)
            let err = fntfs_remove(v, dir.inum, nm, it.inum)
            guard err == 0 else { reply(posixError(-err)); return }
            _ = bumpGeneration()
            reply(nil)
        } catch {
            reply(error)
        }
    }

    func renameItem(_ item: FSItem, inDirectory sourceDirectory: FSItem,
                    named sourceName: FSFileName, to destinationName: FSFileName,
                    inDirectory destinationDirectory: FSItem, overItem: FSItem?,
                    replyHandler reply: @escaping (FSFileName?, Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let it = try requireItem(item)
            let srcDir = try requireItem(sourceDirectory)
            let dstDir = try requireItem(destinationDirectory)
            let srcName = try utf8Name(sourceName)
            let dstName = try utf8Name(destinationName)

            // Do NOT delete the destination up front — the bridge replaces it
            // atomically-safely (keeping the old target under a temporary name
            // until the move succeeds) so a failed rename can't lose data.
            let overInum = try overItem.map { try requireItem($0).inum } ?? 0
            let err = fntfs_rename(v, it.inum, srcDir.inum, srcName,
                                   dstDir.inum, dstName, overInum)
            guard err == 0 else { reply(nil, posixError(-err)); return }
            _ = bumpGeneration()
            reply(destinationName, nil)
        } catch {
            reply(nil, error)
        }
    }

    func enumerateDirectory(_ directory: FSItem, startingAt cookie: FSDirectoryCookie,
                            verifier: FSDirectoryVerifier,
                            attributes: FSItem.GetAttributesRequest?,
                            packer: FSDirectoryEntryPacker,
                            replyHandler reply: @escaping (FSDirectoryVerifier, Error?) -> Void) {
        do {
            let v = try requireVolume()
            let dir = try requireItem(directory)

            final class EnumCtx {
                let volume: NTFSVolume
                let v: OpaquePointer
                let packer: FSDirectoryEntryPacker
                let attributes: FSItem.GetAttributesRequest?
                var packedCount = 0
                init(volume: NTFSVolume, v: OpaquePointer,
                     packer: FSDirectoryEntryPacker,
                     attributes: FSItem.GetAttributesRequest?) {
                    self.volume = volume
                    self.v = v
                    self.packer = packer
                    self.attributes = attributes
                }
            }
            let ctx = EnumCtx(volume: self, v: v, packer: packer,
                              attributes: attributes)

            let cb: fntfs_dirent_cb = { rawCtx, cname, ctype, inum, nextCookie in
                let ctx = Unmanaged<EnumCtx>.fromOpaque(rawCtx!).takeUnretainedValue()
                let name = String(cString: cname)
                let isDot = (name == "." || name == "..")

                // With an attribute request, "." and ".." are omitted.
                if ctx.attributes != nil && isDot { return true }

                var attrs: FSItem.Attributes?
                if let req = ctx.attributes {
                    var a = fntfs_attrs()
                    guard fntfs_getattr(ctx.v, inum, &a) == 0 else {
                        return true  // entry vanished or unreadable: skip
                    }
                    _ = req
                    attrs = ctx.volume.fsAttributes(a)
                }
                let type: FSItem.ItemType =
                    (Int(ctype) == FNTFS_TYPE_DIR) ? .directory : .file
                let ok = ctx.packer.packEntry(
                    name: FSFileName(string: name),
                    itemType: type,
                    itemID: FSItem.Identifier(rawValue: inum) ?? .invalid,
                    nextCookie: FSDirectoryCookie(rawValue: UInt64(nextCookie)),
                    attributes: attrs)
                if ok { ctx.packedCount += 1 }
                return ok
            }

            let rawCtx = Unmanaged.passUnretained(ctx).toOpaque()
            let err = fntfs_readdir(v, dir.inum, Int64(cookie.rawValue),
                                    rawCtx, cb)
            guard err == 0 else { reply(FSDirectoryVerifier(rawValue: 0), posixError(-err)); return }
            itemsLock.lock()
            let gen = generation
            itemsLock.unlock()
            reply(FSDirectoryVerifier(rawValue: gen), nil)
        } catch {
            reply(FSDirectoryVerifier(rawValue: 0), error)
        }
    }
}

// MARK: - Read/Write

extension NTFSVolume: FSVolume.ReadWriteOperations {

    func read(from item: FSItem, at offset: off_t, length: Int,
              into buffer: FSMutableFileDataBuffer,
              replyHandler reply: @escaping (Int, Error?) -> Void) {
        do {
            let v = try requireVolume()
            let it = try requireItem(item)
            let want = min(length, buffer.length)
            let n: Int64 = buffer.withUnsafeMutableBytes { raw in
                guard let base = raw.baseAddress else { return Int64(-EINVAL) }
                return fntfs_read(v, it.inum, base, Int64(want), offset)
            }
            if n < 0 {
                reply(0, posixError(Int32(-n)))
            } else {
                reply(Int(n), nil)
            }
        } catch {
            reply(0, error)
        }
    }

    func write(contents: Data, to item: FSItem, at offset: off_t,
               replyHandler reply: @escaping (Int, Error?) -> Void) {
        do {
            let v = try requireWritableVolume()
            let it = try requireItem(item)
            let n: Int64 = contents.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return 0 }
                return fntfs_write(v, it.inum, base, Int64(raw.count), offset)
            }
            if n < 0 {
                reply(0, posixError(Int32(-n)))
            } else {
                reply(Int(n), nil)
            }
        } catch {
            reply(0, error)
        }
    }
}
