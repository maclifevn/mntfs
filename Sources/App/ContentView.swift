//
//  ContentView.swift
//  Mntfs — NTFS volume manager. Its own visual identity: a Maclife-blue
//  midnight theme, a capacity ring as the hero, pill actions and switch
//  toggles. Same job as any NTFS manager, deliberately not a clone of one.
//

import SwiftUI
import AppKit

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

struct VolumeItem: Identifiable, Hashable {
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

    var mounted: Bool { mountPoint != nil }
    var displayName: String { name.isEmpty ? "Untitled" : name }
    var sizeText: String { ByteCount.string(sizeBytes) }
    var usedFraction: Double { sizeBytes > 0 ? Double(usedBytes) / Double(sizeBytes) : 0 }
    var readOnly: Bool { !writable }

    /// diskutil misreports third-party FSKit NTFS volumes as "ExFAT"; trust the
    /// partition content instead so NTFS drives read as NTFS.
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
    @Published var actionMessage: String?
    @Published var extensionActive = true
    @Published var verifying = false
    @Published var erasing = false
    @Published var eraseTarget: VolumeItem?

    var selected: VolumeItem? { (ntfs + others).first { $0.id == selectedID } }

    init() {
        refresh()
        checkExtension()
        let nc = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [.init("NSWorkspaceDidMountNotification"),
                                          .init("NSWorkspaceDidUnmountNotification"),
                                          .init("NSWorkspaceDidRenameVolumeNotification")] {
            nc.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func refresh() {
        scanning = true
        checkExtension()
        Task.detached(priority: .userInitiated) {
            let all = Self.enumerate()
            await MainActor.run { self.apply(all) }
        }
    }

    /// Ask pluginkit whether our FSKit module is enabled ("+" prefix = enabled).
    func checkExtension() {
        Task.detached(priority: .utility) {
            let active = Self.extensionEnabled()
            await MainActor.run { self.extensionActive = active }
        }
    }

    nonisolated private static func extensionEnabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pluginkit")
        p.arguments = ["-m", "-i", "com.fastntfs.FastNTFS.FSModule"]
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return false }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard let s = String(data: d, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return false }
        return s.hasPrefix("+")
    }

