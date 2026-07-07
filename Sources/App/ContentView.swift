//
//  ContentView.swift
//  FastNTFS — Paragon-style volume manager UI with Maclife branding.
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
    static let sidebar   = Color(0x1f2836)
    static let sidebarTop = Color(0x26313f)
    static let detailA   = Color(0x2b3644)
    static let detailB   = Color(0x212b38)
    static let line      = Color.white.opacity(0.07)
    static let card      = Color.white.opacity(0.045)
    static let text      = Color(0xe8edf3)
    static let dim       = Color(0x93a0b1)
    static let faint     = Color(0x68727f)
    static let accent    = Color(0x12c3f4)
    static let link      = Color(0x4aa8ec)
    static let green     = Color(0x37c85b)
    static let amber     = Color(0xf0a83a)
    static let sel       = Color(0x7d94b2).opacity(0.20)
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

/// External-drive graphic with the Maclife badge (the app's signature mark).
struct DriveGraphic: View {
    var size: CGFloat = 210
    var body: some View {
        let w = size, h = size * 150 / 210
        ZStack(alignment: .bottomLeading) {
            ZStack(alignment: .top) {
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color(0xe9edf1), Color(0xc4cbd4), Color(0x98a1ad)],
                                         startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color(0x7a828f), lineWidth: 1.5))
                VStack(spacing: 0) {
                    UnevenRoundedRectangle(topLeadingRadius: 14, topTrailingRadius: 14)
                        .fill(LinearGradient(colors: [Color(0x4c5663), Color(0x333b46)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(height: h * 0.26)
                        .overlay(alignment: .topTrailing) {
                            Circle().fill(UI.accent).frame(width: 6, height: 6)
                                .padding(.top, h * 0.13).padding(.trailing, 16)
                        }
                    Spacer()
                }
                VStack(alignment: .leading, spacing: 8) {
                    Spacer().frame(height: h * 0.42)
                    Capsule().fill(Color(0x8b93a0).opacity(0.7)).frame(width: w * 0.55, height: 5)
                    Capsule().fill(Color(0x8b93a0).opacity(0.5)).frame(width: w * 0.38, height: 5)
                }.padding(.leading, w * 0.18)
            }
            .frame(width: w, height: h)

            ZStack {
                Circle().fill(.white)
                    .overlay(Circle().stroke(Color(0xd3d8de), lineWidth: 1.5))
                MaclifeMark().padding(size * 0.055)
            }
            .frame(width: size * 0.285, height: size * 0.285)
            .offset(x: -size * 0.02, y: size * 0.06)
        }
        .frame(width: w, height: h + size * 0.06)
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

    var selected: VolumeItem? { (ntfs + others).first { $0.id == selectedID } }

    init() { refresh() }

    func refresh() {
        let all = Self.enumerate()
        let items = all.isEmpty ? Self.sample() : all
        ntfs = items.filter { $0.isNTFS }
        others = items.filter { !$0.isNTFS }
        if selectedID == nil || !items.contains(where: { $0.id == selectedID }) {
            selectedID = ntfs.first?.id ?? others.first?.id
        }
    }

    // MARK: diskutil enumeration

    private static func run(_ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        let d = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return d.isEmpty ? nil : d
    }

    private static func plist(_ d: Data?) -> [String: Any]? {
        guard let d else { return nil }
        return (try? PropertyListSerialization.propertyList(from: d, options: [], format: nil))
            as? [String: Any]
    }

    private static func enumerate() -> [VolumeItem] {
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

            let isNTFS = fs.localizedCaseInsensitiveContains("ntfs")
                || content == "Windows_NTFS"

            var used: Int64 = 0, free: Int64 = 0
            if let mp = mount,
               let a = try? FileManager.default.attributesOfFileSystem(forPath: mp) {
                let total = (a[.systemSize] as? NSNumber)?.int64Value ?? size
                free = (a[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
                used = max(0, total - free)
            }
            let nobrowse = mount.map { !$0.hasPrefix("/Volumes") && $0 != "/" } ?? false

            items.append(VolumeItem(
                id: id, name: name, sizeBytes: size, device: dev, fileSystem: fs,
                content: content, mountPoint: mount, writable: writable,
                ejectable: ejectable, isNTFS: isNTFS, nobrowse: nobrowse,
                usedBytes: used, freeBytes: free))
        }
        return items
    }

    // MARK: actions

    func toggleMount(_ v: VolumeItem) {
        _ = Self.run([v.mounted ? "unmount" : "mount", v.device])
        refresh()
    }

    // MARK: fallback sample (matches design preview)

    private static func sample() -> [VolumeItem] {
        func mk(_ id: String, _ n: String, _ gb: Double, ntfs: Bool, mounted: Bool,
                dev: String, fs: String, content: String = "", ro: Bool = false,
                eject: Bool = false, nobrowse: Bool = false, usedFrac: Double = 0.5) -> VolumeItem {
            let size = Int64(gb * 1_000_000_000)
            let used = Int64(Double(size) * usedFrac)
            return VolumeItem(id: id, name: n, sizeBytes: size, device: dev,
                              fileSystem: fs, content: content,
                              mountPoint: mounted ? "/Volumes/\(n)" : nil,
                              writable: !ro, ejectable: eject, isNTFS: ntfs,
                              nobrowse: nobrowse, usedBytes: used, freeBytes: size - used)
        }
        return [
            mk("disk0s6", "BOOTCAMP", 40.15, ntfs: true, mounted: true, dev: "/dev/disk0s6",
               fs: "Microsoft NTFS", content: "Windows_NTFS", usedFrac: 0.501),
            mk("disk4s1", "My USB Stick", 15.16, ntfs: true, mounted: true, dev: "/dev/disk4s1",
               fs: "Microsoft NTFS", ro: true, eject: true, usedFrac: 0.4),
            mk("disk5s1", "My Portable Drive", 499.93, ntfs: true, mounted: true, dev: "/dev/disk5s1",
               fs: "Microsoft NTFS", eject: true, usedFrac: 0.62),
            mk("disk6s1", "My Photo Archive", 499.8, ntfs: true, mounted: false, dev: "/dev/disk6s1",
               fs: "Microsoft NTFS", usedFrac: 0.3),
            mk("disk3s1", "", 0.5337, ntfs: false, mounted: false, dev: "/dev/disk3s1", fs: "EFI"),
            mk("disk3s5", "Macintosh HD - Data", 210, ntfs: false, mounted: true,
               dev: "/dev/disk3s5", fs: "APFS", nobrowse: true, usedFrac: 0.7),
            mk("disk3s1b", "Macintosh HD", 210, ntfs: false, mounted: true, dev: "/dev/disk3s1",
               fs: "APFS", ro: true, usedFrac: 0.7),
        ]
    }
}

// MARK: - Sidebar

private struct VolumeRow: View {
    let v: VolumeItem
    let selected: Bool
    var body: some View {
        HStack(spacing: 11) {
            Circle().fill(v.mounted ? UI.green : Color(0x7d6a3a))
                .frame(width: 7, height: 7)
            Image(systemName: v.ejectable ? "externaldrive.fill" : "internaldrive.fill")
                .font(.system(size: 17))
                .foregroundStyle(selected ? UI.text : Color(0xaeb8c6))
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(v.displayName).font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(UI.text).lineLimit(1)
                Text(v.sizeText).font(.system(size: 11.5)).foregroundStyle(UI.dim)
            }
            Spacer(minLength: 4)
            if !v.writable { Badge("read-only") }
            if v.nobrowse { Badge("nobrowse", amber: true) }
            if v.ejectable {
                Image(systemName: "eject.fill").font(.system(size: 12)).foregroundStyle(UI.dim)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 8).fill(selected ? UI.sel : .clear))
        .contentShape(Rectangle())
    }
}

private struct Badge: View {
    let text: String; var amber = false
    init(_ t: String, amber: Bool = false) { text = t; self.amber = amber }
    var body: some View {
        Text(text).font(.system(size: 10, weight: .semibold))
            .foregroundStyle(amber ? Color(0x3a2a06) : Color(0xc7d0db))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(amber ? UI.amber : Color.white.opacity(0.11)))
    }
}

