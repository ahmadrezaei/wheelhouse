import Foundation
import Observation
import WheelhouseKit

/// Fleet-wide numbers for the Fleet dashboard, the alerts inbox and the bell badge.
/// Cheap per-cluster probes only (nodes, node metrics, a Prometheus range, Warning events); no full pod lists.
@MainActor @Observable
final class FleetModel {
    static let shared = FleetModel()

    struct Snapshot: Sendable {
        var usage: ClusterUsage
        var skew: VersionSkew
        var metrics: MetricsAvailability
        var prometheus: PromUsageSeries?
        /// Per-node CPU fraction (0...1) for the widgets; empty without node metrics.
        var nodeCPU: [Double] = []
    }

    struct FleetWarning: Identifiable, Sendable {
        var id: String
        var clusterID: ClusterID
        var clusterName: String
        var event: KubeEvent
    }

    struct FleetSeries {
        var usage: [MetricPoint]
        var requests: [MetricPoint]
        var capacity: Double
        var isHistory: Bool
        var coverage: String
    }

    private(set) var snapshots: [ClusterID: Snapshot] = [:]
    private(set) var sparklines: [ClusterID: [Double]] = [:]
    private(set) var warnings: [FleetWarning] = []
    private(set) var cpuSeries: FleetSeries?
    private(set) var lastRefresh: Date?
    private(set) var isRefreshing = false

    private struct Gathered: Sendable {
        var id: ClusterID
        var snapshot: Snapshot?
        var warnings: [KubeEvent] = []
    }

    // MARK: Derived

    func skews(for registry: ClusterRegistry) -> [ClusterID: VersionSkew] {
        var out: [ClusterID: VersionSkew] = [:]
        for c in registry.clusters { if let s = snapshots[c.id]?.skew { out[c.id] = s } }
        return out
    }

    func alerts(in registry: ClusterRegistry) -> [DashboardAlert] {
        DashboardAlert.ranked(healths: registry.clusters.compactMap { registry.health(for: $0.id) }, skews: skews(for: registry))
    }

    /// Fleet totals across reachable clusters that have a usage source.
    func fleetUsage(in registry: ClusterRegistry) -> ClusterUsage {
        ClusterUsage.sum(registry.clusters.compactMap { c in registry.health(for: c.id)?.isReachable == true ? snapshots[c.id]?.usage : nil })
    }

    // MARK: Refresh

