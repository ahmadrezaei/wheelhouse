import CryptoKit
import Foundation
import Synchronization

/// A source of bearer tokens that can change over time (an exec credential plugin on the Mac).
public protocol BearerTokenProviding: Sendable {
    /// The bearer token to send now (without the `Bearer ` prefix). May run a plugin, so it is async. `nil` means send no
    /// `Authorization` header (a client-certificate credential).
    func authorization() async throws -> String?
    /// A client certificate and key (PEM) when the credential is a certificate, else nil. Called after ``authorization()``.
    func clientCertificate() async throws -> ClientCertificateMaterial?
    /// Drops the cached credential because the server answered 401. The next ``authorization()`` produces a fresh one.
    func invalidate() async
}

public extension BearerTokenProviding {
    func clientCertificate() async throws -> ClientCertificateMaterial? { nil }
}

public struct ClientCertificateMaterial: Sendable, Equatable {
    public var certificatePEM: String
    public var keyPEM: String
    public init(certificatePEM: String, keyPEM: String) {
        self.certificatePEM = certificatePEM
        self.keyPEM = keyPEM
    }
}

/// How ``LiveKubeClient`` authenticates with a bearer token. iOS keeps `.static`.
public enum BearerTokenSource: Sendable {
    case `static`(String?)
    case dynamic(any BearerTokenProviding)

    public var isDynamic: Bool {
        if case .dynamic = self { return true }
        return false
    }
}

extension LiveKubeClient {
    /// Minimum time between two invalidations caused by a 401.
    static let unauthorizedRetryInterval: TimeInterval = 10

    /// Adds the dynamic credential to a request built by `makeRequest`. A no-op for `.static` (the header is already set).
    nonisolated func authorize(_ request: URLRequest) async throws -> URLRequest {
        guard case .dynamic(let provider) = tokenSource else { return request }
        var request = request
        let token: String?
        do { token = try await currentDynamicToken(provider) }
        catch let e as KubeError { throw e }
        catch is CancellationError { throw CancellationError() }
        catch { throw KubeError.unreachable(cause: error.localizedDescription) }   // a plugin failure reads as a connection problem
        if let token, !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    /// Asks the provider for the credential and installs its client certificate (once per distinct certificate).
    private nonisolated func currentDynamicToken(_ provider: any BearerTokenProviding) async throws -> String? {
        let token = try await provider.authorization()?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let material = try await provider.clientCertificate() { installClientCertificate(material) }
        streamingToken.withLock { $0 = token }
        return token
    }

    private nonisolated func installClientCertificate(_ m: ClientCertificateMaterial) {
        let digest = SHA256.hash(data: Data((m.certificatePEM + m.keyPEM).utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        let label = ClientIdentityBuilder.label(for: config.id) + ".exec.\(digest)"
        identityBox.withLock { current in
            if let current, current.label == label { return }
            current = LazyClientIdentity(label: label) {
                try ClientIdentityBuilder.build(certificatePEM: m.certificatePEM, keyPEM: m.keyPEM, label: label)
            }
        }
    }

    /// THE one place that authenticates a send. Any send path (`perform`, a proxy request, a future one) calls this: it adds the
    /// credential, sends, and on a 401 with a dynamic source invalidates the credential and retries once (at most once per 10 s).
    /// A static token is sent as built by `makeRequest`, with no retry. M9's `proxyRequest` should wrap its send in it.
    nonisolated func withAuthorization<T>(_ request: URLRequest, _ send: (URLRequest) async throws -> T) async throws -> T {
        do {
            return try await send(try await authorize(request))
        } catch KubeError.unauthorized where shouldRetryAfterUnauthorized() {
            await invalidateDynamicCredential()
            return try await send(try await authorize(request))
        }
    }

    /// True once per ``unauthorizedRetryInterval`` for a dynamic source: the caller then invalidates and retries once.
    nonisolated func shouldRetryAfterUnauthorized(now: Date = Date()) -> Bool {
        guard tokenSource.isDynamic else { return false }
        return lastUnauthorizedInvalidation.withLock { last in
            if let last, now.timeIntervalSince(last) < Self.unauthorizedRetryInterval { return false }
            last = now
            return true
        }
    }

    nonisolated func invalidateDynamicCredential() async {
        guard case .dynamic(let provider) = tokenSource else { return }
        streamingToken.withLock { $0 = nil }
        await provider.invalidate()
    }

    /// Runs the asynchronous part of authentication before a synchronous WebSocket is built. `ExecSession.start` and the
    /// port-forward pump call it first. A no-op for a static token.
    public nonisolated func prepareStreaming() async throws {
        guard case .dynamic(let provider) = tokenSource else { return }
        _ = try await currentDynamicToken(provider)
    }
}

/// A shared, lock-protected slot for the client identity (the delegate reads it on every TLS challenge).
final class IdentityHolder: Sendable {
    private let state: Mutex<LazyClientIdentity?>
    init(_ initial: LazyClientIdentity?) { state = Mutex(initial) }
    func withLock<R>(_ body: (inout sending LazyClientIdentity?) throws -> sending R) rethrows -> sending R { try state.withLock(body) }
}
