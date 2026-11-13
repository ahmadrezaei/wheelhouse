import Foundation
import Observation
import WheelhouseKit

/// What the sidebar needs from a cluster session. A protocol so `SidebarModelTests` can count calls with a fake: the model must never
/// create a store, a list or a watch just to count (ARCHITECTURE-MAC section 12.5).
@MainActor
protocol SidebarSessionProviding: AnyObject {
    var clusters: [ClusterConfig] { get }
    var isDemoMode: Bool { get }
    func namespace(for id: ClusterID) -> String?
    func loadDiscovery(for id: ClusterID) async -> DiscoveryInfo?
    /// One `SelfSubjectRulesReview` for the namespace scope (nil = cluster scope); nil result = the review failed.
    func rulesReview(for id: ClusterID, namespace: String?) async -> JSONValue?
    /// Items of a store that ALREADY EXISTS and is running (`consumerCount > 0` and loaded). Never creates anything.
    func runningItems(for id: ClusterID, kind: ResourceKind, namespace: String?) -> (items: [Unstructured], updated: Date?)?
    func health(for id: ClusterID) -> ClusterHealth?
}

/// The sidebar's state: the tree built from discovery and RBAC, disclosure, filter, and problem badges.
///
/// - Collapsed clusters trigger no request and no timer. Expanding one reads discovery (cached per cluster by `ClusterSession`) and
///   posts one `SelfSubjectRulesReview` per namespace scope, cached for 5 minutes and dropped on a 403.
/// - Counts and badges come only from stores that already run and from the latest `ClusterHealth`; the model never calls
///   `session.store(for:)`. Badge refreshes are coalesced to at most one per second.
@MainActor @Observable
final class SidebarModel {
    /// Free-text filter over rows and kind names (matches short names and singular forms).
    var filter = "" { didSet { if filter != oldValue { rebuild() } } }
    /// Clusters that are expanded. Collapsed clusters trigger no request and no timer (ARCHITECTURE-MAC section 12.3.3).
    var expandedClusters: Set<ClusterID> = []
    /// Show Forbidden Kinds: hidden kinds are shown dimmed with a lock.
    var showsForbiddenKinds = false { didSet { if showsForbiddenKinds != oldValue { rebuild() } } }
    /// Clusters the user pinned open (survive focus moving away).
    var keepExpanded: Set<ClusterID> = []
    /// `"<cluster>|<group>"` keys of open groups and API sub-groups.
    var expandedGroups: Set<String> = []

    private(set) var rows: [SidebarRow] = []
    private(set) var forcedOpen: Set<String> = []
    private(set) var badges: [String: SidebarBadge] = [:]
    private(set) var counts: [String: Int] = [:]
    /// Bumped whenever `rows` changed structurally (the outline view diffs on it).
    private(set) var structureRevision = 0

    private(set) var discovery: [ClusterID: DiscoveryInfo] = [:]
    private(set) var discoveryFailed: Set<ClusterID> = []
    private(set) var rules: [ClusterID: SidebarRuleSet] = [:]

    /// Test hooks.
    private(set) var discoveryReads = 0
    private(set) var reviewPosts = 0
    private(set) var badgeRefreshes = 0

    static let rulesTTL: TimeInterval = 300
    static let badgeMinInterval: TimeInterval = 1

    @ObservationIgnored private let provider: any SidebarSessionProviding
    @ObservationIgnored private let features: () -> [FeatureDescriptor]
    @ObservationIgnored private var rulesFetchedAt: [String: Date] = [:]
    @ObservationIgnored private var inflight: [ClusterID: Task<Void, Never>] = [:]
    @ObservationIgnored private var lastBadgeRefresh = Date.distantPast
    @ObservationIgnored private var storeStamps: [String: Date] = [:]
    @ObservationIgnored private var summaryCache: [String: (rv: String?, status: HealthStatus)] = [:]

    init(provider: any SidebarSessionProviding, features: @escaping () -> [FeatureDescriptor] = { FeatureRegistry.enabled }) {
        self.provider = provider
        self.features = features
        rebuild()
    }

    // MARK: Matching (kept for the M1a API)

