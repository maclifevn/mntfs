import Foundation

enum UpdateRuntimePolicy {
    static func updatesEnabled(debug: Bool, environment: [String: String]) -> Bool {
        guard environment["XCTestConfigurationFilePath"] == nil else { return false }
        return !debug || environment["MNTFS_ENABLE_UPDATES"] == "1"
    }

    static func installationEligible(bundleURL: URL, writable: Bool) -> Bool {
        let url = bundleURL.standardizedFileURL
        return writable && url.pathExtension.lowercased() == "app"
            && url.deletingLastPathComponent().path == "/Applications"
            && !url.path.contains("/AppTranslocation/")
    }
}

struct UpdateSafetySnapshot {
    let activeOperations: Int
    /// nil means the mount table could not be read: refuse installation.
    let mountedVolumes: [String]?

    var blockingReason: String? {
        if activeOperations > 0 {
            return "MNtfs is still mounting, verifying, formatting, or setting up a drive. Wait for it to finish, then retry."
        }
        guard let mountedVolumes else {
            return "Could not check mounted drives. Retry before installing the update."
        }
        if !mountedVolumes.isEmpty {
            return "Finish copying files and eject these drives in Finder before updating MNtfs:\n\n"
                + mountedVolumes.joined(separator: "\n")
                + "\n\nThe file system extension must be idle while it is replaced."
        }
        return nil
    }
}

/// Stop new app disk operations before checking the live mount table. Never
/// force-unmount a drive: Finder and other apps may still be copying files.
@MainActor
final class UpdateSafetyGate {
    private let pause: () -> Void
    private let resume: () -> Void
    private let snapshot: () -> UpdateSafetySnapshot
    private(set) var isPrepared = false

    init(pause: @escaping () -> Void, resume: @escaping () -> Void,
         snapshot: @escaping () -> UpdateSafetySnapshot) {
        self.pause = pause
        self.resume = resume
        self.snapshot = snapshot
    }

    func prepare() -> String? {
        pause()
        if let reason = snapshot().blockingReason {
            cancel()
            return reason
        }
        isPrepared = true
        return nil
    }

    func cancel() {
        isPrepared = false
        resume()
    }
}
