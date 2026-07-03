//
//  NTFSItem.swift
//  FastNTFS — FSItem backed by an NTFS MFT record number.
//

import Foundation
import FSKit

final class NTFSItem: FSItem {
    let inum: UInt64
    var type: FSItem.ItemType

    init(inum: UInt64, type: FSItem.ItemType) {
        self.inum = inum
        self.type = type
        super.init()
    }
}