private struct Sidebar: View {
    @ObservedObject var store: VolumeStore
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                ZStack {
                    Circle().fill(LinearGradient(colors: [Color(0x48566a), Color(0x333d4c)],
                                                 startPoint: .top, endPoint: .bottom))
                    Image(systemName: "person.fill").font(.system(size: 12))
                        .foregroundStyle(Color(0xc7d0db))
                }.frame(width: 26, height: 26)
                Text("This Mac").font(.system(size: 14, weight: .semibold)).foregroundStyle(UI.text)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold))
                    .foregroundStyle(UI.faint)
                Spacer()
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 12)
            .background(UI.sidebarTop)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("NTFS Volumes", store.ntfs)
                    section("Other Volumes", store.others)
                }.padding(.bottom, 12)
            }

            Spacer(minLength: 0)
            Divider().overlay(UI.line)
            HStack(spacing: 11) {
                DriveGraphic(size: 40).frame(width: 40, height: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("FastNTFS").font(.system(size: 14, weight: .semibold)).foregroundStyle(UI.text)
                    Text("NTFS for Mac").font(.system(size: 11)).foregroundStyle(UI.faint)
                }
                Spacer()
            }.padding(.horizontal, 18).padding(.vertical, 12)
        }
        .background(UI.sidebar)
    }

    @ViewBuilder private func section(_ title: String, _ items: [VolumeItem]) -> some View {
        if !items.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold)).tracking(0.6)
                .foregroundStyle(UI.faint)
                .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 6)
            VStack(spacing: 2) {
                ForEach(items) { v in
                    VolumeRow(v: v, selected: v.id == store.selectedID)
                        .onTapGesture { store.selectedID = v.id }
                }
            }.padding(.horizontal, 10)
        }
    }
}

