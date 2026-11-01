import Foundation
import Darwin

enum MountStatusReader {
    static func read(at path: String, device: String? = nil) -> NTFSMountStatus? {
        var fs = statfs()
        guard statfs(path, &fs) == 0,
              string(fs.f_fstypename) == "mntfs", string(fs.f_mntonname) == path,
              device == nil || string(fs.f_mntfromname) == device else { return nil }
        let name = NTFSMountStatus.attributeName
        let size = getxattr(path, name, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0 && size <= 8192 else { return nil }
        var data = Data(count: size)
        let count = data.withUnsafeMutableBytes {
            getxattr(path, name, $0.baseAddress, $0.count, 0, XATTR_NOFOLLOW)
        }
        guard count > 0 && count <= size else { return nil }
        data.count = count
        guard let status = try? JSONDecoder().decode(NTFSMountStatus.self, from: data),
              status.isConsistent else { return nil }
        return status
    }

    private static func string<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }
}

struct DiagnosticCheck: Codable, Equatable, Sendable {
    enum Status: String, Codable { case ok, warning, error, unknown }
    let name: String
    let status: Status
    let detail: String
}

struct DiagnosticVolume: Codable, Equatable, Sendable {
    let index: Int
    let mounted: Bool
    let readOnly: Bool
    let filesystem: String
    let module: NTFSMountStatus?

    init(index: Int, mounted: Bool, readOnly: Bool, filesystem: String,
         module: NTFSMountStatus?) {
        self.index = index
        self.mounted = mounted
        self.readOnly = readOnly || module?.readOnly == true
        self.filesystem = ["mntfs", "ntfs"].contains(filesystem) ? filesystem : "unknown"
        self.module = module?.isConsistent == true ? module : nil
    }
}

struct DiagnosticReport: Codable, Identifiable, Sendable {
    let schemaVersion: Int
    let generatedAt: String
    let appVersion: String
    let macOSVersion: String
    let architecture: String
    let checks: [DiagnosticCheck]
    let volumes: [DiagnosticVolume]
    var id: String { generatedAt }

    var text: String {
        (["MNtfs diagnostics — \(appVersion)", "macOS \(macOSVersion), \(architecture)",
          "Collected: \(generatedAt)", ""] +
         checks.map { "[\($0.status.rawValue)] \($0.name): \($0.detail)" } +
         ["", "Privacy: drive labels, device IDs, UUIDs, file paths and network identity are omitted.",
          "No data is uploaded. Volume safety flags describe the mount-time check."])
            .joined(separator: "\n")
    }

