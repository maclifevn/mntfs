// Regressions for the name bundle installer. All copies stay in a disposable
// directory; no authorization, ownership changes, or disk operations occur.
import Foundation
import Darwin

@main
struct LabelSupportRegression {
    static func main() throws {
        // Reproduce restrictive permissions on both the staged and installed
        // bundle; Finder must still be able to read it after root takes ownership.
        let previousMask = umask(0o077)
        defer { umask(previousMask) }
        let fm = FileManager.default
        let scratch = fm.temporaryDirectory.appendingPathComponent("mntfs-label-test-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: scratch) }

        // Include spaces, Unicode, and shell punctuation in both paths.
        let source = scratch.appendingPathComponent("Người dùng's \"Mac\" $test/mntfs.fs")
        try fm.createDirectory(at: source.appendingPathComponent("Contents/Resources"),
                               withIntermediateDirectories: true)
        try VolumeStore.labelBundleInfoPlist.write(
            to: source.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        let destination = scratch.appendingPathComponent("Thư mục's \"Mac\" $test/Library/Filesystems/mntfs.fs")
        let parent = destination.deletingLastPathComponent()

        // This failed in 0.1.2: cp cannot create the missing Filesystems parent.
        precondition(!fm.fileExists(atPath: parent.path))
        let first = try copy(from: source, to: destination)
        precondition(first.ok, first.text)
        try verifyBundle(at: destination)
        try verifyPermissions(at: destination)
        try verifyMode(at: parent, expected: 0o755)

        // Reinstall also works when a previous bundle and the parent exist.
        let stale = destination.appendingPathComponent("stale-file")
        try Data("old".utf8).write(to: stale)
        let second = try copy(from: source, to: destination)
        precondition(second.ok, second.text)
        precondition(!fm.fileExists(atPath: stale.path))
        try verifyBundle(at: destination)
        try verifyPermissions(at: destination)

        // A blocked parent fails with the real filesystem error.
        let blockedParent = scratch.appendingPathComponent("blocked-parent")
        try Data("keep".utf8).write(to: blockedParent)
        let blocked = try copy(from: source, to: blockedParent.appendingPathComponent("mntfs.fs"))
        precondition(!blocked.ok && !blocked.text.isEmpty)
        let preserved = try Data(contentsOf: blockedParent)
        precondition(preserved == Data("keep".utf8))
        try verifyBundle(at: source)
        print("NTFS name support tests passed (AppleScript, missing parent, reinstall, quoted paths, umask 077, blocked parent)")
    }

    static func copy(from source: URL, to destination: URL) throws -> VolumeStore.RunResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        let script = "umask 077\n" + VolumeStore.labelSupportCopyScript(from: source.path, to: destination.path)
        process.arguments = ["-e", VolumeStore.labelSupportAppleScript(script)]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return VolumeStore.RunResult(status: process.terminationStatus, out: data)
    }

    static func verifyBundle(at path: URL) throws {
        let data = try Data(contentsOf: path.appendingPathComponent("Contents/Info.plist"))
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
            as! [String: Any]
        precondition(plist["CFBundleName"] as? String == "mntfs")
        let personalities = plist["FSPersonalities"] as! [String: [String: String]]
        precondition(personalities["NTFS"]?["FSName"] == "Windows NT File System (NTFS)")
        precondition(FileManager.default.fileExists(atPath: path.appendingPathComponent("Contents/Resources").path))
    }

    static func verifyPermissions(at path: URL) throws {
        for directory in [path, path.appendingPathComponent("Contents"),
                          path.appendingPathComponent("Contents/Resources")] {
            try verifyMode(at: directory, expected: 0o755)
        }
        try verifyMode(at: path.appendingPathComponent("Contents/Info.plist"), expected: 0o644)
    }

    static func verifyMode(at path: URL, expected: Int) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        precondition(attributes[.posixPermissions] as? Int == expected,
                     "Unexpected permissions for \(path.path)")
    }
}
