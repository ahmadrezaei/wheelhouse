import Foundation
import Testing
@testable import WheelhouseKit

// MARK: - Scripted client

/// Client whose list/watch behaviour is scripted. Pods only; everything else is empty.
final class ScriptedClient: KubeClientProtocol, @unchecked Sendable {
    enum WatchMode { case hold, closeImmediately, goneOnce }
    private let lock = NSLock()
    private var _lists = 0, _watches = 0, _versionCalls = 0
    var watchMode: WatchMode = .hold
    var listDelay: Duration = .zero
    var podsError: KubeError?
    var versionFails = false
    var versionError: KubeError?
    var podNames = ["a", "b"]
    /// Per-namespace scripting for lists that name a namespace (multi-namespace tests).
    var podNamesByNamespace: [String: [String]] = [:]
    var podsErrorByNamespace: [String: KubeError] = [:]
    var metricsByNamespace: [String: Result<[PodMetrics], KubeError>] = [:]

    var lists: Int { lock.withLock { _lists } }
    var watches: Int { lock.withLock { _watches } }

    private func podJSON(_ name: String, namespace: String = "ns") -> JSONValue {
        ["apiVersion": "v1", "kind": "Pod", "metadata": ["name": .string(name), "namespace": .string(namespace), "uid": .string(name), "resourceVersion": "7"],
         "spec": ["containers": [["name": "c", "image": "i"]]]]
    }

    func version() async throws -> KubeVersion {
        if let e = lock.withLock({ versionError }) { throw e }
        if lock.withLock({ versionFails }) { throw KubeError.unreachable(cause: "down") }
        return KubeVersion(major: "1", minor: "31", gitVersion: "v1.31.0", platform: nil, buildDate: nil)
    }
    func discovery() async throws -> DiscoveryInfo { throw KubeError.unsupported("scripted") }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        lock.withLock { _lists += 1 }
        if listDelay > .zero { try await Task.sleep(for: listDelay) }
        var items: [JSONValue] = []
        if kind.id == ResourceKind.pod.id {
            if let namespace, let e = lock.withLock({ podsErrorByNamespace[namespace] }) { throw e }
            if let podsError { throw podsError }
            if let namespace, let names = lock.withLock({ podNamesByNamespace[namespace] }) { items = names.map { podJSON($0, namespace: namespace) } }
            else { items = podNames.map { podJSON($0) } }
        }
        let json: JSONValue = ["apiVersion": "v1", "kind": "List", "metadata": ["resourceVersion": "7"], "items": .array(items)]
        return try json.decode(KubeList<T>.self)
    }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("scripted") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("scripted") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("scripted") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        let n = lock.withLock { () -> Int in _watches += 1; return _watches }
        let mode = watchMode
        return AsyncThrowingStream { c in
            switch mode {
            case .hold: break
            case .closeImmediately: c.finish()
            case .goneOnce: if n == 1 { c.finish(throwing: KubeError.gone) }
            }
        }
    }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("scripted") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("scripted") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("scripted") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("scripted") }
    /// Scripted log behaviour: receives each request's options. Default: an empty, finished stream.
    var logsHandler: (@Sendable (LogOptions) -> AsyncThrowingStream<String, Error>)?
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> {
        if let h = lock.withLock({ logsHandler }) { return h(options) }
        return AsyncThrowingStream { $0.finish() }
    }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] {
        guard let namespace, let r = lock.withLock({ metricsByNamespace[namespace] }) else { return [] }
        return try r.get()
    }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("scripted") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("scripted") }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}

@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

// MARK: - ResourceStore

@MainActor @Suite struct FixStoreTests {
    @Test func pauseKeepsConsumersAndResumeRestartsTheWatch() async {
        let client = ScriptedClient()
        let store = ResourceStore<Pod>(client: client)
        store.start()
        #expect(await waitUntil { store.phase == .loaded && client.watches == 1 })
        #expect(store.items.count == 2)

        store.pause()
        #expect(store.consumerCount == 1)          // the screen is still registered
        #expect(!store.isLive)
        store.resume()
        #expect(await waitUntil { client.watches == 2 })
        #expect(store.isLive)

        // A second consumer coming and going must not stop the first one's watch.
        store.start(); store.stop()
        #expect(store.consumerCount == 1)
        #expect(store.isLive)
        store.stop()
        #expect(store.consumerCount == 0)
        #expect(store.idleSince != nil)
    }

