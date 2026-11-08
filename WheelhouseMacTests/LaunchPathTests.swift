import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// `App.init` (through `MacAppEnvironment.live()`) must not read the test kubeconfig and must not call Security: either can block the
/// main thread behind a macOS prompt (a file under ~/Documents) or a Security main-thread warning, and the app then never launches.
@Suite("Launch path", .serialized)
@MainActor
struct LaunchPathTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _calls: [(path: String, onMain: Bool)] = []
        var calls: [(path: String, onMain: Bool)] { lock.withLock { _calls } }
        func read(_ url: URL) throws -> String {
            lock.withLock { _calls.append((url.path, Thread.isMainThread)) }
            return try String(contentsOf: url, encoding: .utf8)
        }
    }

    /// A throw-away kubeconfig with one cluster at 127.0.0.1, so no test depends on the owner's `.testcluster`.
    private func tempKubeconfig() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appending(path: "kubeconfig")
        let text = "clusters:\n- name: a\n  cluster: { server: 'https://127.0.0.1:6443' }\ncontexts:\n- name: a\n  context: { cluster: a, user: u }\nusers:\n- name: u\n  user: { token: t }\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var _hosts: Set<String> = []
        private var _servers: [URL] = []
        var hosts: Set<String> { get { lock.withLock { _hosts } } set { lock.withLock { _hosts = newValue } } }
        var servers: [URL] { lock.withLock { _servers } }
        func record(_ url: URL) { lock.withLock { _servers.append(url) } }
    }

    private func waitReady(_ env: MacAppEnvironment) async {
        for _ in 0..<300 where !env.isReady { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func liveDoesNoSynchronousFileReadOfTheTestKubeconfig() async {
        let recorder = Recorder()
        let env = MacAppEnvironment.live(reader: recorder.read, testKubeconfig: try? tempKubeconfig())
        #expect(env.hostsState == .pending)
        #expect(recorder.calls.isEmpty, "App.init read a file: \(recorder.calls)")
        // The kubeconfig is read after launch, off the main thread, exactly once.
        env.start()
        await waitReady(env)
        #expect(env.isReady)
        #expect(env.hostsState == .ready(hosts: 1))
        #expect(recorder.calls.count == 1)
        #expect(recorder.calls.allSatisfy { !$0.onMain }, "the read ran on the main thread")
    }

    @Test func aFailedReadIsReportedInlineAndNeverRetried() async {
        defer { DevSafety.setHostConfigurationError(nil) }
        struct Denied: Error, LocalizedError { var errorDescription: String? { "Operation not permitted" } }
        let counter = Recorder()
        let env = MacAppEnvironment.live(reader: { url in _ = try? counter.read(url); throw Denied() }, testKubeconfig: try? tempKubeconfig())
        env.start()
        await waitReady(env)
        if case .failed(let message) = env.hostsState { #expect(message.contains("couldn't be read")) } else { Issue.record("expected a failure, got \(env.hostsState)") }
        #expect(DevSafety.hostConfigurationError != nil)
        #expect(counter.calls.count == 1)                                    // one attempt, no loop
        // The import UI says why a host is blocked instead of hanging.
        let policy = MacImportPolicy(gate: DevSafetyPolicy(isActive: true, allowedHosts: []))
        let ctx = try? KubeconfigParser.parse("clusters:\n- name: a\n  cluster: { server: 'https://203.0.113.9:6443' }\ncontexts:\n- name: a\n  context: { cluster: a, user: u }\nusers:\n- name: u\n  user: { token: t }\n").contexts.first
        if let ctx { #expect(policy.blockedReason(for: ctx)?.contains("couldn't be read") == true) }
    }

    @Test func theClientFactoryReadsTheGateOnEveryCallNotWhenItIsBuilt() {
        // The app builds the factory in App.init, before the allowed hosts exist; a cluster added later must still reach its host.
        let box = Box()
        let factory = MacAppEnvironment.guardedClientFactory(
            gate: { DevSafetyPolicy(isActive: true, allowedHosts: box.hosts) },
            base: { config, _ in box.record(config.server); return LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"), tlsServerName: nil) })
        box.hosts = ["127.0.0.1"]                                                     // configured after the factory was built
        _ = factory(ClusterConfig(name: "test", server: URL(string: "https://127.0.0.1:6443")!, environment: .development), ClusterSecrets(token: "x"))
        _ = factory(ClusterConfig(name: "other", server: URL(string: "https://203.0.113.9:6443")!, environment: .production), ClusterSecrets(token: "x"))
        #expect(box.servers.first?.host == "127.0.0.1")
        #expect(box.servers.last?.host == "blocked-in-development.invalid")
    }

    @Test func testConnectionToAHostThatIsNotAllowedFailsUnderTheGate() async {
        // Add Cluster and the import sheet build their client from the injected factory, which is the guarded one on the Mac.
        let factory = MacAppEnvironment.guardedClientFactory(gate: { DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"]) })
        let config = ClusterConfig(name: "elsewhere", server: URL(string: "https://203.0.113.9:6443")!, environment: .production)
        let result = await ConnectionTester.run(client: factory(config, ClusterSecrets(token: "x")), namespace: nil)
        #expect(result.version == nil)
        #expect(result.error != nil)
    }

    @Test func theGateIsTheSameOnEveryRead() {
        let first = DevSafety.isActive
        #expect(MacAppEnvironment.live(testKubeconfig: nil).gateActive == first)
        #expect(DevSafety.isActive == first)
    }

    @Test func untilTheHostsAreKnownNoHostIsAllowed() {
        // Fail closed: the allowed set starts empty, so only the reserved fixture names pass while the file is still being read.
        let pending = DevSafetyPolicy(isActive: true, allowedHosts: [])
        #expect(!pending.isAllowed(server: URL(string: "https://127.0.0.1:6443")))
        #expect(pending.isAllowed(server: URL(string: "https://x.test")))
    }
}
