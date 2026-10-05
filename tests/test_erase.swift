import Foundation

@main
struct EraseRegression {
    static func main() {
        let selected = VolumeStore.eraseIdentity(volumeUUID: "A", diskUUID: "P1")
        let original: [String: Any] = ["VolumeUUID": "A", "DiskUUID": "P1",
                                      "TotalSize": 1_000_000, "Content": "Windows_NTFS"]
        // A second drive can reuse the same /dev/disk node, size and type.
        let replacement: [String: Any] = ["VolumeUUID": "B", "DiskUUID": "P2",
                                         "TotalSize": 1_000_000, "Content": "Windows_NTFS"]
        precondition(VolumeStore.matchesEraseIdentity(original, expected: selected))
        precondition(!VolumeStore.matchesEraseIdentity(replacement, expected: selected))
        precondition(!VolumeStore.matchesEraseIdentity(["VolumeUUID": "A"], expected: selected))
        precondition(!VolumeStore.matchesEraseIdentity(original, expected: [:]))
        precondition(VolumeStore.eraseIdentity(volumeUUID: "", diskUUID: nil).isEmpty)
        let mbr = VolumeStore.eraseIdentity(volumeUUID: "A", diskUUID: nil)
        precondition(VolumeStore.matchesEraseIdentity(original, expected: mbr))
        precondition(!VolumeStore.matchesEraseIdentity(replacement, expected: mbr))
        print("erase identity tests passed (no disk operations performed)")
    }
}
