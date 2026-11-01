import Combine
import Foundation
import FSKit

enum FilesystemExtensionState: String, Sendable {
    case checking, enabled, disabled, notFound, unavailable

    var isEnabled: Bool { self == .enabled }

    var title: String {
        switch self {
        case .checking: "Checking extension…"
        case .enabled: "Extension enabled"
        case .disabled: "Extension not enabled"
        case .notFound: "Extension unavailable"
        case .unavailable: "Extension status unknown"
        }
    }

    var detail: String {
        switch self {
        case .checking: "Waiting for FSKit to report the module's state."
        case .enabled: "FSKit reports this copy of FastNTFSFSModule enabled."
        case .disabled: "Enable FastNTFSFSModule in System Settings."
        case .notFound: "FSKit cannot find this copy of the module. Open MNtfs from Applications and check File System Extensions."
        case .unavailable: "Could not query FSKit. Check File System Extensions in System Settings, then refresh."
        }
    }
}

struct InstalledFilesystemExtension: Sendable {
    let bundleIdentifier: String
    let url: URL
    let isEnabled: Bool
}

enum ExtensionStatusReader {
    static let identifier = "com.fastntfs.FastNTFS.FSModule"
    static let relativePath = "Contents/Extensions/FastNTFSFSModule.appex"

    /// Registration, PlugInKit election and the absence of NTFS disks do not
    /// prove enablement. Also reject an enabled development/older app copy.
    static func resolve(_ modules: [InstalledFilesystemExtension], bundleURL: URL) -> FilesystemExtensionState {
        let expected = bundleURL.appendingPathComponent(relativePath).resolvingSymlinksInPath().standardizedFileURL
        let matching = modules.filter {
            $0.bundleIdentifier == identifier && $0.url.resolvingSymlinksInPath().standardizedFileURL == expected
        }
        guard !matching.isEmpty else { return .notFound }
        return matching.allSatisfy(\.isEnabled) ? .enabled : .disabled
    }

    @MainActor
    static func read() async throws -> FilesystemExtensionState {
        let modules = try await FSClient.shared.installedExtensions
        return resolve(modules.map {
            InstalledFilesystemExtension(bundleIdentifier: $0.bundleIdentifier, url: $0.url, isEnabled: $0.isEnabled)
        }, bundleURL: Bundle.main.bundleURL)
    }
}

@MainActor
final class ExtensionStatusMonitor: ObservableObject {
    @Published private(set) var state: FilesystemExtensionState = .checking
    private let query: () async throws -> FilesystemExtensionState
    private var revision = 0

    init(query: @escaping () async throws -> FilesystemExtensionState = { try await ExtensionStatusReader.read() }) {
        self.query = query
    }

    /// A foreground refresh can overtake a launch/mount query. An older reply
    /// must never turn the badge green after the latest reply said disabled.
    @discardableResult
    func refresh() async -> Bool {
        revision += 1
        let request = revision
        let next: FilesystemExtensionState
        do { next = try await query() }
        catch { next = .unavailable }
        guard request == revision, !Task.isCancelled else { return false }
        if state != next { state = next }
        return true
    }
}