    @Test func startWhilePausedWaitsForResume() async {
        let client = ScriptedClient()
        let store = ResourceStore<Pod>(client: client)
        store.pause()
        store.start()
        try? await Task.sleep(for: .milliseconds(150))
        #expect(client.lists == 0)
        store.resume()
        #expect(await waitUntil { store.phase == .loaded })
        store.invalidate()
        #expect(store.consumerCount == 0)
    }

    @Test func goneTriggersRelist() async {
        let client = ScriptedClient()
        client.watchMode = .goneOnce
        let store = ResourceStore<Pod>(client: client)
        store.start()
        #expect(await waitUntil { client.lists >= 2 && client.watches >= 2 })
        #expect(store.items.count == 2)
        store.stop()
    }

    @Test func watchThatClosesImmediatelyBacksOff() async {
        let client = ScriptedClient()
        client.watchMode = .closeImmediately
        let store = ResourceStore<Pod>(client: client)
        store.start()
        try? await Task.sleep(for: .milliseconds(1300))
        store.stop()
        #expect(client.watches <= 3, "reflector spun \(client.watches) times in 1.3 s")
    }

    @Test func refreshWaitsForTheList() async {
        let client = ScriptedClient()
        client.listDelay = .milliseconds(200)
        let store = ResourceStore<Pod>(client: client)
        store.start()
        #expect(await waitUntil { store.phase == .loaded })
        let clock = ContinuousClock()
        let start = clock.now
        await store.refresh()
        #expect(clock.now - start >= .milliseconds(150))
        #expect(store.phase == .loaded)
        store.stop()
    }
}

// MARK: - Session health

@MainActor @Suite struct FixSessionTests {
    func session(_ client: ScriptedClient, env: ClusterEnvironment = .development) -> ClusterSession {
        ClusterSession(config: ClusterConfig(id: "s1", name: "s1", server: URL(string: "https://s1")!, environment: env), client: client)
    }

    @Test func forbiddenPodsListIsPartialNotHealthy() async {
        let client = ScriptedClient()
        client.podsError = .forbidden(verb: "list", resource: "pods", namespace: nil, message: "forbidden")
        let h = await session(client).refreshHealth()
        #expect(h.isReachable)
        #expect(h.isPartial)
        #expect(h.failedKinds.contains("pods"))
        #expect(h.status != .healthy)
    }

    @Test func evaluatorMarksFailedKindsPartial() {
        var input = ClusterHealthInput(clusterID: "c", environment: .development)
        input.failedKinds = ["nodes"]
        let h = HealthEvaluator.evaluate(input)
        #expect(h.isPartial)
        #expect(h.status == .unknown)
        input.failedKinds = ["jobs"]
        #expect(HealthEvaluator.evaluate(input).status == .healthy)   // not a blind spot for pods or nodes
    }

    @Test func oneFailedProbeKeepsLastGoodHealthStale() async {
        let client = ScriptedClient()
        let s = session(client)
        await s.refreshHealth()
        #expect(s.health?.isReachable == true)
        client.versionFails = true
        await s.refreshHealth()
        #expect(s.health?.isReachable == true)
        #expect(s.health?.isStale == true)
        await s.refreshHealth()
        #expect(s.health?.isReachable == true)
        await s.refreshHealth()
        #expect(s.health?.isReachable == false)       // third failure in a row
        client.versionFails = false
        await s.refreshHealth()
        #expect(s.health?.isReachable == true)
        #expect(s.health?.isStale == false)
    }

    @Test func runningStoresReplaceHealthLists() async {
        let client = ScriptedClient()
        let s = session(client)
        let pods = s.store(for: Pod.self)
        pods.start()
        #expect(await waitUntil { pods.isLive })
        let before = client.lists
        let h = await s.refreshHealth()
        // Pods came from the store: only the small non-store lists (pvcs, namespaces) plus unstarted kinds are fetched.
        let podLists = client.lists - before
        #expect(h.counts.podsTotal == 2)
        #expect(podLists <= 8)
        pods.stop()
    }

