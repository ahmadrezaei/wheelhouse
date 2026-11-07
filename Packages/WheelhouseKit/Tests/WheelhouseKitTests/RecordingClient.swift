import Foundation
@testable import WheelhouseKit

/// A client that records every mutation it is asked to make and changes nothing.
final class RecordingClient: KubeClientProtocol, @unchecked Sendable {
    struct Mutation: Equatable { var verb: String; var dryRun: Bool }
    private let lock = NSLock()
    private var recorded: [Mutation] = []
    private var contentTypes: [String] = []
    private let failMutations: Bool

    init(failMutations: Bool = false) { self.failMutations = failMutations }

    var mutations: [Mutation] { lock.withLock { recorded } }
    var lastPatchContentTypes: [String] { lock.withLock { contentTypes } }

    private func record(_ verb: String, dryRun: Bool, contentType: String? = nil) throws {
        lock.withLock {
            recorded.append(Mutation(verb: verb, dryRun: dryRun))
            if let contentType { contentTypes.append(contentType) }
        }
        if failMutations && !dryRun { throw KubeError.unsupported("conflict") }
    }

    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try record("create", dryRun: options.dryRun); return [:]
    }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try record("replace", dryRun: options.dryRun); return [:]
    }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue {
        try record("patch", dryRun: options.dryRun, contentType: patch.contentType); return [:]
    }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { try record("delete", dryRun: options.dryRun) }

    func version() async throws -> KubeVersion { throw KubeError.unsupported("stub") }
    func discovery() async throws -> DiscoveryInfo { DiscoveryInfo(resources: []) }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { KubeList(items: []) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("stub") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { [:] }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { [:] }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
}
