#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Counts every client that is created per server host and answers `/version` through the Demo client (no network).
final class CountingClients: MooringsClientMaking, @unchecked Sendable {
    private let state = Mutex<[String: Int]>([:])
    func count(host: String) -> Int { state.withLock { $0[host] ?? 0 } }
    var total: Int { state.withLock { $0.values.reduce(0, +) } }
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol {
        state.withLock { $0[config.host, default: 0] += 1 }
        return DemoFleet.client(for: DemoFleet.configs[0])
    }
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? { nil }
}

struct AllowAuthorizer: ChangeAuthorizing {
    var answer = true
    func authorize(reason: String) async -> Bool { answer }
}

/// A service over a scratch home, with an open gate (the shell KUBECONFIG list drives the default set).
final class MooringsHarness: @unchecked Sendable {
    let scratch: Scratch
    let home: URL
    let state: MooringsState
    let clients = CountingClients()
    let changes = ChangeLog()
    var service: MooringsService!

    init(files: [URL], user: [MooringsSource] = [], gate: DevSafetyPolicy? = nil, firstRunCompleted: Bool = false,
         authorizer: any ChangeAuthorizing = AllowAuthorizer(), registry: PeriodicTaskRegistry = PeriodicTaskRegistry(), scratch: Scratch) throws {
        self.scratch = scratch
        home = try scratch.home()
        let gate = gate ?? openGate(home: home)
        state = MooringsState(overrides: DiscoveredClusterStore(fileURL: scratch.root.appending(path: "discovered-clusters.json")),
                              preferences: MooringsPreferencesStore(fileURL: scratch.root.appending(path: "moorings.json")), gate: gate)
        try state.preferences.update { $0.userSources = user; $0.firstRunCompleted = firstRunCompleted }
        let list = files.map(\.path).joined(separator: ":")
        service = MooringsService(config: MooringsConfiguration(gate: gate, home: home, explicitTestKubeconfig: nil, shellKubeconfig: { list }, registry: registry),
                                  state: state, clients: clients, authorizer: authorizer,
                                  onChange: { [changes] c in changes.append(c) })
    }
}

@Suite("MooringsService")
struct MooringsServiceTests {
    static func threeContexts(_ s: Scratch) throws -> URL {
        try s.write("kc.yaml", """
        current-context: prod-eu
        clusters:
        - {name: c-prod, cluster: {server: "https://prod-eu.example.test:6443"}}
        - {name: c-stg, cluster: {server: "https://staging.example.test:6443"}}
        - {name: c-mini, cluster: {server: "https://127.0.0.1:8443"}}
        - {name: c-plain, cluster: {server: "https://plain.example.test:6443"}}
        users:
        - {name: u, user: {token: tok}}
        contexts:
        - {name: prod-eu, context: {cluster: c-prod, user: u}}
        - {name: stg-1, context: {cluster: c-stg, user: u}}
        - {name: minikube, context: {cluster: c-mini, user: u}}
        - {name: sandbox, context: {cluster: c-plain, user: u}}
        """)
    }

