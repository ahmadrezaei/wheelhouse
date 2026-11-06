import Foundation

/// Prometheus series for the dashboards.
public struct PromUsageSeries: Sendable {
    public var cpuUsage: [MetricPoint] = []
    public var cpuRequests: [MetricPoint] = []
    public var memUsage: [MetricPoint] = []
    public var memRequests: [MetricPoint] = []
    public var cpuAllocatable: Double?
    public var memAllocatable: Double?
    public var range: MetricsRange = .hour
    public var isEmpty: Bool { cpuUsage.count < 2 && memUsage.count < 2 }
    public init() {}

    /// Usage points divided by a capacity, for sparklines.
    public func cpuFractions(since: Date? = nil) -> [Double] {
        guard let cap = cpuAllocatable, cap > 0 else { return [] }
        let cutoff = since ?? .distantPast
        return cpuUsage.filter { $0.time >= cutoff }.map { $0.value / cap }
    }
}

public enum DashboardPrometheus {
    /// Loads CPU + memory usage and requests plus allocatable. Failed queries leave their series empty.
    public static func load(_ client: PrometheusClient, range: MetricsRange, end: Date = Date()) async -> PromUsageSeries {
        async let cu = try? client.queryRange(PromQL.clusterCPUUsage, name: "CPU", range: range, end: end)
        async let cr = try? client.queryRange(PromQL.clusterCPURequests, name: "CPU requests", range: range, end: end)
        async let mu = try? client.queryRange(PromQL.clusterMemoryUsage, name: "Memory", range: range, end: end)
        async let mr = try? client.queryRange(PromQL.clusterMemoryRequests, name: "Memory requests", range: range, end: end)
        async let ca = try? client.query(PromQL.clusterCPUAllocatable, name: "CPU allocatable")
        async let ma = try? client.query(PromQL.clusterMemoryAllocatable, name: "Memory allocatable")
        var s = PromUsageSeries()
        s.range = range
        s.cpuUsage = await cu?.first?.points ?? []
        s.cpuRequests = await cr?.first?.points ?? []
        s.memUsage = await mu?.first?.points ?? []
        s.memRequests = await mr?.first?.points ?? []
        s.cpuAllocatable = await ca?.first?.last
        s.memAllocatable = await ma?.first?.last
        return s
    }
}

public enum SeriesMath {
    /// Adds series point-by-point, aligning on `bucket`-second slots (series from one `end` and `step` share timestamps).
    public static func sum(_ series: [[MetricPoint]], bucket: TimeInterval) -> [MetricPoint] {
        var acc: [Int: (Date, Double)] = [:]
        for points in series {
            for p in points {
                let slot = Int((p.time.timeIntervalSince1970 / bucket).rounded())
                let current = acc[slot] ?? (p.time, 0)
                acc[slot] = (current.0, current.1 + p.value)
            }
        }
        return acc.keys.sorted().compactMap { k in acc[k].map { MetricPoint(time: $0.0, value: $0.1) } }
    }

    /// Value of a node-name label e.g. `ip-10-2-4-5.eu-west-1.compute.internal` → `ip-10-2-4-5`.
    public static func shortNodeName(_ name: String) -> String {
        var head = name.split(separator: ".").first.map(String.init) ?? name
        guard head.hasPrefix("ip-") else { return head }
        head = String(head.dropFirst(3))
        return head.count > 8 ? String(head.suffix(8)).trimmingCharacters(in: CharacterSet.alphanumerics.inverted) : head
    }
}