    var json: Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? encoder.encode(self)) ?? Data("{\"error\":\"report-encoding-failed\"}".utf8)
    }

    static func make(appVersion: String, extensionPresent: Bool, registered: Bool?,
                     signatureValid: Bool?, extensionState: FilesystemExtensionState = .unavailable,
                     volumes: [DiagnosticVolume]) -> DiagnosticReport {
        #if arch(arm64)
        let architecture = "arm64"
        #else
        let architecture = "unsupported"
        #endif
        let system = ProcessInfo.processInfo.operatingSystemVersion
        let supported = architecture == "arm64" &&
            (system.majorVersion > 15 || (system.majorVersion == 15 && system.minorVersion >= 4))
        var checks = [DiagnosticCheck(name: "Platform", status: supported ? .ok : .error,
            detail: supported ? "Supported Apple Silicon macOS." : "Requires Apple Silicon and macOS 15.4+."),
            DiagnosticCheck(name: "Extension bundle", status: extensionPresent ? .ok : .error,
                detail: extensionPresent ? "Bundled filesystem extension found." : "Filesystem extension missing; reinstall MNtfs.")]
        checks.append(DiagnosticCheck(name: "Extension enablement",
            status: extensionState.isEnabled ? .ok :
                [.disabled, .notFound].contains(extensionState) ? .warning : .unknown,
            detail: extensionState.detail))
        let live = volumes.contains { $0.mounted && $0.module != nil }
        checks.append(DiagnosticCheck(name: "Extension activation", status: live ? .ok : .unknown,
            detail: live ? "A mounted MNtfs volume answered the live status query." :
                registered == true ? "Registered; no live MNtfs volume in this snapshot. See Extension enablement for the FSKit setting." :
                registered == false ? "No registration found. Check File System Extensions in System Settings." :
                "Registration query was unavailable or timed out."))
        checks.append(DiagnosticCheck(name: "App signature", status: signatureValid == true ? .ok : .unknown,
            detail: signatureValid == true ? "Bundle passed codesign verification." :
                "Bundle signature could not be verified; use an official signed build."))
        checks.append(DiagnosticCheck(name: "Power-loss durability", status: .warning,
            detail: "FSKit resource-buffer flush is used. Hardware-cache flush is not exposed; physical power-loss protection is not certified."))
        if volumes.isEmpty {
            checks.append(DiagnosticCheck(name: "NTFS volumes", status: .unknown,
                detail: "No NTFS volumes in this snapshot. Plug in a test drive to verify the live module."))
        }
        for volume in volumes {
            let detail: String
            let status: DiagnosticCheck.Status
            if !volume.mounted {
                status = .unknown; detail = "Not mounted."
            } else if let module = volume.module {
                let errors = module.io.readErrors + module.io.writeErrors + module.io.flushErrors
                status = volume.readOnly || errors > 0 ? .warning : .ok
                detail = (volume.readOnly ? module.readOnlyExplanation : "Mounted read/write; mount-time safety check passed.") +
                    " I/O errors: \(errors); flush calls: \(module.io.flushCalls)."
            } else {
                status = .unknown
                detail = "Live MNtfs status unavailable. The mount mode alone does not identify the reason for read-only access."
            }
            checks.append(DiagnosticCheck(name: "NTFS volume \(volume.index)", status: status, detail: detail))
        }
        return DiagnosticReport(schemaVersion: 1, generatedAt: ISO8601DateFormatter().string(from: Date()),
            appVersion: appVersion, macOSVersion: "\(system.majorVersion).\(system.minorVersion).\(system.patchVersion)",
            architecture: architecture, checks: checks, volumes: volumes)
    }
}

enum DiagnosticCommand {
    struct Result { let status: Int32?; let output: Data }

    /// Only known read-only tools call this runner. Output and execution time
    /// are bounded; raw output never enters the exported report.
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 8,
                    outputLimit: Int = 65536) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return Result(status: nil, output: Data()) }
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.25) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + max(0.01, timeout), execute: watchdog)
        var output = Data()
        while let chunk = try? pipe.fileHandleForReading.read(upToCount: 4096), !chunk.isEmpty {
            if output.count < outputLimit { output.append(chunk.prefix(max(0, outputLimit - output.count))) }
        }
        process.waitUntilExit()
        watchdog.cancel()
        return Result(status: process.terminationReason == .exit ? process.terminationStatus : nil, output: output)
    }
}

enum Diagnostics {
    static func collect(bundle: Bundle = .main, volumes: [DiagnosticVolume],
                        extensionState: FilesystemExtensionState = .unavailable) -> DiagnosticReport {
        let identifier = ExtensionStatusReader.identifier
        let registration = DiagnosticCommand.run("/usr/bin/pluginkit", ["-m", "-A", "-D", "-i", identifier])
        let registered: Bool? = registration.status == 0
            ? String(data: registration.output, encoding: .utf8)?.contains(identifier) : nil
        let signature = DiagnosticCommand.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", bundle.bundleURL.path])
        let present = FileManager.default.fileExists(atPath:
            bundle.bundleURL.appendingPathComponent(ExtensionStatusReader.relativePath).path)
        return DiagnosticReport.make(appVersion: (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development",
            extensionPresent: present, registered: registered,
            signatureValid: signature.status.map { $0 == 0 }, extensionState: extensionState, volumes: volumes)
    }
}