    @Test func firstRunListsEveryContextWithSuggestionsAndNothingIsContactedBeforeAdd() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try MooringsHarness(files: [try Self.threeContexts(s)], scratch: s)
        await h.service.rescan()
        let rows = await h.service.firstRunRows()
        #expect(rows.count == 4)
        let byName = Dictionary(uniqueKeysWithValues: rows.map { ($0.context.context.name, $0) })
        #expect(byName["prod-eu"]?.context.suggestion?.environment == .production)
        #expect(byName["stg-1"]?.context.suggestion?.environment == .staging)
        #expect(byName["minikube"]?.context.suggestion?.label == "Development (local)")
        #expect(byName["sandbox"]?.context.suggestion == nil)
        #expect(byName["prod-eu"]?.context.isCurrent == true)
        #expect(h.clients.total == 0)
        // Not added yet: no cluster exists.
        #expect(h.state.listedConfigs().isEmpty)
    }

    @Test func productionSuggestedRowsAreNeverContactedByTheFirstRunChecks() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try MooringsHarness(files: [try Self.threeContexts(s)], scratch: s)
        await h.service.rescan()
        let ids = await h.service.firstRunRows().map(\.id)
        await h.service.startFirstRunChecks(ids: ids)
        #expect(h.clients.count(host: "prod-eu.example.test") == 0)
        #expect(h.clients.count(host: "staging.example.test") == 1)
        #expect(h.clients.count(host: "127.0.0.1") == 1)
        #expect(h.clients.count(host: "plain.example.test") == 1)
        let prod = try #require(h.state.contexts.first { $0.context.name == "prod-eu" })
        #expect(h.state.checkState(for: prod.id) == .notChecked)
        // Clicking Check is the only thing that contacts it.
        let result = await h.service.check(prod.id)
        guard case .reachable = result else { Issue.record("expected reachable, got \(result)"); return }
        #expect(h.clients.count(host: "prod-eu.example.test") == 1)
    }

    @Test func firstRunChecksRunAtMostFourAtATime() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        var yaml = "clusters:\n- {name: c, cluster: {server: \"https://x.example.test:6443\"}}\nusers:\n- {name: u, user: {token: t}}\ncontexts:\n"
        for i in 0..<12 { yaml += "- {name: ctx\(i), context: {cluster: c, user: u}}\n" }
        let file = try s.write("many.yaml", yaml)
        let gauge = GaugeClients()
        let home = try s.home()
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "p.json")), gate: openGate(home: home))
        let service = MooringsService(config: MooringsConfiguration(gate: openGate(home: home), home: home, explicitTestKubeconfig: nil, shellKubeconfig: { file.path }),
                                      state: state, clients: gauge)
        await service.rescan()
        await service.startFirstRunChecks(ids: state.contexts.map(\.id))
        let peak = gauge.box.peak
        #expect(peak >= 2 && peak <= 4)
    }

    @Test func addingReadOnlyIsTheDefaultAndAllowChangesNeedsAnExplicitEnvironment() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try MooringsHarness(files: [try Self.threeContexts(s)], scratch: s)
        await h.service.rescan()
        let rows = await h.service.firstRunRows()
        var choices: [ClusterID: FirstRunChoice] = [:]
        for r in rows {
            switch r.context.context.name {
            // Accepts the suggestion but ticks Allow changes: ignored, because the environment was not picked.
            case "prod-eu": choices[r.id] = FirstRunChoice(selected: true, environment: .production, environmentPicked: false, allowChanges: true)
            // Picks the environment and ticks Allow changes.
            case "sandbox": choices[r.id] = FirstRunChoice(selected: true, environment: .development, environmentPicked: true, allowChanges: true)
            case "stg-1": choices[r.id] = FirstRunChoice(selected: true, environment: .staging)
            default: choices[r.id] = FirstRunChoice(selected: false)
            }
        }
        try await h.service.completeFirstRun(choices: choices)
        let configs = Dictionary(uniqueKeysWithValues: h.state.listedConfigs().map { ($0.name, $0) })
        #expect(Set(configs.keys) == ["prod-eu", "stg-1", "sandbox"])
        #expect(configs["prod-eu"]?.readOnly == true)
        #expect(configs["prod-eu"]?.environment == .production)
        #expect(configs["stg-1"]?.readOnly == true)
        #expect(configs["sandbox"]?.readOnly == false)
        #expect(configs["sandbox"]?.iCloudSync == false)
        #expect(configs.values.allSatisfy { $0.origin != nil })
        #expect(h.state.preferences.value.firstRunCompleted)
    }

    @Test func allowChangesOnProductionNeedsAuthenticationAndAnExplicitChoice() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let denied = try MooringsHarness(files: [try Self.threeContexts(s)], authorizer: AllowAuthorizer(answer: false), scratch: s)
        await denied.service.rescan()
        let prod = try #require(denied.state.contexts.first { $0.context.name == "prod-eu" })
        try await denied.service.completeFirstRun(choices: [prod.id: FirstRunChoice(selected: true, environment: .production)])
        await #expect(throws: MooringsError.authorizationDenied) { try await denied.service.allowChanges(id: prod.id, environment: .production) }
        #expect(denied.state.listedConfigs().first?.readOnly == true)

        let s2 = try Scratch(); defer { s2.cleanup() }
        let ok = try MooringsHarness(files: [try Self.threeContexts(s2)], scratch: s2)
        await ok.service.rescan()
        let prod2 = try #require(ok.state.contexts.first { $0.context.name == "prod-eu" })
        try await ok.service.completeFirstRun(choices: [prod2.id: FirstRunChoice(selected: true, environment: .production)])
        try await ok.service.allowChanges(id: prod2.id, environment: .production)
        let cfg = try #require(ok.state.listedConfigs().first)
        #expect(cfg.readOnly == false && cfg.environment == .production)
    }

    @Test func aProductionSuggestedClusterIsHeldUntilCheckedAndTheFactoryRefusesIt() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try MooringsHarness(files: [try Self.threeContexts(s)], scratch: s)
        await h.service.rescan()
        let prod = try #require(h.state.contexts.first { $0.context.name == "prod-eu" })
        try await h.service.completeFirstRun(choices: [prod.id: FirstRunChoice(selected: true, environment: .production)])
        #expect(h.state.isContactHeld(prod.id))
        let factory = DesktopClientFactory(state: h.state, settings: MacClusterSettingsStore(fileURL: s.root.appending(path: "cs.json")),
                                           broker: ExecCredentialBroker(locator: { ExecutableLocator(searchPath: []) }, environment: { EnvironmentBuilder(snapshot: nil) }),
                                           gate: openGate(home: h.home))
        let config = try #require(h.state.listedConfigs().first)
        let client = factory.make(config: config, secrets: ClusterSecrets())
        #expect(client is RefusedKubeClient)
        await #expect(throws: KubeError.self) { _ = try await client.version() }
        // Opening it (or Check) lifts the hold.
        try await h.service.markOpened(prod.id)
        #expect(!h.state.isContactHeld(prod.id))
        #expect(factory.make(config: config, secrets: ClusterSecrets()) is LiveKubeClient)
    }

    @Test func aNewProductionSuggestedContextAfterFirstRunIsAddedReadOnlyAndNotProbed() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "sandbox", server: "https://sandbox.example.test:6443"))
        let h = try MooringsHarness(files: [file], firstRunCompleted: true, scratch: s)
        await h.service.rescan()          // first scan: sandbox auto-added (it is "found" after the first run)
        #expect(h.state.listedConfigs().map(\.name) == ["sandbox"])
        // A production-suggested context appears in the watched file.
        try (kubeconfigText(context: "sandbox", server: "https://sandbox.example.test:6443") + "\n").write(to: file, atomically: true, encoding: .utf8)
        let extra = """
        apiVersion: v1
        kind: Config
        clusters:
        - {name: p, cluster: {server: "https://prod-us.example.test:6443"}}
        users:
        - {name: pu, user: {token: t}}
        contexts:
        - {name: prod-us, context: {cluster: p, user: pu}}
        - {name: sandbox, context: {cluster: p, user: pu}}
        """
        let more = try s.write("more.yaml", extra)
        let list = [file, more].map(\.path).joined(separator: ":")
        let home = h.home
        let service2 = MooringsService(config: MooringsConfiguration(gate: openGate(home: home), home: home, explicitTestKubeconfig: nil, shellKubeconfig: { list }),
                                       state: h.state, clients: h.clients)
        await service2.rescan()
        let prod = try #require(h.state.listedConfigs().first { $0.name == "prod-us" })
        #expect(prod.readOnly)
        #expect(prod.environment == .production)
        let o = try #require(h.state.overrides.override(for: prod.id))
        #expect(o.isNew)
        #expect(h.state.isContactHeld(prod.id))
        #expect(h.clients.total == 0)      // nothing contacted anything
    }

    @Test func sourceRemovedKeepsTheClusterAndTheOverridesAndRelinkMovesThem() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", kubeconfigText(context: "alpha", server: "https://alpha.example.test:6443"))
        let h = try MooringsHarness(files: [file], scratch: s)
        await h.service.rescan()
        let alpha = try #require(h.state.contexts.first)
        try await h.service.completeFirstRun(choices: [alpha.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true)])
        try h.state.overrides.update(alpha.id) { $0.name = "My Alpha"; $0.pinnedNamespaces = ["a", "b"] }
        // The context is renamed in the file: the old cluster is Source removed, the new one is a different cluster.
        try kubeconfigText(context: "beta", server: "https://alpha.example.test:6443").write(to: file, atomically: true, encoding: .utf8)
        let change = await h.service.rescan()
        #expect(change.removed == [alpha.id])
        let removed = try #require(h.state.listedConfigs().first { $0.id == alpha.id })
        #expect(removed.name == "My Alpha")
        #expect(removed.readOnly)
        let info = try #require(h.state.info(for: alpha.id))
        #expect(info.sourceRemovedAt != nil)
        #expect(h.state.overrides.override(for: alpha.id)?.sourceRemovedAt != nil)
        // Re-link moves the overrides to the renamed context.
        let beta = try #require(h.state.contexts.first)
        try await h.service.relink(from: alpha.id, to: beta.key)
        #expect(h.state.overrides.override(for: beta.id)?.pinnedNamespaces == ["a", "b"])
        #expect(h.state.overrides.override(for: alpha.id) == nil)
    }

    @Test func overridesAreSweptAfterThirtyDays() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let store = DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json"))
        let now = Date()
        try store.update("kc-old") { $0.added = true; $0.sourceRemovedAt = now.addingTimeInterval(-31 * 86_400) }
        try store.update("kc-recent") { $0.added = true; $0.sourceRemovedAt = now.addingTimeInterval(-5 * 86_400) }
        try store.update("kc-live") { $0.added = true }
        try store.sweep(now: now)
        #expect(Set(store.all.keys) == ["kc-recent", "kc-live"])
        // persisted
        #expect(Set(DiscoveredClusterStore(fileURL: s.root.appending(path: "o.json")).all.keys) == ["kc-recent", "kc-live"])
    }

    @Test func editsToAWatchedFileAreReflectedWithinOneSecondAndInvalidateTheCluster() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("watched.yaml", kubeconfigText(context: "w", server: "https://w.example.test:6443", user: "    token: one"))
        let h = try MooringsHarness(files: [file], firstRunCompleted: true, scratch: s)
        await h.service.start()
        defer { Task { await h.service.stop() } }
        let id = try #require(h.state.contexts.first?.id)
        #expect(await h.service.isWatching)

        let invalidated = InvalidationCollector()

        try await Task.sleep(for: .milliseconds(300))   // let the stream settle
        let started = ContinuousClock.now
        // An atomic replace, like an editor or `kubectl config` does.
        let tmp = s.root.appending(path: ".watched.yaml.tmp")
        try kubeconfigText(context: "w", server: "https://w.example.test:6443", user: "    token: two").write(to: tmp, atomically: false, encoding: .utf8)
        _ = rename(tmp.path, file.path)
        let reflected = await eventually(timeout: .seconds(4)) { h.state.context(for: id)?.context.auth == .token("two") }
        let elapsed = started.duration(to: .now)
        #expect(reflected)
        #expect(elapsed < .seconds(1), "took \(elapsed)")
        #expect(await eventually(timeout: .seconds(2)) { invalidated.contains(id) })
        #expect(h.changes.all.contains { $0.changed.contains(id) })
    }

    @Test func anUnchangedRewriteIsNotAChange() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("same.yaml", kubeconfigText())
        let h = try MooringsHarness(files: [file], scratch: s)
        await h.service.rescan()
        let before = h.changes.all.count
        try Data(contentsOf: file).write(to: file)
        let change = await h.service.rescan()
        #expect(change.isEmpty)
        #expect(h.changes.all.count == before)
    }

    @Test func theSafetyRescanIsAPeriodicTaskThatStopsWhileHidden() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let registry = PeriodicTaskRegistry()
        let h = try MooringsHarness(files: [try s.write("kc.yaml", kubeconfigText())], registry: registry, scratch: s)
        await h.service.start()
        let info = try #require(registry.snapshot().first { $0.name == "moorings.safety-rescan" })
        #expect(info.interval == 600)
        #expect(info.hiddenInterval == nil)
        let hidden = registry.effectiveIntervals(windowsVisible: false).map(\.name)
        #expect(!hidden.contains("moorings.safety-rescan"))
        await h.service.stop()
        #expect(registry.snapshot().isEmpty)
        #expect(!(await h.service.isWatching))
    }

    @Test func duplicateNamesAcrossStandaloneFilesAreToldApartByFileName() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let a = try s.write("a.yaml", kubeconfigText(context: "same", server: "https://a.example.test:6443"))
        let b = try s.write("b.yaml", kubeconfigText(context: "same", server: "https://b.example.test:6443"))
        let h = try MooringsHarness(files: [], user: [MooringsSource(kind: .userFile, path: a.path), MooringsSource(kind: .userFile, path: b.path)], scratch: s)
        await h.service.rescan()
        #expect(Set(h.state.contexts.map(\.displayName)) == ["same — a.yaml", "same — b.yaml"])
    }

    @Test func addFileSourceThroughTheSeamAddsTheFileByRealpath() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("exec.yaml", kubeconfigText(context: "viaexec", user: "    exec: {command: aws, args: [eks, get-token]}"))
        let link = s.root.appending(path: "link.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let h = try MooringsHarness(files: [], scratch: s)
        #expect(h.service.isAvailable)
        try await h.service.addFileSource(link)
        #expect(h.state.preferences.value.userSources == [MooringsSource(kind: .userFile, path: file.path)])
        #expect(h.state.contexts.map(\.context.name) == ["viaexec"])
        #expect(h.state.contexts.first?.authSummary == .exec(command: "aws"))
    }
}

