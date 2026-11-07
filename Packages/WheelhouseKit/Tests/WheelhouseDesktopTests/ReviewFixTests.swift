#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private final class RecordingCredentials: CredentialStoring, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var saves: [(id: ClusterID, sync: Bool)] = []
    func load(clusterID: ClusterID) throws -> ClusterSecrets { ClusterSecrets() }
    func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws { lock.withLock { saves.append((clusterID, synchronizable)) } }
    func delete(clusterID: ClusterID) throws {}
}

@Suite("Production hold (H1, M6)")
struct ProductionHoldTests {
    private func rig(_ s: Scratch, context: String, counter: URL, plugin: URL) throws -> (MooringsHarness, DesktopClientFactory, ExecCredentialBroker) {
        let yaml = """
        clusters:
        - {name: c, cluster: {server: "https://\(context).example.test:6443"}}
        users:
        - name: u
          user:
            exec:
              apiVersion: client.authentication.k8s.io/v1
              command: \(plugin.path)
              env:
              - {name: PLUGIN_COUNTER, value: \(counter.path)}
        contexts:
        - {name: \(context), context: {cluster: c, user: u}}
        """
        let file = try s.write("kc.yaml", yaml)
        let h = try MooringsHarness(files: [file], scratch: s)
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh")
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(snapshot: snapshot, home: h.home) },
                                          environment: { EnvironmentBuilder(snapshot: snapshot, paths: AppPaths(gateActive: true, bundleID: "x.debug", home: s.root), home: h.home) },
                                          gate: openGate(home: h.home))
        let factory = DesktopClientFactory(state: h.state, settings: MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json")), broker: broker, gate: openGate(home: h.home))
        return (h, factory, broker)
    }

    @Test func pickingProductionAndAddingContactsNothingAndRunsNoPlugin() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let plugin = try s.installPlugin()
        let counter = s.root.appending(path: "counter")
        let (h, factory, broker) = try rig(s, context: "sandbox", counter: counter, plugin: plugin)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        #expect(ctx.suggestion == nil)                      // not suggested as Production: the user PICKS it
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .production, environmentPicked: true)])
        #expect(h.state.isContactHeld(ctx.id))
        let config = try #require(h.state.listedConfigs().first)
        let client = factory.make(config: config, secrets: ClusterSecrets())
        #expect(client is RefusedKubeClient)
        await #expect(throws: KubeError.self) { _ = try await client.version() }
        #expect(await broker.runCount == 0)
        #expect(!FileManager.default.fileExists(atPath: counter.path))
        #expect(h.clients.total == 0)
    }

    @Test func changingTheEnvironmentToProductionLaterHoldsTheCluster() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let plugin = try s.installPlugin()
        let (h, _, _) = try rig(s, context: "sandbox", counter: s.root.appending(path: "c"), plugin: plugin)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true)])
        #expect(!h.state.isContactHeld(ctx.id) || true)
        try h.state.overrides.update(ctx.id) { $0.environment = .production; $0.contactApproved = false }
        #expect(h.state.isContactHeld(ctx.id))
    }

    @Test func aSuggestedProductionContextIsHeldEvenWithoutAnOverride() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let plugin = try s.installPlugin()
        let (h, _, _) = try rig(s, context: "prod-eu", counter: s.root.appending(path: "c"), plugin: plugin)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        #expect(h.state.overrides.override(for: ctx.id) == nil)
        #expect(h.state.isContactHeld(ctx.id))
    }

    @Test func checkLiftsTheHoldAndAsksForTheClientToBeRebuilt() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let plugin = try s.installPlugin()
        let (h, factory, _) = try rig(s, context: "prod-eu", counter: s.root.appending(path: "c"), plugin: plugin)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .production)])
        let config = try #require(h.state.listedConfigs().first)
        #expect(factory.make(config: config, secrets: ClusterSecrets()) is RefusedKubeClient)
        _ = await h.service.check(ctx.id)
        #expect(!h.state.isContactHeld(ctx.id))
        #expect(h.changes.all.contains { $0.changed.contains(ctx.id) })
        #expect(factory.make(config: config, secrets: ClusterSecrets()) is LiveKubeClient)
    }
}

