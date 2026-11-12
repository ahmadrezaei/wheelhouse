import Foundation
import Observation
import WheelhouseKit

/// What the menu bar glyph and the panel header need, small and Equatable so the label only re-renders when it really changes.
struct FleetSummary: Equatable, Sendable {
    enum Level: Int, Equatable, Sendable { case healthy, warning, critical }
    var level: Level = .healthy
    /// Objects needing attention across the checked clusters.
    var attentionCount = 0
    var clusterCount = 0

    /// Unreachable clusters alone turn the glyph red only when they are Production (the health evaluator already ranks them so).
    static func make(attention: [AttentionItem], clusterCount: Int) -> FleetSummary {
        let worst = attention.map(\.severity).max { $0.rank < $1.rank }
        let level: Level = switch worst {
        case .critical: .critical
        case .warning: .warning
        default: .healthy
        }
        return FleetSummary(level: level, attentionCount: attention.filter { $0.severity == .warning || $0.severity == .critical }.count, clusterCount: clusterCount)
    }
}

/// Crow's Nest health checks (DESIGN-MAC section 6.15, ARCHITECTURE-MAC section 12.3.3). One `PeriodicTask`, every 60 s (times the
/// energy multiplier) with a 30 s tolerance, in the window-visible state and in menu-bar mode alike: with no window it is the only
/// periodic work in the app and the only thing that talks to a cluster. It never starts a watch: a check is `refreshHealth`, which
/// reads running stores when there are any and otherwise does one short list per kind.
///
/// It replaces `MacAlertMonitor` while the menu bar item is on (the two do the same tick; see `MacAppEnvironment`), and posts alerts
/// through `process`, which tests replace so no real notification is ever delivered from an automated test.
///
/// Wake from sleep needs no code of its own: the task sleeps on the continuous clock, so it fires once when the Mac wakes.
@MainActor @Observable
final class MacFleetMonitor {
    static let interval: TimeInterval = 60
    static let tolerance: TimeInterval = 30
    static let staleAfter: TimeInterval = 45
    static let deepInterval: TimeInterval = 900
    static let deepIntervalProduction: TimeInterval = 300

    private(set) var summary = FleetSummary()
    private(set) var lastCheck: Date?
    private(set) var pausedUntil: Date?
    private(set) var checks = 0
    /// Full health evaluations run by menu-bar checks (probes are not counted).
    private(set) var deepChecks = 0

    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let preferences: AppPreferences
    @ObservationIgnored private let mac: MacPreferences
    @ObservationIgnored private let railClusters: @MainActor () -> Set<ClusterID>
    @ObservationIgnored private let process: @MainActor ([ClusterHealth], [ClusterConfig]) async -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private let policy: @Sendable () -> EnergyPolicy
    @ObservationIgnored private let alertSettings: @Sendable () -> AlertSettings
    /// Called after every check (development builds publish the periodic-work report for the performance sampler).
    @ObservationIgnored var didTick: (@MainActor () -> Void)?
    @ObservationIgnored private var deepChecked: [ClusterID: Date] = [:]
    @ObservationIgnored private var task: PeriodicTask?
    @ObservationIgnored private let periodicRegistry: PeriodicTaskRegistry

    init(registry: ClusterRegistry, preferences: AppPreferences, mac: MacPreferences, railClusters: @escaping @MainActor () -> Set<ClusterID>,
         process: @escaping @MainActor ([ClusterHealth], [ClusterConfig]) async -> Void,
         now: @escaping @Sendable () -> Date = { Date() }, policy: @escaping @Sendable () -> EnergyPolicy = { EnergyPolicy.current },
         alertSettings: @escaping @Sendable () -> AlertSettings = { AlertSettings.load() },
         periodicRegistry: PeriodicTaskRegistry = .shared) {
        self.registry = registry
        self.preferences = preferences
        self.mac = mac
        self.railClusters = railClusters
        self.process = process
        self.now = now
        self.policy = policy
        self.alertSettings = alertSettings
        self.periodicRegistry = periodicRegistry
    }

