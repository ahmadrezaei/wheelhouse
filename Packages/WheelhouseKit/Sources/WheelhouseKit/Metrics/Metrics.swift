import Foundation

public enum MetricsAvailability: String, Codable, Sendable, Equatable {
    case none, metricsServer, prometheus, both
    public var hasLiveUsage: Bool { self == .metricsServer || self == .both }
    public var hasHistory: Bool { self == .prometheus || self == .both }
    public var footnote: String {
        switch self {
        case .none: "No metrics source found. Showing requests and limits only."
        case .metricsServer: "Live usage from metrics-server. History needs Prometheus."
        case .prometheus: "History from Prometheus."
        case .both: "Live usage from metrics-server · history from Prometheus."
        }
    }
}

public struct MetricPoint: Hashable, Sendable {
    public var time: Date
    public var value: Double
    public init(time: Date, value: Double) { self.time = time; self.value = value }
}

public struct TimeSeries: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var labels: [String: String]
    public var points: [MetricPoint]
    public init(id: String? = nil, name: String, labels: [String: String] = [:], points: [MetricPoint]) {
        self.id = id ?? name + labels.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ",")
        self.name = name
        self.labels = labels
        self.points = points
    }
    public var last: Double? { points.last?.value }
    public var peak: Double? { points.map(\.value).max() }
}

public enum MetricsRange: String, CaseIterable, Sendable, Identifiable {
    case hour = "1H", sixHours = "6H", day = "24H", week = "7D"
    public var id: String { rawValue }
    public var duration: TimeInterval {
        switch self { case .hour: 3600; case .sixHours: 6 * 3600; case .day: 86_400; case .week: 7 * 86_400 }
    }
    /// Query resolution giving roughly 120–170 points.
    public var step: TimeInterval { duration / 144 }
}

/// Where Prometheus lives: behind the API-server service proxy, or at a user-provided URL.
///
/// Deliberately not `Codable`: the `url` case carries a bearer token that must never be persisted or cached with the endpoint.
public enum PrometheusEndpoint: Hashable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    case service(namespace: String, name: String, port: String)
    case url(URL, bearerToken: String?)

    public var description: String {
        switch self {
        case .service(let ns, let name, let port): "service \(ns)/\(name):\(port) via API proxy"
        case .url(let url, _): url.absoluteString
        }
    }
    public var debugDescription: String { description }   // never print the token
    public var customMirror: Mirror { Mirror(self, children: [("endpoint", description)], displayStyle: .enum) }
}

/// PromQL templates for the dashboards (kube-prometheus-stack metric names).
public enum PromQL {
    public static let clusterCPUUsage = #"sum(rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[5m]))"#
    public static let clusterCPURequests = #"sum(kube_pod_container_resource_requests{resource="cpu"})"#
    public static let clusterCPUAllocatable = #"sum(kube_node_status_allocatable{resource="cpu"})"#
    public static let clusterMemoryUsage = #"sum(container_memory_working_set_bytes{container!="",container!="POD"})"#
    public static let clusterMemoryRequests = #"sum(kube_pod_container_resource_requests{resource="memory"})"#
    public static let clusterMemoryAllocatable = #"sum(kube_node_status_allocatable{resource="memory"})"#
    public static let nodeCPUFraction = #"1 - avg by (instance)(rate(node_cpu_seconds_total{mode="idle"}[5m]))"#
    public static let podRestarts = #"sum by (namespace,pod)(increase(kube_pod_container_status_restarts_total[1h]))"#

    public static func podCPU(namespace: String, pod: String) -> String {
        #"sum(rate(container_cpu_usage_seconds_total{namespace="\#(namespace)",pod="\#(pod)",container!="",container!="POD"}[5m]))"#
    }
    public static func podMemory(namespace: String, pod: String) -> String {
        #"sum(container_memory_working_set_bytes{namespace="\#(namespace)",pod="\#(pod)",container!="",container!="POD"})"#
    }
}

