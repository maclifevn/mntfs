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

    /// Per-directory change counters, used as enumeration verifiers: a
    /// directory's counter bumps whenever an entry is added, removed, or
    /// renamed in it, so a resumed enumeration can detect that its cookie
    /// may no longer be valid. Starts at 1 (0 is the "initial" verifier).
    private var dirGeneration: [UInt64: UInt64] = [:]

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

    @discardableResult
    private func forget(_ it: NTFSItem) -> Int32 {
        itemsLock.lock()
        if items[it.inum] === it {
            items.removeValue(forKey: it.inum)
        }
        itemsLock.unlock()
        if let v = vol { return fntfs_forget(v, it.inum) }
        return 0
    }

    private func bumpGeneration(of dirs: UInt64...) {
        itemsLock.lock()
        for d in dirs { dirGeneration[d] = (dirGeneration[d] ?? 1) &+ 1 }
        itemsLock.unlock()
    }

    private func generation(of dir: UInt64) -> UInt64 {
        itemsLock.lock()
        defer { itemsLock.unlock() }
        return dirGeneration[dir] ?? 1
    }

    /// Finalize an open-unlinked item: delete the ghost entry that kept its
    /// data alive. Call once the last open handle is gone. Ghosts live in the
    /// root directory, so root's enumeration generation is bumped too.
    private func finalizeUnlink(_ it: NTFSItem) {
        itemsLock.lock()
        let ghost = it.unlinkedGhost
        it.unlinkedGhost = nil
        itemsLock.unlock()
        if let ghost, let v = vol {
            _ = fntfs_remove(v, fntfs_root_inum(), ghost, it.inum)
            bumpGeneration(of: fntfs_root_inum())
        }
    }

    /// Forget the change counter of a directory that no longer exists.
    private func dropGeneration(of dir: UInt64) {
        itemsLock.lock()
        dirGeneration.removeValue(forKey: dir)
        itemsLock.unlock()
    }

    // MARK: - Attribute conversion

    private static func itemType(_ raw: Int32) -> FSItem.ItemType {
        switch Int(raw) {
        case FNTFS_TYPE_DIR: return .directory
        case FNTFS_TYPE_SYMLINK: return .symlink
        default: return .file
        }
    }

    /// FSKit reserves ID 2 for the root. Keep raw MFT numbers in the bridge,
    /// and translate consistently at both attribute and enumeration boundaries.
    static func itemID(for inum: UInt64) -> FSItem.Identifier {
        inum == fntfs_root_inum() ? .rootDirectory
            : FSItem.Identifier(rawValue: inum) ?? .invalid
    }

    static func fsAttributes(_ a: fntfs_attrs) -> FSItem.Attributes {
        let out = FSItem.Attributes()
        out.invalidateAllProperties()
        let type = Self.itemType(a.type)
        out.type = type
        out.fileID = itemID(for: a.inum)
        out.uid = 99  // unknown; ownerless volume
        out.gid = 99
        out.linkCount = a.nlink

        var mode: UInt32 = (type == .directory) ? 0o777 : 0o666
        if a.win_attrs & UInt32(FNTFS_WINATTR_READONLY) != 0 {
            mode &= ~UInt32(0o222)
        }
        out.mode = mode

        var flags: UInt32 = 0
        // NTFS marks its root as hidden/system on Windows. Mapping that to
        // UF_HIDDEN hides the entire mounted drive in Finder and on Desktop.
        // Preserve hidden semantics for children without changing disk flags.
        if a.inum != fntfs_root_inum(),
           a.win_attrs & UInt32(FNTFS_WINATTR_HIDDEN) != 0 {
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
        dirGeneration.removeAll()
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
            reply(Self.fsAttributes(a), nil)
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
            reply(Self.fsAttributes(a), nil)
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
            finalizeUnlink(it)   // safety net if no close arrived
            let err = forget(it)
            reply(err == 0 ? nil : posixError(-err))
            return
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
            bumpGeneration(of: dir.inum)
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
            // POSIX forbids hard links to directories — they'd create cycles.
            // (The bridge's rename path may still link directories internally;
            // that use is safe because the old name is removed in the same
            // locked sequence.)
            guard it.type != .directory else {
                reply(nil, posixError(EPERM))
                return
            }
            let err = fntfs_link(v, it.inum, dir.inum, nm)
            guard err == 0 else { reply(nil, posixError(-err)); return }
            bumpGeneration(of: dir.inum)
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

            // POSIX open-unlink: a file deleted while a process still has it
            // open must stay readable/writable until the last handle closes.
            // The bridge decides under its lock whether a ghost is needed
            // (only when this is the inode's last real name) and parks it in
            // the root directory; the delete is finalized on the last close
            // (or reclaim, or the next mount's sweep).
            itemsLock.lock()
            let deferDelete = it.isOpen && it.type == .file
                && it.unlinkedGhost == nil
            itemsLock.unlock()
            if deferDelete {
                var ghost = [CChar](repeating: 0, count: 64)
                let err = fntfs_unlink_keep(v, dir.inum, nm, it.inum, &ghost)
                guard err == 0 else { reply(posixError(-err)); return }
                if ghost[0] != 0 {
                    itemsLock.lock()
                    it.unlinkedGhost = String(cString: ghost)
                    itemsLock.unlock()
                    // The ghost entry landed in the root directory.
                    bumpGeneration(of: dir.inum, fntfs_root_inum())
                } else {
                    bumpGeneration(of: dir.inum)
                }
                reply(nil)
                return
            }

            let err = fntfs_remove(v, dir.inum, nm, it.inum)
            guard err == 0 else { reply(posixError(-err)); return }
            if it.type == .directory { dropGeneration(of: it.inum) }
            bumpGeneration(of: dir.inum)
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
            let overIt = try overItem.map { try requireItem($0) }
            let overInum = overIt?.inum ?? 0

            // If the replaced destination is still open somewhere, its data
            // must outlive the rename (same POSIX rule as open-unlink): ask
            // the bridge to park it instead of deleting it.
            var keepOver = false
            if let overIt, overIt.type == .file {
                itemsLock.lock()
                keepOver = overIt.isOpen && overIt.unlinkedGhost == nil
                itemsLock.unlock()
            }

            var ghost = [CChar](repeating: 0, count: 64)
            let err = keepOver
                ? fntfs_rename2(v, it.inum, srcDir.inum, srcName,
                                dstDir.inum, dstName, overInum, &ghost)
                : fntfs_rename(v, it.inum, srcDir.inum, srcName,
                               dstDir.inum, dstName, overInum)
            guard err == 0 else { reply(nil, posixError(-err)); return }

            if keepOver, ghost[0] != 0, let overIt {
                itemsLock.lock()
                overIt.unlinkedGhost = String(cString: ghost)
                itemsLock.unlock()
                // The parked ghost landed in the root directory.
                bumpGeneration(of: fntfs_root_inum())
            }
            if let overIt, overIt.type == .directory {
                dropGeneration(of: overIt.inum)   // empty dir was replaced
            }
            bumpGeneration(of: srcDir.inum, dstDir.inum)
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

            // A resumed enumeration (cookie != initial) is only valid against
            // the directory version it started from: entries added or removed
            // in between can shift NTFS index positions, so the cookie could
            // skip or repeat entries. Tell the caller to restart.
            let currentGen = generation(of: dir.inum)
            if cookie.rawValue != 0, verifier.rawValue != currentGen {
                reply(FSDirectoryVerifier(rawValue: 0),
                      NSError(domain: FSKitErrorDomain,
                              code: FSError.Code.invalidDirectoryCookie.rawValue))
                return
            }

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
                    attrs = NTFSVolume.fsAttributes(a)
                }
                let type: FSItem.ItemType =
                    (Int(ctype) == FNTFS_TYPE_DIR) ? .directory : .file
                let ok = ctx.packer.packEntry(
                    name: FSFileName(string: name),
                    itemType: type,
                    itemID: NTFSVolume.itemID(for: inum),
                    nextCookie: FSDirectoryCookie(rawValue: UInt64(nextCookie)),
                    attributes: attrs)
                if ok { ctx.packedCount += 1 }
                return ok
            }

            let rawCtx = Unmanaged.passUnretained(ctx).toOpaque()
            let err = fntfs_readdir(v, dir.inum, Int64(cookie.rawValue),
                                    rawCtx, cb)
            guard err == 0 else { reply(FSDirectoryVerifier(rawValue: 0), posixError(-err)); return }
            reply(FSDirectoryVerifier(rawValue: currentGen), nil)
        } catch {
            reply(FSDirectoryVerifier(rawValue: 0), error)
        }
    }
}

// MARK: - Open/Close

// Tracks which items the kernel holds open, so removeItem can tell an
// open-unlink (defer the real delete) from a plain delete.
extension NTFSVolume: FSVolume.OpenCloseOperations {

    func openItem(_ item: FSItem, modes: FSVolume.OpenModes,
                  replyHandler reply: @escaping (Error?) -> Void) {
        guard let it = item as? NTFSItem else {
            reply(posixError(EINVAL))
            return
        }
        itemsLock.lock()
        it.isOpen = true
        itemsLock.unlock()
        reply(nil)
    }

    func closeItem(_ item: FSItem, modes: FSVolume.OpenModes,
                   replyHandler reply: @escaping (Error?) -> Void) {
        guard let it = item as? NTFSItem else {
            reply(posixError(EINVAL))
            return
        }
        // `modes` is the set that remains after this close; empty means the
        // last handle is gone — finalize a pending open-unlink, if any.
        if modes.isEmpty {
            itemsLock.lock()
            it.isOpen = false
            itemsLock.unlock()
            finalizeUnlink(it)
        }
        reply(nil)
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
