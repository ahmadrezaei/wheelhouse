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

/// Per-cluster `URLSession` delegate: custom CA anchors, skip-verify, client certificate identity.
final class ClusterSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let anchors: [SecCertificate]
    private let insecure: Bool
    /// Auxiliary sessions (a user-supplied Prometheus URL): try the system trust store first, then the cluster CA.
    private let systemTrustFirst: Bool
    /// Resolved on the first client-certificate challenge (off the main thread, on the URLSession delegate queue).
    private let identityProvider: (@Sendable () -> ClientIdentityBuilder.Result?)?
    /// Name the server certificate must be valid for instead of the URL host (kubeconfig `tls-server-name`).
    private let serverName: String?

    private struct Failures {
        var latest: TLSFailureInfo?
        var byURL: [String: (info: TLSFailureInfo, at: Date)] = [:]
    }
    private let failures = Mutex(Failures())

    /// The most recent rejection, cleared as soon as any later server trust evaluation succeeds.
    var lastFailure: TLSFailureInfo? { failures.withLock { $0.latest } }

    init(anchors: [SecCertificate], insecure: Bool, serverName: String? = nil, systemTrustFirst: Bool = false, identityProvider: (@Sendable () -> ClientIdentityBuilder.Result?)? = nil) {
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
            if let url, let hit = state.byURL[Self.key(url)], Date().timeIntervalSince(hit.at) < 60 { return hit.info }
            return nil
        }
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
            return handleServerTrust(trust, host: challenge.protectionSpace.host, url: url)
        }
        if method == NSURLAuthenticationMethodClientCertificate, let built = identityProvider?() {
            let intermediates = built.certificates.dropFirst().map { $0 }
            return (.useCredential, URLCredential(identity: built.identity, certificates: intermediates.isEmpty ? nil : intermediates, persistence: .forSession))
        }
        return (.performDefaultHandling, nil)
    }

    func handleServerTrust(_ trust: SecTrust, host: String, url: URL? = nil) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        if insecure {
            clearFailure(url)
            return (.useCredential, URLCredential(trust: trust))
        }
        var verdict = TLSValidator.evaluate(trust, host: serverName ?? host, anchors: systemTrustFirst ? [] : anchors)
        if !verdict.trusted, systemTrustFirst, !anchors.isEmpty {
            verdict = TLSValidator.evaluate(trust, host: serverName ?? host, anchors: anchors)
        }
        if verdict.trusted {
            clearFailure(url)
            return (.useCredential, URLCredential(trust: trust))
        }
        record(trust, message: verdict.message, url: url)
        return (.cancelAuthenticationChallenge, nil)
    }

    private func clearFailure(_ url: URL?) {
        failures.withLock { state in
            state.latest = nil
            if let url { state.byURL[Self.key(url)] = nil }
        }
    }

    private func record(_ trust: SecTrust, message: String, url: URL?) {
        let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
        let subject = leaf.flatMap { SecCertificateCopySubjectSummary($0) as String? } ?? "Unknown certificate"
        let digest = leaf.map { SHA256.hash(data: SecCertificateCopyData($0) as Data).map { String(format: "%02X", $0) }.joined(separator: ":") } ?? ""
        let info = TLSFailureInfo(subject: subject, sha256: digest, message: message)
        failures.withLock { state in
            state.latest = info
            if let url {
                state.byURL[Self.key(url)] = (info, Date())
                if state.byURL.count > 24, let oldest = state.byURL.min(by: { $0.value.at < $1.value.at })?.key {
                    state.byURL[oldest] = nil
                }
            }
        }
    }
}
