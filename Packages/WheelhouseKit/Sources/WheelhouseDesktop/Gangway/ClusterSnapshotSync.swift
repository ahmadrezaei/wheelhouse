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
    private let service: @MainActor () -> GangwayService?
    private var observer: (any NSObjectProtocol)?
    private var tracking = false

    public init(registry: ClusterRegistry, provider: SnapshotClusterProvider, service: @escaping @MainActor () -> GangwayService?) {
        self.registry = registry
        self.provider = provider
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

    private func applyWithoutNotifying() { provider.update(registry.clusters) }

    /// Updates the snapshot, then re-evaluates every cluster that changed, appeared or went away. Credential digests are read only for
    /// clusters with a live session, off the main actor, so an app without guarded sessions does no Keychain or file reads here.
    public func refresh() {
        let known = provider.knownIDs
        let before = Dictionary(registry.clusters.compactMap { c in provider.config(for: c.id).map { (c.id, $0) } }, uniquingKeysWith: { a, _ in a })
        let clusters = registry.clusters
        provider.update(clusters)
        guard let service = service() else { return }
        let now = Set(clusters.map(\.id))
        for id in known.subtracting(now) { service.clusterChanged(id, removed: true) }
        for cluster in clusters where before[cluster.id] != cluster { service.clusterChanged(cluster.id) }
        let withSessions = Set(service.registry.sessions.map(\.clusterID)).intersection(now)
        guard !withSessions.isEmpty else { return }
        Task { @MainActor [provider] in
            let changed = await provider.refreshDigests(for: withSessions)
            for id in changed { service.clusterChanged(id) }
        }
    }
}
#endif
