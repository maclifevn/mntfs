//
//  NTFSItem.swift
//  FastNTFS — FSItem backed by an NTFS MFT record number.
//

import Foundation
import FSKit

final class NTFSItem: FSItem {
    let inum: UInt64
    var type: FSItem.ItemType

    /// True while the kernel holds this item open (FSVolume.OpenCloseOperations).
    /// Guarded by the volume's itemsLock.
    var isOpen = false

    /// When the item was unlinked while still open, the ghost name (in the
    /// root directory) keeping its data alive until the last close/reclaim.
    /// Guarded by the volume's itemsLock.
    var unlinkedGhost: String?

    init(inum: UInt64, type: FSItem.ItemType) {
        self.inum = inum
        self.type = type
        super.init()
    }
}
