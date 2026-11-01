//
//  ContentView.swift
//  Mntfs — NTFS volume manager. Its own visual identity: a Maclife-blue
//  midnight theme, a capacity ring as the hero, pill actions and switch
//  toggles. Same job as any NTFS manager, deliberately not a clone of one.
//

import SwiftUI
import AppKit
import UniformTypeIdentifiers
import FSKit

// MARK: - Palette

private extension Color {
    init(_ hex: UInt32) {
        self.init(.sRGB,
                  red:   Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue:  Double(hex & 0xff) / 255)
    }
}

private enum UI {
    static let appBG   = Color(0x0d1720)
    static let sidebar = Color(0x0f1a24)
    static let detailA = Color(0x16232f)
    static let detailB = Color(0x0e1822)
    static let line    = Color.white.opacity(0.07)
    static let card    = Color.white.opacity(0.04)
    static let text    = Color(0xeef4fa)
    static let dim     = Color(0x90a4b6)
    static let faint   = Color(0x5f7183)
    static let accent  = Color(0x12c3f4)
    static let accentDeep = Color(0x0066ab)
    static let green   = Color(0x37d07f)
    static let amber   = Color(0xf5a623)
    static let rose    = Color(0xff6f6f)

    static let ntfsGrad = LinearGradient(colors: [Color(0x18c8f5), Color(0x0a72bd)],
                                         startPoint: .top, endPoint: .bottom)
    static let ringGrad = AngularGradient(
        gradient: Gradient(colors: [Color(0x0066ab), Color(0x12c3f4), Color(0x7fe4ff)]),
        center: .center, startAngle: .degrees(-90), endAngle: .degrees(270))
}

// MARK: - Maclife logo mark

struct MaclifeMark: View {
    var body: some View {
        Canvas { ctx, size in
            let vbW = 64.0, vbH = 54.75
            let s = min(size.width / vbW, size.height / vbH)
            let ox = (size.width - vbW * s) / 2
            let oy = (size.height - vbH * s) / 2
            func poly(_ pts: [(Double, Double)], _ color: Color) {
                var path = Path()
                for (i, p) in pts.enumerated() {
                    let pt = CGPoint(x: ox + p.0 * s, y: oy + p.1 * s)
                    if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(color))
            }
            poly([(13.77, 17.46), (1.29, 50.15), (12.29, 50.15), (27.56, 26.78)], Color(0x12c3f4))
            poly([(43.12, 2.94), (27.56, 26.78), (62.16, 50.15)], Color(0x39a4dc))
            poly([(27.56, 26.78), (12.29, 50.15), (62.16, 50.15)], Color(0x0066ab))
        }
    }
}

/// A flat, branded disk tile — Mntfs's mark, distinct from a photoreal drive.
struct DiskEmblem: View {
    var size: CGFloat
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .fill(LinearGradient(colors: [Color(0x223444), Color(0x152230)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1))
                .shadow(color: .black.opacity(0.35), radius: size * 0.08, y: size * 0.03)
            MaclifeMark().padding(size * 0.24)
        }
        .frame(width: size, height: size)
    }
}

/// The real macOS drive icon for a volume (Finder icon when mounted),
/// falling back to an SF Symbol drive when the volume isn't mounted.
struct VolumeGlyph: View {
    let volume: VolumeItem
    let size: CGFloat
    var body: some View {
        if let img = Self.finderIcon(volume) {
            Image(nsImage: img).resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
        } else {
            Image(systemName: volume.ejectable ? "externaldrive.fill" : "internaldrive.fill")
                .font(.system(size: size * 0.5, weight: .regular))
                .foregroundStyle(Color(0xaab8c6))
                .frame(width: size, height: size)
        }
    }
    static func finderIcon(_ v: VolumeItem) -> NSImage? {
        guard let mp = v.mountPoint else { return nil }
        return NSWorkspace.shared.icon(forFile: mp)
    }
}

/// Capacity ring — the hero. Maclife-gradient arc over a faint track, with the
/// macOS drive icon at its centre.
struct CapacityRing: View {
    var fraction: Double
    var size: CGFloat
    var volume: VolumeItem
    var body: some View {
        let lw = size * 0.085
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lw)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(UI.ringGrad, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VolumeGlyph(volume: volume, size: size * 0.46)
        }
        .frame(width: size, height: size)
    }
}

// MARK: - Model

struct VolumeItem: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    var sizeBytes: Int64
    var device: String
    var fileSystem: String
    var content: String
    var mountPoint: String?
    var writable: Bool
    var ejectable: Bool
    var isNTFS: Bool
    var nobrowse: Bool
    var usedBytes: Int64
    var freeBytes: Int64
    /// Stable identifiers used to revalidate a destructive erase. BSD disk
    /// numbers, size, and partition type can all be reused after a replug.
    var volumeUUID: String? = nil
    var diskUUID: String? = nil
    /// True for the placeholder rows shown when no volumes are detected.
    /// Sample rows must never reach diskutil/mkntfs.
    var isSample: Bool = false
    var mountedFileSystem: String = ""
    var driverStatus: NTFSMountStatus? = nil
    var attachmentIdentity: VolumeAttachmentIdentity? = nil

    var mounted: Bool { mountPoint != nil }
    var displayName: String { name.isEmpty ? "Untitled" : name }
    var sizeText: String { ByteCount.string(sizeBytes) }
    var usedFraction: Double { sizeBytes > 0 ? Double(usedBytes) / Double(sizeBytes) : 0 }
    var readOnly: Bool { !writable }
    var accessVerified: Bool { mountedFileSystem != "mntfs" || driverStatus != nil }
    var accessText: String { accessVerified ? (readOnly ? "Read-only" : "Read & Write") : "Unverified" }

    /// `isNTFS` is derived from the real mounted filesystem type (see
    /// `enumerate()`), so it stays correct even though diskutil labels our
    /// FSKit NTFS volumes "ExFAT". Show NTFS for those, the true filesystem
    /// name (e.g. "ExFAT", "APFS") for everything else.
    var formatDisplay: String {
        if isNTFS { return "Windows NTFS" }
        return fileSystem.isEmpty ? "Unknown" : fileSystem
    }
}

enum ByteCount {
    static func string(_ b: Int64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useGB, .useMB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: b)
    }
}

@MainActor
final class VolumeStore: ObservableObject {
    @Published var ntfs: [VolumeItem] = []
    @Published var others: [VolumeItem] = []
    @Published var selectedID: String?
    @Published var scanning = false
    @Published var usingSampleData = false
    @Published private(set) var scanError: String?
    @Published private(set) var busyDevices: Set<String> = []
    @Published var actionMessage: String?
    let extensionMonitor = ExtensionStatusMonitor()
    @Published var verifying = false
    @Published var erasing = false
    @Published var eraseTarget: VolumeItem?
    @Published var offerLabelSupport = false
    @Published var diagnosing = false
    @Published var diagnosticReport: DiagnosticReport?

    /// Last time we tried to convert each device from Apple's read-only mount
    /// (throttle, so a cold/disabled extension can't send us into a tight loop),
    /// and devices currently being processed (guard against overlapping runs).
    private var remountAttempts: [VolumeAttachmentIdentity: Date] = [:]
    private var remountInFlight: Set<String> = []
    private var diskOperations = 0
    private let diskMountService = DiskMountService()
    private var liveStatusInFlight = false
    private lazy var refreshCoordinator = SnapshotRefreshCoordinator<[VolumeItem]>(
        load: { try await Task.detached(priority: .userInitiated) { try Self.enumerate() }.value },
        apply: { [weak self] result in
            guard let self else { return }
            self.scanning = false
            switch result {
            case .success(let volumes): self.scanError = nil; self.apply(volumes)
            case .failure(let error): self.scanError = error.localizedDescription
            }
        })
    var updatePreparationInProgress = false