    /// Catalogue kinds that match the current filter (name, singular, plural, short name).
    func matchingKinds(in group: SidebarGroup) -> [SidebarKindEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return group.kinds }
        return group.kinds.filter { entry in SidebarCatalog.filterTerms(for: entry.kind).contains { $0.contains(q) } }
    }

    // MARK: Disclosure

    func isExpanded(rowID: String) -> Bool {
        if forcedOpen.contains(rowID) { return true }
        guard let row = find(rowID) else { return false }
        if row.role == .cluster, let id = row.clusterID { return expandedClusters.contains(id) }
        if let id = row.clusterID { return expandedGroups.contains(SidebarTreeBuilder.groupKey(id, groupPart(of: row))) }
        return false
    }

    private func groupPart(of row: SidebarRow) -> String {
        switch row.role {
        case .group(let g): g.rawValue
        case .apiGroup: row.title
        default: row.id
        }
    }

    /// The user opened or closed a row (the outline view reports it).
    func setExpanded(_ expanded: Bool, rowID: String) {
        guard let row = find(rowID) else { return }
        if row.role == .cluster, let id = row.clusterID {
            if expanded { expand(cluster: id) } else { collapse(cluster: id) }
            return
        }
        guard let id = row.clusterID else { return }
        let key = SidebarTreeBuilder.groupKey(id, groupPart(of: row))
        if expanded { expandedGroups.insert(key) } else { expandedGroups.remove(key) }
    }

    func expand(cluster id: ClusterID) {
        guard !expandedClusters.contains(id) else { return }
        expandedClusters.insert(id)
        rebuild()
        load(cluster: id)
    }

    func collapse(cluster id: ClusterID) {
        guard expandedClusters.contains(id) else { return }
        expandedClusters.remove(id)
        inflight[id]?.cancel(); inflight[id] = nil
        rebuild()
    }

    /// Expands every group (and API group) of a cluster, or collapses them all.
    func setAllGroups(expanded: Bool, in id: ClusterID) {
        let prefix = "\(id)|"
        expandedGroups = expandedGroups.filter { !$0.hasPrefix(prefix) }
        if expanded, let cluster = rows.first(where: { $0.clusterID == id && $0.role == .cluster }) {
            for row in cluster.children + cluster.children.flatMap(\.children) where row.isExpandable {
                expandedGroups.insert(SidebarTreeBuilder.groupKey(id, groupPart(of: row)))
            }
        }
        structureRevision += 1
    }

    /// Only the focused pane's cluster auto-expands; other clusters collapse unless pinned (Keep Expanded). M4a wires focus-follow;
    /// M1b uses it for the current cluster at launch.
    func focus(cluster id: ClusterID?) {
        guard let id else { return }
        for other in expandedClusters where other != id && !keepExpanded.contains(other) { collapse(cluster: other) }
        expand(cluster: id)
    }

    func toggleKeepExpanded(_ id: ClusterID) {
        if keepExpanded.contains(id) { keepExpanded.remove(id) } else { keepExpanded.insert(id) }
    }

    // MARK: Discovery and RBAC

    /// Reads discovery and the rules review for an expanded cluster (both cached). Called on expansion and when the namespace changes.
    func load(cluster id: ClusterID) {
        guard expandedClusters.contains(id) || !filter.isEmpty else { return }
        inflight[id]?.cancel()
        let namespace = provider.namespace(for: id)
        inflight[id] = Task { [weak self] in
            guard let self else { return }
            if self.discovery[id] == nil {
                self.discoveryReads += 1
                if let info = await self.provider.loadDiscovery(for: id) {
                    if Task.isCancelled { return }
                    self.discovery[id] = info
                    self.discoveryFailed.remove(id)
                } else {
                    if Task.isCancelled { return }
                    self.discoveryFailed.insert(id)
                }
                self.rebuild()
            }
            await self.loadRules(for: id, namespace: namespace)
        }
    }

    private func rulesKey(_ id: ClusterID, _ namespace: String?) -> String { "\(id)|\(namespace ?? "*")" }

    private func loadRules(for id: ClusterID, namespace: String?) async {
        let key = rulesKey(id, namespace)
        if let at = rulesFetchedAt[key], Date().timeIntervalSince(at) < Self.rulesTTL, rules[id] != nil { return }
        if Task.isCancelled { return }
        reviewPosts += 1
        let response = await provider.rulesReview(for: id, namespace: namespace)
        if Task.isCancelled { return }
        rulesFetchedAt[key] = Date()
        // A failed or unreadable review hides nothing.
        if let response, let parsed = SidebarRuleSet.parse(response) { rules[id] = parsed } else { rules[id] = nil }
        rebuild()
    }

    /// Any 403 from a cluster invalidates its cached review (the next expansion or namespace change posts a new one).
    func forbiddenSeen(cluster id: ClusterID) {
        rulesFetchedAt = rulesFetchedAt.filter { !$0.key.hasPrefix("\(id)|") }
    }

    /// The namespace scope changed (the focused pane switched namespace): re-review the expanded clusters.
    func namespaceChanged(cluster id: ClusterID) {
        if expandedClusters.contains(id) { load(cluster: id) }
    }

    /// Reconnect or CRD change: discovery is read again.
    func invalidateDiscovery(cluster id: ClusterID) {
        discovery[id] = nil
        discoveryFailed.remove(id)
        rules[id] = nil
        rulesFetchedAt = rulesFetchedAt.filter { !$0.key.hasPrefix("\(id)|") }
        rebuild()
        if expandedClusters.contains(id) { load(cluster: id) }
    }

    // MARK: Build

    func rebuild() {
        let provider = provider
        let anyExist: (ClusterID, ResourceKind) -> Bool = { id, kind in
            provider.runningItems(for: id, kind: kind, namespace: provider.namespace(for: id))?.items.isEmpty == false
        }
        var input = SidebarBuildInput(clusters: provider.clusters, expandedClusters: expandedClusters, expandedGroups: expandedGroups, filter: filter,
                                      showsForbiddenKinds: showsForbiddenKinds, discovery: discovery, discoveryFailed: discoveryFailed, rules: rules,
                                      features: features(), isDemo: provider.isDemoMode)
        input.anyExist = anyExist
        let out = SidebarTreeBuilder.build(input)
        rows = out.rows
        forcedOpen = out.forcedOpen
        structureRevision += 1
    }

    func find(_ id: String) -> SidebarRow? {
        func walk(_ rows: [SidebarRow]) -> SidebarRow? {
            for r in rows {
                if r.id == id { return r }
                if let f = walk(r.children) { return f }
            }
            return nil
        }
        return walk(rows)
    }

    /// The row a destination selects (for revealing the selection when it changes elsewhere).
    func rowID(for destination: SidebarDestination) -> String? {
        func walk(_ rows: [SidebarRow]) -> String? {
            for r in rows {
                if r.destination == destination { return r.id }
                if let f = walk(r.children) { return f }
            }
            return nil
        }
        return walk(rows)
    }

    // MARK: Badges and counts (running stores only)

    /// Recomputes badges and hover counts from stores that already run and from the latest health snapshot. Coalesced: at most once
    /// per second. A kind with neither shows nothing. Collapsed groups aggregate what their kinds already know.
    func refreshBadges(now: Date = Date()) {
        guard now.timeIntervalSince(lastBadgeRefresh) >= Self.badgeMinInterval else { return }
        lastBadgeRefresh = now
        badgeRefreshes += 1
        var newBadges: [String: SidebarBadge] = [:]
        var newCounts: [String: Int] = [:]
        for cluster in rows where cluster.role == .cluster {
            guard let id = cluster.clusterID, expandedClusters.contains(id) else { continue }
            let health = provider.health(for: id)
            let namespace = provider.namespace(for: id)
            var clusterBadge: SidebarBadge?
            for group in cluster.children {
                var groupBadge: SidebarBadge?
                func visit(_ row: SidebarRow) {
                    for child in row.children { visit(child) }
                    guard let kind = row.kind, row.role == .kind || { if case .group = row.role { return true } else { return false } }() else { return }
                    if let r = readKind(id, kind: kind, namespace: namespace, health: health) {
                        if let c = r.count { newCounts[row.id] = c }
                        if let b = r.badge {
                            newBadges[row.id] = b
                            groupBadge = groupBadge.map { $0.merged(with: b) } ?? b
                        }
                    }
                }
                visit(group)
                if let gb = groupBadge {
                    if group.isExpandable { newBadges["agg." + group.id] = gb }
                    clusterBadge = clusterBadge.map { $0.merged(with: gb) } ?? gb
                }
                // API sub-groups aggregate too.
                for sub in group.children where sub.role == .apiGroup {
                    let kids = sub.children.compactMap { newBadges[$0.id] }
                    if let first = kids.first { newBadges["agg." + sub.id] = kids.dropFirst().reduce(first) { $0.merged(with: $1) } }
                }
            }
            if let cb = clusterBadge { newBadges["agg." + cluster.id] = cb }
        }
        if newBadges != badges { badges = newBadges }
        if newCounts != counts { counts = newCounts }
    }

    /// Reads one kind: a running store first, then the health snapshot (pods only). Never creates a store.
    private func readKind(_ id: ClusterID, kind: ResourceKind, namespace: String?, health: ClusterHealth?) -> (count: Int?, badge: SidebarBadge?)? {
        if let live = provider.runningItems(for: id, kind: kind, namespace: namespace) {
            let stamp = "\(id)|\(kind.id)"
            _ = stamp
            var critical = 0, warning = 0
            for o in live.items {
                let st = status(of: o, kind: kind)
                if st == .critical { critical += 1 } else if st == .warning { warning += 1 }
            }
            let badge: SidebarBadge? = critical > 0 ? SidebarBadge(count: critical, severity: .critical) : (warning > 0 ? SidebarBadge(count: warning, severity: .warning) : nil)
            return (live.items.count, badge)
        }
        if kind == .pod, let h = health, h.isReachable {
            let failing = h.counts.podsFailing, pending = h.counts.podsPending
            let badge: SidebarBadge? = failing > 0 ? SidebarBadge(count: failing, severity: .critical) : (pending > 0 ? SidebarBadge(count: pending, severity: .warning) : nil)
            return (nil, badge)
        }
        // Nodes: with no live store the health snapshot gives only the NotReady count (red). Cordoned nodes (orange) show only while a
        // Nodes store is running, through the summariser path above.
        if kind == .node, let h = health, h.isReachable {
            let notReady = h.counts.nodesNotReady
            return (nil, notReady > 0 ? SidebarBadge(count: notReady, severity: .critical) : nil)
        }
        return nil
    }

    /// The severity of one object, from the same summariser the lists use, cached per object version.
    private func status(of object: Unstructured, kind: ResourceKind) -> HealthStatus {
        let key = "\(kind.id)|\(object.id)"
        let rv = object.metadata.resourceVersion
        if let hit = summaryCache[key], hit.rv == rv, rv != nil { return hit.status }
        let s = ResourceSummarizer.summarize(kind: kind, object: object).status
        summaryCache[key] = (rv, s)
        if summaryCache.count > 20_000 { summaryCache.removeAll(keepingCapacity: false) }
        return s
    }

    /// Memory pressure: drop the summary cache.
    func trimCaches() { summaryCache.removeAll(keepingCapacity: false) }

    // MARK: Per-window state (restored by M4a)

    struct Persisted: Codable, Equatable {
        var expandedClusters: [ClusterID] = []
        var keepExpanded: [ClusterID] = []
        var expandedGroups: [String] = []
        var showsForbiddenKinds = false
    }

    var persisted: Persisted {
        Persisted(expandedClusters: Array(expandedClusters).sorted(), keepExpanded: Array(keepExpanded).sorted(), expandedGroups: Array(expandedGroups).sorted(),
                  showsForbiddenKinds: showsForbiddenKinds)
    }

    func restore(_ p: Persisted) {
        keepExpanded = Set(p.keepExpanded)
        expandedGroups = Set(p.expandedGroups)
        showsForbiddenKinds = p.showsForbiddenKinds
        for id in p.expandedClusters { expand(cluster: id) }
    }
}

