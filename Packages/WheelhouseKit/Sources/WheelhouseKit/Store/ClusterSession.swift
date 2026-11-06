import Foundation
import Observation

public enum ConnectionState: Sendable, Equatable {
    case unknown
    case connecting
    case connected
    case failed(KubeError)

    public var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// Runtime state for one cluster: owns the client, discovery cache, health summary and shared ResourceStores.
@MainActor @Observable
public final class ClusterSession: Identifiable {
    public private(set) var config: ClusterConfig
    @ObservationIgnored public let client: any KubeClientProtocol
    @ObservationIgnored public let discoveryCache = DiscoveryCache()

    public private(set) var connection: ConnectionState = .unknown
    public private(set) var version: KubeVersion?
    /// Round-trip time of the last `/version` probe.
    public private(set) var latency: Duration?
    public private(set) var health: ClusterHealth?
    public private(set) var metricsAvailability: MetricsAvailability?
    public private(set) var prometheusEndpoint: PrometheusEndpoint?
    public private(set) var discovery: DiscoveryInfo?
    public private(set) var lastHealthRefresh: Date?
    /// Nodes and recent Warning events (24 h, newest first, max 60) from the last health pass, so the Fleet dashboard
    /// does not list them a second time.
    public private(set) var lastNodes: [Node] = []
    public private(set) var lastWarningEvents: [KubeEvent] = []

    @ObservationIgnored private var stores: [String: AnyObject] = [:]
    @ObservationIgnored private var cachedMetrics: MetricsService?
    @ObservationIgnored private var consecutiveProbeFailures = 0
    @ObservationIgnored private var lastEviction = Date()
    /// Stores nobody has used for this long are dropped (their cached items go with them).
    static let storeIdleLifetime: TimeInterval = 5 * 60
    static let probeFailuresBeforeUnreachable = 3

    public nonisolated var id: ClusterID { clusterID }
    private nonisolated let clusterID: ClusterID

    public init(config: ClusterConfig, client: any KubeClientProtocol) {
        self.config = config
        self.clusterID = config.id
        self.client = client
    }

    /// True when the cluster needs credentials that are not stored on this device (see `ClusterSecrets.isMissingCredentials`).
    /// Such sessions are never cached by the registry; UI shows "Credentials not on this device" instead of unreachable/unauthorized.
    public internal(set) var credentialsMissing = false
    public var status: HealthStatus { health?.status ?? .unknown }
    public var isReadOnly: Bool { config.readOnly }
    /// Built once (with the Prometheus bearer token, if the user stored one) and rebuilt by ``update(config:)``.
    public var metrics: MetricsService {
        if let cachedMetrics { return cachedMetrics }
        let token = (config.prometheusURL != nil && !config.isDemo) ? PrometheusTokenStore.load(clusterID: config.id) : nil
        let service = MetricsService(client: client, prometheusURL: config.prometheusURL, prometheusToken: token)
        cachedMetrics = service
        return service
    }

    // MARK: Stores

    /// Shared, reference-counted store. Same arguments return the same instance, so screens share one watch.
    ///
    ///     let pods = session.store(for: Pod.self, namespace: ns)
    ///     .task { await pods.run() }
    public func store<T: KubeObject>(for type: T.Type, namespace: String? = nil, labelSelector: String? = nil, fieldSelector: String? = nil) -> ResourceStore<T> {
        let key = "\(T.resourceKind.id)|\(namespace ?? "*")|\(labelSelector ?? "")|\(fieldSelector ?? "")"
        if let existing = stores[key] as? ResourceStore<T> { return existing }
        evictIdleStores()
        let s = ResourceStore<T>(client: client, namespace: namespace, labelSelector: labelSelector, fieldSelector: fieldSelector)
        stores[key] = s
        return s
    }

    /// Store for any kind as raw objects (custom resources, generic lists).
    public func unstructuredStore(kind: ResourceKind, namespace: String? = nil, labelSelector: String? = nil, fieldSelector: String? = nil) -> ResourceStore<Unstructured> {
        let key = "U|\(kind.id)|\(namespace ?? "*")|\(labelSelector ?? "")|\(fieldSelector ?? "")"
        if let existing = stores[key] as? ResourceStore<Unstructured> { return existing }
        evictIdleStores()
        let s = ResourceStore<Unstructured>(client: client, kind: kind, namespace: kind.namespaced ? namespace : nil, labelSelector: labelSelector, fieldSelector: fieldSelector)
        stores[key] = s
        return s
    }