    func updateSafetySnapshot() -> UpdateSafetySnapshot {
        var buf: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buf, MNT_NOWAIT)
        guard count > 0, let list = buf else {
            if let buf { free(buf) }
            return UpdateSafetySnapshot(activeOperations: diskOperations + remountInFlight.count,
                                        mountedVolumes: nil)
        }
        defer { free(list) }
        let mounts = UnsafeBufferPointer(start: list, count: Int(count))
            .filter { Self.cStr16($0.f_fstypename) == "mntfs" }
            .map { Self.cStr16($0.f_mntonname) }
        return UpdateSafetySnapshot(activeOperations: diskOperations + remountInFlight.count,
                                    mountedVolumes: mounts)
    }

    var selected: VolumeItem? { (ntfs + others).first { $0.id == selectedID } }

    func diagnose() {
        guard !diagnosing else { return }
        diagnosing = true
        let snapshot = ntfs.filter { !$0.isSample }
        Task {
            await refreshExtension()
            let state = extensionMonitor.state
            let report = await Task.detached(priority: .utility) {
                let volumes = snapshot.enumerated().map { index, volume in
                    DiagnosticVolume(index: index + 1, mounted: volume.mounted,
                        readOnly: volume.readOnly, filesystem: volume.mountedFileSystem,
                        module: volume.mountPoint.flatMap { MountStatusReader.read(at: $0, device: volume.device) })
                }
                return Diagnostics.collect(volumes: volumes, extensionState: state)
            }.value
            diagnosticReport = report
            diagnosing = false
        }
    }

    init(startMonitoring: Bool = true) {
        guard startMonitoring else { return }
        refresh()
        maybeOfferLabelSupport()
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: .init("NSWorkspaceDidMountNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh(); self?.autoRemountReadOnlyNTFS() }
        }
        nc.addObserver(forName: .init("NSWorkspaceDidUnmountNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            // A drive left: let a future replug of the same device be retried.
            Task { @MainActor in self?.remountAttempts.removeAll(); self?.refresh() }
        }
        nc.addObserver(forName: .init("NSWorkspaceDidRenameVolumeNotification"),
                       object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        // Returning from System Settings after toggling the extension on: re-check
        // status AND force a remount of any read-only drive, so an already-plugged
        // drive becomes writable and the status flips to active without a replug.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.checkExtension()
                self?.autoRemountReadOnlyNTFS(force: true)
            }
        }
    }

    func refresh() {
        scanning = true
        checkExtension()
        refreshCoordinator.request()
    }

    /// Poll only the driver's small live xattr; a full diskutil scan is not
    /// needed to notice a write-error latch on an already mounted volume.
    func refreshLiveStatus() {
        guard !liveStatusInFlight else { return }
        let snapshot = ntfs.filter { !$0.isSample && $0.mountedFileSystem == "mntfs" && $0.mounted }
        guard !snapshot.isEmpty else { return }
        liveStatusInFlight = true
        Task {
            let updated = await Task.detached(priority: .utility) {
                snapshot.map { volume -> VolumeItem in
                    var copy = volume
                    let current = NativeDiskMountBackend.readIdentity(device: volume.device)
                    let same = volume.attachmentIdentity.map { expected in current.map(expected.matches) ?? false } ?? false
                    copy.driverStatus = same ? volume.mountPoint.flatMap {
                        MountStatusReader.read(at: $0, device: volume.device)
                    } : nil
                    let kernelWritable = volume.mountPoint.flatMap { Self.mountDetails($0) }.map { !$0.readOnly } ?? false
                    copy.writable = kernelWritable && copy.driverStatus?.readOnly == false
                    return copy
                }
            }.value
            for volume in updated {
                guard let index = ntfs.firstIndex(where: {
                    $0.id == volume.id && $0.attachmentIdentity == volume.attachmentIdentity &&
                    $0.mountPoint == volume.mountPoint && $0.mountedFileSystem == "mntfs"
                }) else { continue }
                if ntfs[index].driverStatus != volume.driverStatus || ntfs[index].writable != volume.writable {
                    ntfs[index].driverStatus = volume.driverStatus
                    ntfs[index].writable = volume.writable
                }
            }
            liveStatusInFlight = false
        }
    }

    func checkExtension() {
        Task { [weak self] in
            await self?.refreshExtension()
        }
    }

    private func refreshExtension() async {
        let wasEnabled = extensionMonitor.state.isEnabled
        guard await extensionMonitor.refresh() else { return }
        if Self.hasMntfsMount() {
            UserDefaults.standard.set(true, forKey: "setupComplete")
        }
        if extensionMonitor.state.isEnabled && !wasEnabled {
            autoRemountReadOnlyNTFS(force: true)
        }
    }

    func openExtensionSettings() {
        if #available(macOS 27.0, *), FSClient.shared.openFileSystemExtensionsSettings() { return }
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule")!
        NSWorkspace.shared.open(url)
    }

    // MARK: NTFS name registration for Finder / Disk Utility
    //
    // FSKit gives no runtime channel for a third-party volume's display type, and
    // the "ntfs" short name is reserved by Apple's system handler. But Finder and
    // Disk Utility resolve a mount's f_fstypename ("mntfs") to a display name via
    // the classic filesystem-bundle registry. Dropping a tiny name-only bundle
    // (no FSMediaTypes, so it never competes for probing/mounting) at
    // /Library/Filesystems/mntfs.fs makes them show "Windows NT File System
    // (NTFS)" instead of a bogus "ExFAT" / "Unknown (mntfs)". Requires one admin
    // authorization; optional (everything works without it, just mislabeled).

    nonisolated static let labelBundlePath = "/Library/Filesystems/mntfs.fs"

    nonisolated static let labelBundleInfoPlist = """
    <?xml version="1.0" encoding="UTF-8"?>
    <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
    <plist version="1.0">
    <dict>
    \t<key>CFBundleDevelopmentRegion</key><string>English</string>
    \t<key>CFBundleIdentifier</key><string>com.fastntfs.filesystems.mntfs</string>
    \t<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    \t<key>CFBundleName</key><string>mntfs</string>
    \t<key>CFBundlePackageType</key><string>fs  </string>
    \t<key>CFBundleShortVersionString</key><string>1.0</string>
    \t<key>CFBundleVersion</key><string>1.0</string>
    \t<key>FSImplementation</key><array><string>UserFS</string></array>
    \t<key>FSPersonalities</key>
    \t<dict>
    \t\t<key>NTFS</key>
    \t\t<dict>
    \t\t\t<key>FSName</key><string>Windows NT File System (NTFS)</string>
    \t\t</dict>
    \t</dict>
    </dict>
    </plist>
    """

    nonisolated static func labelSupportInstalled() -> Bool {
        guard let d = FileManager.default.contents(atPath: labelBundlePath + "/Contents/Info.plist"),
              let pl = (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil))
                as? [String: Any] else { return false }
        return (pl["CFBundleName"] as? String) == "mntfs"
    }

    func maybeOfferLabelSupport() {
        guard !Self.labelSupportInstalled(),
              !UserDefaults.standard.bool(forKey: "labelSupportDeclined") else { return }
        offerLabelSupport = true
    }

    func declineLabelSupport() {
        offerLabelSupport = false
        UserDefaults.standard.set(true, forKey: "labelSupportDeclined")
    }

    func installLabelSupport() {
        guard !updatePreparationInProgress else { return }
        diskOperations += 1
        offerLabelSupport = false
        Task.detached(priority: .userInitiated) {
            let result = Self.doInstallLabelSupport()
            // Finder/Disk Utility cache a volume's display name from mount time,
            // so already-mounted NTFS drives keep the old "ExFAT"/"Unknown" label
            // until remounted. Remount them once so the new name shows immediately.
            if result.ok {
                await self.remountNTFSVolumes()
            } else {
                NSLog("MNtfs: NTFS name support installation failed (%d): %@",
                      result.status, result.text)
            }
            await MainActor.run {
                self.diskOperations -= 1
                let detail = result.text.isEmpty
                    ? "The installer exited with status \(result.status)."
                    : result.text
                self.actionMessage = result.ok
                    ? "Done — NTFS drives now show as “Windows NT File System (NTFS)” in Finder and Disk Utility."
                    : "Could not install NTFS name support.\n\n\(detail)\n\n"
                    + "This optional component only changes the name shown in Finder and Disk Utility."
                self.refresh()
            }
        }
    }

    /// Thread-safe snapshot of the mount table. Never use `getmntinfo` here:
    /// it reuses ONE static buffer per process and reallocs it on every call,
    /// so two threads calling it at once corrupt the heap — that crashed the
    /// app whenever plugging a drive fired refresh + auto-remount + extension
    /// checks concurrently. `getmntinfo_r_np` gives each caller its own copy.
    nonisolated private static func mountTable() -> [statfs] {
        var buf: UnsafeMutablePointer<statfs>? = nil
        let n = getmntinfo_r_np(&buf, MNT_NOWAIT)
        guard n > 0, let list = buf else { return [] }
        defer { free(list) }
        return Array(UnsafeBufferPointer(start: list, count: Int(n)))
    }

    nonisolated private static func cStr16<T>(_ field: T) -> String {
        withUnsafeBytes(of: field) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
    }

    /// Remount every volume our driver has mounted ("mntfs"), so Finder and
    /// Disk Utility re-read the (now installed) display name. Best-effort:
    /// a busy volume that won't unmount is simply left as-is.
    private func remountNTFSVolumes() async {
        for fs in Self.mountTable() {
            guard Self.cStr16(fs.f_fstypename) == "mntfs" else { continue }
            let device = Self.cStr16(fs.f_mntfromname)
            guard !busyDevices.contains(device), !remountInFlight.contains(device),
                  let identity = NativeDiskMountBackend.readIdentity(device: device) else { continue }
            busyDevices.insert(device)
            do { try await diskMountService.remount(identity) }
            catch { NSLog("MNtfs: name refresh remount failed: %@", error.localizedDescription) }
            busyDevices.remove(device)
        }
    }

    /// Keep the filesystem copy separate from authorization and ownership so
    /// the install can be checked against disposable directories without root.
    nonisolated static func labelSupportCopyScript(from source: String, to destination: String) -> String {
        func quoted(_ path: String) -> String {
            "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
        }
        let parent = (destination as NSString).deletingLastPathComponent
        // /Library/Filesystems is optional and can be absent on a fresh Mac.
        return "/bin/mkdir -p -m 0755 \(quoted(parent))"
            + " && /bin/rm -rf \(quoted(destination))"
            + " && /bin/cp -R \(quoted(source)) \(quoted(destination))"
            + " && /bin/chmod -R u=rwX,go=rX \(quoted(destination))"
    }

    nonisolated static func labelSupportAppleScript(_ shellScript: String) -> String {
        let escaped = shellScript.replacingOccurrences(of: "\\", with: "\\\\")
                                 .replacingOccurrences(of: "\"", with: "\\\"")
        return "do shell script \"\(escaped)\""
    }

    nonisolated private static func doInstallLabelSupport() -> RunResult {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("mntfs-label-\(UUID().uuidString)")
        let tmp = staging.appendingPathComponent("mntfs.fs").path
        defer { try? fm.removeItem(at: staging) }
        do {
            try fm.createDirectory(at: staging, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            try fm.createDirectory(atPath: tmp + "/Contents/Resources",
                                   withIntermediateDirectories: true)
            try labelBundleInfoPlist.write(toFile: tmp + "/Contents/Info.plist",
                                           atomically: true, encoding: .utf8)
        } catch {
            return RunResult(status: -1, out: Data(
                "Could not prepare NTFS name support: \(error.localizedDescription)".utf8))
        }
        let script = labelSupportCopyScript(from: tmp, to: labelBundlePath)
                   + " && /usr/sbin/chown -R root:wheel '\(labelBundlePath)'"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", labelSupportAppleScript(script) + " with administrator privileges"]
        let output = Pipe()
        p.standardOutput = output
        p.standardError = output
        do { try p.run() } catch {
            return RunResult(status: -1, out: Data(
                "Could not start the installer: \(error.localizedDescription)".utf8))
        }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            return RunResult(status: p.terminationStatus, out: data)
        }
        guard labelSupportInstalled() else {
            return RunResult(status: -1, out: Data(
                "The installed NTFS name bundle is missing, unreadable, or invalid.".utf8))
        }
        return RunResult(status: 0, out: data)
    }

    private func apply(_ all: [VolumeItem]) {
        usingSampleData = false
        let items = all
        ntfs = items.filter { $0.isNTFS }
        others = items.filter { !$0.isNTFS }
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = ntfs.first?.id ?? others.first?.id
        }
        scanning = false
    }

    /// Result of a tool invocation. Keeps the exit status so callers can tell
    /// a real failure from merely-unexpected output (grepping stdout is fragile).
    struct RunResult {
        let status: Int32
        let out: Data
        var ok: Bool { status == 0 }
        var text: String {
            (String(data: out, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    nonisolated private static func run(_ args: [String]) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return RunResult(status: -1, out: Data()) }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return RunResult(status: p.terminationStatus, out: d)
    }

    nonisolated private static func readOnlyDiskutil(_ args: [String]) -> RunResult {
        let result = DiagnosticCommand.run("/usr/sbin/diskutil", args, timeout: 15, outputLimit: 1 << 20)
        return RunResult(status: result.status ?? -1, out: result.output)
    }

    nonisolated private static func plist(_ r: RunResult) -> [String: Any]? {
        guard r.ok, !r.out.isEmpty else { return nil }
        return (try? PropertyListSerialization.propertyList(from: r.out, options: [], format: nil))
            as? [String: Any]
    }

    /// Kernel mount properties are authoritative; diskutil may mislabel FSKit
    /// volumes. A /Volumes path alone doesn't prove a mount is browsable.
    nonisolated private static func mountDetails(_ path: String)
        -> (type: String, readOnly: Bool, noBrowse: Bool)? {
        var s = statfs()
        guard statfs(path, &s) == 0 else { return nil }
        let type = withUnsafeBytes(of: s.f_fstypename) {
            String(cString: $0.baseAddress!.assumingMemoryBound(to: CChar.self))
        }
        return (type, s.f_flags & UInt32(MNT_RDONLY) != 0,
                s.f_flags & UInt32(MNT_DONTBROWSE) != 0)
    }

    /// A real "mntfs" mount proves the extension is active even when the
    /// safety policy intentionally kept the drive read-only.
    nonisolated static func hasMntfsMount() -> Bool {
        for fs in mountTable() {
            let t = cStr16(fs.f_fstypename)
            if t == "mntfs" { return true }
        }
        return false
    }

    /// After boot (or if Apple's handler wins the race), an NTFS drive that was
    /// already connected mounts read-only as "ntfs". Our driver uses "mntfs",
    /// including for safety read-only mounts — unmount and remount Apple's volume
    /// once so DiskArbitration re-probes and our writable "mntfs" driver
    /// (probe order 500, ahead of Apple's 1000) claims it. This is what makes
    /// drives writable right after login without a manual replug.
    /// - Parameter force: bypass the per-device throttle (used when the user
    ///   returns from System Settings, where a prompt retry is expected).
    /// Only attempt a takeover after FSKit confirms this module is enabled.
    /// The enablement check schedules a retry when Settings changes take effect.
    func autoRemountReadOnlyNTFS(force: Bool = false) {
        guard extensionMonitor.state.isEnabled, !updatePreparationInProgress else { return }
        Task { [weak self] in
            guard let self else { return }
            let identities = await Task.detached(priority: .utility) {
                Self.readOnlyAppleNTFSDevices().compactMap { NativeDiskMountBackend.readIdentity(device: $0) }
            }.value
            for identity in identities {
                guard extensionMonitor.state.isEnabled, !updatePreparationInProgress else { break }
                let device = identity.device
                guard identity.writable, !remountInFlight.contains(device), !busyDevices.contains(device) else { continue }
                if !force, let last = remountAttempts[identity], Date().timeIntervalSince(last) < 8 { continue }
                remountAttempts[identity] = Date()
                remountInFlight.insert(device)
                // One non-force attempt. Never repeatedly unmount a user's drive
                // while waiting for a cold/disabled driver to become ready.
                do { try await diskMountService.remount(identity, requireWritable: true) }
                catch { NSLog("MNtfs: automatic remount failed: %@", error.localizedDescription) }
                remountInFlight.remove(device)
            }
            if !identities.isEmpty { refresh() }
        }
    }

    /// BSD device nodes of NTFS volumes currently mounted read-only by Apple's
    /// built-in handler (fstype "ntfs"). Our driver uses "mntfs", so these are
    /// exactly the ones we want to take over.
    nonisolated private static func readOnlyAppleNTFSDevices() -> [String] {
        var out: [String] = []
        for fs in mountTable() {
            let readOnly = (fs.f_flags & UInt32(MNT_RDONLY)) != 0
            guard cStr16(fs.f_fstypename) == "ntfs", readOnly else { continue }
            out.append(cStr16(fs.f_mntfromname))
        }
        return out
    }

    nonisolated private static func enumerate() throws -> [VolumeItem] {
        guard let list = plist(readOnlyDiskutil(["list", "-plist"])),
              let disks = list["AllDisksAndPartitions"] as? [[String: Any]] else {
            throw NSError(domain: "com.fastntfs.scan", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Could not read the drive list. The last known volumes are still shown; refresh to try again."])
        }
        var ids: [String] = []
        for disk in disks {
            // Partitionless NTFS media has no Partitions/APFSVolumes array.
            if disk["Partitions"] == nil, disk["APFSVolumes"] == nil,
               let id = disk["DeviceIdentifier"] as? String {
                ids.append(id)
            }
            if let parts = disk["Partitions"] as? [[String: Any]] {
                ids += parts.compactMap { $0["DeviceIdentifier"] as? String }
            }
            if let vols = disk["APFSVolumes"] as? [[String: Any]] {
                ids += vols.compactMap { $0["DeviceIdentifier"] as? String }
            }
        }
        var items: [VolumeItem] = []
        for id in ids {
            guard let info = plist(readOnlyDiskutil(["info", "-plist", id])) else { continue }
            let name = (info["VolumeName"] as? String) ?? ""
            let size = (info["Size"] as? NSNumber)?.int64Value
                ?? (info["TotalSize"] as? NSNumber)?.int64Value ?? 0
            if size <= 0 { continue }
            let fs = (info["FilesystemUserVisibleName"] as? String)
                ?? (info["FilesystemName"] as? String) ?? ""
            let content = (info["Content"] as? String) ?? ""
            let mount = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let ejectable = (info["Ejectable"] as? NSNumber)?.boolValue ?? false
            let dev = (info["DeviceNode"] as? String) ?? "/dev/\(id)"
            // Detect real NTFS from the KERNEL mount type (statfs f_fstypename),
            // NOT diskutil's FilesystemType/Name — both misreport our FSKit NTFS
            // volumes as "exfat" — and NOT the MBR partition byte (an exFAT drive
            // reformatted over a former NTFS one keeps partition type 0x07). Our
            // driver mounts as "mntfs", Apple's read-only handler as "ntfs".
            let details = mount.flatMap { Self.mountDetails($0) }
            let kfs = details?.type ?? ""
            let driverStatus = kfs == "mntfs" ? mount.flatMap { MountStatusReader.read(at: $0, device: dev) } : nil
            let kernelWritable = details.map { !$0.readOnly }
                ?? (info["WritableVolume"] as? NSNumber)?.boolValue ?? true
            let writable = kernelWritable && (kfs != "mntfs" || driverStatus?.readOnly == false)
            let isNTFS: Bool
            if kfs == "mntfs" || kfs == "ntfs" {
                isNTFS = true
            } else if !kfs.isEmpty {
                isNTFS = false                     // mounted as exfat/apfs/hfs/msdos…
            } else {                               // unmounted: best-effort guess
                isNTFS = fs.localizedCaseInsensitiveContains("ntfs") || content == "Windows_NTFS"
            }
            var used: Int64 = 0, free: Int64 = 0
            if let mp = mount,
               let a = try? FileManager.default.attributesOfFileSystem(forPath: mp) {
                let total = (a[.systemSize] as? NSNumber)?.int64Value ?? size
                free = (a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                used = max(0, total - free)
            }
            let nobrowse = details?.noBrowse ?? false
            let browsable = !nobrowse &&
                (mount == "/" || (mount?.hasPrefix("/Volumes/") ?? false))

            // Keep the list useful: every NTFS disk (mounted or not, so it can
            // be mounted), plus normal browsable volumes. Hide the APFS system
            // helpers (Preboot/Recovery/VM/Update/iSCPreboot/xART/Hardware),
            // EFI, and other nobrowse system volumes.
            guard isNTFS || browsable else { continue }

            items.append(VolumeItem(
                id: id, name: name, sizeBytes: size, device: dev, fileSystem: fs,
                content: content, mountPoint: mount, writable: writable,
                ejectable: ejectable, isNTFS: isNTFS, nobrowse: nobrowse,
                usedBytes: used, freeBytes: free,
                volumeUUID: info["VolumeUUID"] as? String,
                diskUUID: info["DiskUUID"] as? String,
                mountedFileSystem: kfs, driverStatus: driverStatus,
                attachmentIdentity: NativeDiskMountBackend.readIdentity(device: dev)))
        }
        return items
    }

    /// True when `v` is a real volume that diskutil may act on. Sample rows
    /// (and anything without a /dev/disk path) are display-only.
    private func actionable(_ v: VolumeItem) -> Bool {
        if scanError != nil {
            actionMessage = "Refresh the drive list before starting another operation."
            return false
        }
        if busyDevices.contains(v.device) || remountInFlight.contains(v.device) {
            actionMessage = DiskMountError.busy.localizedDescription
            return false
        }
        if updatePreparationInProgress {
            actionMessage = "MNtfs is preparing an update. Try again after it restarts."
            return false
        }
        if v.isSample || usingSampleData || !v.device.hasPrefix("/dev/disk") {
            actionMessage = "This is sample data — plug in a real drive first."
            return false
        }
        return true
    }

    func toggleMount(_ v: VolumeItem) {
        guard actionable(v) else { return }
        guard let identity = v.attachmentIdentity else {
            actionMessage = DiskMountError.targetChanged.localizedDescription
            return
        }
        diskOperations += 1
        busyDevices.insert(v.device)
        Task {
            do { try await diskMountService.setMounted(!v.mounted, identity: identity) }
            catch { actionMessage = error.localizedDescription }
            busyDevices.remove(v.device)
            diskOperations -= 1
            refresh()
        }
    }

    func verify(_ v: VolumeItem) {
        guard actionable(v) else { return }
        guard v.mountedFileSystem != "mntfs" else {
            actionMessage = "Unmount this NTFS drive before verifying it. Use Diagnostics to inspect a mounted drive."
            return
        }
        diskOperations += 1
        busyDevices.insert(v.device)
        verifying = true
        Task.detached(priority: .userInitiated) {
            let r = Self.run(["verifyVolume", v.device])
            await MainActor.run {
                self.diskOperations -= 1
                self.busyDevices.remove(v.device)
                self.verifying = false
                self.actionMessage = r.text.isEmpty ? "No output." : r.text
            }
        }
    }

    // MARK: Erase / reformat as NTFS

    func erase(_ v: VolumeItem, newName: String) {
        guard actionable(v) else { eraseTarget = nil; return }
        diskOperations += 1
        busyDevices.insert(v.device)
        erasing = true
        Task.detached(priority: .userInitiated) {
            let result = Self.performErase(device: v.device, name: newName,
                                           expectedSize: v.sizeBytes,
                                           expectedContent: v.content,
                                           expectedVolumeUUID: v.volumeUUID,
                                           expectedDiskUUID: v.diskUUID)
            await MainActor.run {
                self.diskOperations -= 1
                self.busyDevices.remove(v.device)
                self.erasing = false
                self.eraseTarget = nil
                self.actionMessage = result
                self.refresh()
            }
        }
    }

    nonisolated private static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    nonisolated private static func performErase(device: String, name: String,
                                                 expectedSize: Int64,
                                                 expectedContent: String,
                                                 expectedVolumeUUID: String?,
                                                 expectedDiskUUID: String?) -> String {
        guard device.hasPrefix("/dev/disk") else {
            return "Erase refused: no real device selected."
        }
        guard let mkntfs = Bundle.main.path(forResource: "mkntfs", ofType: nil) else {
            return "Erase failed: the mkntfs formatter is missing from the app bundle."
        }
        let identity = eraseIdentity(volumeUUID: expectedVolumeUUID,
                                     diskUUID: expectedDiskUUID)
        // Same-sized drives can have identical partition types. Require at
        // least one stable UUID and check it before unmounting anything.
        guard let before = plist(run(["info", "-plist", device])),
              matchesEraseIdentity(before, expected: identity) else {
            return "Erase aborted: the selected drive's identity cannot be confirmed. Refresh the drive list and try again."
        }
        // The user has confirmed destruction, so force the volume unmounted to
        // be sure mkntfs can take the raw partition.
        let um = run(["unmount", "force", device])

        // Revalidate the target before touching it: it must still exist, be
        // the same partition the user selected (same partition type and size —
        // device numbers get reshuffled when drives are re/unplugged), and be
        // unmounted now. Formatting a moved or still-mounted volume would
        // destroy the wrong data.
        let info = run(["info", "-plist", device])
        guard info.ok,
              let plist = try? PropertyListSerialization.propertyList(
                  from: info.out, format: nil),
              let d = plist as? [String: Any] else {
            return "Erase aborted: \(device) is no longer readable (unplugged?)."
        }
        if let mp = d["MountPoint"] as? String, !mp.isEmpty {
            return "Erase aborted: \(device) could not be unmounted"
                + (um.text.isEmpty ? "." : ":\n\(um.text)")
        }
        let contentNow = d["Content"] as? String ?? ""
        guard matchesEraseIdentity(d, expected: identity) else {
            return "Erase aborted: \(device) is not the drive that was selected (UUID changed)."
        }
        guard expectedContent.isEmpty || contentNow == expectedContent else {
            return "Erase aborted: \(device) is not the partition that was selected (type changed)."
        }
        let sizeNow = (d["TotalSize"] as? NSNumber)?.int64Value
            ?? (d["Size"] as? NSNumber)?.int64Value ?? -1
        guard sizeNow == expectedSize else {
            return "Erase aborted: \(device) is not the partition that was selected (size changed)."
        }
        guard (d["Ejectable"] as? Bool) ?? false else {
            return "Erase aborted: \(device) is not a removable drive."
        }

        // Sanitize the label; mkntfs -Q quick-formats, -F forces past warnings.
        let label = String(name.prefix(32)).filter { $0 != "\"" && $0 != "'" && $0 != "\\" }

        // The admin-password dialog below can sit open for minutes, during
        // which drives can be un/replugged and device numbers reshuffled. So
        // the identity check must ALSO run inside the privileged shell,
        // immediately before mkntfs writes — the pre-check above only gives
        // early, friendly errors.
        let q = shQuote(device)
        var recheck = "test \"$(diskutil info -plist \(q) | plutil -extract TotalSize raw -)\" = \(shQuote(String(expectedSize)))"
        recheck += " && test -z \"$(diskutil info -plist \(q) | plutil -extract MountPoint raw - 2>/dev/null)\""
        if !expectedContent.isEmpty {
            recheck += " && test \"$(diskutil info -plist \(q) | plutil -extract Content raw -)\" = \(shQuote(expectedContent))"
        }
        for key in identity.keys.sorted() {
            recheck += " && test \"$(diskutil info -plist \(q) | plutil -extract \(key) raw -)\" = \(shQuote(identity[key]!))"
        }
        let shell = "{ \(recheck) ; } || { echo MNTFS_TARGET_CHANGED; exit 90; }; "
            + "\(shQuote(mkntfs)) -Q -F -L \(shQuote(label)) \(q)"
        let esc = shell.replacingOccurrences(of: "\\", with: "\\\\")
                       .replacingOccurrences(of: "\"", with: "\\\"")
        let appleScript = "do shell script \"\(esc)\" with administrator privileges"

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", appleScript]
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return "Erase failed: \(error.localizedDescription)" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let outText = (String(data: data, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Remount so the freshly-formatted volume reappears.
        _ = run(["mount", device])

        if p.terminationStatus == 0 {
            return "Reformatted \(device) as NTFS “\(label)”."
        }
        if outText.contains("MNTFS_TARGET_CHANGED") {
            return "Erase aborted: \(device) changed while waiting for authorization — nothing was formatted. Plug the drive back in and try again."
        }
        if outText.contains("-128") || outText.localizedCaseInsensitiveContains("cancel") {
            return "Erase cancelled."
        }
        // macOS gates raw access to external drives behind Full Disk Access
        // (TCC, attributed to this app) — even for root. Guide the user there.
        if outText.localizedCaseInsensitiveContains("not permitted") {
            return Self.fdaMessage
        }
        return "Erase failed:\n\(outText)"
    }

    nonisolated static func eraseIdentity(volumeUUID: String?,
                                         diskUUID: String?) -> [String: String] {
        var identity: [String: String] = [:]
        if let volumeUUID, !volumeUUID.isEmpty { identity["VolumeUUID"] = volumeUUID }
        if let diskUUID, !diskUUID.isEmpty { identity["DiskUUID"] = diskUUID }
        return identity
    }

    nonisolated static func matchesEraseIdentity(_ info: [String: Any],
                                                 expected: [String: String]) -> Bool {
        !expected.isEmpty && expected.allSatisfy { key, value in
            (info[key] as? String)?.caseInsensitiveCompare(value) == .orderedSame
        }
    }

    /// Marker + user guidance shown when Erase is blocked by missing
    /// Full Disk Access. The alert adds an "Open Settings" button for it.
    nonisolated static let fdaMessage = "MNtfs needs Full Disk Access to reformat external drives.\n\nOpen System Settings → Privacy & Security → Full Disk Access, add MNtfs and turn it ON, then quit and reopen MNtfs and try again."

    func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    static func preview() -> VolumeStore {
        let store = VolumeStore(startMonitoring: false)
        store.apply(Self.sample())
        store.usingSampleData = true
        return store
    }

    /// Placeholder rows for the empty state. No real device paths: every row
    /// is flagged `isSample` and carries an empty `device`, so nothing here
    /// can ever be passed to diskutil or mkntfs.
    nonisolated private static func sample() -> [VolumeItem] {
        func mk(_ id: String, _ n: String, _ gb: Double, ntfs: Bool, mounted: Bool,
                fs: String, ro: Bool = false,
                eject: Bool = false, nobrowse: Bool = false, usedFrac: Double = 0.5) -> VolumeItem {
            let size = Int64(gb * 1_000_000_000)
            let used = Int64(Double(size) * usedFrac)
            return VolumeItem(id: id, name: n, sizeBytes: size, device: "", fileSystem: fs,
                              content: "", mountPoint: mounted ? "/Volumes/\(n)" : nil,
                              writable: !ro, ejectable: eject, isNTFS: ntfs, nobrowse: nobrowse,
                              usedBytes: used, freeBytes: size - used, isSample: true)
        }
        return [
            mk("sample1", "SAMSUNG T7", 1000, ntfs: true, mounted: true,
               fs: "Windows NTFS", eject: true, usedFrac: 0.58),
            mk("sample2", "WD Elements", 15.16, ntfs: true, mounted: true,
               fs: "Windows NTFS", ro: true, eject: true, usedFrac: 0.41),
            mk("sample3", "Project Files", 499.93, ntfs: true, mounted: false,
               fs: "Windows NTFS", eject: true, usedFrac: 0.62),
            mk("sample4", "", 0.5337, ntfs: false, mounted: false, fs: "EFI"),
            mk("sample5", "Macintosh HD — Data", 994, ntfs: false, mounted: true,
               fs: "APFS", nobrowse: true, usedFrac: 0.46),
            mk("sample6", "Macintosh HD", 994, ntfs: false, mounted: true,
               fs: "APFS", ro: true, usedFrac: 0.12),
        ]
    }
}

// MARK: - Sidebar

private struct MicroBar: View {
    var fraction: Double
    var ntfs: Bool
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(ntfs ? AnyShapeStyle(UI.ntfsGrad) : AnyShapeStyle(Color(0x59708a)))
                    .frame(width: max(3, g.size.width * fraction))
            }
        }
        .frame(height: 3)
    }
}

private struct Badge: View {
    let text: String; var kind: Kind = .neutral
    enum Kind { case neutral, amber, rose }
    var body: some View {
        let (fg, bg): (Color, Color) = {
            switch kind {
            case .neutral: return (Color(0xc4d3e0), Color.white.opacity(0.10))
            case .amber:   return (Color(0x3a2a06), UI.amber)
            case .rose:    return (Color(0xfff0f0), UI.rose.opacity(0.85))
            }
        }()
        return Text(text).font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(bg))
    }
}

private struct VolumeRow: View {
    let v: VolumeItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(v.isNTFS ? AnyShapeStyle(UI.ntfsGrad)
                                   : AnyShapeStyle(Color.white.opacity(0.08)))
                    .frame(width: 30, height: 30)
                Image(systemName: v.ejectable ? "externaldrive.fill" : "internaldrive.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(v.isNTFS ? .white : Color(0x9fb2c4))
                if v.mounted {
                    Circle().fill(UI.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(UI.sidebar, lineWidth: 2))
                        .offset(x: 12, y: 11)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(v.displayName).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UI.text).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: v.readOnly ? "lock.fill" : "square.and.pencil")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(v.readOnly ? Color(0xff8f8f) : Color(0x62e6a4))
                        .help(v.readOnly ? "Read-only" : "Read & Write")
                    if v.nobrowse { Badge(text: "hidden", kind: .amber) }
                }
                HStack(spacing: 6) {
                    MicroBar(fraction: v.usedFraction, ntfs: v.isNTFS)
                    Text(v.sizeText).font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UI.faint).monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(selected ? Color.white.opacity(0.06) : .clear)
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(UI.ntfsGrad).frame(width: 3, height: 20)
                        .padding(.leading, 2)
                }
            })
        .contentShape(Rectangle())
    }
}

