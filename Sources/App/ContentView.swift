//
//  ContentView.swift
//  Mntfs — NTFS volume manager. Its own visual identity: a Maclife-blue
//  midnight theme, a capacity ring as the hero, pill actions and switch
//  toggles. Same job as any NTFS manager, deliberately not a clone of one.
//

import SwiftUI

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

/// Capacity ring — the hero. Maclife-gradient arc over a faint track.
struct CapacityRing: View {
    var fraction: Double
    var size: CGFloat
    var body: some View {
        let lw = size * 0.085
        ZStack {
            Circle().stroke(Color.white.opacity(0.08), lineWidth: lw)
            Circle()
                .trim(from: 0, to: max(0.004, min(1, fraction)))
                .stroke(UI.ringGrad, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            DiskEmblem(size: size * 0.44)
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

    var selected: VolumeItem? { (ntfs + others).first { $0.id == selectedID } }

    init() {
        refresh()
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
        Task.detached(priority: .userInitiated) {
            let all = Self.enumerate()
            await MainActor.run { self.apply(all) }
        }
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
        Task.detached(priority: .userInitiated) {
            let out = Self.run(["verifyVolume", v.device])
            let text = out.flatMap { String(data: $0, encoding: .utf8) } ?? "No output."
            await MainActor.run { self.actionMessage = text }
        }
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
                    if !v.writable { Badge(text: "RO", kind: .rose) }
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
            HStack(spacing: 8) {
                Circle().fill(UI.green).frame(width: 7, height: 7)
                Text("Extension active").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(UI.dim)
                Spacer()
            }.padding(.horizontal, 16).padding(.vertical, 11)
        }
        .background(UI.sidebar)
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
    var tint: Color = UI.text
    var action: () -> Void = {}
    @State private var hover = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 12, weight: .semibold))
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
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
        .onHover { hover = $0 && !disabled }
    }
}

private struct InfoRow: View {
    let k: String; let v: String; var link = false; var good = false
    var body: some View {
        HStack(spacing: 10) {
            Text(k).font(.system(size: 12.5)).foregroundStyle(UI.dim)
                .frame(width: 118, alignment: .leading)
            if good {
                HStack(spacing: 6) {
                    Circle().fill(UI.green).frame(width: 7, height: 7)
                    Text(v)
                }.font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.text)
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

private struct DetailPane: View {
    @ObservedObject var store: VolumeStore
    @State private var saveAccess = true
    @State private var spotlight = false
    @State private var readOnly = false
    @State private var noAuto = false

    var body: some View {
        Group {
            if let v = store.selected {
                content(v)
            } else {
                VStack { Spacer(); Text("Select a volume").foregroundStyle(UI.dim); Spacer() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(LinearGradient(colors: [UI.detailA, UI.detailB],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder private func content(_ v: VolumeItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // header: title + actions
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 9) {
                        Text(v.displayName).font(.system(size: 26, weight: .bold))
                            .foregroundStyle(UI.text)
                        Image(systemName: "pencil").font(.system(size: 13))
                            .foregroundStyle(UI.faint)
                    }
                    Text(v.fileSystem.isEmpty ? "Unknown format" : v.fileSystem)
                        .font(.system(size: 12.5, weight: .medium)).foregroundStyle(UI.dim)
                }
                Spacer()
                HStack(spacing: 9) {
                    PillButton(icon: v.mounted ? "eject.fill" : "arrow.down.circle.fill",
                               label: v.mounted ? "Unmount" : "Mount", prominent: true,
                               disabled: v.mountPoint == "/") {
                        store.toggleMount(v)
                    }
                    PillButton(icon: "checkmark.shield", label: "Verify") {
                        store.verify(v)
                    }
                    PillButton(icon: "trash", label: "Erase") {
                        store.actionMessage = "Erasing volumes isn't available in this build yet."
                    }
                }
            }
            .padding(.horizontal, 34).padding(.top, 26).padding(.bottom, 22)
            .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }

            // hero: capacity ring + info
            HStack(alignment: .top, spacing: 44) {
                VStack(spacing: 14) {
                    CapacityRing(fraction: v.usedFraction, size: 168)
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
                    InfoRow(k: "Format", v: v.fileSystem.isEmpty ? "—" : v.fileSystem)
                    InfoRow(k: "Location", v: v.mountPoint ?? "—", link: v.mounted)
                    capacityLegend(v).padding(.top, 16)
                }
                .frame(maxWidth: 520, alignment: .leading)
            }
            .padding(.horizontal, 34).padding(.top, 30)

            // mount options
            Text("MOUNT OPTIONS").font(.system(size: 10.5, weight: .bold)).tracking(0.7)
                .foregroundStyle(UI.faint)
                .padding(.horizontal, 34).padding(.top, 34).padding(.bottom, 4)
            VStack(spacing: 0) {
                toggleRow("Save last access time", $saveAccess)
                toggleRow("Enable Spotlight indexing", $spotlight)
                toggleRow("Mount as read-only", $readOnly)
                toggleRow("Skip automatic mounting", $noAuto)
            }
            .padding(.horizontal, 18)
            .background(RoundedRectangle(cornerRadius: 12).fill(UI.card)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(UI.line, lineWidth: 1)))
            .padding(.horizontal, 34)

            Spacer(minLength: 20)
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

    private func toggleRow(_ label: String, _ bind: Binding<Bool>) -> some View {
        Toggle(isOn: bind) {
            Text(label).font(.system(size: 13.5)).foregroundStyle(UI.text)
        }
        .toggleStyle(.switch).tint(UI.accent)
        .padding(.vertical, 11)
        .overlay(alignment: .bottom) {
            if label != "Skip automatic mounting" {
                Rectangle().fill(UI.line).frame(height: 1)
            }
        }
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
    }
}

#Preview { ContentView() }
