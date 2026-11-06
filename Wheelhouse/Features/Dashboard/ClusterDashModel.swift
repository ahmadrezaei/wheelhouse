import Foundation
import Observation
import WheelhouseKit
import WheelhouseUI

/// Live metric state for one cluster dashboard. Resource lists come from shared `ResourceStore`s; this holds metrics only.
@MainActor @Observable
final class ClusterDashModel {
    private(set) var nodeMetrics: [NodeMetrics]?
    private(set) var podMetrics: [PodMetrics]?
    private(set) var prom: PromUsageSeries?
    private(set) var lastRefresh: Date?
    private(set) var isLoadingHistory = false
    private(set) var historyFailed = false
    /// Everything the dashboard derives from the resource stores. Recomputed at most once a second, and only when a store changed.
    private(set) var dash: Dash?
    private(set) var topCPU: [TopPod] = []
    private(set) var topMemory: [TopPod] = []

    @ObservationIgnored private var metricsGeneration = 0
    @ObservationIgnored private var lastStamp: Stamp?

    struct FailingRow: Identifiable {
        var id: String; var title: String; var subtitle: String; var lead: ResourceRow.Lead; var ref: ResourceRef; var trailing: String?
    }

    struct TopPod: Identifiable {
        var id: String; var name: String; var namespace: String; var value: Double; var cap: Double; var ref: ResourceRef
    }

    struct Dash {
        var nodes: [Node]
        var usage: ClusterUsage
        var breakdown: PodPhaseBreakdown
        var skew: VersionSkew
        var heat: [HeatTile]
        var heatIsLive: Bool
        var nodeTypes: String
        var failing: [FailingRow]
        var events: [KubeEvent]
        var podsLoading: Bool, nodesLoading: Bool, eventsLoading: Bool
        var forbidden: [String]
    }

    private struct StoreStamp: Equatable { var updated: Date?; var phase: String; var failed: Bool }
    private struct Stamp: Equatable {
        var nodes: StoreStamp, pods: StoreStamp, deployments: StoreStamp, statefulSets: StoreStamp, daemonSets: StoreStamp, jobs: StoreStamp, events: StoreStamp
        var metrics: Int
        var version: String?
    }

    func reset() {
        nodeMetrics = nil; podMetrics = nil; prom = nil; lastRefresh = nil; historyFailed = false
        dash = nil; topCPU = []; topMemory = []; lastStamp = nil
    }

    // MARK: Derived state (H6)

    /// Polls the shared stores while the dashboard is on screen. The view never reads store items itself, so a busy
    /// watch (10 Hz per store) costs one cheap timestamp comparison a second instead of a full re-derivation per render.
    func pollStores(_ session: ClusterSession) async {
        while !Task.isCancelled {
            recomputeIfNeeded(session)
            try? await Task.sleep(for: .milliseconds(dash?.nodes.isEmpty == false ? 1000 : 250))
        }
    }