// MARK: - Live provider

/// The live provider over `ClusterRegistry`. Everything it reads is cached or already running.
@MainActor
final class RegistrySidebarProvider: SidebarSessionProviding {
    private let registry: ClusterRegistry
    init(registry: ClusterRegistry) { self.registry = registry }

    var clusters: [ClusterConfig] { registry.clusters }
    var isDemoMode: Bool { registry.isDemoMode }
    func namespace(for id: ClusterID) -> String? { registry.namespace(for: id) }
    func health(for id: ClusterID) -> ClusterHealth? { registry.health(for: id) }

    func loadDiscovery(for id: ClusterID) async -> DiscoveryInfo? {
        guard let session = registry.session(for: id) else { return nil }
        await session.loadDiscovery()
        return session.discovery
    }

    func rulesReview(for id: ClusterID, namespace: String?) async -> JSONValue? {
        guard let session = registry.session(for: id) else { return nil }
        let body: JSONValue = ["apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectRulesReview", "spec": ["namespace": .string(namespace ?? "")]]
        return try? await session.client.create(.selfSubjectRulesReview, namespace: nil, name: nil, subresource: nil, body: body, options: MutationOptions())
    }

    func runningItems(for id: ClusterID, kind: ResourceKind, namespace: String?) -> (items: [Unstructured], updated: Date?)? {
        guard let session = registry.session(for: id) else { return nil }
        // The store of the focused pane's namespace scope first, then the all-namespaces store.
        for ns in [namespace, nil] as [String?] {
            if let store = session.existingUnstructuredStore(kind: kind, namespace: kind.namespaced ? ns : nil),
               store.consumerCount > 0, store.phase == .loaded { return (store.items, store.lastUpdated) }
        }
        return nil
    }
}