final class ChangeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [MooringsChange] = []
    func append(_ c: MooringsChange) { lock.withLock { items.append(c) } }
    var all: [MooringsChange] { lock.withLock { items } }
}

final class InvalidationCollector: @unchecked Sendable {
    private let ids = Mutex<[ClusterID]>([])
    private var token: NSObjectProtocol?
    init() {
        token = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: nil) { [weak self] note in
            if let cid = ClusterEvents.clusterID(from: note) { self?.ids.withLock { $0.append(cid) } }
        }
    }
    func contains(_ id: ClusterID) -> Bool { ids.withLock { $0.contains(id) } }
    deinit { if let token { NotificationCenter.default.removeObserver(token) } }
}

final class GaugeBox: @unchecked Sendable {
    private let state = Mutex((running: 0, peak: 0))
    func enter() { state.withLock { $0.running += 1; $0.peak = max($0.peak, $0.running) } }
    func leave() { state.withLock { $0.running -= 1 } }
    var peak: Int { state.withLock { $0.peak } }
}

final class GaugeClients: MooringsClientMaking, @unchecked Sendable {
    let box = GaugeBox()
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol { SlowClient(gauge: box) }
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? { nil }
}

private struct SlowClient: KubeClientProtocol {
    let gauge: GaugeBox
    private let inner = DemoFleet.client(for: DemoFleet.configs[0])
    init(gauge: GaugeBox) { self.gauge = gauge }
    func version() async throws -> KubeVersion {
        let g = gauge
        g.enter(); defer { g.leave() }
        try await Task.sleep(for: .milliseconds(80))
        return try await inner.version()
    }
    func discovery() async throws -> DiscoveryInfo { try await inner.discovery() }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { try await inner.list(type, kind: kind, namespace: namespace, options: options) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { try await inner.get(type, kind: kind, name: name, namespace: namespace) }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { try await inner.listRaw(kind, namespace: namespace, options: options) }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { try await inner.getRaw(kind, name: name, namespace: namespace) }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { inner.watch(type, kind: kind, namespace: namespace, options: options) }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { try await inner.create(kind, namespace: namespace, name: name, subresource: subresource, body: body, options: options) }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { try await inner.replace(kind, name: name, namespace: namespace, body: body, options: options) }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { try await inner.patch(kind, name: name, namespace: namespace, subresource: subresource, patch: patch, options: options) }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { try await inner.delete(kind, name: name, namespace: namespace, options: options) }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { inner.logs(namespace: namespace, pod: pod, options: options) }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { try await inner.podMetrics(namespace: namespace) }
    func nodeMetrics() async throws -> [NodeMetrics] { try await inner.nodeMetrics() }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { try await inner.proxyGET(namespace: namespace, service: service, port: port, path: path, query: query) }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { try inner.execWebSocket(namespace: namespace, pod: pod, options: options) }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { try inner.portForwardWebSocket(namespace: namespace, pod: pod, ports: ports) }
}
#endif
