#if os(macOS)
import Testing
import Foundation
@testable import WheelhouseDesktop

/// The gate is decided on its first read and never changes afterwards. Only a Distribution candidate needs the code-signature check,
/// which runs synchronously on that first read.
@Suite("DevSafety launch")
struct DevSafetyLaunchTests {
    @Test func onlyADistributionBuildIsACandidateForTurningTheGateOff() {
        let id = DevSafety.distributionBundleID
        #expect(DevSafety.isDistributionCandidate(info: ["WHDevSafety": "NO"], bundleID: id))
        #expect(!DevSafety.isDistributionCandidate(info: ["WHDevSafety": "YES"], bundleID: id))
        #expect(!DevSafety.isDistributionCandidate(info: [:], bundleID: id))
        #expect(!DevSafety.isDistributionCandidate(info: ["WHDevSafety": "NO"], bundleID: id + ".debug"))
        #expect(!DevSafety.isDistributionCandidate(info: ["WHDevSafety": "NO"], bundleID: nil))
    }

    @Test func theGateIsDecidedOnceAndNeverChanges() {
        // The test bundle is not a Distribution app: the first read decides it from Info.plist alone (no Security call), ON.
        let first = DevSafety.isActive
        #expect(first)
        for _ in 0..<50 { #expect(DevSafety.isActive == first) }
    }

    @Test func theConfigurationErrorIsStoredForTheImportUI() {
        defer { DevSafety.setHostConfigurationError(nil) }
        #expect(DevSafety.hostConfigurationError == nil)
        DevSafety.setHostConfigurationError("denied")
        #expect(DevSafety.hostConfigurationError == "denied")
    }

    @Test func allowedHostsAreReadThroughAnInjectedReader() throws {
        let gate = DevSafetyPolicy(isActive: true, home: URL(fileURLWithPath: "/nonexistent-home"))
        let text = "clusters:\n- name: a\n  cluster: { server: 'https://127.0.0.1:6443' }\ncontexts:\n- name: a\n  context: { cluster: a, user: u }\nusers:\n- name: u\n  user: { token: t }\n"
        let hosts = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: URL(fileURLWithPath: "/tmp/never-read.yaml"), gate: gate, read: { _ in text })
        #expect(hosts == ["127.0.0.1"])
        #expect(throws: DevSafetyError.self) {
            _ = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: URL(fileURLWithPath: "/tmp/never-read.yaml"), gate: gate, read: { _ in throw CocoaError(.fileReadNoPermission) })
        }
    }
}
#endif