// MARK: - Detail

private struct ToolButton: View {
    let icon: String; let label: String; var tint: Color = UI.dim; var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 20)).frame(height: 24)
                Text(label).font(.system(size: 11.5))
            }.foregroundStyle(tint).frame(minWidth: 56)
        }.buttonStyle(.plain)
    }
}

private struct InfoRow: View {
    let k: String; let v: String; var link = false; var mounted = false
    var body: some View {
        HStack(spacing: 8) {
            Text(k).font(.system(size: 13.5)).foregroundStyle(UI.dim)
                .frame(width: 150, alignment: .leading)
            if mounted {
                HStack(spacing: 7) {
                    Circle().fill(UI.green).frame(width: 8, height: 8)
                    Text(v).foregroundStyle(UI.text)
                }.font(.system(size: 13.5))
            } else {
                Text(v).font(.system(size: 13.5)).foregroundStyle(link ? UI.link : UI.text)
            }
            Spacer()
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }
    }
}

private struct OptionRow: View {
    let label: String; @Binding var on: Bool
    var body: some View {
        Button { on.toggle() } label: {
            HStack(spacing: 11) {
                RoundedRectangle(cornerRadius: 5)
                    .fill(on ? UI.accent : Color.white.opacity(0.05))
                    .overlay(RoundedRectangle(cornerRadius: 5)
                        .stroke(on ? UI.accent : Color.white.opacity(0.22), lineWidth: 1))
                    .frame(width: 19, height: 19)
                    .overlay {
                        if on {
                            Image(systemName: "checkmark").font(.system(size: 11, weight: .heavy))
                                .foregroundStyle(Color(0x062430))
                        }
                    }
                Text(label).font(.system(size: 14)).foregroundStyle(on ? UI.text : UI.dim)
                Spacer()
            }
        }.buttonStyle(.plain)
    }
}

private struct DetailPane: View {
    @ObservedObject var store: VolumeStore
    @State private var saveAccess = true
    @State private var spotlight = false
    @State private var readOnly = false
    @State private var noAuto = false

