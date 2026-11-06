import Foundation
import Security
import Synchronization
import Testing
import WheelhouseUI
@testable import WheelhouseKit

// MARK: - Request-capturing URLProtocol

/// Captures every request that reaches the wire, keyed by host so parallel tests do not interfere.
final class CapturingProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable {
        var method: String
        var url: URL
        var body: Data?
        var json: JSONValue? { body.flatMap { try? JSONValue.parse($0) } }
        func query(_ name: String) -> String? { URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value }
    }
    private static let store = Mutex<[String: [Captured]]>([:])

    static func requests(host: String) -> [Captured] { store.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            body = data
        }
        if let url = request.url, let host = url.host {
            Self.store.withLock { $0[host, default: []].append(Captured(method: request.httpMethod ?? "GET", url: url, body: body)) }
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"kind":"Status","status":"Success"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private func makeClient() -> (LiveKubeClient, host: String) {
    let host = "dry-\(UUID().uuidString.lowercased().prefix(8)).test"
    let config = ClusterConfig(name: "t", server: URL(string: "https://\(host):6443")!, environment: .development)
    return (LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"), protocolClasses: [CapturingProtocol.self]), host)
}

// MARK: - B1: dry-run must be in the request body

@Suite("Dry-run requests carry dryRun in the body")
struct DryRunBodyTests {
    @Test func dryRunDeleteSendsDryRunInBodyAndQuery() async throws {
        let (client, host) = makeClient()
        try await client.delete(.pod, name: "web-1", namespace: "shop", options: DeleteOptions(propagation: .background, dryRun: true))
        let req = try #require(CapturingProtocol.requests(host: host).first)
        #expect(req.method == "DELETE")
        #expect(req.query("dryRun") == "All")
        #expect(req.json?["dryRun"]?.arrayValue?.compactMap(\.stringValue) == ["All"])
        #expect(req.json?["kind"]?.stringValue == "DeleteOptions")
        #expect(req.json?["propagationPolicy"]?.stringValue == "Background")
    }

    @Test func realDeleteHasNoDryRunAnywhere() async throws {
        let (client, host) = makeClient()
        try await client.delete(.pod, name: "web-1", namespace: "shop", options: DeleteOptions(propagation: .foreground, gracePeriodSeconds: 5))
        let req = try #require(CapturingProtocol.requests(host: host).first)
        #expect(req.query("dryRun") == nil)
        #expect(req.json?["dryRun"] == nil)
        #expect(req.json?["gracePeriodSeconds"]?.intValue == 5)
    }

    @Test func dryRunEvictionSendsDryRunInDeleteOptionsAndQuery() async throws {
        let (client, host) = makeClient()
        try await client.evict(pod: "web-1", namespace: "shop", gracePeriodSeconds: 10, dryRun: true)
        let req = try #require(CapturingProtocol.requests(host: host).first)
        #expect(req.method == "POST")
        #expect(req.url.path.hasSuffix("/pods/web-1/eviction"))
        #expect(req.query("dryRun") == "All")
        #expect(req.json?.value(at: "deleteOptions.dryRun")?.arrayValue?.compactMap(\.stringValue) == ["All"])
        #expect(req.json?.value(at: "deleteOptions.gracePeriodSeconds")?.intValue == 10)
    }

    @Test func dryRunEvictionWithoutGraceStillCarriesDryRun() async throws {
        let (client, host) = makeClient()
        try await client.evict(pod: "web-1", namespace: "shop", dryRun: true)
        let req = try #require(CapturingProtocol.requests(host: host).first)
        #expect(req.json?.value(at: "deleteOptions.dryRun")?.arrayValue?.compactMap(\.stringValue) == ["All"])
    }

    @Test func realEvictionHasNoDryRun() async throws {
        let (client, host) = makeClient()
        try await client.evict(pod: "web-1", namespace: "shop")
        let req = try #require(CapturingProtocol.requests(host: host).first)
        #expect(req.query("dryRun") == nil)
        #expect(req.json?.value(at: "deleteOptions.dryRun") == nil)
    }

    @Test func objectMutationsKeepTheDryRunQuery() async throws {
        let (client, host) = makeClient()
        let body: JSONValue = ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "c", "namespace": "shop"]]
        _ = try await client.create(.configMap, namespace: "shop", name: nil, subresource: nil, body: body, options: MutationOptions(dryRun: true))
        _ = try await client.replace(.configMap, name: "c", namespace: "shop", body: body, options: MutationOptions(dryRun: true))
        _ = try await client.patch(.configMap, name: "c", namespace: "shop", subresource: nil, patch: .merge(["data": ["a": "b"]]), options: MutationOptions(dryRun: true))
        _ = try await client.patch(.configMap, name: "c", namespace: "shop", subresource: nil, patch: .apply(body), options: MutationOptions(dryRun: true, force: true))
        let reqs = CapturingProtocol.requests(host: host)
        #expect(reqs.count == 4)
        for r in reqs { #expect(r.query("dryRun") == "All", "\(r.method) lost its dryRun query") }
        // These bodies are the object itself (no DeleteOptions), so the query is the only carrier and it is honoured.
        #expect(reqs.allSatisfy { $0.json?["dryRun"] == nil })
    }
}

// MARK: - H1: a rejected trust challenge (-999) maps to a TLS error

@Suite("Server-trust rejection mapping")
struct TLSRejectionMappingTests {
    private func untrustedTrust(host: String) -> SecTrust {
        let der = PEM.decode(TLSFixtures.long).first { $0.label == "CERTIFICATE" }!.der
        let cert = SecCertificateCreateWithData(nil, der as CFData)!
        var t: SecTrust?
        precondition(SecTrustCreateWithCertificates(cert, SecPolicyCreateSSL(true, host as CFString), &t) == errSecSuccess)
        return t!
    }

    private func client(port: Int = 60561) -> LiveKubeClient {
        let config = ClusterConfig(name: "t", server: URL(string: "https://127.0.0.1:\(port)")!, environment: .development)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: "x"))
    }

    @Test func sessionLevelRejectionIsFoundByHostAndPort() {
        let d = ClusterSessionDelegate(anchors: [], insecure: false)
        _ = d.handleServerTrust(untrustedTrust(host: "127.0.0.1"), host: "127.0.0.1", port: 60561, url: nil)
        #expect(d.failure(for: URL(string: "https://127.0.0.1:60561/version")!) != nil)
        #expect(d.failure(for: URL(string: "https://127.0.0.1:60562/version")!) == nil)
        #expect(d.failure(for: URL(string: "https://other.test:60561/version")!) == nil)
        #expect(d.failure(for: nil) != nil)
    }

    @Test func cancelledAfterRejectedTrustMapsToTLSUntrusted() {
        let c = client()
        _ = c.delegate.handleServerTrust(untrustedTrust(host: "127.0.0.1"), host: "127.0.0.1", port: 60561, url: nil)
        let err = c.mapTransportError(URLError(.cancelled, userInfo: [NSURLErrorFailingURLStringErrorKey: "https://127.0.0.1:60561/version"]))
        guard case .tlsUntrusted(let summary) = err else { Issue.record("expected tlsUntrusted, got \(err)"); return }
        #expect(summary?.contains("SHA-256") == true)
    }

    @Test func cancelledWithoutFailingURLStillMapsAfterRecentRejection() {
        let c = client()
        _ = c.delegate.handleServerTrust(untrustedTrust(host: "127.0.0.1"), host: "127.0.0.1", port: 60561, url: nil)
        if case .tlsUntrusted = c.mapTransportError(URLError(.cancelled)) {} else { Issue.record("expected tlsUntrusted") }
    }

    @Test func plainCancellationStaysCancelled() {
        let c = client()
        #expect(c.mapTransportError(URLError(.cancelled)) == .cancelled)
        #expect(c.mapTransportError(CancellationError()) == .cancelled)
    }

    @Test func laterSuccessfulTrustClearsTheRejection() {
        let d = ClusterSessionDelegate(anchors: [], insecure: true)
        d.recordFailureForTesting(TLSFailureInfo(subject: "x", sha256: "AA", message: "m"), host: "127.0.0.1", port: 60561, url: nil)
        #expect(d.failure(for: nil) != nil)
        _ = d.handleServerTrust(untrustedTrust(host: "127.0.0.1"), host: "127.0.0.1", port: 60561, url: nil)   // insecure: passes
        #expect(d.failure(for: URL(string: "https://127.0.0.1:60561/")!) == nil)
        #expect(d.failure(for: nil) == nil)
    }
}

