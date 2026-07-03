//
//  ContentView.swift
//  FastNTFS — setup instructions and status.
//

import SwiftUI

struct ContentView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "externaldrive.fill.badge.checkmark")
                    .font(.system(size: 40))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading) {
                    Text("FastNTFS").font(.title.bold())
                    Text("NTFS read/write for macOS — FSKit + libntfs-3g")
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                Label {
                    Text("Enable the **FastNTFS** file-system extension in "
                         + "System Settings → General → Login Items & Extensions "
                         + "→ File System Extensions.")
                } icon: {
                    Image(systemName: "1.circle.fill")
                }
                Label {
                    Text("Plug in an NTFS disk. It mounts read/write "
                         + "automatically — no kernel extension, no reduced "
                         + "security, no SIP changes.")
                } icon: {
                    Image(systemName: "2.circle.fill")
                }
                Label {
                    Text("Manual mount: `mount -F -t fastntfs /dev/diskXsY /path`")
                        .font(.callout)
                } icon: {
                    Image(systemName: "terminal")
                }
            }

            Spacer()

            HStack {
                Button("Open File System Extensions Settings") {
                    let url = URL(string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.fskit.fsmodule")!
                    NSWorkspace.shared.open(url)
                }
                Spacer()
                Text("Powered by libntfs-3g (GPL)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(24)
    }
}

#Preview {
    ContentView()
}
