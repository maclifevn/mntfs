import AppKit
import Combine
import Sparkle

@MainActor
final class UpdateController: NSObject, ObservableObject {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false
    @Published private(set) var availableVersion: String?
    @Published private(set) var installationPending = false

    private let safety: UpdateSafetyGate
    private let environment: [String: String]
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: self, userDriverDelegate: self)
    private var observations = Set<AnyCancellable>()
    private var started = false
    private var preparing = false
    private var installing = false
    private var installHandler: (() -> Void)?

    init(safety: UpdateSafetyGate,
         environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.safety = safety
        self.environment = environment
        super.init()
    }

    private var updatesEnabled: Bool {
#if DEBUG
        let debug = true
#else
        let debug = false
#endif
        return UpdateRuntimePolicy.updatesEnabled(debug: debug, environment: environment)
    }

    private var installationEligible: Bool {
        let url = Bundle.main.bundleURL
        return UpdateRuntimePolicy.installationEligible(bundleURL: url,
            writable: FileManager.default.isWritableFile(atPath: url.path)
                && FileManager.default.isWritableFile(atPath: url.deletingLastPathComponent().path))
    }

    func start() {
        guard updatesEnabled, !started else { return }
        started = true
        controller.updater.publisher(for: \.canCheckForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] value in
                guard let self else { return }
                self.canCheckForUpdates = !self.preparing && (value || self.installationPending)
            }.store(in: &observations)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates)
            .receive(on: RunLoop.main).sink { [weak self] in
                self?.automaticallyChecksForUpdates = $0
            }.store(in: &observations)
        controller.startUpdater()
    }

    func setAutomaticChecks(_ enabled: Bool) {
        controller.updater.automaticallyChecksForUpdates = enabled
    }

    func checkForUpdates() {
        guard updatesEnabled, canCheckForUpdates else { return }
        NSApp.activate(ignoringOtherApps: true)
        guard installationEligible else {
            let alert = NSAlert()
            alert.messageText = "Move MNtfs to Applications"
            alert.informativeText = "Move MNtfs to /Applications and open it there before checking for updates."
            alert.runModal()
            return
        }
        if installHandler != nil { prepareInstallation() }
        else { controller.checkForUpdates(nil) }
    }

    /// Automatic downloads also install on quit. Guard that route as well as
    /// the interactive Install button; quitting the host does not stop FSKit.
    func applicationShouldTerminate() -> NSApplication.TerminateReply {
        if installing { return .terminateNow }
        if preparing { return .terminateCancel }
        guard installHandler != nil else { return .terminateNow }
        prepareInstallation()
        return .terminateCancel
    }

    private func prepareInstallation() {
        guard !preparing, !installing, installHandler != nil else { return }
        preparing = true
        canCheckForUpdates = false
        // Defer out of Sparkle's delegate/termination call stack.
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                preparing = false
                canCheckForUpdates = !installing
                    && (installationPending || controller.updater.canCheckForUpdates)
            }
            while let handler = installHandler {
                if let reason = safety.prepare() {
                    let alert = NSAlert()
                    alert.alertStyle = .warning
                    alert.messageText = "Eject drives before updating"
                    alert.informativeText = reason
                    alert.addButton(withTitle: "Retry")
                    alert.addButton(withTitle: "Later")
                    NSApp.activate(ignoringOtherApps: true)
                    guard alert.runModal() == .alertFirstButtonReturn else { return }
                    continue
                }
                installing = true
                installHandler = nil
                installationPending = false
                handler()
                return
            }
        }
    }
}

extension UpdateController: SPUUpdaterDelegate {
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        guard installationEligible else {
            throw NSError(domain: "com.fastntfs.FastNTFS.updates", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "MNtfs must be in /Applications before checking for updates."])
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
#if DEBUG
        // Local QA only; release builds always use the signed production feed.
        return environment["MNTFS_UPDATE_FEED_URL"]
#else
        return nil
#endif
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock handler: @escaping () -> Void) -> Bool {
        installHandler = handler
        installationPending = true
        prepareInstallation()
        return true
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                 immediateInstallationBlock handler: @escaping () -> Void) -> Bool {
        installHandler = handler
        installationPending = true
        canCheckForUpdates = true
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        installHandler = nil
        installationPending = false
        installing = false
        safety.cancel()
    }
}

// Sparkle invokes standard UI delegates on the main thread. Older Sparkle
// headers do not annotate this protocol's actor isolation.
extension UpdateController: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem,
                                                              andInImmediateFocus immediateFocus: Bool) -> Bool {
        immediateFocus
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool,
                                                   forUpdate update: SUAppcastItem,
                                                   state: SPUUserUpdateState) {
        availableVersion = update.displayVersionString
    }

    func standardUserDriverWillFinishUpdateSession() {
        availableVersion = nil
    }
}
