import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// Hosts Gangway in the Mac app (ARCHITECTURE-MAC section 3.6). Nothing listens until a consumer (the Deck Terminal, a Chart Room helm
/// run, `flux diff`) asks for the service: creating this object only registers one notification observer, so an app without a guarded
/// session has no listener, no socket and no timer.
@MainActor
final class MacGangway {
    private let registry: ClusterRegistry
    private let paths: AppPaths
    private let provider: SnapshotClusterProvider
    private var service: GangwayService?
    private var starting: Task<GangwayService, Error>?
    private var clusterObserver: (any NSObjectProtocol)?
    private var locked = false
    /// Shows the confirmation sheets. M5b installs the real one; until then every held request is declined.
    var confirmer: any GangwayConfirming = DecliningConfirmer()

    init(registry: ClusterRegistry, moorings: MooringsController, paths: AppPaths) {
        self.registry = registry
        self.paths = paths
        let credentials = moorings.credentials
        let factory = moorings.factory
        let state = moorings.state
        provider = SnapshotClusterProvider { config in
            let secrets = (try? credentials.load(clusterID: config.id)) ?? ClusterSecrets()
            return factory.gangwayUpstream(config: config, secrets: secrets, contactHeld: state.isContactHeld(config.id))
        }
        provider.update(registry.clusters)
        // The snapshot is refreshed first, then the service re-evaluates its streams and grants against it (one observer, no ordering to rely on).
        clusterObserver = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: .main) { [weak self] note in
            let id = ClusterEvents.clusterID(from: note), removed = ClusterEvents.wasRemoved(note)
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshClusters()
                if let id { self.service?.clusterChanged(id, removed: removed) }
            }
        }
    }

    private func refreshClusters() { provider.update(registry.clusters) }

    /// The running service, started on first use.
    func service() async throws -> GangwayService {
        if let service { return service }
        if let starting { return try await starting.value }
        let task = Task { @MainActor () throws -> GangwayService in
            refreshClusters()
            var confirmer = self.confirmer
#if WH_TEST_HOOKS
            if let hook = GangwayTestHooks.confirmerIfRequested() { confirmer = hook }
#endif
            let made = GangwayService(paths: paths, clusters: provider, confirmer: confirmer, observesClusterEvents: false)
            if locked { made.lock() }
            try await made.start()
            service = made
            return made
        }
        starting = task
        defer { starting = nil }
        return try await task.value
    }

    /// Follows the app lock without polling: re-arms an observation of `isLocked` after each change.
    func follow(lock: MacLockCoordinator) {
        apply(locked: lock.isLocked)
        withObservationTracking { _ = lock.isLocked } onChange: { [weak self, weak lock] in
            Task { @MainActor in
                guard let self, let lock else { return }
                self.follow(lock: lock)
            }
        }
    }

    private func apply(locked now: Bool) {
        guard now != locked else { return }
        locked = now
        if now { service?.lock() } else { service?.unlock() }
    }

    func shutdown() {
        service?.stop()
        service = nil
        if let clusterObserver { NotificationCenter.default.removeObserver(clusterObserver) }
        clusterObserver = nil
    }
}