    func recomputeIfNeeded(_ session: ClusterSession) {
        let nodes = session.store(for: Node.self), pods = session.store(for: Pod.self)
        let deployments = session.store(for: Deployment.self), sts = session.store(for: StatefulSet.self)
        let ds = session.store(for: DaemonSet.self), jobs = session.store(for: Job.self)
        let events = session.store(for: KubeEvent.self, fieldSelector: "type=Warning")
        func stamp<T>(_ s: ResourceStore<T>) -> StoreStamp { StoreStamp(updated: s.lastUpdated, phase: "\(s.phase)", failed: s.error != nil) }
        let current = Stamp(nodes: stamp(nodes), pods: stamp(pods), deployments: stamp(deployments), statefulSets: stamp(sts), daemonSets: stamp(ds),
                            jobs: stamp(jobs), events: stamp(events), metrics: metricsGeneration, version: session.version?.gitVersion)
        guard current != lastStamp else { return }
        lastStamp = current

        let nodeItems = nodes.items, podItems = pods.items
        let usage = ClusterUsage.compute(nodes: nodeItems, nodeMetrics: nodeMetrics, pods: podItems.isEmpty && pods.phase != .loaded ? nil : podItems)
        let heat = Self.heat(nodes: nodeItems, pods: podItems, nodeMetrics: nodeMetrics)
        var forbidden: [String] = []
        func check<T>(_ store: ResourceStore<T>, _ name: String) { if case .forbidden? = store.error { forbidden.append(name) } }
        check(pods, "pods"); check(nodes, "nodes"); check(deployments, "deployments"); check(jobs, "jobs")
        dash = Dash(nodes: nodeItems, usage: usage, breakdown: PodPhaseBreakdown.compute(podItems),
                    skew: VersionSkew.analyze(apiVersion: session.version?.gitVersion, nodes: nodeItems),
                    heat: heat.tiles, heatIsLive: heat.live,
                    nodeTypes: Dictionary(grouping: nodeItems, by: { $0.instanceType ?? "unknown" }).map { "\($0.value.count)× \($0.key)" }.sorted().joined(separator: " · "),
                    failing: Self.failing(clusterID: session.id, deployments: deployments.items, statefulSets: sts.items, daemonSets: ds.items, jobs: jobs.items, pods: podItems),
                    events: Array(events.items.sorted { ($0.lastSeen ?? .distantPast) > ($1.lastSeen ?? .distantPast) }.prefix(4)),
                    podsLoading: pods.isLoading, nodesLoading: nodes.isLoading, eventsLoading: events.isLoading, forbidden: forbidden)
    }

    private static func heat(nodes: [Node], pods: [Pod], nodeMetrics: [NodeMetrics]?) -> (tiles: [HeatTile], live: Bool) {
        let nm = Dictionary((nodeMetrics ?? []).map { ($0.metadata.name, $0) }, uniquingKeysWith: { a, _ in a })
        var requestedOn: [String: Double] = [:]
        if nm.isEmpty { for p in pods where p.isCountedForRequests { requestedOn[p.spec.nodeName ?? "", default: 0] += p.resourceRequests.cpu } }
        let live = !nm.isEmpty
        let tiles = nodes.map { n -> HeatTile in
            let alloc = n.status?.allocatable?["cpu"]?.cores ?? n.status?.capacity?["cpu"]?.cores ?? 0
            let used = live ? (nm[n.metadata.name]?.cpuCores ?? 0) : (requestedOn[n.metadata.name] ?? 0)
            return HeatTile(id: n.metadata.name, label: SeriesMath.shortNodeName(n.metadata.name), value: alloc > 0 ? min(used / alloc, 1) : 0, isNotReady: !n.isReady)
        }
        return (tiles, live)
    }

    private static func failing(clusterID cid: ClusterID, deployments: [Deployment], statefulSets: [StatefulSet], daemonSets: [DaemonSet], jobs: [Job], pods: [Pod]) -> [FailingRow] {
        var rows: [FailingRow] = []
        for x in deployments where x.desiredReplicas > 0 && x.availableReplicas < x.desiredReplicas {
            rows.append(FailingRow(id: "d/\(x.id)", title: x.metadata.name, subtitle: "Deployment · \(x.metadata.namespace ?? "")", lead: .ring(ready: x.availableReplicas, desired: x.desiredReplicas), ref: ResourceRef(clusterID: cid, object: x), trailing: nil))
        }
        for x in statefulSets where x.readyReplicas < x.desiredReplicas {
            rows.append(FailingRow(id: "s/\(x.id)", title: x.metadata.name, subtitle: "StatefulSet · \(x.metadata.namespace ?? "")", lead: .ring(ready: x.readyReplicas, desired: x.desiredReplicas), ref: ResourceRef(clusterID: cid, object: x), trailing: nil))
        }
        for x in daemonSets where x.readyReplicas < x.desiredReplicas {
            rows.append(FailingRow(id: "ds/\(x.id)", title: x.metadata.name, subtitle: "DaemonSet · \(x.metadata.namespace ?? "")", lead: .ring(ready: x.readyReplicas, desired: x.desiredReplicas), ref: ResourceRef(clusterID: cid, object: x), trailing: nil))
        }
        for x in jobs where x.isFailed {
            rows.append(FailingRow(id: "j/\(x.id)", title: x.metadata.name, subtitle: "Job failed · \(x.metadata.namespace ?? "")", lead: .symbol("calendar.badge.exclamationmark", .warning), ref: ResourceRef(clusterID: cid, object: x), trailing: Format.age(from: x.failureCondition?.lastTransitionTime)))
        }
        for p in pods where p.status?.phase == "Pending" && p.metadata.deletionTimestamp == nil {
            let why = p.status?.conditions.first { $0.type == "PodScheduled" && $0.status == "False" }?.reason ?? "Pending"
            rows.append(FailingRow(id: "p/\(p.id)", title: p.metadata.name, subtitle: "Pod · \(p.metadata.namespace ?? "") · \(why)", lead: .symbol("hourglass", .warning), ref: ResourceRef(clusterID: cid, object: p), trailing: Format.age(from: p.metadata.creationTimestamp)))
        }
        return rows
    }

