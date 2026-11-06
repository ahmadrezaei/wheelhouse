import BackgroundTasks
import Foundation
import WidgetKit
import WheelhouseKit

/// BGAppRefreshTask `app.wheelhouse.refresh`: health-check clusters (parallel, 8 s each, 25 s total), write the widget snapshot,
/// reload widget timelines, post alerts, reschedule (DESIGN.md §10).
enum BackgroundRefresh {
    static let taskIdentifier = "app.wheelhouse.refresh"
    static let totalBudget: Duration = .seconds(25)
    static let perClusterBudget: Duration = .seconds(8)

    /// Must be called before the app finishes launching (from `WheelhouseApp.init`).
    static func register() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            guard let task = task as? BGAppRefreshTask else { return }
            schedule()
            let box = TaskBox(task)
            let work = Task { @MainActor in
                let ok = await runRefresh()
                box.task.setTaskCompleted(success: ok)
            }
            task.expirationHandler = { work.cancel() }
        }
    }

    /// `BGTask` is not `Sendable`; it is only touched to report completion.
    private final class TaskBox: @unchecked Sendable {
        let task: BGAppRefreshTask
        init(_ task: BGAppRefreshTask) { self.task = task }
    }

    static func schedule(earliest interval: TimeInterval = 15 * 60) {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: EnergyPolicy.current.interval(interval))
        Task { try? await BGTaskScheduler.shared.submitTaskRequest(request) }
    }

    /// Checks all clusters (alerts-enabled ones are evaluated by the rules; every cluster is refreshed for the snapshot).
    @MainActor
    static func runRefresh() async -> Bool {
        let registry = ClusterRegistry()
        if AppGroup.defaults.bool(forKey: "demoMode") { registry.enterDemoMode(persist: false) }
        let sessions = registry.allSessions
        var usage: [ClusterID: ClusterUsage] = [:]
        var nodeCPU: [ClusterID: [Double]] = [:]
        // Clusters in parallel, each capped at 8 s, everything capped at 25 s. Cancelling a refresh cancels its URLSession calls.
        // Only pods, nodes and jobs (plus a few small lists) are fetched, then one nodeMetrics() call for the widget gauges.
        let works = sessions.map { s in
            Task { @MainActor in
                let one = Task { @MainActor () -> (ClusterUsage, [Double])? in
                    await s.refreshHealth()
                    guard !Task.isCancelled, s.health?.isReachable == true else { return nil }
                    return await s.usageSummary().map { ($0.usage, $0.nodeCPU) }
                }
                let timer = Task { try? await Task.sleep(for: perClusterBudget); one.cancel() }
                let result = await withTaskCancellationHandler { await one.value } onCancel: { one.cancel() }
                timer.cancel()
                return result
            }
        }
        let overall = Task { try? await Task.sleep(for: totalBudget); works.forEach { $0.cancel() } }
        await withTaskCancellationHandler {
            for (s, w) in zip(sessions, works) {
                if let (u, cpu) = await w.value { usage[s.id] = u; nodeCPU[s.id] = cpu }
            }
        } onCancel: { works.forEach { $0.cancel() } }
        overall.cancel()
        if Task.isCancelled { return false }
        writeSnapshot(registry, usage: usage, nodeCPU: nodeCPU)
        let health = sessions.map { $0.health ?? ClusterHealth.unreachable(clusterID: $0.config.id, environment: $0.config.environment, cause: "Timed out") }
        // Demo clusters are not real: never post alerts for them.
        if BackgroundPolicy.shouldPostAlerts(isDemoMode: registry.isDemoMode, settings: AlertSettings.load()) { await AlertNotifier.process(health: health, clusters: registry.clusters) }
        return true
    }

    /// Writes the widget snapshot from the registry's current health and reloads timelines.
    @MainActor
    static func writeSnapshot(_ registry: ClusterRegistry, usage: [ClusterID: ClusterUsage] = [:], nodeCPU: [ClusterID: [Double]] = [:]) {
        try? WidgetDataStore.write(registry.makeSnapshot(usage: usage, nodeCPU: nodeCPU))
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Call when the app goes to the background: refreshes the widget snapshot from what the app already knows and schedules the next refresh.
    @MainActor
    static func appDidEnterBackground(registry: ClusterRegistry) {
        if registry.allSessions.contains(where: { $0.health != nil }) {
            let fleet = FleetModel.shared
            writeSnapshot(registry, usage: fleet.snapshots.mapValues(\.usage), nodeCPU: fleet.snapshots.mapValues(\.nodeCPU))
        }
        schedule()
    }
}
