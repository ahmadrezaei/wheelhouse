import Foundation
import Observation

// MARK: - Pod phase breakdown

public struct PodPhaseBreakdown: Sendable, Hashable {
    public var healthy = 0, crashing = 0, pending = 0, failed = 0, completed = 0
    public init() {}
    public var total: Int { healthy + crashing + pending + failed + completed }

    public static func compute(_ pods: [Pod]) -> PodPhaseBreakdown {
        var b = PodPhaseBreakdown()
        for pod in pods {
            let s = pod.stateSummary()
            if s.isCompleted { b.completed += 1; continue }
            let phase = pod.status?.phase
            if phase == "Failed" || s.reason == "Evicted" || s.reason == "Error" { b.failed += 1 }
            else if pod.isPendingForCounts(s) { b.pending += 1 }
            else if s.severity == .critical || s.severity == .warning { b.crashing += 1 }
            else { b.healthy += 1 }
        }
        return b
    }
}

// MARK: - Version skew

public struct KubeSemVer: Comparable, Hashable, Sendable {
    public var major: Int, minor: Int, patch: Int
    public init(major: Int, minor: Int, patch: Int) { self.major = major; self.minor = minor; self.patch = patch }

    /// Parses `v1.31.3`, `v1.30.6+k3s1`, `1.29.8-eks-a737599`.
    public init?(_ string: String) {
        var s = Substring(string)
        if s.hasPrefix("v") { s = s.dropFirst() }
        let core = s.prefix { $0.isNumber || $0 == "." }
        let parts = core.split(separator: ".").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        self.init(major: parts[0], minor: parts[1], patch: parts.count > 2 ? parts[2] : 0)
    }

    public static func < (a: KubeSemVer, b: KubeSemVer) -> Bool { (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch) }
}

public struct VersionSkew: Sendable, Hashable {
    public struct VersionCount: Hashable, Sendable, Identifiable {
        public var version: String
        public var count: Int
        public var id: String { version }
    }
    public var apiVersion: String?
    public var kubelets: [VersionCount] = []
    /// Largest number of minor versions a kubelet is behind the API server.
    public var maxMinorLag = 0
    public var kubeletNewerThanAPI = false
    public var isMixed: Bool { kubelets.count > 1 }

    /// Alerts only for a kubelet newer than the API server or two or more minor versions behind (one behind is a normal rolling upgrade).
    public var severity: HealthStatus? { kubeletNewerThanAPI || maxMinorLag >= 2 ? .warning : nil }

    public var summary: String {
        if kubeletNewerThanAPI { return "kubelet is newer than the API server" }
        if maxMinorLag > 0 { return "kubelet \(maxMinorLag) minor version\(maxMinorLag == 1 ? "" : "s") behind the API server" }
        if isMixed { return "\(kubelets.count) patch versions across nodes" }
        return "Versions aligned"
    }

    public static func analyze(apiVersion: String?, nodes: [Node]) -> VersionSkew {
        var skew = VersionSkew(apiVersion: apiVersion)
        var counts: [String: Int] = [:]
        for n in nodes { if let v = n.status?.nodeInfo?.kubeletVersion { counts[v, default: 0] += 1 } }
        skew.kubelets = counts.map { VersionCount(version: $0.key, count: $0.value) }.sorted { ($0.count, $0.version) > ($1.count, $1.version) }
        if let api = apiVersion.flatMap(KubeSemVer.init) {
            for entry in skew.kubelets {
                guard let k = KubeSemVer(entry.version) else { continue }
                if k.major == api.major {
                    if k.minor > api.minor { skew.kubeletNewerThanAPI = true }
                    skew.maxMinorLag = max(skew.maxMinorLag, api.minor - k.minor)
                }
            }
        }
        return skew
    }
}

// MARK: - Alerts

public struct DashboardAlert: Identifiable, Hashable, Sendable {
    public enum Category: String, Sendable { case workload, node, job, storage, cluster, version }
    public var id: String
    public var clusterID: ClusterID
    public var severity: HealthStatus
    public var category: Category
    public var symbol: String
    public var title: String
    public var detail: String
    public var resource: ResourceRef?
    public var since: Date?

    public init(item: AttentionItem) {
        id = item.id
        clusterID = item.clusterID
        severity = item.severity
        title = item.title
        detail = item.detail
        resource = item.resource
        since = item.since
        switch item.kind {
        case .crashLoop, .oomKilled, .imagePull, .configError, .podPending, .podFailed, .highRestarts, .deploymentUnavailable, .deploymentDegraded:
            category = .workload
        case .nodeNotReady, .nodePressure, .nodeCordoned: category = .node
        case .jobFailed: category = .job
        case .pvcPending: category = .storage
        case .unreachable, .credentialsExpiring: category = .cluster
        }
        switch item.kind {
        case .crashLoop: symbol = "arrow.triangle.2.circlepath"
        case .oomKilled: symbol = "memorychip"
        case .imagePull: symbol = "shippingbox"
        case .configError: symbol = "gearshape.trianglebadge.exclamationmark"
        case .podPending: symbol = "hourglass"
        case .podFailed: symbol = "xmark.octagon"
        case .highRestarts: symbol = "arrow.counterclockwise"
        case .nodeNotReady: symbol = "server.rack"
        case .nodePressure: symbol = "gauge.with.dots.needle.100percent"
        case .nodeCordoned: symbol = "nosign"
        case .jobFailed: symbol = "calendar.badge.exclamationmark"
        case .deploymentUnavailable, .deploymentDegraded: symbol = "square.stack.3d.up.trianglebadge.exclamationmark"
        case .pvcPending: symbol = "externaldrive.badge.exclamationmark"
        case .unreachable: symbol = "wifi.slash"
        case .credentialsExpiring: symbol = "key.horizontal"
        }
    }

    public init(skew: VersionSkew, clusterID: ClusterID, severity: HealthStatus) {
        id = "\(clusterID)/version-skew"
        self.clusterID = clusterID
        self.severity = severity
        category = .version
        symbol = "arrow.up.arrow.down.circle"
        title = "Version skew"
        detail = "\(skew.summary) · API \(skew.apiVersion ?? "?"), kubelets \(skew.kubelets.map(\.version).joined(separator: ", "))"
        resource = nil
        since = nil
    }

    /// Ranked critical → warning → unknown, then recency.
    public static func ranked(healths: [ClusterHealth], skews: [ClusterID: VersionSkew]) -> [DashboardAlert] {
        var all = healths.flatMap(\.items).map(DashboardAlert.init(item:))
        for h in healths where h.isReachable {
            if let skew = skews[h.clusterID], let sev = skew.severity { all.append(DashboardAlert(skew: skew, clusterID: h.clusterID, severity: sev)) }
        }
        return all.sorted { a, b in
            if a.severity != b.severity { return a.severity > b.severity }
            if (a.since ?? .distantPast) != (b.since ?? .distantPast) { return (a.since ?? .distantPast) > (b.since ?? .distantPast) }
            return a.id < b.id
        }
    }
}

/// Which alerts the user has looked at, in memory only.
@MainActor @Observable
public final class AlertsSeen {
    public static let shared = AlertsSeen()
    public private(set) var seen: Set<String> = []
    public init() {}
    public func isSeen(_ id: String) -> Bool { seen.contains(id) }
    public func markSeen(_ ids: some Sequence<String>) { seen.formUnion(ids) }
    public func markUnseen(_ id: String) { seen.remove(id) }
    public func unseenCount(in alerts: [DashboardAlert]) -> Int { alerts.filter { !seen.contains($0.id) }.count }
}
