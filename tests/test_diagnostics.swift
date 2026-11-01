import Foundation

@main
struct DiagnosticRegression {
    static func main() throws {
        let clean = NTFSMountStatus(readOnly: false, safetyFlags: 0, io: NTFSIOStatistics())
        let hibernated = NTFSMountStatus(readOnly: true, safetyFlags: 2, io: NTFSIOStatistics())
        precondition(clean.isConsistent && hibernated.isConsistent)
        precondition(!NTFSMountStatus(readOnly: false, safetyFlags: 2, io: NTFSIOStatistics()).isConsistent)
        precondition(!NTFSMountStatus(readOnly: true, safetyFlags: 16, io: NTFSIOStatistics()).isConsistent)
        precondition(hibernated.readOnlyExplanation.contains("hibernation"))
        precondition(hibernated.readOnlyExplanation.contains("preserves"))
        let failed = NTFSMountStatus(readOnly: true, safetyFlags: 0, io: NTFSIOStatistics(), failureError: EIO)
        precondition(failed.isConsistent && failed.readOnlyExplanation.contains("Writing stopped"))
        precondition(!NTFSMountStatus(readOnly: false, safetyFlags: 0, io: NTFSIOStatistics(), failureError: EIO).isConsistent)

        let input = DiagnosticVolume(index: 1, mounted: true, readOnly: false,
            filesystem: "mntfs", module: hibernated)
        precondition(input.readOnly)
        let report = DiagnosticReport.make(appVersion: "regression", extensionPresent: true,
            registered: true, signatureValid: true, volumes: [input])
        let decoded = try JSONDecoder().decode(DiagnosticReport.self, from: report.json)
        precondition(decoded.volumes == [input] && decoded.schemaVersion == 1)
        precondition(decoded.checks.contains { $0.name == "Extension activation" && $0.status == .ok })
        precondition(decoded.checks.contains { $0.name == "NTFS volume 1" && $0.status == .warning })
        let noMount = DiagnosticReport.make(appVersion: "regression", extensionPresent: true,
            registered: true, signatureValid: nil, extensionState: .enabled, volumes: [])
        precondition(noMount.checks.contains { $0.name == "Extension activation" && $0.status == .unknown })
        precondition(noMount.checks.contains { $0.name == "Extension enablement" && $0.status == .ok })
        let disabled = DiagnosticReport.make(appVersion: "regression", extensionPresent: true,
            registered: true, signatureValid: true, extensionState: .disabled, volumes: [input])
        precondition(disabled.checks.contains { $0.name == "Extension enablement" && $0.status == .warning })
        precondition(disabled.checks.contains { $0.name == "Extension activation" && $0.status == .ok })
        let unknown = DiagnosticVolume(index: 2, mounted: true, readOnly: true,
            filesystem: "/Volumes/Private Drive", module: nil)
        let missing = DiagnosticReport.make(appVersion: "regression", extensionPresent: false,
            registered: nil, signatureValid: nil, volumes: [unknown])
        precondition(missing.checks.contains { $0.name == "NTFS volume 2" && $0.status == .unknown })
        precondition(missing.checks.contains { $0.name == "Extension bundle" && $0.status == .error })
        precondition(!String(decoding: missing.json, as: UTF8.self).contains("Private Drive"))
        precondition(!String(decoding: missing.json, as: UTF8.self).contains("/Volumes/"))

        // Raw command output is bounded, and hung child processes cannot keep
        // the diagnostics worker blocked indefinitely.
        let bounded = DiagnosticCommand.run("/usr/bin/printf", ["%s", String(repeating: "x", count: 10000)], outputLimit: 128)
        precondition(bounded.status == 0 && bounded.output.count == 128)
        let start = Date()
        let timeout = DiagnosticCommand.run("/bin/sleep", ["5"], timeout: 0.05)
        precondition(timeout.status == nil && Date().timeIntervalSince(start) < 2)
        precondition(DiagnosticCommand.run("/no/such/tool", []).status == nil)
        print("Diagnostics tests passed (live evidence, unknown states, read-only reasons, JSON round trip, privacy, command limits)")
    }
}
