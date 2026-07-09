//
//  FastNTFSApp.swift
//  MNtfs — host app for the FSKit NTFS module.
//
//  Runs as a menu-bar (accessory) app: no Dock icon, starts at login, and works
//  quietly in the background so NTFS drives are writable right after boot without
//  opening anything or replugging (see VolumeStore.autoRemountReadOnlyNTFS).
//

import SwiftUI
import AppKit
import ServiceManagement

@main
struct MNtfsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra("MNtfs", systemImage: "externaldrive.fill") {
            MenuBarContent(delegate: delegate)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let store = VolumeStore()
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)   // menu-bar only, no Dock icon
        let d = UserDefaults.standard
        if !d.bool(forKey: "didFirstRun") {
            d.set(true, forKey: "didFirstRun")
            LoginItem.setEnabled(true)          // start at login by default; toggle in the menu
        }
        // Show the setup window until setup is done (extension enabled + a drive
        // mounted writable at least once). New users always get a visible window
        // to grant permissions from; afterwards login launches stay quiet in the
        // background and the menu-bar item reopens it on demand.
        if !d.bool(forKey: "setupComplete") {
            showWindow()
        }
    }

    // Keep running in the background when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    // Re-opening the app from Finder/Dock (while it runs in the background) shows the window.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    func showWindow() {
        // Defer to the next run-loop tick: calling activate/makeKeyAndOrderFront
        // synchronously inside applicationDidFinishLaunching for an accessory app
        // often no-ops, leaving the user with only the menu-bar item and no way
        // to reach the setup UI.
        DispatchQueue.main.async { [self] in
            if window == nil {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
                w.title = "MNtfs"
                w.isReleasedWhenClosed = false
                w.contentMinSize = NSSize(width: 1000, height: 640)
                w.contentViewController = NSHostingController(rootView: ContentView(store: store))
                w.center()
                window = w
            }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

struct MenuBarContent: View {
    @ObservedObject var delegate: AppDelegate
    @State private var loginOn = LoginItem.isEnabled

    var body: some View {
        Button("Open MNtfs") { delegate.showWindow() }
        Divider()
        Toggle("Open at Login", isOn: $loginOn)
            .onChange(of: loginOn) { _, on in LoginItem.setEnabled(on) }
        Divider()
        Button("Quit MNtfs") { NSApp.terminate(nil) }
    }
}

/// Start-at-login via the modern ServiceManagement API (no helper bundle needed).
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ on: Bool) {
        do {
            if on {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("MNtfs login item error: \(error.localizedDescription)")
        }
    }
}
