import Foundation
import Synchronization

// MARK: - Options & value types

public struct KubeVersion: Codable, Hashable, Sendable {
    public var major: String?
    public var minor: String?
    public var gitVersion: String
    public var platform: String?
    public var buildDate: String?
}

public struct ListOptions: Hashable, Sendable {
    public var labelSelector: String?
    public var fieldSelector: String?
    public var limit: Int?
    public var resourceVersion: String?
    public init(labelSelector: String? = nil, fieldSelector: String? = nil, limit: Int? = nil, resourceVersion: String? = nil) {
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
        self.limit = limit
        self.resourceVersion = resourceVersion
    }
}

public struct WatchOptions: Hashable, Sendable {
    public var labelSelector: String?
    public var fieldSelector: String?
    public var resourceVersion: String?
    public var timeoutSeconds: Int
    public init(labelSelector: String? = nil, fieldSelector: String? = nil, resourceVersion: String? = nil, timeoutSeconds: Int = 290) {
        self.labelSelector = labelSelector
        self.fieldSelector = fieldSelector
        self.resourceVersion = resourceVersion
        self.timeoutSeconds = timeoutSeconds
    }
}

public enum WatchEvent<T: Sendable>: Sendable {
    case added(T)
    case modified(T)
    case deleted(T)
    case bookmark(resourceVersion: String)
}

public enum PropagationPolicy: String, Sendable { case foreground = "Foreground", background = "Background", orphan = "Orphan" }

public struct DeleteOptions: Hashable, Sendable {
    public var propagation: PropagationPolicy?
    public var gracePeriodSeconds: Int?
    public var dryRun: Bool
    public init(propagation: PropagationPolicy? = .background, gracePeriodSeconds: Int? = nil, dryRun: Bool = false) {
        self.propagation = propagation
        self.gracePeriodSeconds = gracePeriodSeconds
        self.dryRun = dryRun
    }
}

public struct MutationOptions: Hashable, Sendable {
    public var dryRun: Bool
    public var fieldManager: String
    public var force: Bool
    public init(dryRun: Bool = false, fieldManager: String = "wheelhouse", force: Bool = false) {
        self.dryRun = dryRun
        self.fieldManager = fieldManager
        self.force = force
    }
}

/// Patch flavours supported by the API server.
public enum KubePatch: Sendable {
    case merge(JSONValue)
    case strategicMerge(JSONValue)
    case json([JSONValue])
    /// Server-side apply with a full (or partial) object body.
    case apply(JSONValue)

    public var contentType: String {
        switch self {
        case .merge: "application/merge-patch+json"
        case .strategicMerge: "application/strategic-merge-patch+json"
        case .json: "application/json-patch+json"
        case .apply: "application/apply-patch+yaml"
        }
    }
    public var body: JSONValue {
        switch self {
        case .merge(let v), .strategicMerge(let v), .apply(let v): v
        case .json(let ops): .array(ops)
        }
    }
}

public struct LogOptions: Hashable, Sendable {
    public var container: String?
    public var follow: Bool
    public var previous: Bool
    public var timestamps: Bool
    public var tailLines: Int?
    public var sinceSeconds: Int?
    public var limitBytes: Int?
    /// RFC 3339 timestamp; only lines at or after it (used by the non-follow polling fallback). Exclusive with `sinceSeconds`.
    public var sinceTime: String?
    public init(container: String? = nil, follow: Bool = false, previous: Bool = false, timestamps: Bool = false,
                tailLines: Int? = 500, sinceSeconds: Int? = nil, limitBytes: Int? = nil, sinceTime: String? = nil) {
        self.sinceTime = sinceTime
        self.container = container
        self.follow = follow
        self.previous = previous
        self.timestamps = timestamps
        self.tailLines = tailLines
        self.sinceSeconds = sinceSeconds
        self.limitBytes = limitBytes
    }
}

public struct ExecOptions: Hashable, Sendable {
    public var container: String?
    public var command: [String]
    public var tty: Bool
    public var stdin: Bool
    public init(container: String? = nil, command: [String] = ["/bin/sh"], tty: Bool = true, stdin: Bool = true) {
        self.container = container
        self.command = command
        self.tty = tty
        self.stdin = stdin
    }
}

