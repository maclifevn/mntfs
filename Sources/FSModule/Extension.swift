//
//  Extension.swift
//  FastNTFS FSModule — FSKit extension entry point.
//

import Foundation
import FSKit

@main
struct FastNTFSExtension: UnaryFileSystemExtension {
    var fileSystem: FSUnaryFileSystem & FSUnaryFileSystemOperations {
        NTFSFileSystem.shared
    }
}
