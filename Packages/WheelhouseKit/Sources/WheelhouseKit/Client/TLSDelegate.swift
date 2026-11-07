import Foundation
import Security
import CryptoKit
import Synchronization

/// Describes why a server certificate was rejected, for the TLS error screen.
public struct TLSFailureInfo: Sendable, Equatable {
    public var subject: String
    public var sha256: String
    public var message: String
    public var summary: String {
        let base = "\(subject) · SHA-256 \(sha256.prefix(23))…"
        return message.isEmpty ? base : "\(base) — \(message)"
    }
}

/// Non-secret facts about the last TLS exchange(s), for the copyable connection report.
public struct TLSTrace: Sendable, Equatable {
    public enum ServerTrust: String, Sendable { case notReached = "not reached", passed, failed }
    public var serverTrust: ServerTrust = .notReached
    /// The server sent a client-certificate challenge.
    public var clientCertificateRequested = false
    /// The cluster has no client identity configured (token auth): the challenge was declined.
    public var noIdentityConfigured = false
    public var identityPresented = false
    /// nil = not run; "passed"; or the failure text.
    public var signTest: String?
    public var clientLeafSHA256: String?
    public var clientLeafNotAfter: Date?
    public var keyType: String?
    public var keySizeBits: Int?
    public var identityError: String?
    /// `domain:code` pairs of the last transport error's underlying chain, outermost first.
    public var errorChain: [String] = []
    public var streamDomain: Int?
    public var streamCode: Int?
    public init() {}
}