private struct ExtensionStatusView: View {
    @ObservedObject var monitor: ExtensionStatusMonitor
    var openSettings: () -> Void

    var body: some View {
        if monitor.state == .enabled || monitor.state == .checking {
            HStack(spacing: 8) {
                Circle().fill(monitor.state.isEnabled ? UI.green : UI.faint).frame(width: 7, height: 7)
                Text(monitor.state.title).font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.dim)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 46)
            .help(monitor.state.detail)
        } else {
            Button(action: openSettings) {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(UI.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(monitor.state.title)
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.text)
                        Text("Click to check System Settings")
                            .font(.system(size: 10)).foregroundStyle(UI.faint)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold))
                        .foregroundStyle(UI.faint)
                }
                .padding(.horizontal, 14).frame(height: 46)
                .background(UI.amber.opacity(0.13))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(monitor.state.detail)
        }
    }
}

private struct Sidebar: View {
    @ObservedObject var store: VolumeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // brand
            HStack(spacing: 10) {
                DiskEmblem(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("MNtfs").font(.system(size: 17, weight: .bold)).foregroundStyle(UI.text)
                    Text("NTFS for Mac").font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(UI.faint)
                }
                Spacer()
                Button { store.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(UI.dim)
                        .rotationEffect(.degrees(store.scanning ? 360 : 0))
                        .animation(store.scanning
                            ? .linear(duration: 0.8).repeatForever(autoreverses: false)
                            : .default, value: store.scanning)
                }
                .buttonStyle(.plain)
                .help("Rescan volumes")
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 14)