    /// Refreshes now and then every `interval` seconds (`AppPreferences.refreshInterval`; 0 = manual, refresh once).
    func run(registry: ClusterRegistry, interval: Int) async {
        while !Task.isCancelled {
            // A restart (energy policy changed, screen re-entered) must not refresh again right away: wait out the interval.
            if interval > 0, let last = lastRefresh {
                let remaining = EnergyPolicy.current.interval(Double(interval)) - Date().timeIntervalSince(last)
                if remaining > 0 { try? await Task.sleep(for: .seconds(remaining)); if Task.isCancelled { return } }
            }
            await refresh(registry: registry)
            guard interval > 0 else { return }
            try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(Double(interval))))
        }
    }

    func refresh(registry: ClusterRegistry) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        await registry.refreshAllHealth()
        let sessions = registry.allSessions.filter { $0.health?.isReachable == true }
        var gathered: [Gathered] = []
        await withTaskGroup(of: Gathered.self) { group in
            for s in sessions { group.addTask { await Self.gather(s) } }
            for await g in group { gathered.append(g) }
        }
        let live = Set(registry.clusters.map(\.id))
        snapshots = snapshots.filter { live.contains($0.key) }
        sparklines = sparklines.filter { live.contains($0.key) }
        let now = Date()
        for g in gathered {
            guard let snap = g.snapshot else { continue }
            snapshots[g.id] = snap
            if let sample = UsageSample(usage: snap.usage, time: now) { UsageHistory.shared.record(sample, key: g.id) }
            if let prom = snap.prometheus, prom.cpuUsage.count > 1 {
                sparklines[g.id] = prom.cpuFractions(since: now.addingTimeInterval(-6 * 3600))
            } else {
                sparklines[g.id] = UsageHistory.shared.samples(for: g.id).map { $0.cpuAllocatable > 0 ? $0.cpuUsage / $0.cpuAllocatable : 0 }
            }
        }
        // Drop warnings of clusters that went away or became unreachable.
        let names = Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.id, $0.name) })
        warnings = gathered.flatMap { g in g.warnings.map { FleetWarning(id: "\(g.id)/\($0.id)", clusterID: g.id, clusterName: names[g.id] ?? g.id, event: $0) } }
            .sorted { ($0.event.lastSeen ?? .distantPast) > ($1.event.lastSeen ?? .distantPast) }
        buildCPUSeries(registry: registry, now: now)
        lastRefresh = now
    }

    private func buildCPUSeries(registry: ClusterRegistry, now: Date) {
        let covered = registry.clusters.filter { snapshots[$0.id]?.prometheus?.cpuUsage.count ?? 0 > 1 }
        let reachable = registry.clusters.filter { registry.health(for: $0.id)?.isReachable == true }
        if !covered.isEmpty {
            let proms = covered.compactMap { snapshots[$0.id]?.prometheus }
            let bucket = MetricsRange.day.step / 2
            let capacity = covered.reduce(0.0) { $0 + (snapshots[$1.id]?.usage.cpuAllocatable ?? 0) }
            cpuSeries = FleetSeries(usage: SeriesMath.sum(proms.map(\.cpuUsage), bucket: bucket), requests: SeriesMath.sum(proms.map(\.cpuRequests), bucket: bucket),
                                    capacity: capacity, isHistory: true, coverage: "Prometheus on \(covered.count) of \(reachable.count) reachable clusters")
            return
        }
        let usage = fleetUsage(in: registry)
        if let cpu = usage.cpuUsage {
            let sample = UsageSample(time: now, cpuUsage: cpu, memUsage: usage.memUsage ?? 0, cpuAllocatable: usage.cpuAllocatable, memAllocatable: usage.memAllocatable, cpuRequests: nil)
            UsageHistory.shared.record(sample, key: UsageHistory.fleetKey)
        }
        let samples = UsageHistory.shared.samples(for: UsageHistory.fleetKey)
        cpuSeries = samples.isEmpty ? nil : FleetSeries(usage: samples.map { MetricPoint(time: $0.time, value: $0.cpuUsage) }, requests: [],
                                                         capacity: usage.cpuAllocatable, isHistory: false, coverage: "Live samples from metrics-server since the app opened")
    }

    private static func loadProm(_ session: ClusterSession, availability: MetricsAvailability) async -> PromUsageSeries? {
        guard availability.hasHistory, let endpoint = session.prometheusEndpoint else { return nil }
        return await DashboardPrometheus.load(session.metrics.prometheus(endpoint), range: .day)
    }

    /// Reuses what the health pass already fetched (`lastNodes`, `lastWarningEvents`); only node metrics and Prometheus are new requests.
    private static func gather(_ session: ClusterSession) async -> Gathered {
        var g = Gathered(id: session.id)
        if session.metricsAvailability == nil { await session.detectMetrics() }
        let availability = session.metricsAvailability ?? MetricsAvailability.none
        async let summary = session.usageSummary(includeMetrics: availability.hasLiveUsage)
        async let prom = Self.loadProm(session, availability: availability)
        guard let (computed, nodeCPU) = await summary else { return g }
        var usage = computed
        let promSeries = await prom
        if usage.cpuUsage == nil, let p = promSeries { usage.cpuUsage = p.cpuUsage.last?.value; usage.memUsage = p.memUsage.last?.value }
        let skew = VersionSkew.analyze(apiVersion: session.version?.gitVersion, nodes: session.lastNodes)
        g.snapshot = Snapshot(usage: usage, skew: skew, metrics: availability, prometheus: promSeries, nodeCPU: nodeCPU)
        g.warnings = session.lastWarningEvents
        return g
    }
}
