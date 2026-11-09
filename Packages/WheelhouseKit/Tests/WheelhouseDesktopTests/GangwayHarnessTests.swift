#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@Suite("Gangway harness environment")
struct GangwayHarnessTests {
    private func rig() throws -> (GangwayHarness, GangwaySessionHandle, Scratch) {
        let scratch = try Scratch()
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: scratch.root, temporaryDirectory: scratch.root.appending(path: "tmp"))
        let registry = SessionRegistry(gate: { DevSafetyPolicy(isActive: false) })
        let cluster = ClusterConfig(id: "kc-h1", name: "h", server: URL(string: "https://h.test:6443")!)
        let (session, _) = try registry.create(cluster: cluster, origin: .harness("t"))
        let file = paths.sessions.appending(path: "x/kubeconfig")
        let handle = GangwaySessionHandle(session: session, kubeconfig: file, directory: file.deletingLastPathComponent(), kubeconfigHash: "")
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: "/Users/someone/.kube/config",
                                     vars: ["KUBECONFIG": "/Users/someone/.kube/config", "ANTHROPIC_API_KEY": "x", "DYLD_INSERT_LIBRARIES": "y", "KUBECACHEDIR": "/Users/someone/.kube/cache"],
                                     shell: "/bin/zsh")
        return (GangwayHarness(paths: paths, snapshot: snapshot, homeOverride: scratch.root), handle, scratch)
    }

    @Test("every kubectl the harness spawns gets KUBECACHEDIR under AppPaths.root while the gate is active")
    func cacheDirectory() throws {
        let (harness, handle, scratch) = try rig()
        defer { scratch.cleanup() }
        let env = harness.environment(kubeconfig: handle.kubeconfig)
        let cache = try #require(env["KUBECACHEDIR"])
        #expect(cache.hasPrefix(harness.paths.root.path + "/"), Comment(rawValue: cache))
        #expect(!cache.contains("/.kube"))
        let spec = harness.spec(kubectl: URL(fileURLWithPath: "/usr/local/bin/kubectl"), arguments: ["get", "ns"], session: handle)
        #expect(spec.environment["KUBECACHEDIR"] == cache)
    }

    @Test("the child gets the session kubeconfig, kuberc off, a scratch HOME, and nothing from the shell's kube settings or secrets")
    func scrubbed() throws {
        let (harness, handle, scratch) = try rig()
        defer { scratch.cleanup() }
        let env = harness.environment(kubeconfig: handle.kubeconfig)
        #expect(env["KUBECONFIG"] == handle.kubeconfig.path)
        #expect(env["KUBERC"] == "off")
        #expect(env["HOME"] == scratch.root.path)
        #expect(env["ANTHROPIC_API_KEY"] == nil)
        #expect(!env.keys.contains { $0.hasPrefix("DYLD_") })
        #expect(!env.values.contains { $0.contains("/.kube/config") })
    }

    @Test("the gate does not let the session kubeconfig live under ~/.kube")
    func sessionsPath() throws {
        let (harness, _, scratch) = try rig()
        defer { scratch.cleanup() }
        #expect(harness.paths.sessions.path.contains("wheelhouse-debug/sessions"))
        #expect(!harness.paths.sessions.path.contains("/.kube"))
    }
}
#endif
