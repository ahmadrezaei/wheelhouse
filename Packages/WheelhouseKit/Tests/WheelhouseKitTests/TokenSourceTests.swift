import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

/// Answers `/version` with a scripted status per host and records the Authorization header of every request.
final class ScriptedAuthProtocol: URLProtocol, @unchecked Sendable {
    struct Host { var statuses: [Int] = []; var seen: [String?] = [] }
    private static let store = Mutex<[String: Host]>([:])

    static func script(host: String, statuses: [Int]) { store.withLock { $0[host] = Host(statuses: statuses) } }
    static func authorizations(host: String) -> [String?] { store.withLock { $0[host]?.seen ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let host = request.url?.host ?? ""
        let auth = request.value(forHTTPHeaderField: "Authorization")
        let status = Self.store.withLock { s -> Int in
            s[host, default: Host()].seen.append(auth)
            return s[host]?.statuses.isEmpty == false ? s[host]!.statuses.removeFirst() : 200
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = status == 200 ? #"{"major":"1","minor":"32","gitVersion":"v1.32.0"}"# : #"{"kind":"Status","status":"Failure","code":\#(status),"message":"denied"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// A provider whose tokens are `t1`, `t2`, ... and that counts its calls.
final class CountingProvider: BearerTokenProviding, @unchecked Sendable {
    private let state = Mutex((issued: 0, invalidations: 0, fail: false))
    var invalidations: Int { state.withLock { $0.invalidations } }
    var issued: Int { state.withLock { $0.issued } }
    func authorization() async throws -> String? {
        let (inv, fail) = state.withLock { ($0.invalidations, $0.fail) }
        if fail { throw KubeError.unreachable(cause: "plugin failed") }
        state.withLock { $0.issued = max($0.issued, inv + 1) }
        return "t\(inv + 1)"
    }
    func invalidate() async { state.withLock { $0.invalidations += 1 } }
    func setFailing(_ value: Bool) { state.withLock { $0.fail = value } }
}

private func makeClient(source: BearerTokenSource?, statuses: [Int] = []) -> (LiveKubeClient, host: String) {
    let host = "auth-\(UUID().uuidString.lowercased().prefix(8)).test"
    ScriptedAuthProtocol.script(host: host, statuses: statuses)
    let config = ClusterConfig(name: "t", server: URL(string: "https://\(host):6443")!, authKind: .token, environment: .development)
    return (LiveKubeClient(config: config, secrets: ClusterSecrets(token: " stored "), tlsServerName: nil, tokenSource: source,
                           protocolClasses: [ScriptedAuthProtocol.self]), host)
}

@Suite("BearerTokenSource")
struct TokenSourceTests {
    @Test func staticTokenIsTrimmedAndSent() async throws {
        let (client, host) = makeClient(source: nil)
        _ = try await client.version()
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer stored"])
    }

    @Test func explicitStaticSourceWins() async throws {
        let (client, host) = makeClient(source: .static("abc"))
        _ = try await client.version()
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer abc"])
    }

    @Test func dynamicTokenIsAwaitedBeforeEveryRequest() async throws {
        let provider = CountingProvider()
        let (client, host) = makeClient(source: .dynamic(provider))
        _ = try await client.version()
        _ = try await client.version()
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer t1", "Bearer t1"])
    }

    @Test func a401InvalidatesAndRetriesOnce() async throws {
        let provider = CountingProvider()
        let (client, host) = makeClient(source: .dynamic(provider), statuses: [401])
        _ = try await client.version()
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer t1", "Bearer t2"])
        #expect(provider.invalidations == 1)
    }

    @Test func aSecond401WithinTenSecondsIsNotRetried() async throws {
        let provider = CountingProvider()
        let (client, host) = makeClient(source: .dynamic(provider), statuses: [401, 200, 401])
        _ = try await client.version()                               // 401, invalidate, retry -> 200
        await #expect(throws: KubeError.self) { _ = try await client.version() }   // 401 again, inside 10 s: no retry
        #expect(provider.invalidations == 1)
        #expect(ScriptedAuthProtocol.authorizations(host: host).count == 3)
    }

    @Test func staticTokenNeverRetriesAndNeverInvalidates() async throws {
        let (client, host) = makeClient(source: nil, statuses: [401])
        await #expect(throws: KubeError.self) { _ = try await client.version() }
        #expect(ScriptedAuthProtocol.authorizations(host: host).count == 1)
    }

    @Test func retryGateIsRateLimited() {
        let (client, _) = makeClient(source: .dynamic(CountingProvider()))
        let t = Date()
        #expect(client.shouldRetryAfterUnauthorized(now: t))
        #expect(!client.shouldRetryAfterUnauthorized(now: t.addingTimeInterval(9)))
        #expect(client.shouldRetryAfterUnauthorized(now: t.addingTimeInterval(11)))
        let (plain, _) = makeClient(source: nil)
        #expect(!plain.shouldRetryAfterUnauthorized(now: t))
    }

    @Test func aProviderFailureSurfacesAndSendsNothing() async throws {
        let provider = CountingProvider()
        provider.setFailing(true)
        let (client, host) = makeClient(source: .dynamic(provider))
        await #expect(throws: KubeError.self) { _ = try await client.version() }
        #expect(ScriptedAuthProtocol.authorizations(host: host).isEmpty)
    }

    @Test func prepareStreamingResolvesTheTokenForTheSynchronousSocketBuilder() async throws {
        let provider = CountingProvider()
        let (client, _) = makeClient(source: .dynamic(provider))
        // Before the preflight a dynamic client refuses to build a socket.
        #expect(throws: KubeError.self) { _ = try client.execWebSocket(namespace: "n", pod: "p", options: ExecOptions(command: ["sh"], tty: true, stdin: true)) }
        try await client.prepareStreaming()
        let ws = try client.execWebSocket(namespace: "n", pod: "p", options: ExecOptions(command: ["sh"], tty: true, stdin: true))
        ws.close()
        #expect(provider.issued == 1)
    }

    @Test func prepareStreamingIsANoOpForStaticTokens() async throws {
        let (client, _) = makeClient(source: nil)
        try await client.prepareStreaming()
        let ws = try client.portForwardWebSocket(namespace: "n", pod: "p", ports: [80])
        ws.close()
    }
}

@Suite("Proxy request authorization")
struct ProxyAuthorizationTests {
    private func proxy(_ client: LiveKubeClient, headers: [String: String] = [:]) async throws -> ProxyResponse {
        try await client.proxyRequest(method: "GET", namespace: "argocd", service: "https:argocd-server", port: "443",
                                      path: "api/v1/applications", query: [:], headers: headers, body: nil)
    }

    @Test func anExecCredentialClusterSendsItsBearerToken() async throws {
        let (client, host) = makeClient(source: .dynamic(CountingProvider()))
        let r = try await proxy(client)
        #expect(r.statusCode == 200)
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer t1"])
    }

    @Test func a401OnADynamicSourceInvalidatesAndRetriesOnce() async throws {
        let provider = CountingProvider()
        let (client, host) = makeClient(source: .dynamic(provider), statuses: [401])
        let r = try await proxy(client)
        #expect(r.statusCode == 200)
        #expect(provider.invalidations == 1)
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer t1", "Bearer t2"])
    }

    @Test func aPersistent401IsRetriedOnceAndThenReturned() async throws {
        let provider = CountingProvider()
        let (client, host) = makeClient(source: .dynamic(provider), statuses: [401, 401, 401])
        let r = try await proxy(client)
        #expect(r.statusCode == 401)
        #expect(ScriptedAuthProtocol.authorizations(host: host).count == 2)
    }

    @Test func aStaticTokenClusterIsNotRetried() async throws {
        let (client, host) = makeClient(source: nil, statuses: [401])
        let r = try await proxy(client)
        #expect(r.statusCode == 401)
        #expect(ScriptedAuthProtocol.authorizations(host: host) == ["Bearer stored"])
    }

    @Test func aCallerAuthorizationHeaderIsStillDropped() async throws {
        let (dynamic, dynamicHost) = makeClient(source: .dynamic(CountingProvider()))
        _ = try await proxy(dynamic, headers: ["Authorization": "Bearer attacker", "authorization": "Bearer attacker2"])
        #expect(ScriptedAuthProtocol.authorizations(host: dynamicHost) == ["Bearer t1"])
        let (plain, plainHost) = makeClient(source: nil)
        _ = try await proxy(plain, headers: ["Authorization": "Bearer attacker"])
        #expect(ScriptedAuthProtocol.authorizations(host: plainHost) == ["Bearer stored"])
    }
}
