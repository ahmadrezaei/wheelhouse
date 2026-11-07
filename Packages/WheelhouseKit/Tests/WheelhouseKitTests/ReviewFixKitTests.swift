import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

/// Redirects `/version` of host `redirecting` to another host, which answers 200.
final class RedirectingProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        if url.host()?.hasPrefix("redirecting-") == true {
            var target = URLRequest(url: URL(string: "https://elsewhere.test/version")!)
            target.httpMethod = "GET"
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": "https://elsewhere.test/version"])!
            client?.urlProtocol(self, wasRedirectedTo: target, redirectResponse: response)
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"gitVersion":"v1.32.0"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Desktop host gate in LiveKubeClient")
struct HostGateClientTests {
    private func client(hostAllowed: (@Sendable (URL) -> Bool)?, host: String) -> LiveKubeClient {
        let config = ClusterConfig(name: "t", server: URL(string: "https://\(host):6443")!, authKind: .token, environment: .development)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: "t"), tlsServerName: nil, tokenSource: nil,
                              hostAllowed: hostAllowed, protocolClasses: [RedirectingProtocol.self])
    }

    @Test func redirectsAreRefusedWhenAGateIsInjected() async {
        let host = "redirecting-\(UUID().uuidString.lowercased().prefix(6)).test"
        let c = client(hostAllowed: { _ in true }, host: host)       // even an allowed target host: a redirect leaves the original host
        await #expect(throws: KubeError.self) { _ = try await c.version() }
    }

    @Test func withoutAGateRedirectsAreFollowedAsOnIOS() async throws {
        let host = "redirecting-\(UUID().uuidString.lowercased().prefix(6)).test"
        let c = client(hostAllowed: nil, host: host)
        #expect(try await c.version().gitVersion == "v1.32.0")
    }

    @Test func theHostIsCheckedForEveryRequest() async {
        let allowed = Mutex(true)
        let c = client(hostAllowed: { _ in allowed.withLock { $0 } }, host: "plain-\(UUID().uuidString.lowercased().prefix(6)).test")
        #expect((try? await c.version()) != nil)
        allowed.withLock { $0 = false }
        await #expect(throws: KubeError.self) { _ = try await c.version() }
    }
}

@Suite("ExecSession start after close")
struct ExecSessionStartRaceTests {
    @Test func aStartThatResumesAfterCloseDoesNotOpenASocket() async throws {
        let session = ExecSession(client: PrepareThenFailClient(), namespace: "n", pod: "p", options: ExecOptions(command: ["sh"], tty: true, stdin: true))
        await session.close()
        // `execWebSocket` of this client throws; the call must return quietly because the session finished while it awaited.
        try await session.start()
    }
}

private struct PrepareThenFailClient: KubeClientProtocol {
    func version() async throws -> KubeVersion { throw KubeError.unsupported("stub") }
    func discovery() async throws -> DiscoveryInfo { throw KubeError.unsupported("stub") }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { throw KubeError.unsupported("stub") }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("stub") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("stub") }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func prepareStreaming() async throws { try await Task.sleep(for: .milliseconds(50)) }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("must not be called") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
}
