import Foundation

/// Keeps Secret values out of list caches. Lists and counts only need names, types and key names, so every value is
/// blanked the moment a response arrives (the key set survives for "N keys" and search). Full objects are fetched only by
/// the Secret detail screen, behind the reveal/auth flow.
public enum SecretRedaction {
    /// `data` values and `binaryData` values become `""`; `stringData` is dropped; `last-applied-configuration` (which can embed values) is removed.
    public static func strip(_ raw: JSONValue) -> JSONValue {
        guard case .object(var obj) = raw else { return raw }
        if case .object(let data)? = obj["data"] { obj["data"] = .object(data.mapValues { _ in .string("") }) }
        if case .object(let data)? = obj["binaryData"] { obj["binaryData"] = .object(data.mapValues { _ in .string("") }) }
        obj["stringData"] = nil
        if case .object(var meta)? = obj["metadata"], case .object(var ann)? = meta["annotations"] {
            ann["kubectl.kubernetes.io/last-applied-configuration"] = nil
            meta["annotations"] = .object(ann)
            obj["metadata"] = .object(meta)
        }
        return .object(obj)
    }

    /// Strips a raw list response (`items`).
    public static func stripList(_ raw: JSONValue) -> JSONValue {
        guard case .object(var obj) = raw, case .array(let items)? = obj["items"] else { return strip(raw) }
        obj["items"] = .array(items.map(strip))
        return .object(obj)
    }
}

/// Decorator over any client that redacts Secret values from list/watch results. Everything else is forwarded untouched.
/// Use it for Secret *lists* (`ResourceStore(client: SecretStrippingClient(base), kind: .secret, …)`).
public struct SecretStrippingClient: KubeClientProtocol {
    private let base: any KubeClientProtocol
    public init(_ base: any KubeClientProtocol) { self.base = base }

    private func redact<T: KubeObject>(_ item: T) -> T {
        guard let u = item as? Unstructured, let out = Unstructured(raw: SecretRedaction.strip(u.raw)) as? T else { return item }
        return out
    }

    public func version() async throws -> KubeVersion { try await base.version() }
    public func discovery() async throws -> DiscoveryInfo { try await base.discovery() }

    public func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        var list = try await base.list(type, kind: kind, namespace: namespace, options: options)
        list.items = list.items.map(redact)
        return list
    }
    public func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T {
        redact(try await base.get(type, kind: kind, name: name, namespace: namespace))
    }
    public func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue {
        SecretRedaction.stripList(try await base.listRaw(kind, namespace: namespace, options: options))
    }
    public func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue {
        SecretRedaction.strip(try await base.getRaw(kind, name: name, namespace: namespace))
    }
    public func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        let upstream = base.watch(type, kind: kind, namespace: namespace, options: options)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await event in upstream {
                        switch event {
                        case .added(let o): continuation.yield(.added(redact(o)))
                        case .modified(let o): continuation.yield(.modified(redact(o)))
                        case .deleted(let o): continuation.yield(.deleted(redact(o)))
                        case .bookmark(let rv): continuation.yield(.bookmark(resourceVersion: rv))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    public func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try await base.create(kind, namespace: namespace, name: name, subresource: subresource, body: body, options: options)
    }
    public func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try await base.replace(kind, name: name, namespace: namespace, body: body, options: options)
    }
    public func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue {
        try await base.patch(kind, name: name, namespace: namespace, subresource: subresource, patch: patch, options: options)
    }
    public func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws {
        try await base.delete(kind, name: name, namespace: namespace, options: options)
    }
    public func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { base.logs(namespace: namespace, pod: pod, options: options) }
    public func podMetrics(namespace: String?) async throws -> [PodMetrics] { try await base.podMetrics(namespace: namespace) }
    public func nodeMetrics() async throws -> [NodeMetrics] { try await base.nodeMetrics() }
    public func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data {
        try await base.proxyGET(namespace: namespace, service: service, port: port, path: path, query: query)
    }
    public func prepareStreaming() async throws { try await base.prepareStreaming() }
    public func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { try base.execWebSocket(namespace: namespace, pod: pod, options: options) }
    public func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { try base.portForwardWebSocket(namespace: namespace, pod: pod, ports: ports) }
}