            Rectangle().fill(UI.line).frame(height: 1)

            if store.usingSampleData {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle.fill").font(.system(size: 10))
                    Text("Sample data — no volumes detected")
                        .font(.system(size: 10.5, weight: .medium))
                }
                .foregroundStyle(UI.amber)
                .padding(.horizontal, 16).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(UI.amber.opacity(0.10))
            }

            if let error = store.scanError {
                Label("Could not refresh drives — try Refresh", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5)).foregroundStyle(UI.amber)
                    .padding(.horizontal, 16).padding(.vertical, 8)
                    .help(error)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("NTFS Drives", store.ntfs)
                    section("Other Volumes", store.others)
                }.padding(.top, 4).padding(.bottom, 12)
            }

            Rectangle().fill(UI.line).frame(height: 1)
            extensionStatus
        }
        .background(UI.sidebar)
    }

    @ViewBuilder private var extensionStatus: some View {
        ExtensionStatusView(monitor: store.extensionMonitor, openSettings: store.openExtensionSettings)
            .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { _ in
                store.checkExtension()
                store.refreshLiveStatus()
            }
    }

    @ViewBuilder private func section(_ title: String, _ items: [VolumeItem]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold)).tracking(0.7)
                .foregroundStyle(UI.faint)
                .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 7)
            VStack(spacing: 3) {
                ForEach(items) { v in
                    VolumeRow(v: v, selected: v.id == store.selectedID)
                        .onTapGesture { store.selectedID = v.id }
                }
            }.padding(.horizontal, 8)
        }
    }
}

