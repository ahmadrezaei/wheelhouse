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

    /// The Mac client factory over throw-away Moorings stores, with an injected gate.
    static func desktopFactory(gate: @escaping @Sendable () -> DevSafetyPolicy) -> DesktopClientFactory {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-factory-\(UUID().uuidString)", directoryHint: .isDirectory)
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: dir.appending(path: "d.json")),
                                  preferences: MooringsPreferencesStore(fileURL: dir.appending(path: "p.json")))
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(searchPath: []) }, environment: { EnvironmentBuilder(snapshot: nil) })
        return DesktopClientFactory(state: state, settings: MacClusterSettingsStore(fileURL: dir.appending(path: "s.json")), broker: broker, gateProvider: gate)
    }

    @Test func theClientFactoryReadsTheGateOnEveryCallNotWhenItIsBuilt() {
        // The app builds the factory in App.init, before the allowed hosts exist; a cluster added later must still reach its host.
        let box = Box()
        let factory = Self.desktopFactory(gate: { DevSafetyPolicy(isActive: true, allowedHosts: box.hosts) }).clientFactory
        let test = ClusterConfig(name: "test", server: URL(string: "https://127.0.0.1:6443")!, environment: .development)
        #expect(factory(test, ClusterSecrets(token: "x")) is RefusedKubeClient)       // fail closed while the hosts are unknown
        box.hosts = ["127.0.0.1"]                                                     // configured after the factory was built
        #expect(factory(test, ClusterSecrets(token: "x")) is LiveKubeClient)
        let other = ClusterConfig(name: "other", server: URL(string: "https://203.0.113.9:6443")!, environment: .production)
        #expect(factory(other, ClusterSecrets(token: "x")) is RefusedKubeClient)
        box.hosts = []                                                                // and it keeps following the gate
        #expect(factory(test, ClusterSecrets(token: "x")) is RefusedKubeClient)
    }

    @Test func demoClustersAreNeverGated() {
        let factory = Self.desktopFactory(gate: { DevSafetyPolicy(isActive: true, allowedHosts: []) })
        #expect(!(factory.make(config: DemoFleet.configs[0], secrets: ClusterSecrets()) is RefusedKubeClient))
    }

    @Test func testConnectionToAHostThatIsNotAllowedFailsUnderTheGate() async {
        // Add Cluster and the import sheet build their client from the injected factory, which is the Moorings one on the Mac.
        let factory = Self.desktopFactory(gate: { DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"]) }).clientFactory
        let config = ClusterConfig(name: "elsewhere", server: URL(string: "https://203.0.113.9:6443")!, environment: .production)
        let result = await ConnectionTester.run(client: factory(config, ClusterSecrets(token: "x")), namespace: nil)
        #expect(result.version == nil)
        #expect(result.error != nil)
    }

    @Test func liveBuildsMooringsAndTheImporterUsesIt() {
        let env = MacAppEnvironment.live(testKubeconfig: nil)
        #expect(env.importer.moorings.isAvailable)
        #expect(MooringsController.shared === env.moorings)
        #expect(env.moorings.registry === env.registry)
    }

    private func controller(home: URL, kubeconfig: URL) -> MooringsController {
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: home, temporaryDirectory: home)
        try? paths.prepare()
        let gate: @Sendable () -> DevSafetyPolicy = { DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"], home: home) }
        return MooringsController(paths: paths, gate: gate, explicitTestKubeconfig: kubeconfig, keychainMetadata: InMemoryMetadataStore(),
                                  keychainCredentials: InMemoryCredentialStore(),
                                  shell: ShellEnvironment(gate: gate(), home: home, shell: "/usr/bin/true", explicitTestKubeconfig: kubeconfig))
    }

    @Test func clustersAddedInAnEarlierRunAreRealOnceMooringsHasScanned() async throws {
        // The registry is built in App.init, before any scan: until the first scan every added cluster is a "Source removed" stand-in
        // (read-only, grey, no secrets). Starting Moorings must replace them and rebuild their sessions.
        let home = FileManager.default.temporaryDirectory.appending(path: "wh-moor-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let kubeconfig = try tempKubeconfig()
        // Run 1: add the context and allow changes (a developer cluster needs no prompt).
        let first = controller(home: home, kubeconfig: kubeconfig)
        await first.service.rescan()
        let ctx = try #require(first.state.contexts.first)
        try await first.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true, allowChanges: true)])
        #expect(first.state.listedConfigs().first?.readOnly == false)
        // Run 2: the registry exists before start().
        let second = controller(home: home, kubeconfig: kubeconfig)
        let registry = ClusterRegistry(credentials: second.credentials, metadata: second.metadata,
                                       defaults: try #require(UserDefaults(suiteName: "wh.moor.\(UUID().uuidString)")), clientFactory: second.clientFactory)
        second.registry = registry
        let stale = try #require(registry.clusters.first)
        #expect(stale.readOnly && stale.color == .gray)                               // the stand-in
        let staleSession = try #require(registry.session(for: stale.id))
        #expect(registry.secrets(for: stale.id).token == nil)
        await second.start()
        let fresh = try #require(registry.clusters.first)
        #expect(fresh.readOnly == false && fresh.color == .teal)
        #expect(registry.secrets(for: fresh.id).token == "t")
        #expect(try #require(registry.session(for: fresh.id)) !== staleSession)       // rebuilt with the real credentials
    }

    @Test func aDraftOfADiscoveredClusterWithACAIsSavedWithoutSecrets() {
        let pem = "-----BEGIN CERTIFICATE-----\nQUJD\n-----END CERTIFICATE-----\n"
        let config = ClusterConfig(id: "kc-1", name: "d", server: URL(string: "https://d.example.com")!)
        let existing = ClusterSecrets(token: "t", caPEM: pem)
        let draft = ClusterDraft(editing: config, secrets: existing)
        let edited = draft.makeSecrets(existing: existing)
        #expect(edited != existing)
        #expect(ClusterChangeSaver.secretsToWrite(managed: true, existing: existing, edited: edited) == nil)
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
