//
//  FastNTFSApp.swift
//  MNtfs — host app for the FSKit NTFS module.
//
//  Runs quietly in the menu bar at login. While the manager window is open,
//  it becomes a regular app with an application menu and Dock icon.
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
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, ObservableObject {
    let store = VolumeStore()
    lazy var updater = UpdateController(safety: UpdateSafetyGate(
        pause: { [store] in store.updatePreparationInProgress = true },
        resume: { [store] in store.updatePreparationInProgress = false },
        snapshot: { [store] in store.updateSafetySnapshot() }))
    private var window: NSWindow?

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        updater.start()
        let d = UserDefaults.standard
        if !d.bool(forKey: "didFirstRun") {
            d.set(true, forKey: "didFirstRun")
            LoginItem.setEnabled(true)          // start at login by default; toggle in the menu
        }
        // Show the setup window until setup is done (extension enabled + a drive
        // mounted at least once). New users always get a visible window
        // to grant permissions from; afterwards login launches stay quiet in the
        // background and the menu-bar item reopens it on demand.
        if !d.bool(forKey: "setupComplete") {
            showWindow()
        }
    }

    // Keep running in the background when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        updater.applicationShouldTerminate()
    }

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
            // Accessory apps cannot own the application's menu bar. Promote
            // before activation; closing the manager restores background mode.
            installMainMenu()
            NSApp.setActivationPolicy(.regular)
            if window == nil {
                let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                                 styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                 backing: .buffered, defer: false)
                w.title = "MNtfs"
                w.isReleasedWhenClosed = false
                w.delegate = self
                w.contentMinSize = NSSize(width: 1000, height: 640)
                w.contentViewController = NSHostingController(rootView: ContentView(store: store))
                w.center()
                window = w
            }
            window?.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// MenuBarExtra alone does not provide a standard application menu for
    /// the manually hosted manager window.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem(title: "MNtfs", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "MNtfs")
        appMenu.addItem(withTitle: "About MNtfs", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = appMenu.addItem(withTitle: "File System Extensions…", action: #selector(openExtensionSettingsFromMenu(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide MNtfs", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit MNtfs", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let fileItem = NSMenuItem(title: "File", action: nil, keyEquivalent: "")
        let fileMenu = NSMenu(title: "File")
        let open = fileMenu.addItem(withTitle: "Open MNtfs", action: #selector(openManagerFromMenu(_:)), keyEquivalent: "0")
        open.target = self
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        main.addItem(fileItem)

        let editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: "")
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openManagerFromMenu(_ sender: Any?) { showWindow() }
    @objc private func openExtensionSettingsFromMenu(_ sender: Any?) { store.openExtensionSettings() }
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
        UpdateMenu(updater: delegate.updater)
        Button("Diagnostics…") {
            delegate.showWindow()
            delegate.store.diagnose()
        }
        Divider()
        Button("Quit MNtfs") { NSApp.terminate(nil) }
    }
}

private struct UpdateMenu: View {
    @ObservedObject var updater: UpdateController

    var body: some View {
        Button(updater.installationPending ? "Install Downloaded Update…"
               : updater.availableVersion.map { "Update to \($0)…" } ?? "Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Toggle("Automatically Check for Updates", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticChecks($0) }))
        .disabled(!updater.canCheckForUpdates)
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