/// Thin Sendable wrapper over a connected `URLSessionWebSocketTask` plus the negotiated subprotocol candidates.
public final class KubeWebSocket: @unchecked Sendable {
    public let task: URLSessionWebSocketTask
    /// Subprotocols offered, in preference order (e.g. `v5.channel.k8s.io`, `v4.channel.k8s.io`).
    public let offeredProtocols: [String]
    /// The certificate rejection (if any) recorded for this socket's upgrade request, so callers can report
    /// "untrusted certificate" instead of a bare cancellation.
    public let tlsFailure: @Sendable () -> TLSFailureInfo?
    /// Why the client certificate could not be presented, if the server asked for one.
    public let identityFailure: @Sendable () -> String?
    /// The server asked for a client certificate and the cluster has none configured.
    public let clientCertificateMissing: @Sendable () -> Bool
    private let keepAlive = Mutex<Task<Void, Never>?>(nil)

    public init(task: URLSessionWebSocketTask, offeredProtocols: [String], tlsFailure: @escaping @Sendable () -> TLSFailureInfo? = { nil }, identityFailure: @escaping @Sendable () -> String? = { nil }, clientCertificateMissing: @escaping @Sendable () -> Bool = { false }) {
        self.identityFailure = identityFailure
        self.clientCertificateMissing = clientCertificateMissing
        self.task = task
        self.offeredProtocols = offeredProtocols
        self.tlsFailure = tlsFailure
    }
    /// Subprotocol selected by the server (from the upgrade response); valid after the socket opened.
    public var negotiatedProtocol: String? {
        (task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
    }
    public func resume() {
        task.resume()
        let ping = Task { [task] in
            // Idle shells and port-forward tunnels would otherwise be dropped by NATs and load balancers.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, task.state == .running else { return }
                task.sendPing { _ in }
            }
        }
        keepAlive.withLock { $0?.cancel(); $0 = ping }
    }
    public func send(_ data: Data) async throws { try await task.send(.data(data)) }
    public func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    public func close(code: URLSessionWebSocketTask.CloseCode = .normalClosure) {
        keepAlive.withLock { $0?.cancel(); $0 = nil }
        task.cancel(with: code, reason: nil)
    }
    deinit { keepAlive.withLock { $0?.cancel() } }
}

// MARK: - Discovery

public struct APIResource: Codable, Hashable, Sendable {
    public var name: String
    public var singularName: String?
    public var namespaced: Bool
    public var kind: String
    public var verbs: [String]
    public var shortNames: [String]?
    public var group: String?
    public var version: String?
}

public struct DiscoveryInfo: Codable, Hashable, Sendable {
    public var fetchedAt: Date
    public var resources: [APIResource]

    public init(fetchedAt: Date = Date(), resources: [APIResource]) {
        self.fetchedAt = fetchedAt
        self.resources = resources
    }

    /// Top-level resources (no subresources like `pods/log`).
    public var topLevel: [APIResource] { resources.filter { !$0.name.contains("/") } }

    /// Kinds the cluster serves that are not built in — i.e. custom resources.
    public var customKinds: [ResourceKind] {
        let builtIn = Set(ResourceKind.builtIn.map { "\($0.group)/\($0.plural)" })
        return topLevel.compactMap { r in
            guard let version = r.version, let group = r.group, !group.isEmpty,
                  !builtIn.contains("\(group)/\(r.name)"), r.verbs.contains("list") else { return nil }
            return .custom(group: group, version: version, kind: r.kind, plural: r.name, namespaced: r.namespaced)
        }
    }

    public func supports(_ kind: ResourceKind) -> Bool {
        resources.contains { $0.name == kind.plural && ($0.group ?? "") == kind.group }
    }
}

// MARK: - Protocol

/// The single abstraction over a cluster API. Implemented by ``LiveKubeClient`` and ``DemoKubeClient``.
///
/// Mutating calls on a read-only cluster throw ``KubeError/readOnly`` before any request is made.
public protocol KubeClientProtocol: Sendable {
    func version() async throws -> KubeVersion
    func discovery() async throws -> DiscoveryInfo

