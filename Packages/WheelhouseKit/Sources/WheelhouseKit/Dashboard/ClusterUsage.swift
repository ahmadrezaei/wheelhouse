import Foundation
import Observation

/// CPU / memory usage vs allocatable vs requests for one cluster, derived from nodes, metrics-server and pod specs.
public struct ClusterUsage: Sendable, Hashable {
    /// Cores / bytes allocatable on Ready nodes.
    public var cpuAllocatable = 0.0
    public var memAllocatable = 0.0
    /// nil = no usage source (metrics-server missing).
    public var cpuUsage: Double?
    public var memUsage: Double?
    /// Sum of container requests of scheduled, non-terminated pods. nil = pods unknown.
    public var cpuRequests: Double?
    public var memRequests: Double?

    public init() {}

    public var cpuFraction: Double? { Self.fraction(cpuUsage, of: cpuAllocatable) }
    public var memFraction: Double? { Self.fraction(memUsage, of: memAllocatable) }
    public var cpuRequestFraction: Double? { Self.fraction(cpuRequests, of: cpuAllocatable) }
    public var memRequestFraction: Double? { Self.fraction(memRequests, of: memAllocatable) }
    public var hasUsage: Bool { cpuUsage != nil || memUsage != nil }

    static func fraction(_ value: Double?, of total: Double) -> Double? {
        guard let value, total > 0 else { return nil }
        return value / total
    }

    /// - Parameters:
    ///   - nodeMetrics: nil when metrics-server is unavailable.
    ///   - pods: nil when pods have not been loaded.
    public static func compute(nodes: [Node], nodeMetrics: [NodeMetrics]?, pods: [Pod]?) -> ClusterUsage {
        var u = ClusterUsage()
        let ready = nodes.filter(\.isReady)
        u.cpuAllocatable = ready.reduce(0) { $0 + ($1.status?.allocatable?["cpu"]?.cores ?? $1.status?.capacity?["cpu"]?.cores ?? 0) }
        u.memAllocatable = ready.reduce(0) { $0 + ($1.status?.allocatable?["memory"]?.bytes ?? $1.status?.capacity?["memory"]?.bytes ?? 0) }
        if let nodeMetrics {
            let names = Set(ready.map(\.metadata.name))
            let used = nodeMetrics.filter { names.contains($0.metadata.name) }
            u.cpuUsage = used.reduce(0) { $0 + $1.cpuCores }
            u.memUsage = used.reduce(0) { $0 + $1.memoryBytes }
        }
        if let pods {
            var cpu = 0.0, mem = 0.0
            for pod in pods where pod.isCountedForRequests {
                let r = pod.resourceRequests
                cpu += r.cpu; mem += r.memory
            }
            u.cpuRequests = cpu
            u.memRequests = mem
        }
        return u
    }

    public static func sum(_ usages: [ClusterUsage]) -> ClusterUsage {
        var t = ClusterUsage()
        for u in usages {
            t.cpuAllocatable += u.cpuAllocatable
            t.memAllocatable += u.memAllocatable
            if let v = u.cpuUsage { t.cpuUsage = (t.cpuUsage ?? 0) + v }
            if let v = u.memUsage { t.memUsage = (t.memUsage ?? 0) + v }
            if let v = u.cpuRequests { t.cpuRequests = (t.cpuRequests ?? 0) + v }
            if let v = u.memRequests { t.memRequests = (t.memRequests ?? 0) + v }
        }
        return t
    }
}

public extension Pod {
    /// Scheduled and not finished: the pods whose requests the scheduler accounts for.
    var isCountedForRequests: Bool {
        guard spec.nodeName != nil else { return false }
        let phase = status?.phase
        return phase != "Succeeded" && phase != "Failed"
    }

    /// Sum of container requests (limits stand in when only limits are set, as Kubernetes defaults requests to limits).
    var resourceRequests: (cpu: Double, memory: Double) {
        var cpu = 0.0, mem = 0.0
        for c in spec.containers {
            cpu += (c.resources?.requests?["cpu"] ?? c.resources?.limits?["cpu"])?.cores ?? 0
            mem += (c.resources?.requests?["memory"] ?? c.resources?.limits?["memory"])?.bytes ?? 0
        }
        return (cpu, mem)
    }

    /// Sum of container limits; 0 for a resource without limits.
    var resourceLimits: (cpu: Double, memory: Double) {
        var cpu = 0.0, mem = 0.0
        for c in spec.containers {
            cpu += c.resources?.limits?["cpu"]?.cores ?? 0
            mem += c.resources?.limits?["memory"]?.bytes ?? 0
        }
        return (cpu, mem)
    }
}

/// One in-memory usage sample.
public struct UsageSample: Sendable, Hashable {
    public var time: Date
    public var cpuUsage: Double
    public var memUsage: Double
    public var cpuAllocatable: Double
    public var memAllocatable: Double
    public var cpuRequests: Double?
    public var memRequests: Double?

    public init(time: Date = Date(), cpuUsage: Double, memUsage: Double, cpuAllocatable: Double, memAllocatable: Double, cpuRequests: Double? = nil, memRequests: Double? = nil) {
        self.time = time
        self.cpuUsage = cpuUsage
        self.memUsage = memUsage
        self.cpuAllocatable = cpuAllocatable
        self.memAllocatable = memAllocatable
        self.cpuRequests = cpuRequests
        self.memRequests = memRequests
    }

    public init?(usage: ClusterUsage, time: Date = Date()) {
        guard let cpu = usage.cpuUsage, let mem = usage.memUsage else { return nil }
        self.init(time: time, cpuUsage: cpu, memUsage: mem, cpuAllocatable: usage.cpuAllocatable, memAllocatable: usage.memAllocatable,
                  cpuRequests: usage.cpuRequests, memRequests: usage.memRequests)
    }
}

/// Metrics-server values sampled while the app is open, kept in memory only (used when Prometheus is absent).
@MainActor @Observable
public final class UsageHistory {
    public static let shared = UsageHistory()
    public static let fleetKey = "__fleet__"
    public static let maxSamples = 720

    public private(set) var samples: [String: [UsageSample]] = [:]
    public init() {}

    public func record(_ sample: UsageSample, key: String) {
        var list = samples[key] ?? []
        if let last = list.last, sample.time.timeIntervalSince(last.time) < 4 { list[list.count - 1] = sample } else { list.append(sample) }
        if list.count > Self.maxSamples { list.removeFirst(list.count - Self.maxSamples) }
        samples[key] = list
    }

    public func samples(for key: String) -> [UsageSample] { samples[key] ?? [] }
    public func clear() { samples = [:] }
}
