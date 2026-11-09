#if os(macOS)
import Foundation
import Observation
import WheelhouseKit

/// Keeps Gangway's cluster snapshot in step with the registry, and tells the service what changed.
///
/// Two facts shape it. `ClusterRegistry.reloadFromStore` posts `ClusterEvents.invalidated` BEFORE it assigns its new list, so reading
/// the registry inside the notification sees the old clusters. And it posts nothing at all for a change that needs no new client (a
/// read-only toggle found by Moorings), only `ClusterSession.update(config:)`. So the snapshot follows the registry's own `clusters`
/// through Observation (event driven, no polling), refreshes on the next main-actor turn (after the registry has finished), and compares
/// the new list with the old snapshot: every cluster that changed or went away is handed to `GangwayService.clusterChanged`. The
/// notification is still observed, for credential replacements, which change no config.
@MainActor
public final class ClusterSnapshotSync {
    private let registry: ClusterRegistry
    private let provider: SnapshotClusterProvider
    private let digest: @MainActor (ClusterConfig) -> String?
    private let service: @MainActor () -> GangwayService?
    private var observer: (any NSObjectProtocol)?
    private var tracking = false

    public init(registry: ClusterRegistry, provider: SnapshotClusterProvider, digest: @escaping @MainActor (ClusterConfig) -> String? = { _ in nil },
                service: @escaping @MainActor () -> GangwayService?) {
        self.registry = registry
        self.provider = provider
        self.digest = digest
        self.service = service
    }

    public func start() {
        applyWithoutNotifying()
        if !tracking {
            tracking = true
            track()
        }
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    public func stop() {
        tracking = false
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func track() {
        guard tracking else { return }
        withObservationTracking { _ = registry.clusters } onChange: { [weak self] in
            // `onChange` runs before the registry's change lands: the refresh waits for the next turn.
            Task { @MainActor in
                guard let self, self.tracking else { return }
                self.refresh()
                self.track()
            }
        }
    }

    private func snapshot() -> (clusters: [ClusterConfig], digests: [ClusterID: String]) {
        let clusters = registry.clusters
        var digests: [ClusterID: String] = [:]
        for cluster in clusters { if let d = digest(cluster) { digests[cluster.id] = d } }
        return (clusters, digests)
    }

    private func applyWithoutNotifying() {
        let (clusters, digests) = snapshot()
        provider.update(clusters, credentialDigests: digests)
    }

    /// Updates the snapshot, then re-evaluates every cluster that changed, appeared or went away.
    public func refresh() {
        let before = Dictionary(registry.clusters.compactMap { c in provider.config(for: c.id).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let oldDigests = Dictionary(registry.clusters.compactMap { c in provider.credentialDigest(for: c.id).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let known = provider.knownIDs
        let (clusters, digests) = snapshot()
        provider.update(clusters, credentialDigests: digests)
        guard let service = service() else { return }
        let now = Set(clusters.map(\.id))
        for id in known.subtracting(now) { service.clusterChanged(id, removed: true) }
        for cluster in clusters where before[cluster.id] != cluster || oldDigests[cluster.id] != digests[cluster.id] {
            service.clusterChanged(cluster.id)
        }
    }
}
#endif