/// Queries a Prometheus endpoint (via service proxy or direct URL) and returns simple series.
public struct PrometheusClient: Sendable {
    public let endpoint: PrometheusEndpoint
    private let kube: any KubeClientProtocol
    private let session: URLSession
    /// Refuse cleartext `http://` for a direct URL (set for production clusters; the bearer token would travel unencrypted).
    private let requireHTTPS: Bool

    public init(endpoint: PrometheusEndpoint, kube: any KubeClientProtocol, session: URLSession = .shared, requireHTTPS: Bool = false) {
        self.endpoint = endpoint
        self.kube = kube
        self.session = session
        self.requireHTTPS = requireHTTPS
    }

    private func get(path: String, query: [String: String]) async throws -> Data {
        switch endpoint {
        case .service(let ns, let name, let port):
            return try await kube.proxyGET(namespace: ns, service: name, port: port, path: path, query: query)
        case .url(let base, let token):
            guard var comps = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false) else { throw KubeError.unreachable(cause: "Invalid Prometheus URL") }
            comps.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let url = comps.url else { throw KubeError.unreachable(cause: "Invalid Prometheus URL") }
            if requireHTTPS, url.scheme?.lowercased() != "https" {
                throw KubeError.unreachable(cause: "Plain HTTP is not allowed for production clusters. Use an https:// Prometheus URL.")
            }
            var request = URLRequest(url: url, timeoutInterval: 20)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            do {
                let (data, response) = try await session.data(for: request)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw KubeError.from(httpStatus: http.statusCode, status: nil, fallback: "Prometheus returned HTTP \(http.statusCode)")
                }
                return data
            } catch let e as KubeError { throw e } catch { throw KubeError.unreachable(cause: error.localizedDescription) }
        }
    }

    /// `GET /api/v1/query_range`
    public func queryRange(_ query: String, name: String, range: MetricsRange, end: Date = Date()) async throws -> [TimeSeries] {
        let start = end.addingTimeInterval(-range.duration)
        let data = try await get(path: "/api/v1/query_range", query: [
            "query": query, "start": String(start.timeIntervalSince1970), "end": String(end.timeIntervalSince1970), "step": String(Int(range.step)),
        ])
        return try Self.parseMatrix(data, name: name)
    }

    /// `GET /api/v1/query` (instant vector) as one-point series.
    public func query(_ query: String, name: String) async throws -> [TimeSeries] {
        let data = try await get(path: "/api/v1/query", query: ["query": query])
        return try Self.parseMatrix(data, name: name)
    }

    public func isReady() async -> Bool {
        (try? await get(path: "/api/v1/status/buildinfo", query: [:])) != nil
    }

    // MARK: Parsing

    static func parseMatrix(_ data: Data, name: String) throws -> [TimeSeries] {
        let json: JSONValue
        do { json = try JSONValue.parse(data) } catch { throw KubeError.decoding("Prometheus response is not JSON") }
        guard json["status"]?.stringValue == "success" else {
            throw KubeError.server(Status(status: "Failure", message: json["error"]?.stringValue ?? "Prometheus query failed", code: 400))
        }
        let result = json["data"]?["result"]?.arrayValue ?? []
        let type = json["data"]?["resultType"]?.stringValue
        return result.compactMap { r -> TimeSeries? in
            let labels = (r["metric"]?.objectValue ?? [:]).compactMapValues(\.stringValue)
            var pairs: [JSONValue] = r["values"]?.arrayValue ?? []
            if type == "vector", let v = r["value"] { pairs = [v] }
            let points = pairs.compactMap { pair -> MetricPoint? in
                guard let t = pair[0]?.doubleValue, let v = pair[1]?.doubleValue, v.isFinite else { return nil }
                return MetricPoint(time: Date(timeIntervalSince1970: t), value: v)
            }
            return TimeSeries(name: name, labels: labels, points: points)
        }
    }
}

/// Detects and queries metrics sources for one cluster.
public struct MetricsService: Sendable {
    private let client: any KubeClientProtocol
    private let userPrometheusURL: URL?
    private let userToken: String?

