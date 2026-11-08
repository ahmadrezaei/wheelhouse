import Foundation

public enum HealthStatus: String, Codable, Sendable, CaseIterable, Comparable {
    case healthy, warning, critical, unknown

    /// Higher = needs attention sooner. Unknown (unreachable / stale) ranks between healthy and warning.
    public var rank: Int {
        switch self {
        case .healthy: 0
        case .unknown: 1
        case .warning: 2
        case .critical: 3
        }
    }
    public static func < (a: HealthStatus, b: HealthStatus) -> Bool { a.rank < b.rank }

    public var title: String {
        switch self {
        case .healthy: "Healthy"
        case .warning: "Degraded"
        case .critical: "Critical"
        case .unknown: "Unknown"
        }
    }
    public var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        }
    }
}

public enum AttentionKind: String, Codable, Sendable {
    case crashLoop, oomKilled, imagePull, configError, podPending, podFailed, highRestarts
    case nodeNotReady, nodePressure, nodeCordoned
    case jobFailed, deploymentUnavailable, deploymentDegraded, pvcPending
    case unreachable, credentialsExpiring
}

public struct AttentionItem: Identifiable, Hashable, Sendable {
    public var id: String
    public var clusterID: ClusterID
    public var severity: HealthStatus
    public var kind: AttentionKind
    /// Short headline, e.g. `CrashLoopBackOff`.
    public var title: String
    /// Resource name and detail, e.g. `payments-api-7d9f8c6b5-x2k4q restarted 5×`.
    public var detail: String
    public var resource: ResourceRef?
    public var since: Date?
    /// Restart count of the pod behind this item (crash loops, OOM kills, high restarts); 0 otherwise.
    public var restarts: Int = 0
}

public struct ClusterCounts: Codable, Hashable, Sendable {
    public var nodesTotal = 0, nodesReady = 0, nodesNotReady = 0, nodesCordoned = 0, nodesPressure = 0
    public var podsTotal = 0, podsRunning = 0, podsPending = 0, podsFailing = 0, podsCompleted = 0
    public var deploymentsTotal = 0, deploymentsAvailable = 0
    public var statefulSetsTotal = 0, statefulSetsReady = 0
    public var daemonSetsTotal = 0, daemonSetsReady = 0
    public var jobsFailed = 0
    public var warningEvents = 0
    public var namespaces = 0
    public init() {}
}

public struct ClusterHealth: Hashable, Sendable {
    public var clusterID: ClusterID
    public var status: HealthStatus
    public var isReachable: Bool
    public var items: [AttentionItem]
    public var counts: ClusterCounts
    public var updatedAt: Date
    /// Some lists (pods, nodes, …) could not be fetched (timeout, 403), so the result may hide problems. Never shown as "healthy".
    public var isPartial: Bool = false
    /// Kinds that failed to load when ``isPartial`` is true, e.g. `["pods"]`.
    public var failedKinds: [String] = []
    /// The last probe failed but fewer than 3 times in a row, so this is the previous good result.
    public var isStale: Bool = false

    public init(clusterID: ClusterID, status: HealthStatus, isReachable: Bool, items: [AttentionItem], counts: ClusterCounts, updatedAt: Date,
                isPartial: Bool = false, failedKinds: [String] = [], isStale: Bool = false) {
        self.clusterID = clusterID; self.status = status; self.isReachable = isReachable; self.items = items; self.counts = counts
        self.updatedAt = updatedAt; self.isPartial = isPartial; self.failedKinds = failedKinds; self.isStale = isStale
    }

    public var issueSummary: String {
        if !isReachable { return "Unreachable" }
        guard let top = items.first else { return "All workloads healthy" }
        let more = items.count - 1
        return more > 0 ? "\(top.title) · \(top.detail) (+\(more) more)" : "\(top.title) · \(top.detail)"
    }

    public static func unreachable(clusterID: ClusterID, environment: ClusterEnvironment, cause: String? = nil, now: Date = Date()) -> ClusterHealth {
        let item = AttentionItem(id: "\(clusterID)/unreachable", clusterID: clusterID,
                                 severity: environment == .production ? .critical : .warning, kind: .unreachable,
                                 title: "Cluster unreachable", detail: cause ?? "API server not responding", resource: nil, since: now)
        return ClusterHealth(clusterID: clusterID, status: .unknown, isReachable: false, items: [item], counts: ClusterCounts(), updatedAt: now)
    }
}

/// Everything the Health rules need; filled from ResourceStores, a one-shot fetch, or the background refresh.
public struct ClusterHealthInput: Sendable {
    public var clusterID: ClusterID
    public var environment: ClusterEnvironment
    public var pods: [Pod] = []
    public var nodes: [Node] = []
    public var deployments: [Deployment] = []
    public var statefulSets: [StatefulSet] = []
    public var daemonSets: [DaemonSet] = []
    public var jobs: [Job] = []
    public var pvcs: [PersistentVolumeClaim] = []
    public var warningEventCount = 0
    public var namespaceCount = 0
    /// Resource names (`"pods"`, `"nodes"`, …) whose list failed; the evaluator marks the result partial.
    public var failedKinds: Set<String> = []

    public init(clusterID: ClusterID, environment: ClusterEnvironment) {
        self.clusterID = clusterID
        self.environment = environment
    }
}

public struct HealthRules: Sendable {
    public var pendingThreshold: TimeInterval = 5 * 60
    public var highRestartCount = 5
    public init() {}
}