    func openExtensionSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule")!
        NSWorkspace.shared.open(url)
    }

    private func apply(_ all: [VolumeItem]) {
        usingSampleData = all.isEmpty
        let items = all.isEmpty ? Self.sample() : all
        ntfs = items.filter { $0.isNTFS }
        others = items.filter { !$0.isNTFS }
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = ntfs.first?.id ?? others.first?.id
        }
        scanning = false
    }

    @discardableResult
    nonisolated private static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = out
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d.isEmpty ? nil : d
    }

    nonisolated private static func plist(_ d: Data?) -> [String: Any]? {
        guard let d else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil))
            as? [String: Any]
    }

    nonisolated private static func enumerate() -> [VolumeItem] {
        guard let list = plist(run(["list", "-plist"])),
              let disks = list["AllDisksAndPartitions"] as? [[String: Any]] else { return [] }
        var ids: [String] = []
        for disk in disks {
            if let parts = disk["Partitions"] as? [[String: Any]] {
                ids += parts.compactMap { $0["DeviceIdentifier"] as? String }
            }
            if let vols = disk["APFSVolumes"] as? [[String: Any]] {
                ids += vols.compactMap { $0["DeviceIdentifier"] as? String }
            }
        }
        var items: [VolumeItem] = []
        for id in ids {
            guard let info = plist(run(["info", "-plist", id])) else { continue }
            let name = (info["VolumeName"] as? String) ?? ""
            let size = (info["Size"] as? NSNumber)?.int64Value
                ?? (info["TotalSize"] as? NSNumber)?.int64Value ?? 0
            if size <= 0 { continue }
            let fs = (info["FilesystemUserVisibleName"] as? String)
                ?? (info["FilesystemName"] as? String) ?? ""
            let content = (info["Content"] as? String) ?? ""
            let mount = (info["MountPoint"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let writable = (info["WritableVolume"] as? NSNumber)?.boolValue ?? true
            let ejectable = (info["Ejectable"] as? NSNumber)?.boolValue ?? false
            let dev = (info["DeviceNode"] as? String) ?? "/dev/\(id)"
            let isNTFS = fs.localizedCaseInsensitiveContains("ntfs") || content == "Windows_NTFS"
            var used: Int64 = 0, free: Int64 = 0
            if let mp = mount,
               let a = try? FileManager.default.attributesOfFileSystem(forPath: mp) {
                let total = (a[.systemSize] as? NSNumber)?.int64Value ?? size
                free = (a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                used = max(0, total - free)
            }
            let browsable = mount == "/" || (mount?.hasPrefix("/Volumes") ?? false)
            let nobrowse = mount.map { !$0.hasPrefix("/Volumes") && $0 != "/" } ?? false

            // Keep the list useful: every NTFS disk (mounted or not, so it can
            // be mounted), plus normal browsable volumes. Hide the APFS system
            // helpers (Preboot/Recovery/VM/Update/iSCPreboot/xART/Hardware),
            // EFI, and other nobrowse system volumes.
            guard isNTFS || browsable else { continue }

            items.append(VolumeItem(
                id: id, name: name, sizeBytes: size, device: dev, fileSystem: fs,
                content: content, mountPoint: mount, writable: writable,
                ejectable: ejectable, isNTFS: isNTFS, nobrowse: nobrowse,
                usedBytes: used, freeBytes: free))
        }
        return items
    }

    func toggleMount(_ v: VolumeItem) {
        let mounting = !v.mounted
        Task.detached(priority: .userInitiated) {
            let out = Self.run([mounting ? "mount" : "unmount", v.device])
            let text = out.flatMap { String(data: $0, encoding: .utf8) }?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            await MainActor.run {
                if !text.isEmpty, text.localizedCaseInsensitiveContains("failed")
                    || text.localizedCaseInsensitiveContains("could not") {
                    self.actionMessage = text
                }
                self.refresh()
            }
        }
    }

    func verify(_ v: VolumeItem) {
        verifying = true
        Task.detached(priority: .userInitiated) {
            let out = Self.run(["verifyVolume", v.device])
            let text = out.flatMap { String(data: $0, encoding: .utf8) } ?? "No output."
            await MainActor.run {
                self.verifying = false
                self.actionMessage = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    // MARK: Erase / reformat as NTFS

    func erase(_ v: VolumeItem, newName: String) {
        erasing = true
        Task.detached(priority: .userInitiated) {
            let result = Self.performErase(device: v.device, name: newName)
            await MainActor.run {
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

    nonisolated private static func performErase(device: String, name: String) -> String {
        guard let mkntfs = Bundle.main.path(forResource: "mkntfs", ofType: nil) else {
            return "Erase failed: the mkntfs formatter is missing from the app bundle."
        }
        // Best-effort unmount so mkntfs can take the raw partition.
        _ = run(["unmount", device])

        // Sanitize the label; mkntfs -Q quick-formats, -F forces past warnings.
        let label = String(name.prefix(32)).filter { $0 != "\"" && $0 != "'" && $0 != "\\" }
        let shell = "\(shQuote(mkntfs)) -Q -F -L \(shQuote(label)) \(shQuote(device))"
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
        if outText.contains("-128") || outText.localizedCaseInsensitiveContains("cancel") {
            return "Erase cancelled."
        }
        return "Erase failed:\n\(outText)"
    }

    nonisolated private static func sample() -> [VolumeItem] {
        func mk(_ id: String, _ n: String, _ gb: Double, ntfs: Bool, mounted: Bool,
                dev: String, fs: String, content: String = "", ro: Bool = false,
                eject: Bool = false, nobrowse: Bool = false, usedFrac: Double = 0.5) -> VolumeItem {
            let size = Int64(gb * 1_000_000_000)
            let used = Int64(Double(size) * usedFrac)
            return VolumeItem(id: id, name: n, sizeBytes: size, device: dev, fileSystem: fs,
                              content: content, mountPoint: mounted ? "/Volumes/\(n)" : nil,
                              writable: !ro, ejectable: eject, isNTFS: ntfs, nobrowse: nobrowse,
                              usedBytes: used, freeBytes: size - used)
        }
        return [
            mk("disk4s1", "SAMSUNG T7", 1000, ntfs: true, mounted: true, dev: "/dev/disk4s1",
               fs: "Windows NTFS", content: "Windows_NTFS", eject: true, usedFrac: 0.58),
            mk("disk5s1", "WD Elements", 15.16, ntfs: true, mounted: true, dev: "/dev/disk5s1",
               fs: "Windows NTFS", ro: true, eject: true, usedFrac: 0.41),
            mk("disk6s1", "Project Files", 499.93, ntfs: true, mounted: false, dev: "/dev/disk6s1",
               fs: "Windows NTFS", eject: true, usedFrac: 0.62),
            mk("disk3s1", "", 0.5337, ntfs: false, mounted: false, dev: "/dev/disk3s1", fs: "EFI"),
            mk("disk3s5", "Macintosh HD — Data", 994, ntfs: false, mounted: true,
               dev: "/dev/disk3s5", fs: "APFS", nobrowse: true, usedFrac: 0.46),
            mk("disk3s3", "Macintosh HD", 994, ntfs: false, mounted: true, dev: "/dev/disk3s3",
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

private struct Sidebar: View {
    @ObservedObject var store: VolumeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // brand
            HStack(spacing: 10) {
                DiskEmblem(size: 34)
                VStack(alignment: .leading, spacing: 0) {
                    Text("Mntfs").font(.system(size: 17, weight: .bold)).foregroundStyle(UI.text)
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
        if store.extensionActive {
            HStack(spacing: 8) {
                Circle().fill(UI.green).frame(width: 7, height: 7)
                Text("Extension active").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.dim)
                Spacer()
            }
            .padding(.horizontal, 16).frame(height: 46)
        } else {
            Button { store.openExtensionSettings() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(UI.amber)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Extension not enabled")
                            .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(UI.text)
                        Text("NTFS disks won't mount — click to enable")
                            .font(.system(size: 10)).foregroundStyle(UI.faint)
                            .lineLimit(1).minimumScaleFactor(0.85)
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
            .help("Open File System Extensions settings")
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
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: readOnly ? "lock.fill" : "square.and.pencil")
                .font(.system(size: 10, weight: .bold))
            Text(readOnly ? "Read-Only" : "Read & Write")
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
                    VStack { Spacer(); Text("Select a volume").foregroundStyle(UI.dim); Spacer() }
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
                        AccessBadge(readOnly: v.readOnly)
                    }
                }
                Spacer()
                HStack(spacing: 9) {
                    // The boot volume at "/" can't be unmounted; hide the control.
                    if v.mountPoint != "/" {
                        PillButton(icon: v.mounted ? "eject.fill" : "arrow.down.circle.fill",
                                   label: v.mounted ? "Unmount" : "Mount", prominent: true) {
                            store.toggleMount(v)
                        }
                    }
                    PillButton(icon: "checkmark.shield",
                               label: store.verifying ? "Verifying…" : "Verify",
                               busy: store.verifying) {
                        store.verify(v)
                    }
                    // Reformatting as NTFS only makes sense for a removable NTFS
                    // volume — never the boot disk.
                    if v.isNTFS && v.mountPoint != "/" {
                        PillButton(icon: "trash", label: "Erase") {
                            store.eraseTarget = v
                        }
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 26).padding(.bottom, 22)
            .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }

            // hero: capacity ring + info
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
                    InfoRow(k: "Device", v: v.device)
                    InfoRow(k: "Format", v: v.formatDisplay)
                    InfoRow(k: "Access", v: v.readOnly ? "Read-only" : "Read & Write",
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
                Text("Nếu Mntfs hữu ích với bạn, một ly cà phê nhỏ giúp mình duy trì và phát triển dự án. Cảm ơn bạn! 🙏")
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
    @StateObject private var store = VolumeStore()
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(store: store).frame(width: 288)
            DetailPane(store: store)
        }
        .frame(minWidth: 1000, minHeight: 640)
        .background(UI.appBG)
        .preferredColorScheme(.dark)
        .alert("Mntfs", isPresented: Binding(
            get: { store.actionMessage != nil },
            set: { if !$0 { store.actionMessage = nil } })) {
            Button("OK", role: .cancel) { store.actionMessage = nil }
        } message: {
            Text(store.actionMessage ?? "")
        }
        .sheet(item: Binding(get: { store.eraseTarget },
                             set: { store.eraseTarget = $0 })) { target in
            EraseSheet(volume: target, erasing: store.erasing,
                       onErase: { store.erase(target, newName: $0) },
                       onCancel: { store.eraseTarget = nil })
        }
    }
}

/// Destructive reformat dialog. Requires an explicit volume-name confirmation.
private struct EraseSheet: View {
    let volume: VolumeItem
    let erasing: Bool
    let onErase: (String) -> Void
    let onCancel: () -> Void
    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 30)).foregroundStyle(Color(0xf5a623))
                VStack(alignment: .leading, spacing: 5) {
                    Text("Erase “\(volume.displayName)”?")
                        .font(.system(size: 16, weight: .bold))
                    Text("This permanently deletes everything on \(volume.device) and "
                         + "reformats it as NTFS. This cannot be undone.")
                        .font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("NEW VOLUME NAME").font(.system(size: 10, weight: .bold)).tracking(0.6)
                    .foregroundStyle(.secondary)
                TextField("Untitled", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .disabled(erasing)
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
                .disabled(erasing || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 440)
        .onAppear { name = volume.displayName }
    }
}

#Preview { ContentView() }