    public init(client: any KubeClientProtocol, prometheusURL: URL? = nil, prometheusToken: String? = nil) {
        self.client = client
        self.userPrometheusURL = prometheusURL
        self.userToken = prometheusToken
    }

    public func hasMetricsServer() async -> Bool { (try? await client.nodeMetrics()) != nil }

    /// Well-known Prometheus service names and namespaces (kube-prometheus-stack, prometheus-operator, community chart).
    static let candidateNamespaces = ["monitoring", "prometheus", "observability", "kube-prometheus-stack", "kube-system", "default", "openshift-monitoring"]
    static let candidateNames = ["prometheus-operated", "prometheus-k8s", "kube-prometheus-stack-prometheus", "prometheus-server", "prometheus"]

    /// User URL first; otherwise look for known services and verify through the API proxy.
    public func discoverPrometheus() async -> PrometheusEndpoint? {
        if let url = userPrometheusURL {
            let endpoint = PrometheusEndpoint.url(url, bearerToken: userToken)
            if await prometheus(endpoint).isReady() { return endpoint }
        }
        for ns in Self.candidateNamespaces {
            guard let services = try? await client.list(Service.self, namespace: ns, options: ListOptions(limit: 200)).items else { continue }
            let match = services.first { Self.candidateNames.contains($0.metadata.name) }
                ?? services.first { $0.metadata.labels["app.kubernetes.io/name"] == "prometheus" }
            guard let svc = match else { continue }
            let port = svc.spec.ports.first { ["web", "http-web", "http", "prometheus"].contains($0.name ?? "") } ?? svc.spec.ports.first { $0.port == 9090 } ?? svc.spec.ports.first
            guard let port else { continue }
            let endpoint = PrometheusEndpoint.service(namespace: ns, name: svc.metadata.name, port: port.name ?? String(port.port))
            if await PrometheusClient(endpoint: endpoint, kube: client).isReady() { return endpoint }
        }
        return nil
    }

    public func availability() async -> (MetricsAvailability, PrometheusEndpoint?) {
        async let ms = hasMetricsServer()
        async let prom = discoverPrometheus()
        let (hasMS, endpoint) = await (ms, prom)
        switch (hasMS, endpoint != nil) {
        case (true, true): return (.both, endpoint)
        case (true, false): return (.metricsServer, nil)
        case (false, true): return (.prometheus, endpoint)
        case (false, false): return (.none, nil)
        }
    }

    public func prometheus(_ endpoint: PrometheusEndpoint) -> PrometheusClient {
        // A direct URL must honour the cluster's CA / skip-verify settings, not just the system trust store.
        let session = (client as? LiveKubeClient)?.auxiliarySession() ?? .shared
        return PrometheusClient(endpoint: endpoint, kube: client, session: session, requireHTTPS: (client as? LiveKubeClient)?.config.isProduction ?? false)
    }
}

extension Array where Element == MetricPoint {
    /// At most `limit` points: buckets are averaged (time and value) and the last point is kept exactly, so a chart with
    /// thousands of samples renders as many marks as the screen can show (a phone is ~400 px wide).
    public func downsampled(to limit: Int = 160) -> [MetricPoint] {
        guard limit >= 2, count > limit else { return self }
        let bucketSize = Double(count - 1) / Double(limit - 1)
        var out: [MetricPoint] = []
        out.reserveCapacity(limit)
        var start = 0
        for b in 0..<(limit - 1) {
            let end = Swift.min(count - 1, Swift.max(start + 1, Int((Double(b + 1) * bucketSize).rounded(.down))))
            let slice = self[start..<end]
            let t = slice.map { $0.time.timeIntervalSinceReferenceDate }.reduce(0, +) / Double(slice.count)
            let v = slice.map(\.value).reduce(0, +) / Double(slice.count)
            out.append(MetricPoint(time: Date(timeIntervalSinceReferenceDate: t), value: v))
            start = end
        }
        out.append(self[count - 1])
        return out
    }
}