@MainActor @Suite("Health after a rejected certificate")
struct TLSHealthTests {
    private func session(_ client: ScriptedClient) -> ClusterSession {
        ClusterSession(config: ClusterConfig(id: "tls1", name: "tls1", server: URL(string: "https://127.0.0.1:60561")!, environment: .development), client: client)
    }

    @Test func tlsRejectionMarksTheClusterUnreachable() async {
        let client = ScriptedClient()
        client.versionError = .tlsUntrusted(summary: "CN=x · SHA-256 AA")
        let s = session(client)
        for _ in 0..<3 { await s.refreshHealth() }
        #expect(s.health != nil)
        #expect(s.health?.isReachable == false)
        if case .failed(.tlsUntrusted) = s.connection {} else { Issue.record("connection should be a TLS failure") }
    }

    @Test func strayCancelledOutsideACancelledTaskIsAFailureNotASkeleton() async {
        let client = ScriptedClient()
        client.versionError = .cancelled
        let s = session(client)
        for _ in 0..<3 { await s.refreshHealth() }
        #expect(s.health?.isReachable == false)
    }

    @Test func realTaskCancellationDoesNotSetHealth() async {
        let client = ScriptedClient()
        client.versionError = .cancelled
        let s = session(client)
        let task = Task { @MainActor in
            while !Task.isCancelled { await Task.yield() }
            return await s.refreshHealth()
        }
        task.cancel()
        _ = await task.value
        #expect(s.health == nil || s.health?.isReachable == true || s.health?.isStale == true)
    }
}