    @Test func idleStoresAreEvicted() async {
        let s = session(ScriptedClient())
        _ = s.store(for: Pod.self)
        let busy = s.store(for: Node.self)
        busy.start()
        s.evictIdleStores(now: Date().addingTimeInterval(ClusterSession.storeIdleLifetime + 120))
        #expect(s.storeCount == 1)
        busy.stop()
    }
}

// MARK: - Registry

@MainActor @Suite struct FixRegistryTests {
    struct FailingCredentials: CredentialStoring {
        func load(clusterID: ClusterID) throws -> ClusterSecrets { throw KubeError.unreachable(cause: "keychain locked") }
        func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws {}
        func delete(clusterID: ClusterID) throws {}
    }

    func defaults() -> UserDefaults {
        let d = UserDefaults(suiteName: "wheelhouse.fixstate.\(UUID().uuidString)")!
        return d
    }

    func registry(credentials: any CredentialStoring = InMemoryCredentialStore(), d: UserDefaults? = nil) -> ClusterRegistry {
        ClusterRegistry(credentials: credentials, metadata: InMemoryMetadataStore(), defaults: d ?? defaults(),
                        clientFactory: { _, _ in ScriptedClient() })
    }

    let config = ClusterConfig(id: "r1", name: "r1", server: URL(string: "https://r1")!, authKind: .token)

    @Test func demoFlagIsPersistedAndCleared() {
        let d = defaults()
        let r = registry(d: d)
        r.enterDemoMode()
        #expect(d.bool(forKey: "demoMode"))
        r.exitDemoMode()
        #expect(!d.bool(forKey: "demoMode"))
        r.enterDemoMode(persist: false)
        #expect(!d.bool(forKey: "demoMode"))
    }

    @Test func demoModeNeverPostsAlerts() {
        #expect(!BackgroundPolicy.shouldPostAlerts(isDemoMode: true, settings: AlertSettings()))
        #expect(BackgroundPolicy.shouldPostAlerts(isDemoMode: false, settings: AlertSettings()))
        var off = AlertSettings(); off.enabled = false
        #expect(!BackgroundPolicy.shouldPostAlerts(isDemoMode: false, settings: off))
    }

    @Test func metadataOnlyUpdateKeepsTheSessionAndPosts() throws {
        let r = registry()
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        let s1 = try #require(r.session(for: "r1"))
        let posted = Counter()
        let token = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: nil) { note in
            if ClusterEvents.clusterID(from: note) == "r1" { posted.bump() }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        var renamed = config; renamed.name = "renamed"
        try r.update(renamed)
        #expect(r.session(for: "r1") === s1)
        #expect(s1.config.name == "renamed")

        var moved = renamed; moved.server = URL(string: "https://elsewhere")!
        try r.update(moved)
        #expect(r.session(for: "r1") !== s1)
        #expect(posted.value == 2)
    }

