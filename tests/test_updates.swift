import Foundation

@main
struct UpdateRegression {
    @MainActor static func main() {
        precondition(UpdateRuntimePolicy.updatesEnabled(debug: false, environment: [:]))
        precondition(!UpdateRuntimePolicy.updatesEnabled(debug: true, environment: [:]))
        precondition(UpdateRuntimePolicy.updatesEnabled(debug: true,
            environment: ["MNTFS_ENABLE_UPDATES": "1"]))
        precondition(!UpdateRuntimePolicy.updatesEnabled(debug: false,
            environment: ["XCTestConfigurationFilePath": "test"]))
        for path in ["/Volumes/MNtfs/MNtfs.app", "/tmp/MNtfs.app",
                     "/Applications/Subfolder/MNtfs.app",
                     "/private/var/folders/x/AppTranslocation/MNtfs.app"] {
            precondition(!UpdateRuntimePolicy.installationEligible(
                bundleURL: URL(fileURLWithPath: path), writable: true))
        }
        precondition(UpdateRuntimePolicy.installationEligible(
            bundleURL: URL(fileURLWithPath: "/Applications/MNtfs.app"), writable: true))
        precondition(!UpdateRuntimePolicy.installationEligible(
            bundleURL: URL(fileURLWithPath: "/Applications/MNtfs.app"), writable: false))

        var paused = false
        var current = UpdateSafetySnapshot(activeOperations: 0, mountedVolumes: ["/Volumes/Data"])
        let gate = UpdateSafetyGate(pause: { paused = true }, resume: { paused = false },
            snapshot: {
                precondition(paused, "intake must stop before the mount snapshot")
                return current
            })
        precondition(gate.prepare()?.contains("/Volumes/Data") == true)
        precondition(!paused && !gate.isPrepared)
        current = UpdateSafetySnapshot(activeOperations: 1, mountedVolumes: [])
        precondition(gate.prepare() != nil && !paused)
        current = UpdateSafetySnapshot(activeOperations: 0, mountedVolumes: nil)
        precondition(gate.prepare() != nil && !paused, "mount table failure must fail closed")
        current = UpdateSafetySnapshot(activeOperations: 0, mountedVolumes: [])
        precondition(gate.prepare() == nil && paused && gate.isPrepared)
        gate.cancel()
        precondition(!paused && !gate.isPrepared, "abort must resume disk operations")
        // A replug after a postponed attempt must be checked again, not cached.
        current = UpdateSafetySnapshot(activeOperations: 0, mountedVolumes: ["/Volumes/Replug"])
        precondition(gate.prepare() != nil && !paused)
        print("Update safety and runtime policy tests passed")
    }
}