    // Reads
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T>
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error>

    // Mutations
    /// Creates an object, or posts a subresource (e.g. `pods/eviction`) when `subresource` and `name` are given.
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws

    // Streams
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error>

    // Metrics
    func podMetrics(namespace: String?) async throws -> [PodMetrics]
    func nodeMetrics() async throws -> [NodeMetrics]
    /// GET through the API server service proxy, e.g. Prometheus `/api/v1/query_range`.
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data

    // Sockets (protocols are implemented by feature code)
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket
}

// MARK: - Typed conveniences

public extension KubeClientProtocol {
    func list<T: KubeObject>(_ type: T.Type, namespace: String? = nil, options: ListOptions = ListOptions()) async throws -> KubeList<T> {
        try await list(type, kind: T.resourceKind, namespace: namespace, options: options)
    }
    func get<T: KubeObject>(_ type: T.Type, name: String, namespace: String? = nil) async throws -> T {
        try await get(type, kind: T.resourceKind, name: name, namespace: namespace)
    }
    func watch<T: KubeObject>(_ type: T.Type, namespace: String? = nil, options: WatchOptions = WatchOptions()) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        watch(type, kind: T.resourceKind, namespace: namespace, options: options)
    }
    func create(_ kind: ResourceKind, namespace: String?, body: JSONValue, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        try await create(kind, namespace: namespace, name: nil, subresource: nil, body: body, options: options)
    }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, patch: KubePatch, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        try await self.patch(kind, name: name, namespace: namespace, subresource: nil, patch: patch, options: options)
    }
    func logs(namespace: String, pod: String, container: String? = nil, follow: Bool = false) -> AsyncThrowingStream<String, Error> {
        logs(namespace: namespace, pod: pod, options: LogOptions(container: container, follow: follow))
    }

    // MARK: Common actions (each goes through `patch` / `create`, so read-only and dry-run rules apply)

    /// Sets `spec.replicas` through the scale subresource.
    @discardableResult
    func scale(_ kind: ResourceKind, name: String, namespace: String?, replicas: Int, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        try await patch(kind, name: name, namespace: namespace, subresource: "scale",
                        patch: .merge(["spec": ["replicas": .int(replicas)]]), options: options)
    }

    /// Equivalent of `kubectl rollout restart`.
    @discardableResult
    func restartRollout(_ kind: ResourceKind, name: String, namespace: String?, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        let stamp = Date().formatted(.iso8601)
        let body: JSONValue = ["spec": ["template": ["metadata": ["annotations": ["kubectl.kubernetes.io/restartedAt": .string(stamp)]]]]]
        return try await patch(kind, name: name, namespace: namespace, patch: .strategicMerge(body), options: options)
    }

    @discardableResult
    func setCronJobSuspended(name: String, namespace: String, suspended: Bool, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        try await patch(.cronJob, name: name, namespace: namespace, patch: .merge(["spec": ["suspend": .bool(suspended)]]), options: options)
    }

    @discardableResult
    func setNodeUnschedulable(name: String, unschedulable: Bool, options: MutationOptions = MutationOptions()) async throws -> JSONValue {
        try await patch(.node, name: name, namespace: nil, patch: .strategicMerge(["spec": ["unschedulable": unschedulable ? true : .null]]), options: options)
    }

    /// Evicts a pod through the Eviction API (respects PodDisruptionBudgets; throws 429 as `.server`).
    func evict(pod: String, namespace: String, gracePeriodSeconds: Int? = nil, dryRun: Bool = false) async throws {
        var body: JSONValue = [
            "apiVersion": "policy/v1", "kind": "Eviction",
            "metadata": ["name": .string(pod), "namespace": .string(namespace)],
        ]
        if let g = gracePeriodSeconds { body["deleteOptions"] = ["gracePeriodSeconds": .int(g)] }
        _ = try await create(.pod, namespace: namespace, name: pod, subresource: "eviction", body: body, options: MutationOptions(dryRun: dryRun))
    }
}