    @Test func removePostsAndDropsSession() throws {
        let r = registry()
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        _ = r.session(for: "r1")
        let removedPosts = Counter()
        let token = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: nil) { note in
            if ClusterEvents.clusterID(from: note) == "r1", ClusterEvents.wasRemoved(note) { removedPosts.bump() }
        }
        defer { NotificationCenter.default.removeObserver(token) }
        try r.remove(id: "r1")
        #expect(removedPosts.value == 1)
        #expect(r.session(for: "r1") == nil)
    }

    @Test func sessionFromFailedCredentialReadIsNotCached() throws {
        let r = registry(credentials: FailingCredentials())
        r.transientSessionLifetime = 0
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        let a = try #require(r.session(for: "r1"))
        let b = try #require(r.session(for: "r1"))
        #expect(a !== b)

        let r2 = registry()
        r2.transientSessionLifetime = 0
        try r2.add(config, secrets: ClusterSecrets())          // token cluster with no token
        #expect(r2.session(for: "r1") !== r2.session(for: "r1"))
    }

    @Test func alwaysAllNamespacesIgnoresRememberedSelection() throws {
        let d = defaults()
        let r1 = registry(d: d)
        var c = config; c.defaultNamespace = "shop"
        try r1.add(c, secrets: ClusterSecrets(token: "t"))
        #expect(r1.namespace(for: "r1") == "shop")
        d.set(NamespaceBehavior.alwaysAll.rawValue, forKey: "namespaceBehavior")
        #expect(r1.namespace(for: "r1") == nil)
        r1.setNamespace("payments", for: "r1")
        #expect(r1.namespace(for: "r1") == "payments")   // an explicit pick in this launch still applies
    }

    @Test func namespaceSelectionPersistsAndStaysBackwardCompatible() throws {
        let d = defaults()
        d.set(["r1": "shop", "r2": "*"], forKey: "namespaceSelections")          // what every earlier version wrote
        let r = registry(d: d)
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        #expect(r.namespaceSelection(for: "r1") == .namespaces(["shop"]))
        #expect(r.namespace(for: "r1") == "shop")
        #expect(r.namespaceSelection(for: "r2") == .all)
        r.setNamespaceSelection(NamespaceSelection(names: ["web", "payments"]), for: "r1")
        #expect(r.namespace(for: "r1") == nil)                                   // several: no single namespace
        #expect(r.namespaceSelection(for: "r1").names == ["payments", "web"])
        #expect((d.dictionary(forKey: "namespaceSelections") as? [String: String])?["r1"] == "payments,web")
        let reloaded = registry(d: d)
        #expect(reloaded.namespaceSelection(for: "r1").names == ["payments", "web"])
        r.setNamespace("web", for: "r1")                                         // a single pick replaces the set
        #expect(r.namespace(for: "r1") == "web")
        #expect((d.dictionary(forKey: "namespaceSelections") as? [String: String])?["r1"] == "web")
        r.setNamespace(nil, for: "r1")
        #expect(r.namespaceSelection(for: "r1") == .all)
    }

    @Test func multiSelectionIsAllUnderAlwaysAllUntilPicked() throws {
        let d = defaults()
        let r = registry(d: d)
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        r.setNamespaceSelection(NamespaceSelection(names: ["a", "b"]), for: "r1")
        d.set(NamespaceBehavior.alwaysAll.rawValue, forKey: "namespaceBehavior")
        let fresh = registry(d: d)
        #expect(fresh.namespaceSelection(for: "r1") == .all)
        fresh.setNamespaceSelection(NamespaceSelection(names: ["a", "b"]), for: "r1")
        #expect(fresh.namespaceSelection(for: "r1").names == ["a", "b"])
    }

    @Test func clusterWithoutHealthIsNotOfflineOrAttention() throws {
        let r = registry(d: defaults())
        try r.add(config, secrets: ClusterSecrets(token: "t"))   // no session / health yet (e.g. just left Demo mode)
        let snap = r.makeSnapshot()
        let e = try #require(snap.clusters.first { $0.id == "r1" })
        #expect(e.isReachable)
        #expect(e.status == .unknown)
        #expect(e.isNotLoaded)
        #expect(e.statusWord != "Unreachable")
        #expect(snap.needAttentionCount == 0)
        #expect(e.attentionRank == HealthStatus.unknown.rank)
        // A previous non-demo snapshot's last known entry is preferred over a blank one.
        let known = FleetSnapshot.ClusterEntry(id: "r1", name: "old", environment: .production, status: .critical, nodesReady: 2, nodesTotal: 3, failingPods: 1)
        let kept = r.makeSnapshot(previous: FleetSnapshot(isDemo: false, clusters: [known])).clusters.first
        #expect(kept?.status == .critical && kept?.nodesTotal == 3 && kept?.name == config.name)
        let demoPrev = r.makeSnapshot(previous: FleetSnapshot(isDemo: true, clusters: [known])).clusters.first
        #expect(demoPrev?.isNotLoaded == true)
    }

    @Test func timedOutClusterIsOfflineViaFallbackHealth() throws {
        let r = registry(d: defaults())
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        let h = ClusterHealth.unreachable(clusterID: "r1", environment: config.environment, cause: "Timed out")
        let e = try #require(r.makeSnapshot(fallbackHealth: ["r1": h]).clusters.first)
        #expect(!e.isReachable && !e.isNotLoaded)
        let snap = r.makeSnapshot()
        #expect(snap.title == "1 cluster · 1 not loaded" && snap.shortTitle == "1 not loaded")
        // A reused previous entry keeps the older timestamp.
        let old = Date(timeIntervalSinceNow: -3 * 3600)
        let prev = FleetSnapshot(generatedAt: old, isDemo: false, clusters: [.init(id: "r1", name: "r1", environment: .production, status: .healthy)])
        #expect(r.makeSnapshot(previous: prev).generatedAt == old)
    }

    @Test func previousUnreachableEntryIsKeptAndUnknownStatusCounts() throws {
        let r = registry(d: defaults())
        try r.add(config, secrets: ClusterSecrets(token: "t"))
        let off = FleetSnapshot.ClusterEntry(id: "r1", name: "r1", environment: .production, status: .unknown, isReachable: false)
        let kept = try #require(r.makeSnapshot(previous: FleetSnapshot(isDemo: false, clusters: [off])).clusters.first)
        #expect(!kept.isReachable && !kept.isNotLoaded)
        // A previous not-loaded entry is not reused.
        let nl = FleetSnapshot.ClusterEntry(id: "r1", name: "r1", environment: .production, status: .unknown, notLoaded: true)
        #expect(try #require(r.makeSnapshot(previous: FleetSnapshot(isDemo: false, clusters: [nl])).clusters.first).isNotLoaded)
        // Reachable but `.unknown` (blind) is neither healthy nor needing attention.
        let blind = FleetSnapshot(clusters: [.init(id: "a", name: "a", environment: .production, status: .unknown, nodesTotal: 3),
                                             .init(id: "b", name: "b", environment: .production, status: .healthy),
                                             .init(id: "c", name: "c", environment: .production, status: .unknown, notLoaded: true)])
        #expect(blind.needAttentionCount == 0 && blind.unknownStatusCount == 1 && blind.unknownCount == 1)
        #expect(blind.title == "3 clusters · 1 not loaded · 1 unknown" && blind.shortTitle == "1 not loaded · 1 unknown")
        #expect(FleetSnapshot(clusters: [.init(id: "a", name: "a", environment: .production, status: .unknown, nodesTotal: 3)]).title == "1 cluster · 1 unknown")
    }

    @Test func makeSnapshotCarriesUsageNodeCPUAndRestarts() async {
        let r = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: defaults())
        r.enterDemoMode(persist: false)
        await r.refreshAllHealth()
        let prod = DemoFleet.prodID
        var usage = ClusterUsage()
        usage.cpuAllocatable = 10; usage.cpuUsage = 4; usage.memAllocatable = 100; usage.memUsage = 50
        let snap = r.makeSnapshot(usage: [prod: usage], nodeCPU: [prod: [0.2, 0.9]])
        let entry = snap.clusters.first { $0.id == prod }
        #expect(entry?.cpuFraction == 0.4)
        #expect(entry?.memoryFraction == 0.5)
        #expect(entry?.nodeCPU == [0.2, 0.9])
        #expect(snap.isDemo)
        #expect((entry?.failingPodList ?? []).contains { $0.restarts > 0 })
        #expect(snap.clusters.first { $0.id == DemoFleet.stagingID }?.cpuFraction == nil)
    }
}

