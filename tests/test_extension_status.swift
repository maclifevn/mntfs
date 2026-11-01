// No disk enumeration, mounting, settings changes, or live FSKit queries.
import Foundation

@MainActor
@main
struct ExtensionStatusRegression {
    static func main() async {
        let app = URL(fileURLWithPath: "/Applications/MNtfs.app")
        let current = app.appendingPathComponent(ExtensionStatusReader.relativePath)
        let older = URL(fileURLWithPath: "/tmp/Old MNtfs.app")
            .appendingPathComponent(ExtensionStatusReader.relativePath)
        func module(_ enabled: Bool, url: URL? = nil, identifier: String = ExtensionStatusReader.identifier) -> InstalledFilesystemExtension {
            InstalledFilesystemExtension(bundleIdentifier: identifier, url: url ?? current, isEnabled: enabled)
        }

        // No attached disks must never be treated as proof of enablement.
        precondition(ExtensionStatusReader.resolve([], bundleURL: app) == .notFound)
        precondition(ExtensionStatusReader.resolve([module(false)], bundleURL: app) == .disabled)
        precondition(ExtensionStatusReader.resolve([module(true)], bundleURL: app) == .enabled)
        precondition(ExtensionStatusReader.resolve([module(true, identifier: "org.example.OtherFS")], bundleURL: app) == .notFound)
        precondition(ExtensionStatusReader.resolve([module(true, url: older)], bundleURL: app) == .notFound)
        precondition(ExtensionStatusReader.resolve([module(true, url: older), module(false)], bundleURL: app) == .disabled)
        precondition(ExtensionStatusReader.resolve([module(false, url: older), module(true)], bundleURL: app) == .enabled)
        precondition(ExtensionStatusReader.resolve([module(true), module(false)], bundleURL: app) == .disabled)

        var fail = false
        let monitor = ExtensionStatusMonitor {
            if fail { throw CocoaError(.fileReadUnknown) }
            return .enabled
        }
        precondition(monitor.state == .checking && !monitor.state.isEnabled)
        let firstAccepted = await monitor.refresh()
        precondition(firstAccepted && monitor.state == .enabled)
        fail = true
        let errorAccepted = await monitor.refresh()
        precondition(errorAccepted && monitor.state == .unavailable && !monitor.state.isEnabled)

        // A delayed launch query must not overwrite a newer Settings response.
        var pending: [CheckedContinuation<FilesystemExtensionState, Error>] = []
        let racing = ExtensionStatusMonitor {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        let old = Task { await racing.refresh() }
        await waitForQueries(1, count: { pending.count })
        let latest = Task { await racing.refresh() }
        await waitForQueries(2, count: { pending.count })
        pending[1].resume(returning: .disabled)
        let latestAccepted = await latest.value
        precondition(latestAccepted && racing.state == .disabled)
        pending[0].resume(returning: .enabled)
        let oldAccepted = await old.value
        precondition(!oldAccepted && racing.state == .disabled)

        let cancelled = Task { await racing.refresh() }
        await waitForQueries(3, count: { pending.count })
        cancelled.cancel()
        pending[2].resume(returning: .enabled)
        let cancelledAccepted = await cancelled.value
        precondition(!cancelledAccepted && racing.state == .disabled)
        print("Extension status tests passed (disabled without disks, exact app copy, unknown on error, stale and cancelled replies)")
    }

    static func waitForQueries(_ expected: Int, count: () -> Int) async {
        for _ in 0..<1000 {
            if count() == expected { return }
            await Task.yield()
        }
        preconditionFailure("Extension query did not start")
    }
}
