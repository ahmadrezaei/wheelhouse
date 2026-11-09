import AppKit
import CryptoKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// Hosts Gangway in the Mac app (ARCHITECTURE-MAC section 3.6). Nothing listens until a consumer (the Deck Terminal, a Chart Room helm
/// run, `flux diff`) asks for the service: creating this object only registers notification observers, so an app without a guarded
/// session has no listener, no socket and no timer.
@MainActor
final class MacGangway {
    private let registry: ClusterRegistry
    private let paths: AppPaths
    private let provider: SnapshotClusterProvider
    private var service: GangwayService?
    private var starting: Task<GangwayService, Error>?
    private var sync: ClusterSnapshotSync?
    private var terminateObserver: (any NSObjectProtocol)?
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
        sync = ClusterSnapshotSync(registry: registry, provider: provider, digest: { config in
            // A digest of the credentials, never the credentials themselves.
            guard let secrets = try? credentials.load(clusterID: config.id), let data = try? JSONEncoder().encode(secrets) else { return nil }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }, service: { [weak self] in self?.service })
        sync?.start()
        // The app is quitting: sessions end and their kubeconfig folders go (the launch's token and certificate die with the process anyway).
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    private func refreshClusters() { sync?.refresh() }

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
        sync?.stop()
        if let terminateObserver { NotificationCenter.default.removeObserver(terminateObserver) }
        terminateObserver = nil
    }
}
