import Foundation
import WheelhouseKit

/// Alerts while the app runs with a window visible (Crow's Nest takes over in menu-bar mode in M4b). One `PeriodicTask` every
/// 60 s (× the energy multiplier) that hands the latest health snapshots to `AlertNotifier`, the same planner and de-duplication the
/// iOS background refresh uses. It refreshes health only when the snapshots are older than 45 s, so a visible Fleet or Alerts screen
/// (which refreshes every `refreshInterval`) is never doubled up. It has no hidden cadence: with every window hidden it stops.
@MainActor
final class MacAlertMonitor {
    private let registry: ClusterRegistry
    private let preferences: AppPreferences
    private var task: PeriodicTask?
    static let staleAfter: TimeInterval = 45

    init(registry: ClusterRegistry, preferences: AppPreferences) {
        self.registry = registry
        self.preferences = preferences
    }

    func start() {
        guard task == nil else { return }
        let t = PeriodicTask(name: "alerts.health", interval: 60, hiddenInterval: nil, tolerance: 6) { [weak self] in
            await self?.tick()
        }
        task = t
        t.start()
    }

    func stop() { task?.stop(); task = nil }

    /// Clusters worth a periodic health check while the app runs: Production and Staging. Development and personal clusters are
    /// refreshed by the screens that show them (Fleet, Overview) at their own cadence, so they cost nothing here.
    func watched() -> [ClusterSession] {
        registry.clusters.compactMap { c in
            (c.environment == .production || c.environment == .staging) ? registry.session(for: c.id) : nil
        }
    }

    func tick(now: Date = Date()) async {
        guard preferences.alertsEnabled, !registry.isDemoMode, !registry.clusters.isEmpty else { return }
        // One cluster at a time with a pause between: the same work as a parallel refresh, without the CPU spike.
        for s in watched() where s.lastHealthRefresh.map({ now.timeIntervalSince($0) > Self.staleAfter }) ?? true {
            _ = await s.refreshHealth()
            try? await Task.sleep(for: .milliseconds(500))
        }
        guard BackgroundPolicy.shouldPostAlerts(isDemoMode: registry.isDemoMode, settings: AlertSettings.load()) else { return }
        let watchedIDs = Set(watched().map(\.id))
        await AlertNotifier.process(health: registry.allSessions.filter { watchedIDs.contains($0.id) }.compactMap(\.health), clusters: registry.clusters)
    }
}