    var isRunning: Bool { task?.isStarted == true }

    func start() {
        guard task == nil else { return }
        let t = PeriodicTask(name: "crowsnest.health", interval: Self.interval, hiddenInterval: Self.interval, tolerance: Self.tolerance,
                             registry: periodicRegistry, policy: policy) { [weak self] in await self?.tick() }
        task = t
        t.start()
    }

    func stop() {
        task?.stop()
        task = nil
    }

    /// Clusters worth checking: Production and Staging (what the alert monitor watched), Rail clusters and the ones opted in.
    func watched() -> [ClusterSession] {
        let rail = railClusters(), extra = mac.watchedClusterIDs
        return registry.clusters.compactMap { c in
            let on = c.environment == .production || c.environment == .staging || rail.contains(c.id) || extra.contains(c.id)
            return on ? registry.session(for: c.id) : nil
        }
    }

    var isPaused: Bool { pausedUntil.map { $0 > now() } ?? false }

    func pause(for interval: TimeInterval = 3_600) { pausedUntil = now().addingTimeInterval(interval) }
    func resume() { pausedUntil = nil }

    /// With no window open a check is a probe of every watched cluster (`/version`, a few hundred bytes, and an unreachable cluster is
    /// recorded at once). The full health evaluation, which lists pods, nodes, workloads, jobs and events, runs per cluster every
    /// `deepInterval` (5 minutes for Production, 15 for the others), one cluster per check and the never-checked ones first (so the first
    /// minutes after launch do not decode every cluster's lists at once): a fixture cluster with 550 pods and 430 jobs answers 3.5 MB of pods alone, and that list every minute is most of
    /// the CPU and the memory peak a menu-bar-only app is allowed (hidden budget 0.1 % and 100 MB).
    private func menuBarCheck(_ sessions: [ClusterSession], date: Date) async {
        for s in sessions {
            if await s.connect().isFailed {
                _ = await s.refreshHealth()
                deepChecked[s.id] = date
                deepChecks += 1
            }
        }
        let overdue = sessions.filter { s in
            let interval = s.config.environment == .production ? Self.deepIntervalProduction : Self.deepInterval
            return deepChecked[s.id].map { date.timeIntervalSince($0) >= interval } ?? true
        }
        if let oldest = overdue.min(by: { (deepChecked[$0.id] ?? .distantPast) < (deepChecked[$1.id] ?? .distantPast) }) {
            _ = await oldest.refreshHealth()
            deepChecked[oldest.id] = date
            deepChecks += 1
        }
    }

    /// One check. Public for the panel's refresh button and the tests.
    func tick(force: Bool = false) async {
        guard !registry.isDemoMode, !registry.clusters.isEmpty else { return }
        if isPaused, !force { return }
        let date = now()
        var sessions = watched()
        // Thermal critical pauses every cluster but Production (ARCHITECTURE-MAC section 12.3.4 item 8).
        if policy().thermalState == .critical { sessions = sessions.filter { $0.config.environment == .production } }
        if force || periodicRegistry.windowsVisible {
            let due = sessions.filter { force || ($0.lastHealthRefresh.map { date.timeIntervalSince($0) > Self.staleAfter } ?? true) }
            // One burst, clusters in parallel: a staggered check would wake the app once per cluster.
            await withTaskGroup(of: Void.self) { group in
                for s in due { group.addTask { await s.refreshHealth() } }
            }
            for s in due { deepChecked[s.id] = date }
        } else {
            await menuBarCheck(sessions, date: date)
        }
        checks += 1
        lastCheck = now()
        didTick?()
        let healths = sessions.compactMap(\.health)
        let next = FleetSummary.make(attention: HealthEvaluator.fleetAttention(healths), clusterCount: registry.clusters.count)
        if next != summary { summary = next }
        guard BackgroundPolicy.shouldPostAlerts(isDemoMode: registry.isDemoMode, settings: alertSettings()) else { return }
        await process(healths, registry.clusters)
    }
}