    /// Pauses every watch (app backgrounded). Screens stay registered as consumers and cached items remain;
    /// call ``resumeAll()`` when the app is active again.
    public func stopAll() { pauseAll() }

    public func pauseAll() {
        for case let s as StoreCancellable in stores.values { s.pauseStore() }
    }

    /// Restarts the watches of stores that still have consumers.
    public func resumeAll() {
        for case let s as StoreCancellable in stores.values { s.resumeStore() }
    }

    /// Cancels every watch and drops all consumers (cluster removed, credentials replaced).
    public func invalidateAll() {
        for case let s as StoreCancellable in stores.values { s.invalidateStore() }
        stores.removeAll()
    }

    /// Drops stores with no consumers that have been idle for ``storeIdleLifetime``. Checked at most once a minute.
    func evictIdleStores(now: Date = Date()) {
        guard now.timeIntervalSince(lastEviction) >= 60 else { return }
        lastEviction = now
        stores = stores.filter { _, store in
            guard let s = store as? StoreCancellable, let idle = s.storeIdleSince else { return true }
            return now.timeIntervalSince(idle) < Self.storeIdleLifetime
        }
    }

    var storeCount: Int { stores.count }

    /// Items of an already-created store, only when it is running and fresh. Never creates a store.
    private func liveItems<T: KubeObject>(_ type: T.Type, fieldSelector: String? = nil) -> [T]? {
        let key = "\(T.resourceKind.id)|*||\(fieldSelector ?? "")"
        guard let s = stores[key] as? ResourceStore<T>, s.isLive else { return nil }
        return s.items
    }

    // MARK: Connection & health

    /// Probes `/version` and records latency; updates ``connection``.
    @discardableResult
    public func connect() async -> ConnectionState {
        connection = .connecting
        let clock = ContinuousClock()
        let start = clock.now
        do {
            version = try await client.version()
            latency = clock.now - start
            connection = .connected
        } catch let e as KubeError {
            connection = .failed(e)
        } catch {
            connection = .failed(.unreachable(cause: error.localizedDescription))
        }
        return connection
    }

    /// Probes `/version`, then builds the health input: from running ResourceStores where they are live (no extra requests),
    /// otherwise from one-shot lists (best effort per kind). A failed probe keeps the last good result, marked stale,
    /// until ``probeFailuresBeforeUnreachable`` probes in a row have failed.
    @discardableResult
    public func refreshHealth() async -> ClusterHealth {
        let probe = await connect()
        if case .failed(let error) = probe {
            if error == .cancelled || Task.isCancelled {
                return health ?? ClusterHealth.unreachable(clusterID: config.id, environment: config.environment, cause: "Timed out")
            }
            consecutiveProbeFailures += 1
            if consecutiveProbeFailures < Self.probeFailuresBeforeUnreachable, var last = health, last.isReachable {
                last.isStale = true
                health = last
                return last
            }
            let h = ClusterHealth.unreachable(clusterID: config.id, environment: config.environment, cause: error.summary)
            health = h
            lastHealthRefresh = Date()
            return h
        }
        consecutiveProbeFailures = 0
        let snapshot = await fetchHealthInput()
        if Task.isCancelled { return health ?? ClusterHealth.unreachable(clusterID: config.id, environment: config.environment, cause: "Timed out") }
        let h = HealthEvaluator.evaluate(snapshot)
        health = h
        lastHealthRefresh = Date()
        return h
    }