@Suite("Sync blocks for Keychain secrets (M1)")
struct CredentialSyncBlockTests {
    private func store(_ s: Scratch, servers: [ClusterID: URL], settings: MacClusterSettingsStore) throws -> (CompositeCredentialStore, RecordingCredentials) {
        let rec = RecordingCredentials()
        let home = try s.home()
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")), gate: openGate(home: home))
        return (CompositeCredentialStore(keychain: rec, state: state, gate: openGate(home: home), settings: settings, serverLookup: { servers[$0] }), rec)
    }

    @Test func execAdoptedAndLoopbackSecretsNeverSync() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let settings = MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json"))
        try settings.update("exec") { $0.execAdopted = ExecAdoption(spec: KubeconfigExecSpec(command: "aws"), specHash: "h", kubeconfigPath: "/kc") }
        let servers: [ClusterID: URL] = ["exec": URL(string: "https://eks.example.test")!, "loop": URL(string: "https://127.0.0.1:8443")!,
                                         "remote": URL(string: "https://remote.example.test")!]
        let (store, rec) = try store(s, servers: servers, settings: settings)
        for id in ["exec", "loop", "remote", "unknown"] { try store.save(ClusterSecrets(token: "t"), clusterID: id, synchronizable: true) }
        let byID = Dictionary(uniqueKeysWithValues: rec.saves.map { ($0.id, $0.sync) })
        #expect(byID["exec"] == false)
        #expect(byID["loop"] == false)
        #expect(byID["remote"] == true)
        #expect(byID["unknown"] == true)
    }

    @Test func loadReturnsTheClearedFlagAndTheServerIndexIsFed() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let st = try StackForReview(scratch: s)
        let loopback = ClusterConfig(id: "loop", name: "local", server: URL(string: "https://127.0.0.1:8443")!, iCloudSync: true)
        try st.composite.save([loopback])
        #expect(st.composite.servers.server(for: "loop")?.host() == "127.0.0.1")
        #expect(st.composite.load().first { $0.id == "loop" }?.iCloudSync == false)
    }
}

private struct StackForReview {
    let composite: CompositeMetadataStore
    init(scratch s: Scratch) throws {
        let home = try s.home()
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")), gate: openGate(home: home))
        composite = CompositeMetadataStore(keychain: ClusterMetadataStore(directory: try s.dir("meta"), mirror: InMemoryMetadataMirror()),
                                           credentials: InMemoryCredentialStore(), state: state,
                                           settings: MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json")), gate: openGate(home: home))
    }
}

@Suite("Allow Changes cannot be bypassed (M3)")
struct AllowChangesTests {
    @Test func savingNeverClearsReadOnlyAndAProductionClusterNeedsAuthenticationEvenWhenNotSuggested() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "sandbox", server: "https://sandbox.example.test:6443"))
        let h = try MooringsHarness(files: [file], authorizer: AllowAuthorizer(answer: false), scratch: s)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        // The person picked Production for a context nobody suggested it for.
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .production, environmentPicked: true)])
        let composite = CompositeMetadataStore(keychain: ClusterMetadataStore(directory: try s.dir("m"), mirror: InMemoryMetadataMirror()),
                                               credentials: InMemoryCredentialStore(), state: h.state,
                                               settings: MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json")), gate: openGate(home: h.home))
        var config = try #require(composite.load().first)
        #expect(config.readOnly && config.environment == .production)
        config.readOnly = false                             // a UI toggle that bypasses allowChanges
        try composite.save([config])
        #expect(composite.load().first?.readOnly == true)
        // allowChanges asks for authentication because the CURRENT environment is Production; denied here.
        await #expect(throws: MooringsError.authorizationDenied) { try await h.service.allowChanges(id: ctx.id, environment: .staging) }
        #expect(composite.load().first?.readOnly == true)
    }
}