    var body: some View {
        let v = store.selected
        VStack(alignment: .leading, spacing: 0) {
            // toolbar
            HStack(spacing: 34) {
                ToolButton(icon: "eject.fill", label: (v?.mounted ?? true) ? "Unmount" : "Mount") {
                    if let v { store.toggleMount(v) }
                }
                ToolButton(icon: "checkmark.circle", label: "Verify", tint: UI.green)
                ToolButton(icon: "eraser.fill", label: "Erase")
                ToolButton(icon: "flag.checkered", label: "Startup")
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { Rectangle().fill(UI.line).frame(height: 1) }

            if let v {
                content(v).padding(.horizontal, 34).padding(.top, 26)
            } else {
                Spacer(); Text("No volume selected").foregroundStyle(UI.dim); Spacer()
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(LinearGradient(colors: [UI.detailA, UI.detailB],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
    }

    @ViewBuilder private func content(_ v: VolumeItem) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 30) {
                DriveGraphic(size: 210)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 10) {
                        Text(v.displayName).font(.system(size: 30, weight: .bold))
                            .foregroundStyle(UI.text)
                        Image(systemName: "pencil").font(.system(size: 15)).foregroundStyle(UI.faint)
                    }.padding(.bottom, 16)
                    VStack(spacing: 0) {
                        InfoRow(k: "Mounted", v: v.mounted ? "Yes" : "No", mounted: v.mounted)
                        InfoRow(k: "Device", v: v.device)
                        InfoRow(k: "File System", v: v.fileSystem.isEmpty ? "—" : v.fileSystem)
                        InfoRow(k: "Mount Point", v: v.mountPoint ?? "Not mounted",
                                link: v.mounted)
                    }
                    .padding(.horizontal, 18)
                    .background(RoundedRectangle(cornerRadius: 12).fill(UI.card)
                        .overlay(RoundedRectangle(cornerRadius: 12).stroke(UI.line, lineWidth: 1)))
                    .frame(maxWidth: 560)
                }
            }

            usage(v).padding(.top, 30)

            VStack(alignment: .leading, spacing: 14) {
                OptionRow(label: "Save Last Access Time", on: $saveAccess)
                OptionRow(label: "Enable Spotlight Indexing", on: $spotlight)
                OptionRow(label: "Mount in Read-only mode", on: $readOnly)
                OptionRow(label: "Do not mount automatically", on: $noAuto)
            }.padding(.top, 34)
        }
    }

    @ViewBuilder private func usage(_ v: VolumeItem) -> some View {
        let frac = v.sizeBytes > 0 ? Double(v.usedBytes) / Double(v.sizeBytes) : 0
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                label(ByteCount.string(v.sizeBytes), "Total")
                Spacer()
                label(ByteCount.string(v.usedBytes), "Used")
                Spacer()
                label(ByteCount.string(v.freeBytes), "Free")
            }.frame(maxWidth: 620)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.09))
                    Capsule().fill(LinearGradient(colors: [Color(0x2f8fe0), Color(0x4aa8ec)],
                                                  startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(6, geo.size.width * frac))
                }
            }.frame(height: 11)
            HStack(spacing: 9) {
                Circle().fill(Color(0x3f9be6)).frame(width: 9, height: 9)
                Text("Used").foregroundStyle(UI.dim)
                Text(ByteCount.string(v.usedBytes)).foregroundStyle(UI.text).fontWeight(.semibold)
            }.font(.system(size: 13)).padding(.top, 6)
        }
    }

    private func label(_ value: String, _ k: String) -> some View {
        HStack(spacing: 5) {
            Text(value).font(.system(size: 13, weight: .semibold)).foregroundStyle(UI.text)
            Text(k).font(.system(size: 13)).foregroundStyle(UI.dim)
        }
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var store = VolumeStore()
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(store: store).frame(width: 300)
            DetailPane(store: store)
        }
        .frame(minWidth: 1000, minHeight: 660)
        .preferredColorScheme(.dark)
    }
}

#Preview { ContentView() }
