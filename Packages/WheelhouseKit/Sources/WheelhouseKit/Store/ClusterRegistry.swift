import Foundation
import Observation

/// App-wide list of clusters, the current selection, and the per-cluster sessions.
@MainActor @Observable
public final class ClusterRegistry {
    public typealias ClientFactory = @Sendable (ClusterConfig, ClusterSecrets) -> any KubeClientProtocol

    private var realClusters: [ClusterConfig]
    private var demoClusters: [ClusterConfig] = []
    public private(set) var isDemoMode = false
    public private(set) var lastError: String?
    /// Called after a cluster was removed (its id) or Demo mode was left (nil), so the app can drop it from the widget snapshot.
    @ObservationIgnored public var onFleetShrank: (@MainActor (ClusterID?) -> Void)?

    /// Clusters currently shown: demo fleet in demo mode, otherwise the user's clusters (pinned order = array order).
    public var clusters: [ClusterConfig] { isDemoMode ? demoClusters : realClusters }

    public var currentClusterID: ClusterID? {
        didSet { defaults.set(currentClusterID, forKey: "currentClusterID") }
    }

    /// Namespace chosen per cluster; absent = use the cluster default. `nil` namespace means "All namespaces".
    private var namespaceSelections: [ClusterID: String]

    @ObservationIgnored private var sessions: [ClusterID: ClusterSession] = [:]
    /// Sessions built without usable credentials are not cached for long, so a keychain that was locked at launch
    /// (or a re-saved credential) is picked up on the next access instead of sticking forever.
    @ObservationIgnored private var transientSessions: [ClusterID: (session: ClusterSession, created: Date)] = [:]
    @ObservationIgnored var transientSessionLifetime: TimeInterval = 5
    /// Clusters whose namespace the user picked in this launch; with "Always All namespaces" only these use a selection.
    @ObservationIgnored private var touchedNamespaces: Set<ClusterID> = []
    @ObservationIgnored private let credentials: any CredentialStoring
    @ObservationIgnored private let metadata: any ClusterMetadataStoring
    @ObservationIgnored private let clientFactory: ClientFactory
    @ObservationIgnored private let defaults: UserDefaults
    /// True while the app is in the background (watches paused).
    @ObservationIgnored private var isSuspended = false

    private static let allNamespaces = "*"

    public init(credentials: any CredentialStoring = KeychainCredentialStore(),
                metadata: any ClusterMetadataStoring = ClusterMetadataStore(),
                defaults: UserDefaults = AppGroup.defaults,
                clientFactory: @escaping ClientFactory = ClusterRegistry.defaultClientFactory) {
        self.credentials = credentials
        self.metadata = metadata
        self.defaults = defaults
        self.clientFactory = clientFactory
        self.realClusters = metadata.load()
        let alwaysAll = defaults.string(forKey: "namespaceBehavior") == NamespaceBehavior.alwaysAll.rawValue
        self.namespaceSelections = alwaysAll ? [:] : ((defaults.dictionary(forKey: "namespaceSelections") as? [String: String]) ?? [:])
        let saved = defaults.string(forKey: "currentClusterID")
        self.currentClusterID = realClusters.contains { $0.id == saved } ? saved : realClusters.first?.id
    }

    nonisolated public static let defaultClientFactory: ClientFactory = { config, secrets in
        config.isDemo ? DemoFleet.client(for: config) : LiveKubeClient(config: config, secrets: secrets, tlsServerName: config.tlsServerName)
    }

