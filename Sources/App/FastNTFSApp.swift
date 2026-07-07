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
                .frame(minWidth: 1000, minHeight: 660)
        }
        .windowResizability(.contentSize)
    }
}