    private func fetchHealthInput() async -> ClusterHealthInput {
        let client = self.client
        var input = ClusterHealthInput(clusterID: config.id, environment: config.environment)
        let warning = "type=Warning"
        let livePods = liveItems(Pod.self), liveNodes = liveItems(Node.self), liveDeployments = liveItems(Deployment.self)
        let liveStateful = liveItems(StatefulSet.self), liveDaemon = liveItems(DaemonSet.self), liveJobs = liveItems(Job.self)
        let liveEvents = liveItems(KubeEvent.self, fieldSelector: warning)
        async let pods: [Pod]? = livePods != nil ? livePods : (try? await client.list(Pod.self).items)
        async let nodes: [Node]? = liveNodes != nil ? liveNodes : (try? await client.list(Node.self).items)
        async let deployments: [Deployment]? = liveDeployments != nil ? liveDeployments : (try? await client.list(Deployment.self).items)
        async let statefulSets: [StatefulSet]? = liveStateful != nil ? liveStateful : (try? await client.list(StatefulSet.self).items)
        async let daemonSets: [DaemonSet]? = liveDaemon != nil ? liveDaemon : (try? await client.list(DaemonSet.self).items)
        async let jobs: [Job]? = liveJobs != nil ? liveJobs : (try? await client.list(Job.self).items)
        async let pvcs: [PersistentVolumeClaim]? = try? await client.list(PersistentVolumeClaim.self).items
        async let namespaces: [Namespace]? = try? await client.list(Namespace.self).items
        async let events: [KubeEvent]? = liveEvents != nil ? liveEvents : (try? await client.list(KubeEvent.self, options: ListOptions(fieldSelector: warning, limit: 500)).items)
        let (p, n, d, ss, ds, j) = await (pods, nodes, deployments, statefulSets, daemonSets, jobs)
        let (pv, ns, ev) = await (pvcs, namespaces, events)
        func take<T>(_ value: [T]?, _ name: String) -> [T] {
            if value == nil { input.failedKinds.insert(name) }
            return value ?? []
        }
        input.pods = take(p, "pods")
        input.nodes = take(n, "nodes")
        input.deployments = take(d, "deployments")
        input.statefulSets = take(ss, "statefulsets")
        input.daemonSets = take(ds, "daemonsets")
        input.jobs = take(j, "jobs")
        input.pvcs = take(pv, "persistentvolumeclaims")
        input.namespaceCount = take(ns, "namespaces").count
        let recent = take(ev, "events")
        let cutoff = Date().addingTimeInterval(-3600)
        input.warningEventCount = recent.filter { ($0.lastSeen ?? .distantPast) > cutoff }.count
        lastNodes = input.nodes
        let day = Date().addingTimeInterval(-24 * 3600)
        lastWarningEvents = Array(recent.filter { ($0.lastSeen ?? .distantPast) > day }.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }.prefix(60))
        return input
    }

    /// CPU / memory usage and per-node CPU fractions from the nodes of the last health pass plus one `nodeMetrics()` call.
    /// Used by the Fleet dashboard and the background refresh; `nil` when no nodes are known.
    public func usageSummary(includeMetrics: Bool = true) async -> (usage: ClusterUsage, nodeCPU: [Double])? {
        let nodes = lastNodes
        guard !nodes.isEmpty else { return nil }
        let metrics = includeMetrics ? try? await client.nodeMetrics() : nil
        let usage = ClusterUsage.compute(nodes: nodes, nodeMetrics: metrics, pods: nil)
        var nodeCPU: [Double] = []
        if let metrics {
            let used = Dictionary(metrics.map { ($0.metadata.name, $0.cpuCores) }, uniquingKeysWith: { a, _ in a })
            nodeCPU = nodes.compactMap { n in
                let alloc = n.status?.allocatable?["cpu"]?.cores ?? n.status?.capacity?["cpu"]?.cores ?? 0
                guard alloc > 0, let u = used[n.metadata.name] else { return nil }
                return min(u / alloc, 1)
            }
        }
        return (usage, nodeCPU)
    }

    /// Fetches discovery (cached) and, once, detects metrics sources.
    public func loadDiscovery(forceRefresh: Bool = false) async {
        discovery = try? await discoveryCache.info(using: client, forceRefresh: forceRefresh)
    }

    public func detectMetrics() async {
        let service = metrics
        var (availability, endpoint) = await service.availability()
        // A user-supplied URL is returned unverified by the service: check it before trusting it.
        if let ep = endpoint, case .url = ep, !(await service.prometheus(ep).isReady()) {
            endpoint = nil
            availability = availability == .both ? .metricsServer : (availability == .prometheus ? .none : availability)
        }
        metricsAvailability = availability
        prometheusEndpoint = endpoint
    }

    /// Cached kind list for the Resources tab: built-ins plus discovered custom resources.
    public var customKinds: [ResourceKind] { discovery?.customKinds ?? [] }

    /// Metadata-only change (name, colour, default namespace, Prometheus URL, …): keeps the client and stores.
    func update(config: ClusterConfig) {
        let prometheusChanged = self.config.prometheusURL != config.prometheusURL
        self.config = config
        cachedMetrics = nil
        if prometheusChanged { metricsAvailability = nil; prometheusEndpoint = nil }
    }
}

@MainActor protocol StoreCancellable {
    func pauseStore()
    func resumeStore()
    func invalidateStore()
    var storeIdleSince: Date? { get }
}
extension ResourceStore: StoreCancellable {
    func pauseStore() { pause() }
    func resumeStore() { resume() }
    func invalidateStore() { invalidate() }
    var storeIdleSince: Date? { idleSince }
}
