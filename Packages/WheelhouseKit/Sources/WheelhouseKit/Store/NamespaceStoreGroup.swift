import Foundation

/// One or several per-namespace stores read as a single list. A plain value, recomputed in a view's `body`: reading the members'
/// `items`, `phase` and `error` through it registers Observation on each of them.
///
/// The members come from the session's shared store cache (one per namespace), so a namespace that stays selected keeps its watch
/// and namespace-scoped RBAC keeps working. A group of one store behaves exactly like that store.
@MainActor
public struct NamespaceStoreGroup {
    /// The members, in the order of the selection (sorted by namespace). A cluster-wide or non-namespaced list has one member.
    public let stores: [ResourceStore<Unstructured>]

    public init(stores: [ResourceStore<Unstructured>]) { self.stores = stores }

    /// Every member's objects, concatenated in member order. Not sorted: lists sort themselves.
    public var items: [Unstructured] { stores.count == 1 ? stores[0].items : stores.flatMap(\.items) }

    /// Loading while any member loads; idle while any is idle; loaded when at least one loaded; failed when all failed.
    public var phase: ResourceStore<Unstructured>.Phase {
        if stores.contains(where: { $0.phase == .loading }) { return .loading }
        if stores.contains(where: { $0.phase == .idle }) { return .idle }
        return stores.contains(where: { $0.phase == .loaded }) ? .loaded : .failed
    }

    /// The first member error in selection order, so it is stable between reads.
    public var error: KubeError? { stores.lazy.compactMap(\.error).first }

    /// The error of the member that serves this namespace; nil when it loaded (or for a cluster-wide member with no error).
    public func error(forNamespace namespace: String?) -> KubeError? {
        guard let namespace else { return error }
        return (stores.first { $0.namespace == namespace } ?? stores.first { $0.namespace == nil })?.error
    }

    /// Namespaces whose list failed, for the banner.
    public var failedNamespaces: [String] { stores.compactMap { $0.error == nil ? nil : $0.namespace } }

    /// True until the first list completes and nothing is cached.
    public var isLoading: Bool { items.isEmpty && stores.contains { $0.phase == .loading } }
    /// True while a refresh is in flight and cached items are being shown.
    public var isRefreshing: Bool { !items.isEmpty && stores.contains { $0.phase == .loading } }

    /// One stamp per member: any member's update changes the array, which a view uses to know when to rebuild.
    public var updateStamps: [Date?] { stores.map(\.lastUpdated) }
    /// The oldest member update (the age to show for cached data); nil while any member never loaded.
    public var lastUpdated: Date? {
        let stamps = updateStamps
        return stamps.contains { $0 == nil } ? nil : stamps.compactMap { $0 }.min()
    }

    /// Runs every member's reflector while the calling task is alive.
    public func run() async {
        for store in stores { store.start() }
        defer { for store in stores { store.stop() } }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
    }

    /// Forces a fresh list and watch on every member.
    public func refresh() async {
        if stores.count == 1 { await stores[0].refresh(); return }
        await withTaskGroup(of: Void.self) { group in
            for store in stores { group.addTask { await store.refresh() } }
        }
    }
}

public extension ClusterSession {
    /// The stores for a namespace selection: one per selected namespace, or one cluster-wide store for All. A kind that is not
    /// namespaced always gets the single cluster-wide store, however many namespaces are selected.
    func unstructuredStores(kind: ResourceKind, selection: NamespaceSelection, labelSelector: String? = nil) -> NamespaceStoreGroup {
        let names = kind.namespaced ? selection.names : []
        if names.isEmpty { return NamespaceStoreGroup(stores: [unstructuredStore(kind: kind, namespace: nil, labelSelector: labelSelector)]) }
        return NamespaceStoreGroup(stores: names.map { unstructuredStore(kind: kind, namespace: $0, labelSelector: labelSelector) })
    }
}

public extension KubeClientProtocol {
    /// Pod metrics for several namespaces, fetched concurrently and merged. A namespace that fails is skipped; the call throws
    /// only when every namespace failed. No names means all namespaces in one request.
    func podMetrics(namespaces: [String]) async throws -> [PodMetrics] {
        guard namespaces.count > 1 else { return try await podMetrics(namespace: namespaces.first) }
        let results: [Result<[PodMetrics], Error>] = await withTaskGroup(of: Result<[PodMetrics], Error>.self) { group in
            for ns in namespaces {
                group.addTask {
                    do { return .success(try await self.podMetrics(namespace: ns)) } catch { return .failure(error) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let merged = results.compactMap { try? $0.get() }
        if merged.isEmpty, case .failure(let error)? = results.first { throw error }
        return merged.flatMap { $0 }
    }
}
