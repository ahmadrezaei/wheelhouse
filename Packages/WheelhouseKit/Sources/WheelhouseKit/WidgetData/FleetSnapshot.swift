import Foundation

/// What widgets show. Written by the app / background refresh, read by the widget extension. Never contains credentials or secrets.
public struct FleetSnapshot: Codable, Sendable, Equatable {
    public struct FailingPod: Codable, Sendable, Equatable, Identifiable {
        public var id: String { "\(namespace)/\(name)" }
        public var name: String
        public var namespace: String
        public var reason: String
        public var restarts: Int
        public init(name: String, namespace: String, reason: String, restarts: Int) {
            self.name = name; self.namespace = namespace; self.reason = reason; self.restarts = restarts
        }
    }

    public struct ClusterEntry: Codable, Sendable, Equatable, Identifiable {
        public var id: ClusterID
        public var name: String
        public var environment: ClusterEnvironment
        public var status: HealthStatus
        public var isReachable: Bool
        public var nodesReady: Int
        public var nodesTotal: Int
        public var podsRunning: Int
        public var podsTotal: Int
        public var failingPods: Int
        /// 0...1, nil when no metrics source is available.
        public var cpuFraction: Double?
        public var memoryFraction: Double?
        public var topIssue: String?
        public var failingPodList: [FailingPod]
        public var nodeCPU: [Double]

        /// Set when the cluster's health has not been loaded yet (optional so older snapshots still decode).
        public var notLoaded: Bool?
        /// True for a cluster whose health has not been loaded yet. Neutral: not offline, not counted as needing attention.
        public var isNotLoaded: Bool { notLoaded == true }

        public init(id: ClusterID, name: String, environment: ClusterEnvironment, status: HealthStatus, isReachable: Bool = true,
                    nodesReady: Int = 0, nodesTotal: Int = 0, podsRunning: Int = 0, podsTotal: Int = 0, failingPods: Int = 0,
                    cpuFraction: Double? = nil, memoryFraction: Double? = nil, topIssue: String? = nil,
                    failingPodList: [FailingPod] = [], nodeCPU: [Double] = [], notLoaded: Bool? = nil) {
            self.id = id; self.name = name; self.environment = environment; self.status = status; self.isReachable = isReachable
            self.nodesReady = nodesReady; self.nodesTotal = nodesTotal; self.podsRunning = podsRunning; self.podsTotal = podsTotal
            self.failingPods = failingPods; self.cpuFraction = cpuFraction; self.memoryFraction = memoryFraction
            self.topIssue = topIssue; self.failingPodList = failingPodList; self.nodeCPU = nodeCPU; self.notLoaded = notLoaded
        }
    }

    public var generatedAt: Date
    public var isDemo: Bool
    public var clusters: [ClusterEntry]

    public init(generatedAt: Date = Date(), isDemo: Bool = false, clusters: [ClusterEntry]) {
        self.generatedAt = generatedAt
        self.isDemo = isDemo
        self.clusters = clusters
    }

    public var needAttentionCount: Int { clusters.filter { $0.status == .warning || $0.status == .critical || !$0.isReachable }.count }
    public var isStale: Bool { Date().timeIntervalSince(generatedAt) > 2 * 3600 }
    /// Clusters whose health has not been loaded yet.
    public var unknownCount: Int { clusters.filter(\.isNotLoaded).count }
    /// Loaded, reachable clusters whose status is `.unknown` (pods or nodes could not be listed).
    public var unknownStatusCount: Int { clusters.filter { $0.isReachable && $0.status == .unknown && !$0.isNotLoaded }.count }
    public var title: String {
        if needAttentionCount > 0 { return "\(needAttentionCount) need attention" }
        let n = clusters.count
        if unknownCount == 0 && unknownStatusCount == 0 { return n == 1 ? "1 cluster healthy" : "All \(n) clusters healthy" }
        var parts = ["\(n) \(n == 1 ? "cluster" : "clusters")"]
        if unknownCount > 0 { parts.append("\(unknownCount) not loaded") }
        if unknownStatusCount > 0 { parts.append("\(unknownStatusCount) unknown") }
        return parts.joined(separator: " · ")
    }
    public var shortTitle: String {
        if needAttentionCount > 0 { return "\(needAttentionCount) need attention" }
        var parts: [String] = []
        if unknownCount > 0 { parts.append("\(unknownCount) not loaded") }
        if unknownStatusCount > 0 { parts.append("\(unknownStatusCount) unknown") }
        return parts.isEmpty ? "All healthy" : parts.joined(separator: " · ")
    }

    public static let placeholder = FleetSnapshot(isDemo: true, clusters: [
        ClusterEntry(id: "p1", name: "prod-eu-west", environment: .production, status: .critical, nodesReady: 7, nodesTotal: 8, podsRunning: 212, podsTotal: 220, failingPods: 2, cpuFraction: 0.61, memoryFraction: 0.68, topIssue: "payments-api CrashLoopBackOff"),
        ClusterEntry(id: "p2", name: "staging", environment: .staging, status: .healthy, nodesReady: 3, nodesTotal: 3, podsRunning: 64, podsTotal: 64, cpuFraction: 0.34, memoryFraction: 0.41),
    ])
}

public enum WidgetDataStore {
    private static var fileURL: URL { AppGroup.containerURL.appending(path: "fleet-snapshot.json") }

    public static func write(_ snapshot: FleetSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    public static func read() -> FleetSnapshot? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(FleetSnapshot.self, from: data)
    }
}