@Suite("Pending pod severity")
struct PendingSeverityTests {
    @Test func pendingPodIsWarningNotHealthy() throws {
        let json = #"{"apiVersion":"v1","kind":"Pod","metadata":{"name":"p","namespace":"shop"},"spec":{"containers":[{"name":"app","image":"x"}]},"status":{"phase":"Pending"}}"#
        let pod = try KubeJSON.decoder.decode(Pod.self, from: Data(json.utf8))
        let s = pod.stateSummary()
        #expect(s.reason == "Pending")
        #expect(s.severity == .warning)
    }
}

@Suite("Type-to-confirm opt-out")
struct ShellConfirmTests {
    private func request(typeOnProd: Bool = true, always: Bool = false, env: ClusterEnvironment = .production) -> (ConfirmRequest, ClusterConfig) {
        let c = ClusterConfig(name: "p", server: URL(string: "https://p.test")!, environment: env)
        return (ConfirmRequest(title: "t", message: "m", verb: "v", cluster: c, resource: "pod/x", confirmationText: "x",
                               alwaysRequireTyping: always, typeToConfirmOnProduction: typeOnProd, action: {}), c)
    }

    @Test func shellStyleRequestNeedsNoTypingOnProduction() {
        let (r, c) = request(typeOnProd: false)
        #expect(!r.requiresTyping(for: c))
    }

    @Test func defaultRequestsStillRequireTypingOnProduction() {
        let (r, c) = request()
        #expect(r.requiresTyping(for: c))
        #expect(r.requiresTyping)
    }

    @Test func alwaysRequireTypingWinsOverTheOptOut() {
        let (r, c) = request(typeOnProd: false, always: true)
        #expect(r.requiresTyping(for: c))
    }
}