    /// Top pods by CPU and memory. Only recomputed when new pod metrics arrive.
    private func computeTopPods(_ session: ClusterSession) {
        guard let metrics = podMetrics else { topCPU = []; topMemory = []; return }
        let specs = Dictionary(session.store(for: Pod.self).items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        func top(cpu: Bool) -> [TopPod] {
            metrics.map { m in
                let pod = specs[m.id]
                let value = cpu ? m.cpuCores : m.memoryBytes
                let limit = cpu ? pod?.resourceLimits.cpu ?? 0 : pod?.resourceLimits.memory ?? 0
                let request = cpu ? pod?.resourceRequests.cpu ?? 0 : pod?.resourceRequests.memory ?? 0
                return TopPod(id: m.id, name: m.metadata.name, namespace: m.metadata.namespace ?? "", value: value, cap: limit > 0 ? limit : request,
                              ref: ResourceRef(clusterID: session.id, kind: .pod, namespace: m.metadata.namespace, name: m.metadata.name))
            }.sorted { $0.value > $1.value }.prefix(5).map { $0 }
        }
        topCPU = top(cpu: true)
        topMemory = top(cpu: false)
    }

    /// Health, metrics sources, live node/pod metrics, one in-memory usage sample and (with Prometheus) the range series.
    func refresh(_ session: ClusterSession, range: MetricsRange) async {
        await session.refreshHealth()
        guard session.health?.isReachable == true else { return }
        if session.metricsAvailability == nil { await session.detectMetrics() }
        let availability = session.metricsAvailability ?? MetricsAvailability.none
        let client = session.client
        if availability.hasLiveUsage {
            async let nm = try? client.nodeMetrics()
            async let pm = try? client.podMetrics(namespace: nil)
            let (n, p) = await (nm, pm)
            nodeMetrics = n
            podMetrics = p
            computeTopPods(session)
            await recordSample(session)
        } else {
            nodeMetrics = nil
            podMetrics = nil
            topCPU = []; topMemory = []
        }
        metricsGeneration += 1
        lastRefresh = Date()
        if availability.hasHistory { await loadHistory(session, range: range) }
    }

    func loadHistory(_ session: ClusterSession, range: MetricsRange) async {
        guard let endpoint = session.prometheusEndpoint else { return }
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let series = await DashboardPrometheus.load(session.metrics.prometheus(endpoint), range: range)
        historyFailed = series.isEmpty
        if !series.isEmpty || prom == nil { prom = series }
    }

    private func recordSample(_ session: ClusterSession) async {
        var nodes = session.store(for: Node.self).items
        if nodes.isEmpty { nodes = (try? await session.client.list(Node.self).items) ?? [] }
        guard !nodes.isEmpty else { return }
        let pods = session.store(for: Pod.self).items
        let usage = ClusterUsage.compute(nodes: nodes, nodeMetrics: nodeMetrics, pods: pods.isEmpty ? nil : pods)
        if let sample = UsageSample(usage: usage) { UsageHistory.shared.record(sample, key: session.id) }
    }
}