// MARK: - Detail

private struct PillButton: View {
    let icon: String; let label: String
    var prominent = false
    var disabled = false
    var busy = false
    var tint: Color = UI.text
    var action: () -> Void = {}
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if busy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                        .frame(width: 12, height: 12).tint(tint)
                } else {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold))
                }
                Text(label).font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(prominent ? Color(0x06222f) : tint)
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(
                Capsule().fill(prominent ? AnyShapeStyle(UI.ntfsGrad)
                                         : AnyShapeStyle(Color.white.opacity(hover ? 0.10 : 0.05)))
            )
            .overlay(Capsule().stroke(Color.white.opacity(prominent ? 0 : 0.09), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .disabled(disabled || busy)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 && !disabled && !busy }
    }
}

enum AccessKind { case none, ro, rw }

private struct InfoRow: View {
    let k: String; let v: String; var link = false; var good = false
    var access: AccessKind = .none
    var body: some View {
        HStack(spacing: 10) {
            Text(k).font(.system(size: 12.5)).foregroundStyle(UI.dim)
                .frame(width: 118, alignment: .leading)
            if good {
                HStack(spacing: 6) {
                    Circle().fill(UI.green).frame(width: 7, height: 7)
                    Text(v)
                }.font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.text)
            } else if access != .none {
                HStack(spacing: 6) {
                    Image(systemName: access == .ro ? "lock.fill" : "square.and.pencil")
                        .font(.system(size: 11, weight: .semibold))
                    Text(v)
                }
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(access == .ro ? Color(0xff8f8f) : Color(0x37d07f))
            } else {
                Text(v).font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(link ? UI.accent : UI.text)
            }
            Spacer()
        }
        .padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }
    }
}