    /// Registry with in-memory stores, already in demo mode. For previews and tests.
    public static func preview(demo: Bool = true) -> ClusterRegistry {
        let r = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(),
                                defaults: UserDefaults(suiteName: "wheelhouse.preview") ?? .standard)
        if demo { r.enterDemoMode() }
        return r
    }

    // MARK: Selection

    public var currentCluster: ClusterConfig? { clusters.first { $0.id == currentClusterID } ?? clusters.first }
    public var currentSession: ClusterSession? { currentCluster.flatMap { session(for: $0.id) } }

    /// "Always All namespaces" (Settings): start every launch in All namespaces; a pick made in this launch still applies.
    private var alwaysAllNamespaces: Bool { defaults.string(forKey: "namespaceBehavior") == NamespaceBehavior.alwaysAll.rawValue }

    public func namespace(for clusterID: ClusterID) -> String? {
        if alwaysAllNamespaces && !touchedNamespaces.contains(clusterID) { return nil }
        if let selection = namespaceSelections[clusterID] { return selection == Self.allNamespaces ? nil : selection }
        return clusters.first { $0.id == clusterID }?.defaultNamespace
    }

    public func setNamespace(_ namespace: String?, for clusterID: ClusterID) {
        touchedNamespaces.insert(clusterID)
        namespaceSelections[clusterID] = namespace ?? Self.allNamespaces
        defaults.set(namespaceSelections, forKey: "namespaceSelections")
    }

    /// Namespace of the current cluster; `nil` = All namespaces.
    public var currentNamespace: String? {
        get { currentCluster.flatMap { namespace(for: $0.id) } }
        set { if let id = currentCluster?.id { setNamespace(newValue, for: id) } }
    }

    public func select(_ id: ClusterID) {
        guard clusters.contains(where: { $0.id == id }) else { return }
        currentClusterID = id
        if EnergyPolicy.current.suspendsHiddenWatches { applyEnergyPolicy() }
    }

    // MARK: Sessions

    public func config(for id: ClusterID) -> ClusterConfig? { clusters.first { $0.id == id } }

    public func session(for id: ClusterID) -> ClusterSession? {
        if let s = sessions[id] { return s }
        if let t = transientSessions[id] {
            if Date().timeIntervalSince(t.created) < transientSessionLifetime { return t.session }
            t.session.invalidateAll()
            transientSessions[id] = nil
        }
        guard let config = config(for: id) else { return nil }
        var credentialsUsable = true
        var missing = false
        var problem: String?
        let secrets: ClusterSecrets
        do { secrets = try credentials.load(clusterID: id) } catch KeychainError.unreadable {
            secrets = ClusterSecrets(); credentialsUsable = false; problem = KeychainError.unreadable.errorDescription
        } catch { secrets = ClusterSecrets(); credentialsUsable = false }
        if !config.isDemo && credentialsUsable && secrets.isMissingCredentials(for: config.authKind) { missing = true; credentialsUsable = false }
        if secrets.isEmpty && config.authKind != .none && !config.isDemo { credentialsUsable = false }
        let s = ClusterSession(config: config, client: clientFactory(config, secrets))
        s.credentialsMissing = missing
        s.credentialsProblem = problem
        if credentialsUsable { sessions[id] = s } else { transientSessions[id] = (s, Date()) }
        return s
    }

    /// Sessions for every cluster in display order.
    public var allSessions: [ClusterSession] { clusters.compactMap { session(for: $0.id) } }

    public func health(for id: ClusterID) -> ClusterHealth? { sessions[id]?.health }

    /// Refreshes health for every cluster in parallel.
    public func refreshAllHealth() async {
        let all = allSessions
        await withTaskGroup(of: Void.self) { group in
            for s in all { group.addTask { await s.refreshHealth() } }
        }
    }

    /// Memory pressure: every session drops the cached items of stores nobody is using.
    @discardableResult
    public func trimCaches() -> Int {
        var n = sessions.values.reduce(0) { $0 + $1.trimIdleCaches() }
        n += transientSessions.values.reduce(0) { $0 + $1.session.trimIdleCaches() }
        return n
    }

    public var fleetAttention: [AttentionItem] { HealthEvaluator.fleetAttention(allSessions.compactMap(\.health)) }

    /// Pauses all watches, e.g. when the app moves to the background. Screens stay registered and cached items remain;
    /// call ``resumeAllSessions()`` when the app becomes active again.
    public func stopAllSessions() {
        isSuspended = true
        sessions.values.forEach { $0.pauseAll() }
        transientSessions.values.forEach { $0.session.pauseAll() }
    }

    /// Restarts the watches paused by ``stopAllSessions()`` for every screen that is still showing them.
    /// Under thermal pressure only the current cluster's watches restart (see ``applyEnergyPolicy(_:)``).
    public func resumeAllSessions() {
        isSuspended = false
        let policy = EnergyPolicy.current
        for (id, s) in sessions where !(policy.suspendsHiddenWatches && id != currentClusterID) { s.resumeAll() }
        transientSessions.values.forEach { $0.session.resumeAll() }
    }

    /// Reacts to Low Power Mode / thermal changes: while the device is hot, watches of clusters other than the
    /// current one are suspended; they restart when it cools down. No-op while the app is in the background.
    public func applyEnergyPolicy(_ policy: EnergyPolicy = .current) {
        guard !isSuspended else { return }
        for (id, s) in sessions {
            if policy.suspendsHiddenWatches && id != currentClusterID { s.pauseAll() } else { s.resumeAll() }
        }
    }

    private func invalidateAllSessions() {
        sessions.values.forEach { $0.invalidateAll() }
        transientSessions.values.forEach { $0.session.invalidateAll() }
        sessions.removeAll()
        transientSessions.removeAll()
    }

    /// Builds the widget snapshot from current health. `usage` / `nodeCPU` come from the Fleet model or the background
    /// refresh (per cluster); clusters without an entry show no CPU / memory. A cluster with no health yet is "not loaded":
    /// status `.unknown`, reachable, no counts (never "Offline"); when `previous` (a non-demo snapshot) has its last known entry,
    /// that entry is kept instead, with the current name and environment.
    public func makeSnapshot(usage: [ClusterID: ClusterUsage] = [:], nodeCPU: [ClusterID: [Double]] = [:], previous: FleetSnapshot? = nil,
                             fallbackHealth: [ClusterID: ClusterHealth] = [:]) -> FleetSnapshot {
        var reused = false
        let entries = clusters.map { c -> FleetSnapshot.ClusterEntry in
            let h = sessions[c.id]?.health ?? transientSessions[c.id]?.session.health ?? fallbackHealth[c.id]
            if h == nil, let previous, !previous.isDemo, var last = previous.clusters.first(where: { $0.id == c.id }), last.notLoaded != true {
                last.name = c.name; last.environment = c.environment
                reused = true
                return last
            }
            let counts = h?.counts ?? ClusterCounts()
            let failing = (h?.items ?? []).filter { [.crashLoop, .oomKilled, .imagePull, .podFailed, .configError].contains($0.kind) }
            let u = usage[c.id]
            return FleetSnapshot.ClusterEntry(
                id: c.id, name: c.name, environment: c.environment, status: h?.status ?? .unknown, isReachable: h?.isReachable ?? true,
                nodesReady: counts.nodesReady, nodesTotal: counts.nodesTotal, podsRunning: counts.podsRunning, podsTotal: counts.podsTotal,
                failingPods: counts.podsFailing, cpuFraction: u?.cpuFraction, memoryFraction: u?.memFraction,
                topIssue: h?.items.first.map { "\($0.title) · \($0.detail)" },
                failingPodList: failing.prefix(6).map { FleetSnapshot.FailingPod(name: $0.resource?.name ?? $0.detail, namespace: $0.resource?.namespace ?? "", reason: $0.title, restarts: $0.restarts) },
                nodeCPU: nodeCPU[c.id] ?? [], notLoaded: h == nil ? true : nil)
        }
        // Reused last-known entries are old data: keep the older timestamp so the widget's stale dimming still works.
        let generatedAt = reused ? min(previous?.generatedAt ?? Date(), Date()) : Date()
        return FleetSnapshot(generatedAt: generatedAt, isDemo: isDemoMode, clusters: entries)
    }

    // MARK: Mutations

    public func add(_ config: ClusterConfig, secrets: ClusterSecrets) throws {
        var config = config
        config.modifiedAt = Date()
        try credentials.save(secrets, clusterID: config.id, synchronizable: config.iCloudSync)
        realClusters.append(config)
        try persist()
        if currentClusterID == nil { currentClusterID = config.id }
    }

    /// Updates metadata and, when given, replaces credentials. A metadata-only change (name, colour, namespace, Prometheus URL,
    /// iCloud flag) keeps the session and its stores; anything the client is built from drops the session so a new client is made.
    /// Posts ``ClusterEvents/invalidated``.
    public func update(_ config: ClusterConfig, secrets: ClusterSecrets? = nil) throws {
        guard let i = realClusters.firstIndex(where: { $0.id == config.id }) else { return }
        let old = realClusters[i]
        var config = config
        config.modifiedAt = Date()
        if secrets != nil || old.iCloudSync != config.iCloudSync {
            let existing = try secrets ?? credentials.load(clusterID: config.id)
            do {
                try credentials.save(existing, clusterID: config.id, synchronizable: config.iCloudSync)
            } catch {
                // Never leave the cluster without credentials because a keychain write failed.
                try? credentials.save(existing, clusterID: config.id, synchronizable: old.iCloudSync)
                throw error
            }
            if old.iCloudSync != config.iCloudSync, !config.isDemo, let token = PrometheusTokenStore.load(clusterID: config.id) {
                PrometheusTokenStore.save(token, clusterID: config.id, synchronizable: config.iCloudSync)
            }
        }
        realClusters[i] = config
        if secrets != nil || Self.requiresNewClient(old, config) {
            sessions[config.id]?.invalidateAll()
            sessions[config.id] = nil
            transientSessions[config.id]?.session.invalidateAll()
            transientSessions[config.id] = nil
        } else {
            sessions[config.id]?.update(config: config)
        }
        defer { ClusterEvents.postInvalidated(config.id, removed: false) }
        try persist()
    }

    /// True when `new` differs from `old` in something the client is built from (server, TLS, auth, read-only, environment).
    static func requiresNewClient(_ old: ClusterConfig, _ new: ClusterConfig) -> Bool {
        var probe = new
        probe.name = old.name; probe.color = old.color; probe.defaultNamespace = old.defaultNamespace
        probe.pinnedNamespaces = old.pinnedNamespaces; probe.provider = old.provider; probe.region = old.region
        probe.prometheusURL = old.prometheusURL; probe.iCloudSync = old.iCloudSync; probe.modifiedAt = old.modifiedAt
        probe.unknownColorRaw = old.unknownColorRaw   // cosmetic: never a reason to rebuild the client
        return probe != old
    }

    public func remove(id: ClusterID) throws {
        var removed = false
        defer { ClusterEvents.postInvalidated(id, removed: removed); if removed { onFleetShrank?(id) } }
        sessions[id]?.invalidateAll()
        sessions[id] = nil
        transientSessions[id]?.session.invalidateAll()
        transientSessions[id] = nil
        try credentials.delete(clusterID: id)
        PrometheusTokenStore.delete(clusterID: id)
        realClusters.removeAll { $0.id == id }
        namespaceSelections[id] = nil
        if currentClusterID == id { currentClusterID = realClusters.first?.id }
        removed = true
        try persist()
    }

    public func move(fromOffsets: IndexSet, toOffset: Int) {
        let moving = fromOffsets.sorted().map { realClusters[$0] }
        var remaining = realClusters.enumerated().filter { !fromOffsets.contains($0.offset) }.map(\.element)
        remaining.insert(contentsOf: moving, at: toOffset - fromOffsets.filter { $0 < toOffset }.count)
        realClusters = remaining
        try? persist()
    }

    public func secrets(for id: ClusterID) -> ClusterSecrets { (try? credentials.load(clusterID: id)) ?? ClusterSecrets() }

    private func persist() throws {
        do { try metadata.save(realClusters); lastError = nil } catch { lastError = error.localizedDescription; throw error }
    }

    // MARK: Demo mode

    /// - Parameter persist: remembers Demo mode for the next launch (`demoMode` in the App Group defaults, which the
    ///   background refresh reads). Pass `false` for a launch-argument demo (screenshots, UI tests).
    public func enterDemoMode(persist: Bool = true) {
        invalidateAllSessions()
        demoClusters = DemoFleet.configs
        isDemoMode = true
        currentClusterID = demoClusters.first?.id
        if persist { defaults.set(true, forKey: "demoMode") }
    }

    public func exitDemoMode() {
        invalidateAllSessions()
        isDemoMode = false
        demoClusters = []
        currentClusterID = realClusters.first?.id
        defaults.set(false, forKey: "demoMode")
        onFleetShrank?(nil)
    }
}
