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

    func tick(now: Date = Date()) async {
        guard preferences.alertsEnabled, !registry.isDemoMode, !registry.clusters.isEmpty else { return }
        let sessions = registry.allSessions
        let stale = sessions.contains { s in s.lastHealthRefresh.map { now.timeIntervalSince($0) > Self.staleAfter } ?? true }
        if stale { await registry.refreshAllHealth() }
        guard BackgroundPolicy.shouldPostAlerts(isDemoMode: registry.isDemoMode, settings: AlertSettings.load()) else { return }
        await AlertNotifier.process(health: registry.allSessions.compactMap(\.health), clusters: registry.clusters)
    }
}