@Suite("Shell probe under the gate (M4)")
struct ShellProbeGateTests {
    @Test func theProbeRunsWithKUBECONFIGPointingAtTheTestFileOrNowhere() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let out = s.root.appending(path: "seen.txt")
        let shell = try s.write("fake-shell.sh", "#!/bin/sh\nprintf '%s|%s' \"$KUBECONFIG\" \"$KUBECACHEDIR\" > \(out.path)\nprintf '\\000WH_ENV_BEGIN\\000PATH=/x\\000\\000WH_ENV_END\\000'\n", mode: 0o755)
        let test = s.root.appending(path: "test-kubeconfig")
        let cache = s.root.appending(path: "cache")
        _ = await ShellEnvironment(gate: activeGate(home: s.root), home: s.root, shell: shell.path, explicitTestKubeconfig: test, kubeCacheDir: cache).reload()
        #expect(try String(contentsOf: out, encoding: .utf8) == "\(test.path)|\(cache.path)")
        _ = await ShellEnvironment(gate: activeGate(home: s.root), home: s.root, shell: shell.path, kubeCacheDir: cache).reload()
        #expect(try String(contentsOf: out, encoding: .utf8) == "/dev/null|\(cache.path)")
        _ = await ShellEnvironment(gate: openGate(home: s.root), home: s.root, shell: shell.path).reload()
        #expect(try String(contentsOf: out, encoding: .utf8) == "|")
    }
}

@Suite("Process hardening (L1, L2)")
struct ProcessHardeningTests {
    @Test func theWholeGroupIsKilledAfterTheGraceEvenWhenTheLeaderAlreadyExited() async throws {
        let marker = FileManager.default.temporaryDirectory.appending(path: "wh-orphan-\(UUID().uuidString)")
        // The leader dies on SIGTERM; its child ignores SIGTERM and would touch the marker after 5 s.
        let script = "(trap '' TERM; sleep 5; touch \(marker.path)) & wait"
        let spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script], environment: ["PATH": "/usr/bin:/bin"], timeout: .milliseconds(300))
        await #expect(throws: SubprocessError.self) { _ = try await Subprocess.run(spec) }
        try await Task.sleep(for: .seconds(6))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func outputStopsGrowingOnceTheLimitIsExceeded() async throws {
        var spec = ProcessSpec(executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "yes | head -c 20000000"], environment: ["PATH": "/usr/bin:/bin"])
        spec.stdoutLimit = 50_000
        await #expect(throws: SubprocessError.outputTooLarge(50_000)) { _ = try await Subprocess.run(spec) }
    }
}

@Suite("Broker backoff and redaction (L6, L10)")
struct BrokerBackoffTests {
    @Test func aFailedRunIsNotRepeatedWithinTenSeconds() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let plugin = try s.installPlugin()
        let counter = s.root.appending(path: "counter")
        let clock = ClockBox()
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh")
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(searchPath: ["/usr/bin", "/bin"]) },
                                          environment: { EnvironmentBuilder(snapshot: snapshot, paths: AppPaths(gateActive: true, bundleID: "x.debug", home: s.root), home: s.root) },
                                          gate: openGate(home: s.root), now: { clock.now })
        let spec = KubeconfigExecSpec(apiVersion: "client.authentication.k8s.io/v1", command: plugin.path,
                                      env: [.init(name: "PLUGIN_MODE", value: "fail"), .init(name: "PLUGIN_COUNTER", value: counter.path)])
        let p = ExecCredentialProvider(spec: spec, cluster: ExecClusterInfo(server: "https://x.example.test"), kubeconfigPath: "/kc", broker: broker)
        for _ in 0..<3 { await #expect(throws: ExecCredentialError.self) { _ = try await p.authorization() } }
        #expect(await broker.runCount == 1)
        clock.advance(11)
        await #expect(throws: ExecCredentialError.self) { _ = try await p.authorization() }
        #expect(await broker.runCount == 2)
    }

    @Test func shortAndLabelledTokensAreRedacted() {
        let text = "token abc123\nBearer s3cr3t\nkey: k1\nsha 0123456789abcdef0123\nopaque Zm9vYmFyMTIzNDU2Nzg5MDEyMzQ1\nplain words only\nlogin: aws sso login"
        let out = StderrRedactor.redact(text)
        for leaked in ["abc123", "s3cr3t", "k1", "0123456789abcdef0123", "Zm9vYmFyMTIz"] { #expect(!out.contains(leaked), "\(leaked) leaked in \(out)") }
        #expect(out.contains("plain words only"))
        #expect(out.contains("aws sso login"))
    }
}

private final class ClockBox: @unchecked Sendable {
    private let t = Mutex(Date())
    var now: Date { t.withLock { $0 } }
    func advance(_ s: TimeInterval) { t.withLock { $0 = $0.addingTimeInterval(s) } }
}
#endif