// MARK: - Alert planning

@Suite struct FixAlertTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func item(_ kind: AttentionKind, name: String = "api", restarts: Int = 0, title: String = "CrashLoopBackOff") -> AttentionItem {
        AttentionItem(id: "c1/\(name)", clusterID: "c1", severity: .critical, kind: kind, title: title, detail: "\(name) detail",
                      resource: ResourceRef(clusterID: "c1", kind: .pod, namespace: "shop", name: name), since: nil, restarts: restarts)
    }
    func health(_ items: [AttentionItem], reachable: Bool = true, partial: Bool = false) -> ClusterHealth {
        ClusterHealth(clusterID: "c1", status: reachable ? .critical : .unknown, isReachable: reachable, items: items, counts: ClusterCounts(), updatedAt: now,
                      isPartial: partial, failedKinds: partial ? ["pods"] : [])
    }
    func plan(_ h: [ClusterHealth], state: AlertState = AlertState(), at time: Date? = nil, settings: AlertSettings = AlertSettings()) -> AlertPlan {
        AlertPlanner.plan(health: h, clusterNames: ["c1": "prod"], settings: settings, state: state, now: time ?? now)
    }

    @Test func timedOutClusterKeepsNotifiedState() {
        let first = plan([health([item(.crashLoop)])])
        #expect(first.toPost.count == 1)
        let timedOut = plan([ClusterHealth.unreachable(clusterID: "c1", environment: .production, cause: "Timed out", now: now)], state: first.newState)
        #expect(timedOut.resolved.isEmpty)
        #expect(timedOut.newState.notified.keys.contains { $0.contains("crashLoop") })
        // Back and still failing: no second notification.
        #expect(plan([health([item(.crashLoop)])], state: timedOut.newState).toPost.isEmpty)
    }

    @Test func partialClusterDoesNotResolveAlerts() {
        let first = plan([health([item(.crashLoop)])])
        let partial = plan([health([], partial: true)], state: first.newState)
        #expect(partial.resolved.isEmpty)
        #expect(partial.newState.notified == first.newState.notified)
        // A complete, empty result later resolves it (after the crash-loop grace).
        let done = plan([health([])], state: partial.newState, at: now.addingTimeInterval(AlertPlanner.crashLoopRecoveryGrace * 2))
        #expect(!done.resolved.isEmpty)
    }

    @Test func oomKilledCrashLoopAlerts() {
        let p = plan([health([item(.oomKilled, title: "CrashLoopBackOff · OOMKilled")])])
        #expect(p.toPost.count == 1)
        #expect(p.toPost[0].rule == .crashLoop)
        #expect(p.toPost[0].level == .timeSensitive)
        // Same pod flipping its title or kind does not re-notify.
        let again = plan([health([item(.crashLoop)])], state: p.newState)
        #expect(again.toPost.isEmpty)
    }

    @Test func crashLoopAlertsAgainOnlyAfterThreeMoreRestarts() {
        let first = plan([health([item(.crashLoop, restarts: 5)])])
        #expect(first.toPost.count == 1)
        let two = plan([health([item(.crashLoop, restarts: 7)])], state: first.newState)
        #expect(two.toPost.isEmpty)
        let three = plan([health([item(.crashLoop, restarts: 8)])], state: two.newState)
        #expect(three.toPost.count == 1)
        #expect(three.toPost[0].body.contains("+3"))
        #expect(three.newState.restarts.values.contains(8))
    }

    @Test func crashLoopFlappingWithinGraceDoesNotRenotify() {
        let first = plan([health([item(.crashLoop, restarts: 5)])])
        let gap = plan([health([])], state: first.newState, at: now.addingTimeInterval(300))
        #expect(gap.resolved.isEmpty)
        #expect(plan([health([item(.crashLoop, restarts: 5)])], state: gap.newState, at: now.addingTimeInterval(600)).toPost.isEmpty)
    }

    @Test func oldAlertStateStillDecodes() throws {
        let json = #"{"notified":{"c1|crashLoop|shop|api":0},"unreachableStreak":{"c1":2}}"#
        let state = try JSONDecoder().decode(AlertState.self, from: Data(json.utf8))
        #expect(state.notified.count == 1)
        #expect(state.restarts.isEmpty)
    }

    @Test func alertSettingsSaveAndLoadUseTheSameKeys() throws {
        let d = try #require(UserDefaults(suiteName: "wheelhouse.fixstate.keys.\(UUID().uuidString)"))
        var s = AlertSettings()
        s.setRule(.unreachable, on: true)
        s.setRule(.crashLoop, on: false)
        s.setEnabled(false, clusterID: "c9")
        s.quietHoursEnabled = true
        s.quietStartMinutes = 60
        s.quietEndMinutes = 120
        s.save(to: d)
        #expect(AlertSettings.load(from: d) == s)
        // And the raw keys are the documented `AlertKeys`.
        #expect(d.bool(forKey: AlertKeys.ruleUnreachable))
        #expect(!d.bool(forKey: AlertKeys.ruleCrashLoop))
        #expect(d.stringArray(forKey: AlertKeys.disabledClusterIDs) == ["c9"])
        #expect(d.integer(forKey: AlertKeys.quietStartMinutes) == 60)
    }

    @MainActor @Test func secretRevealGateHonoursThePreference() async {
        let gate = SecretRevealGate()
        var prompts = 0
        let auth: () async -> Bool = { prompts += 1; return true }
        _ = await gate.authorize(oncePerSession: true, authenticate: auth)
        _ = await gate.authorize(oncePerSession: true, authenticate: auth)
        #expect(prompts == 1)
        _ = await gate.authorize(oncePerSession: false, authenticate: auth)
        #expect(prompts == 2)
        gate.reset()
        _ = await gate.authorize(oncePerSession: true, authenticate: auth)
        #expect(prompts == 3)
    }
}
