import Foundation
import WheelhouseDesktop
import WheelhouseKit

/// Keeps the Compass index current (ARCHITECTURE-MAC sections 12.3.4 and 12.4).
///
/// - Clusters that opted in (`MacPreferences.compassIndexedClusterIDs`) are listed with the metadata-only call every 5 minutes (10
///   minutes on battery), page by page, one kind at a time, name, namespace, labels and first owner only.
/// - Every other cluster contributes the items of stores that already run (zero network, `existingStore` never creates one).
/// - One `PeriodicTask` with no hidden cadence: with no workspace window visible it parks and no timer is armed. A critical memory
///   warning stops it and empties the index until the next visible tick; a warning drops the clusters outside the focused pane.
@MainActor
final class CompassMetadataIndexer {
    static let interval: TimeInterval = 300
    static let pageSize = 500
    /// What gets listed. Secrets are listed too, as metadata only, and the index keeps just their name and namespace.
    static let kinds: [ResourceKind] = [.pod, .deployment, .statefulSet, .daemonSet, .job, .cronJob, .service, .ingress, .configMap, .secret,
                                        .persistentVolumeClaim, .node, .namespace, .serviceAccount]

    let index: CompassIndex
    private let registry: ClusterRegistry
    private let mac: MacPreferences
    private let onBattery: @MainActor () -> Bool
    private let periodicRegistry: PeriodicTaskRegistry
    private var task: PeriodicTask?
    private var skipNext = false
    private(set) var stopped = false
    private(set) var refreshes = 0

    init(index: CompassIndex, registry: ClusterRegistry, mac: MacPreferences, onBattery: @escaping @MainActor () -> Bool = { false },
         periodicRegistry: PeriodicTaskRegistry = .shared) {
        self.index = index
        self.registry = registry
        self.mac = mac
        self.onBattery = onBattery
        self.periodicRegistry = periodicRegistry
    }

    func start() {
        guard task == nil else { return }
        stopped = false
        let t = PeriodicTask(name: "compass.index", interval: Self.interval, hiddenInterval: nil, tolerance: 30, registry: periodicRegistry) { [weak self] in
            await self?.tick()
        }
        task = t
        t.start()
    }

    func stop() {
        task?.stop()
        task = nil
    }

    /// One scheduled refresh. On battery every second tick is skipped (10 minutes).
    func tick() async {
        guard !stopped, periodicRegistry.windowsVisible else { return }
        if onBattery() { skipNext.toggle(); if skipNext { return } } else { skipNext = false }
        await refresh()
    }

    /// Refreshes every cluster now (the first run after launch, and when a cluster opts in).
    func refresh() async {
        guard !stopped, !registry.isDemoMode else { return }
        let opted = mac.compassIndexedClusterIDs
        for cluster in registry.clusters {
            guard let session = registry.session(for: cluster.id) else { continue }
            if opted.contains(cluster.id) {
                let client = session.client
                await refreshMetadata(cluster: cluster.id, fetch: { kind, token, limit in try await client.listCompassPage(kind: kind, namespace: nil, continueToken: token, limit: limit) })
            } else { await indexLive(cluster: cluster.id, session: session) }
            if stopped || !periodicRegistry.windowsVisible { return }
        }
        refreshes += 1
    }

    /// One page of a kind: the continue token and the page size go in (the client's `listCompassPage`; a test passes a canned one).
    typealias PageFetch = @Sendable (_ kind: ResourceKind, _ token: String?, _ limit: Int) async throws -> CompassMetadataPage

    func refreshMetadata(cluster: ClusterID, fetch: PageFetch) async {
        for kind in Self.kinds {
            if stopped || !periodicRegistry.windowsVisible { return }
            await index.beginRefresh(cluster: cluster, kind: kind)
            var token: String?
            do {
                repeat {
                    let page = try await fetch(kind, token, Self.pageSize)
                    await index.stage(cluster: cluster, kind: kind, items: page.items)
                    token = page.continueToken
                } while token != nil && !Task.isCancelled && !stopped
                if stopped { await index.abortRefresh(cluster: cluster, kind: kind) } else { await index.commit(cluster: cluster, kind: kind) }
            } catch {
                // Forbidden or unsupported kind, or a dropped connection: the previous entries of the kind stay.
                await index.abortRefresh(cluster: cluster, kind: kind)
            }
        }
    }

    /// Items of stores that already run, for a cluster that did not opt in.
    func indexLive(cluster: ClusterID, session: ClusterSession) async {
        await replaceLive(session.existingStore(for: Pod.self)?.items, kind: .pod, cluster: cluster)
        await replaceLive(session.existingStore(for: Deployment.self)?.items, kind: .deployment, cluster: cluster)
        await replaceLive(session.existingStore(for: StatefulSet.self)?.items, kind: .statefulSet, cluster: cluster)
        await replaceLive(session.existingStore(for: DaemonSet.self)?.items, kind: .daemonSet, cluster: cluster)
        await replaceLive(session.existingStore(for: Job.self)?.items, kind: .job, cluster: cluster)
        await replaceLive(session.existingStore(for: Node.self)?.items, kind: .node, cluster: cluster)
    }

    private func replaceLive<T: KubeObject>(_ objects: [T]?, kind: ResourceKind, cluster: ClusterID) async {
        guard let objects, !objects.isEmpty else { return }
        let items = objects.map { o in
            CompassMetadataItem(name: o.metadata.name, namespace: o.metadata.namespace, labels: o.metadata.labels,
                                ownerKind: o.metadata.ownerReferences.first?.kind, ownerName: o.metadata.ownerReferences.first?.name)
        }
        await index.replace(cluster: cluster, kind: kind, items: items)
    }

    // MARK: Memory pressure and focus

    /// Warning: only the focused pane's cluster keeps its entries. Critical: the index is emptied and the indexer waits for the
    /// next visible tick to start over.
    func memoryPressure(critical: Bool, focused: Set<ClusterID>) {
        if critical {
            stopped = true
            Task { await index.removeAll() }
        } else {
            Task { await index.keepOnly(focused) }
        }
    }

    /// A window is visible again after a critical pause.
    func resumeIfStopped() { stopped = false }
}