/// Per-cluster `URLSession` delegate: custom CA anchors, skip-verify, client certificate identity.
final class ClusterSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]
    private let insecure: Bool
    /// Auxiliary sessions (a user-supplied Prometheus URL): try the system trust store first, then the cluster CA.
    private let systemTrustFirst: Bool
    /// Resolved on the first client-certificate challenge (off the main thread, on the URLSession delegate queue).
    private let identityProvider: (@Sendable () -> Result<ClientIdentityBuilder.Result, ClientIdentityError>)?
    /// Name the server certificate must be valid for instead of the URL host (kubeconfig `tls-server-name`).
    private let serverName: String?

    private struct Failures {
        var latest: TLSFailureInfo?
        var latestAt: Date?
        /// Session-level trust challenges carry no task URL; they are keyed by `host:port`.
        var byHost: [String: (info: TLSFailureInfo, at: Date)] = [:]
        var byURL: [String: (info: TLSFailureInfo, at: Date)] = [:]
    }
    private let failures = Mutex(Failures())
    private struct IdentityState {
        /// Set only when a configured identity provider FAILED to produce an identity.
        var failureText: String?
        /// A client certificate was requested but this cluster has none (token auth). A hint, never a failure by itself:
        /// kube-apiserver always sends a CertificateRequest.
        var requestedWithoutIdentity = false
        var signTestFailure: String?
        var trace = TLSTrace()
    }
    private let identityState = Mutex(IdentityState())

    /// Why the client identity could not be built, if a configured identity failed. Takes precedence over generic handshake text.
    var identityFailure: String? { identityState.withLock { $0.failureText } }

    /// Text to append to a 401: the build failure, else the (diagnostic-only) test-signature failure.
    var identityNote: String? { identityState.withLock { $0.failureText ?? $0.signTestFailure.map { "Client key cannot sign: \($0)" } } }

    /// The server asked for a client certificate and none is configured; only relevant to `.clientCertificateRequired` / -9863.
    var clientCertificateMissing: Bool { identityState.withLock { $0.requestedWithoutIdentity } }

    /// Snapshot for the diagnostics report.
    var trace: TLSTrace { identityState.withLock { $0.trace } }

    /// The most recent rejection, cleared as soon as any later server trust evaluation succeeds.
    var lastFailure: TLSFailureInfo? { failures.withLock { $0.latest } }

    /// Desktop gate: when set, a redirect is refused unless it stays on the original host AND the host is allowed. nil (iOS) keeps the
    /// system behaviour of following redirects. Set once, before the session is used.
    nonisolated(unsafe) var hostAllowed: (@Sendable (URL) -> Bool)?

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        guard let hostAllowed else { return request }
        guard let to = request.url, hostAllowed(to), to.host()?.lowercased() == task.originalRequest?.url?.host()?.lowercased() else { return nil }
        return request
    }

    init(anchors: [SecCertificate], insecure: Bool, serverName: String? = nil, systemTrustFirst: Bool = false, identityProvider: (@Sendable () -> Result<ClientIdentityBuilder.Result, ClientIdentityError>)? = nil) {
        self.anchors = anchors
        self.insecure = insecure
        self.systemTrustFirst = systemTrustFirst
        self.identityProvider = identityProvider
        let trimmed = serverName?.trimmingCharacters(in: .whitespaces)
        self.serverName = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The rejection recorded for the request that failed (matched by URL), if any.
    func failure(for url: URL?) -> TLSFailureInfo? {
        failures.withLock { state in
            let now = Date()
            if let url, let hit = state.byURL[Self.key(url)], now.timeIntervalSince(hit.at) < Self.failureWindow { return hit.info }
            // A rejected session-level challenge (no task URL) is matched by host:port, or, when the failing request is unknown,
            // by recency: URLSession reports the rejection as -999 (cancelled).
            if let url, let hk = Self.hostKey(url), let hit = state.byHost[hk], now.timeIntervalSince(hit.at) < Self.failureWindow { return hit.info }
            if url == nil, let latest = state.latest, let at = state.latestAt, now.timeIntervalSince(at) < Self.failureWindow { return latest }
            return nil
        }
    }

    static let failureWindow: TimeInterval = 60

    static func hostKey(_ url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        return "\(host):\(hostKeyPort(url.port, scheme: url.scheme))"
    }

    static func hostKeyPort(_ port: Int?, scheme: String?) -> Int { port ?? (scheme?.lowercased() == "http" ? 80 : 443) }

    /// Test hook: records a rejection exactly as a trust challenge would.
    func recordFailureForTesting(_ info: TLSFailureInfo, host: String, port: Int, url: URL?) {
        store(info, url: url, hostKey: "\(host.lowercased()):\(port)")
    }

    private static func key(_ url: URL) -> String { url.absoluteString }

    // MARK: Challenges

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge, url: nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        handle(challenge, url: task.originalRequest?.url ?? task.currentRequest?.url)
    }

    private func handle(_ challenge: URLAuthenticationChallenge, url: URL?) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        let method = challenge.protectionSpace.authenticationMethod
        if method == NSURLAuthenticationMethodServerTrust, let trust = challenge.protectionSpace.serverTrust {
            return handleServerTrust(trust, host: challenge.protectionSpace.host, port: challenge.protectionSpace.port, url: url)
        }
        if method == NSURLAuthenticationMethodClientCertificate { return handleClientCertificate() }
        return (.performDefaultHandling, nil)
    }

    func handleClientCertificate() -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        identityState.withLock { $0.trace.clientCertificateRequested = true }
        guard let provider = identityProvider else {
            identityState.withLock { $0.requestedWithoutIdentity = true; $0.trace.noIdentityConfigured = true }
            return (.performDefaultHandling, nil)
        }
        switch provider() {
        case .success(let built):
            identityState.withLock { state in
                state.failureText = nil
                state.requestedWithoutIdentity = false
                // The sign test is diagnostic only; the identity is presented either way.
                state.signTestFailure = built.signTestFailure
                state.trace.identityPresented = true
                state.trace.signTest = built.signTestRan ? (built.signTestFailure ?? "passed") : nil
                state.trace.clientLeafSHA256 = built.leafSHA256
                state.trace.clientLeafNotAfter = built.leafNotAfter
                state.trace.keyType = built.keyType
                state.trace.keySizeBits = built.keySizeBits
                state.trace.identityError = nil
            }
            let intermediates = built.certificates.dropFirst().map { $0 }
            return (.useCredential, URLCredential(identity: built.identity, certificates: intermediates.isEmpty ? nil : intermediates, persistence: .forSession))
        case .failure(let error):
            identityState.withLock { $0.failureText = error.diagnostic; $0.trace.identityError = error.diagnostic; $0.trace.identityPresented = false }
            return (.performDefaultHandling, nil)
        }
    }

    /// Records the last transport error's chain for the report.
    func recordTransportError(_ error: Error) {
        let x = TLSDiagnostics.extract(from: error)
        let chain = TLSDiagnostics.errorChain(from: error)
        identityState.withLock { $0.trace.errorChain = chain; $0.trace.streamCode = x.streamCode; $0.trace.streamDomain = x.streamDomain }
    }

    func handleServerTrust(_ trust: SecTrust, host: String, port: Int? = nil, url: URL? = nil) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if insecure {
            identityState.withLock { $0.trace.serverTrust = .passed }
            clearFailure(url, hostKey: hostKey(host, port))
            return (.useCredential, URLCredential(trust: trust))
        }
        var verdict = TLSValidator.evaluate(trust, host: serverName ?? host, anchors: systemTrustFirst ? [] : anchors)
        if !verdict.trusted, systemTrustFirst, !anchors.isEmpty {
            verdict = TLSValidator.evaluate(trust, host: serverName ?? host, anchors: anchors)
        }
        if verdict.trusted {
            identityState.withLock { $0.trace.serverTrust = .passed }
            clearFailure(url, hostKey: hostKey(host, port))
            return (.useCredential, URLCredential(trust: trust))
        }
        identityState.withLock { $0.trace.serverTrust = .failed }
        record(trust, message: verdict.message, url: url, hostKey: hostKey(host, port))
        return (.cancelAuthenticationChallenge, nil)
    }

    private func hostKey(_ host: String, _ port: Int?) -> String? {
        guard let port, port > 0 else { return nil }
        return "\(host.lowercased()):\(port)"
    }

    private func clearFailure(_ url: URL?, hostKey: String?) {
        failures.withLock { state in
            state.latest = nil
            state.latestAt = nil
            if let hostKey { state.byHost[hostKey] = nil }
            if let url { state.byURL[Self.key(url)] = nil }
        }
    }

    private func record(_ trust: SecTrust, message: String, url: URL?, hostKey: String?) {
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let subject = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unknown certificate"
        let digest = leaf.map { SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02X", $0) }.joined(separator: ":") } ?? ""
        store(TLSFailureInfo(subject: subject, sha256: digest, message: message), url: url, hostKey: hostKey)
    }

    private func store(_ info: TLSFailureInfo, url: URL?, hostKey: String?) {
        failures.withLock { state in
            state.latest = info
            state.latestAt = Date()
            if let hostKey { state.byHost[hostKey] = (info, Date()) }
            if let url {
                state.byURL[Self.key(url)] = (info, Date())
                if state.byURL.count > 24, let oldest = state.byURL.min(by: { $0.value.at < $1.value.at })?.key {
                    state.byURL[oldest] = nil
                }
            }
        }
    }
}