/// Prominent read/write pill near the volume title. No cryptic "RO" text.
private struct AccessBadge: View {
    let readOnly: Bool
    var verified = true
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: readOnly ? "lock.fill" : "square.and.pencil")
                .font(.system(size: 10, weight: .bold))
            Text(verified ? (readOnly ? "Read-Only" : "Read & Write") : "Unverified")
                .font(.system(size: 11, weight: .bold))
        }
        .foregroundStyle(readOnly ? Color(0xffb0b0) : Color(0x62e6a4))
        .padding(.horizontal, 9).padding(.vertical, 4)
        .background(Capsule().fill((readOnly ? Color(0xff6f6f) : Color(0x37d07f)).opacity(0.16)))
        .overlay(Capsule().stroke((readOnly ? Color(0xff6f6f) : Color(0x37d07f)).opacity(0.35),
                                  lineWidth: 1))
    }
}

private struct DetailPane: View {
    @ObservedObject var store: VolumeStore
    @State private var showDonate = false

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if let v = store.selected {
                    content(v)
                } else {
                    VStack {
                        Spacer()
                        Text(store.scanning ? "Scanning volumes…" :
                            store.scanError != nil ? "Could not refresh volumes. Try Refresh." :
                            "No volumes found. Connect a drive to get started.")
                            .foregroundStyle(UI.dim)
                        Spacer()
                    }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            footer
        }
        .background(LinearGradient(colors: [UI.detailA, UI.detailB],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Rectangle().fill(UI.line).frame(height: 1)
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    Text("Made with ❤️ for ").foregroundStyle(UI.faint)
                    Link("Maclife & Đồng Bọn",
                         destination: URL(string: "https://www.facebook.com/groups/maclife.vn")!)
                        .foregroundStyle(UI.accent)
                        .pointerStyle(.link)
                }
                .font(.system(size: 11.5))
                Spacer()
                Button(store.diagnosing ? "Collecting…" : "Diagnostics…") { store.diagnose() }
                    .font(.system(size: 11.5))
                    .disabled(store.diagnosing)
                    .padding(.trailing, 16)
                Button { showDonate.toggle() } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "cup.and.saucer.fill").font(.system(size: 11))
                        Text("Ủng hộ").font(.system(size: 12, weight: .medium))
                    }
                    .foregroundStyle(Color(0x06222f))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Capsule().fill(UI.ntfsGrad))
                }
                .buttonStyle(.plain)
                .pointerStyle(.link)
                .popover(isPresented: $showDonate, arrowEdge: .bottom) { DonateCard() }
            }
            .padding(.horizontal, 34)
            .frame(height: 46)
        }
    }

    @ViewBuilder private func content(_ v: VolumeItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // header: title + actions
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(v.displayName).font(.system(size: 26, weight: .bold))
                        .foregroundStyle(UI.text)
                    HStack(spacing: 9) {
                        Text(v.formatDisplay)
                            .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.dim)
                        AccessBadge(readOnly: v.readOnly, verified: v.accessVerified)
                    }
                }
                Spacer()
                HStack(spacing: 9) {
                    // Sample rows are display-only: no diskutil action may run.
                    let sampleOnly = v.isSample || store.usingSampleData || store.busyDevices.contains(v.device)
                    // The boot volume at "/" can't be unmounted; hide the control.
                    if v.mountPoint != "/" {
                        PillButton(icon: v.mounted ? "eject.fill" : "arrow.down.circle.fill",
                                   label: v.mounted ? "Unmount" : "Mount", prominent: true,
                                   disabled: sampleOnly) {
                            store.toggleMount(v)
                        }
                    }
                    PillButton(icon: "checkmark.shield",
                               label: store.verifying ? "Verifying…" : "Verify",
                               disabled: sampleOnly,
                               busy: store.verifying) {
                        store.verify(v)
                    }
                    // Erase is destructive, so only offer it for a REMOVABLE
                    // (ejectable) NTFS volume — never the boot disk and never an
                    // internal partition (e.g. a Boot Camp / Windows system disk).
                    if v.isNTFS && v.ejectable && v.mountPoint != "/" {
                        PillButton(icon: "trash", label: "Erase",
                                   disabled: sampleOnly) {
                            store.eraseTarget = v
                        }
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 26).padding(.bottom, 22)
            .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }

            // hero: capacity ring + info
            if v.isNTFS && v.mounted && v.readOnly {
                Label(v.driverStatus?.readOnlyExplanation ?? "This drive is read-only. The reason has not been verified. Check write protection and the requested mount mode. If Windows used hibernation or Fast Startup, resume Windows and shut down fully; use chkdsk /f on Windows if repair is needed.",
                      systemImage: "lock.shield")
                    .font(.system(size: 12))
                    .foregroundStyle(UI.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 34).padding(.top, 16)
            }
            HStack(alignment: .top, spacing: 44) {
                VStack(spacing: 14) {
                    CapacityRing(fraction: v.usedFraction, size: 168, volume: v)
                    VStack(spacing: 3) {
                        Text("\(Int((v.usedFraction * 100).rounded()))%")
                            .font(.system(size: 20, weight: .bold)).foregroundStyle(UI.text)
                        Text("used").font(.system(size: 11.5)).foregroundStyle(UI.faint)
                    }
                }
                .frame(width: 200)

                VStack(alignment: .leading, spacing: 0) {
                    InfoRow(k: "Status", v: v.mounted ? "Mounted" : "Not mounted", good: v.mounted)
                    InfoRow(k: "Device", v: v.device.isEmpty ? "—" : v.device)
                    InfoRow(k: "Format", v: v.formatDisplay)
                    InfoRow(k: "Access", v: v.accessText,
                            access: v.readOnly ? .ro : .rw)
                    InfoRow(k: "Location", v: v.mountPoint ?? "—", link: v.mounted)
                    capacityLegend(v).padding(.top, 16)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.horizontal, 34).padding(.top, 30)

            Spacer(minLength: 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func capacityLegend(_ v: VolumeItem) -> some View {
        HStack(spacing: 22) {
            legend(UI.accent, "Used", ByteCount.string(v.usedBytes))
            legend(Color.white.opacity(0.14), "Free", ByteCount.string(v.freeBytes))
            legend(.clear, "Total", ByteCount.string(v.sizeBytes))
        }
    }

    private func legend(_ c: Color, _ k: String, _ val: String) -> some View {
        HStack(spacing: 7) {
            if c != .clear {
                RoundedRectangle(cornerRadius: 3).fill(c).frame(width: 10, height: 10)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(k).font(.system(size: 10.5)).foregroundStyle(UI.faint)
                Text(val).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
                    .monospacedDigit()
            }
        }
    }

}

// MARK: - Donate

private struct DonateCard: View {
    var body: some View {
        VStack(spacing: 14) {
            Text("Mời mình ly cà phê ☕").font(.system(size: 15, weight: .bold))
            Image("DonateQR").resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                .frame(width: 190, height: 190)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
            VStack(spacing: 6) {
                Text("Nếu MNtfs hữu ích với bạn, một ly cà phê nhỏ giúp mình duy trì và phát triển dự án. Cảm ơn bạn! 🙏")
                    .font(.callout).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Text("Quét bằng MoMo hoặc app ngân hàng (VietQR · Napas 247)")
                    .font(.caption).multilineTextAlignment(.center).foregroundStyle(.tertiary)
            }
        }
        .padding(22).frame(width: 300)
    }
}

// MARK: - Root

struct ContentView: View {
    @ObservedObject var store: VolumeStore
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(store: store).frame(width: 288)
            DetailPane(store: store)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(UI.appBG)
        .preferredColorScheme(.dark)
        .alert("MNtfs", isPresented: Binding(
            get: { store.actionMessage != nil },
            set: { if !$0 { store.actionMessage = nil } })) {
            if store.actionMessage == VolumeStore.fdaMessage {
                Button("Open Settings") {
                    store.openFullDiskAccessSettings()
                    store.actionMessage = nil
                }
            }
            Button("OK", role: .cancel) { store.actionMessage = nil }
        } message: {
            Text(store.actionMessage ?? "")
        }
        .alert("Show NTFS drives correctly?", isPresented: Binding(
            get: { store.offerLabelSupport },
            set: { if !$0 { store.offerLabelSupport = false } })) {
            Button("Install") { store.installLabelSupport() }
            Button("Not Now", role: .cancel) { store.declineLabelSupport() }
        } message: {
            Text("Finder and Disk Utility mislabel NTFS drives as “ExFAT”. "
               + "MNtfs can install a small system component so they show "
               + "“Windows NT File System (NTFS)” correctly. This needs your "
               + "administrator password once. Reading and writing work either way.")
        }
        .sheet(item: Binding(get: { store.eraseTarget },
                             set: { store.eraseTarget = $0 })) { target in
            EraseSheet(volume: target, erasing: store.erasing,
                       onErase: { store.erase(target, newName: $0) },
                       onCancel: { store.eraseTarget = nil })
        }
        .sheet(item: $store.diagnosticReport) { report in
            DiagnosticsSheet(report: report)
        }
    }
}

