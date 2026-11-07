#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// The gate cannot be redirected through the environment, and a hard link cannot hide a file.
@Suite("Gate hardening", .serialized)
struct GateHardeningTests {
    @Test func accountHomeComesFromThePasswordDatabaseNotTheEnvironment() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let before = DevSafetyPolicy.accountHome.path
        let fake = try s.dir("fakehome")
        let old = getenv("CFFIXED_USER_HOME").map { String(cString: $0) }
        setenv("CFFIXED_USER_HOME", fake.path, 1)
        defer { if let old { setenv("CFFIXED_USER_HOME", old, 1) } else { unsetenv("CFFIXED_USER_HOME") } }
        #expect(DevSafetyPolicy.accountHome.path == before)
        #expect(before == String(cString: getpwuid(getuid())!.pointee.pw_dir))
    }

    @Test func aKubeFolderUnderAnyOfTheKnownHomesIsRefused() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let injected = try s.dir("injected")
        let redirected = try s.dir("redirected")
        let inRedirected = try s.write("redirected/.kube/config", kubeconfigText())
        let old = getenv("HOME").map { String(cString: $0) }
        setenv("HOME", redirected.path, 1)
        defer { if let old { setenv("HOME", old, 1) } else { unsetenv("HOME") } }
        // The policy was built with another home; $HOME still points at a .kube that must be protected.
        let policy = activeGate(home: injected)
        #expect(policy.isUnderHomeKube(inRedirected))
        #expect(throws: DevSafetyError.self) { try policy.assertReadable(inRedirected) }
    }

    @Test func aHardLinkToAnyFileIsRefusedWhileActive() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let secret = try s.write("home/not-a-kubeconfig.txt", kubeconfigText())
        let alias = s.root.appending(path: "alias.yaml")
        #expect(link(secret.path, alias.path) == 0)
        #expect(throws: DevSafetyError.self) { try activeGate(home: home).assertReadable(alias) }
        #expect(throws: DevSafetyError.self) { try activeGate(home: home).assertReadable(secret) }
        #expect(throws: DevSafetyError.self) { _ = try DiscoveredSecrets.readFile(alias.path, gate: activeGate(home: home)) }
        #expect(throws: DevSafetyError.self) { _ = try KubeconfigLoader(gate: activeGate(home: home)).loadStandalone(alias) }
        // Inactive gate: no restriction. A plain single-link file is fine while active.
        try openGate(home: home).assertReadable(alias)
        let plain = try s.write("plain.yaml", kubeconfigText())
        try activeGate(home: home).assertReadable(plain)
    }
}
#endif
