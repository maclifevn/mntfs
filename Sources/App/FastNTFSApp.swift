//
//  FastNTFSApp.swift
//  FastNTFS — host app for the FSKit NTFS module.
//

import SwiftUI

@main
struct FastNTFSApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(minWidth: 520, minHeight: 400)
        }
        .windowResizability(.contentSize)
    }
}
