import Foundation

/// The only door from the toolbox to a cluster client, and it only opens for reads.
///
/// This is a struct of read closures, not a ``KubeClientProtocol``: it has no `create`, `replace`, `patch`, `delete`, exec or
/// port-forward member, so code that holds one cannot change a cluster (a compile-time guarantee, ARCHITECTURE-MAC section 9.2).
/// The single POST it can make is a `SelfSubjectAccessReview`, built here from fixed fields; that request is read-only in
/// effect and is classified as `.review` by ``MutationPolicy``.
///
/// This file is the only file in `Toolbox/` that may name ``KubeClientProtocol`` (`ToolboxStructureTests` checks it).
public struct ReadOnlyKubeAccess: Sendable {
    public typealias DiscoveryFn = @Sendable () async throws -> DiscoveryInfo
    public typealias ListRawFn = @Sendable (ResourceKind, String?, ListOptions) async throws -> JSONValue
    public typealias GetRawFn = @Sendable (ResourceKind, String, String?) async throws -> JSONValue
    public typealias LogsFn = @Sendable (String, String, LogOptions) -> AsyncThrowingStream<String, Error>
    public typealias PodMetricsFn = @Sendable (String?) async throws -> [PodMetrics]
    public typealias NodeMetricsFn = @Sendable () async throws -> [NodeMetrics]
    public typealias CanIFn = @Sendable (AccessQuestion) async throws -> Bool

    /// What `rbac_can_i` asks (a `SelfSubjectAccessReview` for the current identity).
    public struct AccessQuestion: Sendable, Hashable {
        public var verb: String
        public var group: String
        public var resource: String
        public var subresource: String?
        public var namespace: String?
        public var name: String?
        public init(verb: String, group: String = "", resource: String, subresource: String? = nil, namespace: String? = nil, name: String? = nil) {
            self.verb = verb
            self.group = group
            self.resource = resource
            self.subresource = subresource
            self.namespace = namespace
            self.name = name
        }
    }

    public let discovery: DiscoveryFn
    public let listRaw: ListRawFn
    public let getRaw: GetRawFn
    public let logs: LogsFn
    public let podMetrics: PodMetricsFn
    public let nodeMetrics: NodeMetricsFn
    public let canI: CanIFn

    /// Closure-based initialiser for tests and fakes (internal: the app wraps a client with `init(_:)`). Anything not supplied
    /// fails with ``KubeError/unsupported(_:)``.
    init(
        discovery: @escaping DiscoveryFn = { throw KubeError.unsupported("discovery") },
        listRaw: @escaping ListRawFn = { _, _, _ in throw KubeError.unsupported("list") },
        getRaw: @escaping GetRawFn = { _, _, _ in throw KubeError.unsupported("get") },
        logs: @escaping LogsFn = { _, _, _ in AsyncThrowingStream { $0.finish(throwing: KubeError.unsupported("logs")) } },
        podMetrics: @escaping PodMetricsFn = { _ in throw KubeError.unsupported("metrics") },
        nodeMetrics: @escaping NodeMetricsFn = { throw KubeError.unsupported("metrics") },
        canI: @escaping CanIFn = { _ in throw KubeError.unsupported("access review") }
    ) {
        self.discovery = discovery
        self.listRaw = listRaw
        self.getRaw = getRaw
        self.logs = logs
        self.podMetrics = podMetrics
        self.nodeMetrics = nodeMetrics
        self.canI = canI
    }

    /// Wraps a client, keeping only its read functions.
    public init(_ client: any KubeClientProtocol) {
        self.init(
            discovery: { try await client.discovery() },
            listRaw: { kind, namespace, options in try await client.listRaw(kind, namespace: namespace, options: options) },
            getRaw: { kind, name, namespace in try await client.getRaw(kind, name: name, namespace: namespace) },
            logs: { namespace, pod, options in client.logs(namespace: namespace, pod: pod, options: options) },
            podMetrics: { namespace in try await client.podMetrics(namespace: namespace) },
            nodeMetrics: { try await client.nodeMetrics() },
            canI: { question in
                var attributes: [String: JSONValue] = [
                    "verb": .string(question.verb), "group": .string(question.group), "resource": .string(question.resource),
                    "subresource": .string(question.subresource ?? ""),
                ]
                if let namespace = question.namespace, !namespace.isEmpty { attributes["namespace"] = .string(namespace) }
                if let name = question.name, !name.isEmpty { attributes["name"] = .string(name) }
                let body: JSONValue = [
                    "apiVersion": "authorization.k8s.io/v1", "kind": "SelfSubjectAccessReview",
                    "spec": ["resourceAttributes": .object(attributes)],
                ]
                let result = try await client.create(.selfSubjectAccessReview, namespace: nil, body: body)
                return result.value(at: "status.allowed")?.boolValue == true
            }
        )
    }
}