private struct DiagnosticsDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    let data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

private struct DiagnosticsSheet: View {
    let report: DiagnosticReport
    @Environment(\.dismiss) private var dismiss
    @State private var exporting = false
    @State private var exportError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("MNtfs Diagnostics").font(.title2.bold())
            Text("Collected locally. Drive names, paths and device identifiers are omitted.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                Text(report.text).font(.system(.body, design: .monospaced))
                    .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Button("Copy Report") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(String(decoding: report.json, as: UTF8.self), forType: .string)
                }
                Button("Save JSON…") { exporting = true }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 700, height: 500)
        .fileExporter(isPresented: $exporting, document: DiagnosticsDocument(data: report.json),
                      contentType: .json, defaultFilename: "MNtfs-diagnostics") { result in
            if case let .failure(error) = result { exportError = error.localizedDescription }
        }
        .alert("Could not save diagnostics", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) { exportError = nil }
        } message: { Text(exportError ?? "") }
    }
}

/// Destructive reformat dialog. Shows exactly which disk is targeted and
/// requires the user to retype the current volume name to confirm.
private struct EraseSheet: View {
    let volume: VolumeItem
    let erasing: Bool
    let onErase: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""
    @State private var confirm: String = ""

    private var confirmed: Bool {
        confirm.trimmingCharacters(in: .whitespaces) == volume.displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(Color(0xf5a623))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Erase “\(volume.displayName)”?")
                        .font(.system(size: 16, weight: .bold))
                    Text("This permanently deletes everything on this drive and "
                         + "reformats it as NTFS. This cannot be undone.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            // Spell out exactly which disk, so nobody erases the wrong one.
            VStack(alignment: .leading, spacing: 3) {
                eraseInfoRow("Volume", volume.displayName)
                eraseInfoRow("Device", volume.device)
                eraseInfoRow("Size", volume.sizeText)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.05)))

            VStack(alignment: .leading, spacing: 6) {
                Text("TYPE “\(volume.displayName)” TO CONFIRM")
                    .font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                TextField(volume.displayName, text: $confirm)
                    .textFieldStyle(.roundedBorder).disabled(erasing)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NEW VOLUME NAME").font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                TextField("Untitled", text: $name)
                    .textFieldStyle(.roundedBorder).disabled(erasing)
                Text("Format: Windows NTFS").font(.system(size: 11)).foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                if erasing {
                    ProgressView().controlSize(.small)
                    Text("Erasing… (you may be asked for your password)")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel", action: onCancel).disabled(erasing)
                Button(role: .destructive) { onErase(name) } label: {
                    Text("Erase").frame(minWidth: 60)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(erasing || !confirmed
                          || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { name = volume.displayName }
    }

    private func eraseInfoRow(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 56, alignment: .leading)
            Text(v).font(.system(size: 11.5, weight: .medium))
            Spacer()
        }
    }
}

#Preview { ContentView(store: VolumeStore.preview()) }
