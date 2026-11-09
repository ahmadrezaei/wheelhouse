#if os(macOS)
import CryptoKit
import Foundation
import Network
import Security
import Synchronization
import WheelhouseKit

public enum UpstreamError: Error, Equatable, LocalizedError {
    case notReachable(String)
    case plainHTTPOnProduction
    case contactHeld
    case credentials(String)
    public var errorDescription: String? {
        switch self {
        case .notReachable(let why): "Wheelhouse could not reach the cluster: \(why)"
        case .plainHTTPOnProduction: "Wheelhouse refuses plain HTTP to a Production cluster."
        case .contactHeld: "Not checked yet. Click Check to connect to this cluster."
        case .credentials(let why): "Wheelhouse could not get credentials for the cluster: \(why)"
        }
    }
}

/// An open connection to a cluster's API server plus what to add to every request on it.
struct UpstreamLink: Sendable {
    var stream: NWStream
    /// `Authorization` value, nil for a client-certificate credential.
    var authorization: String?
    /// Host header value and base path of the server URL.
    var hostHeader: String
    var basePath: String
    var provider: (any BearerTokenProviding)?
}

/// Opens the leg to the real API server (ARCHITECTURE-MAC section 3.6, step 7): TLS through `sec_protocol_options_set_verify_block`
/// into `TLSValidator.evaluate` (the same validator as `LiveKubeClient`, with `tls-server-name`, and the rule that insecure TLS is
/// never allowed on Production), the client identity from `ClientIdentityBuilder` (stored PEM or an exec plugin), ALPN `http/1.1`.
///
/// While the safety gate is active a server whose host is not an allowed test host is refused here, again, at connect time.
public final class UpstreamConnector: Sendable {
    private let gate: @Sendable () -> DevSafetyPolicy
    private let queue = DispatchQueue(label: "app.wheelhouse.gangway.upstream", qos: .userInitiated)
    private let identities = Mutex<[String: IdentityBox]>([:])

    private final class IdentityBox: @unchecked Sendable {
        let identity: SecIdentity
        init(_ identity: SecIdentity) { self.identity = identity }
    }

    public init(gate: @escaping @Sendable () -> DevSafetyPolicy = { .current }) { self.gate = gate }

    func connect(_ target: GangwayUpstream, queue downstreamQueue: DispatchQueue? = nil) async throws -> UpstreamLink {
        let config = target.config
        try gate().validate(server: config.server)
        if target.contactHeld { throw UpstreamError.contactHeld }
        let https = config.server.scheme?.lowercased() == "https"
        if !https, config.environment.requiresTypeToConfirm { throw UpstreamError.plainHTTPOnProduction }
        guard let host = config.server.host(), !host.isEmpty else { throw UpstreamError.notReachable("the server address has no host") }
        let port = UInt16(config.server.port ?? (https ? 443 : 80))

        // Credentials: a bearer token, and possibly a client certificate (exec plugins can return either).
        var authorization: String?
        var certificate: ClientCertificateMaterial?
        var provider: (any BearerTokenProviding)?
        switch target.tokenSource ?? .static(target.secrets.token?.trimmingCharacters(in: .whitespacesAndNewlines)) {
        case .static(let token):
            if let token, !token.isEmpty { authorization = "Bearer \(token)" }
        case .dynamic(let p):
            provider = p
            do {
                let token = try await p.authorization()?.trimmingCharacters(in: .whitespacesAndNewlines)
                if let token, !token.isEmpty { authorization = "Bearer \(token)" }
                certificate = try await p.clientCertificate()
            } catch is CancellationError { throw CancellationError() } catch let error as KubeError {
                throw UpstreamError.credentials(error.localizedDescription)
            } catch { throw UpstreamError.credentials(error.localizedDescription) }
        }
        var identity: SecIdentity?
        if https {
            if let certificate {
                identity = try await resolveIdentity(clusterID: config.id, certificatePEM: certificate.certificatePEM, keyPEM: certificate.keyPEM)
            } else if config.authKind == .clientCertificate, let cert = target.secrets.clientCertificatePEM, let key = target.secrets.clientKeyPEM {
                identity = try await resolveIdentity(clusterID: config.id, certificatePEM: cert, keyPEM: key)
            }
        }

        let anchors = target.secrets.caPEM.map { PEM.decode($0).filter { $0.label == "CERTIFICATE" }.compactMap { SecCertificateCreateWithData(nil, $0.der as CFData) } } ?? []
        let parameters: NWParameters
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.enableKeepalive = true
        if https {
            let tls = NWProtocolTLS.Options()
            let sec = tls.securityProtocolOptions
            sec_protocol_options_set_min_tls_protocol_version(sec, .TLSv12)
            sec_protocol_options_add_tls_application_protocol(sec, "http/1.1")
            let name = config.tlsServerName?.trimmingCharacters(in: .whitespaces).nilIfEmpty ?? host
            if IPv4Address(name) == nil, IPv6Address(name) == nil {
                sec_protocol_options_set_tls_server_name(sec, name)
            }
            if let identity, let secIdentity = sec_identity_create(identity) { sec_protocol_options_set_local_identity(sec, secIdentity) }
            let insecure = config.allowsInsecureTLS
            sec_protocol_options_set_verify_block(sec, { _, trust, complete in
                if insecure { complete(true); return }
                let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
                complete(TLSValidator.evaluate(secTrust, host: name, anchors: anchors).trusted)
            }, self.queue)
            parameters = NWParameters(tls: tls, tcp: tcp)
        } else {
            parameters = NWParameters(tls: nil, tcp: tcp)
        }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw UpstreamError.notReachable("bad port") }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: parameters)
        let stream = NWStream(connection, queue: queue)
        do { try await stream.start() } catch {
            stream.cancel()
            throw UpstreamError.notReachable((error as? StreamError).map { if case .failed(let why) = $0 { why } else { "closed" } } ?? error.localizedDescription)
        }
        var hostHeader = host.contains(":") ? "[\(host)]" : host
        if let p = config.server.port { hostHeader += ":\(p)" }
        var base = config.server.path
        while base.hasSuffix("/") { base.removeLast() }
        return UpstreamLink(stream: stream, authorization: authorization, hostHeader: hostHeader, basePath: base, provider: provider)
    }

    /// Builds (once per distinct certificate) the keychain identity, off the cooperative pool: `SecItemAdd` can block.
    private func resolveIdentity(clusterID: ClusterID, certificatePEM: String, keyPEM: String) async throws -> SecIdentity {
        let key = clusterID + ":" + SHA256.hash(data: Data((certificatePEM + keyPEM).utf8)).map { String(format: "%02x", $0) }.joined()
        if let hit = identities.withLock({ $0[key] }) { return hit.identity }
        let box: IdentityBox = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let built = try ClientIdentityBuilder.build(certificatePEM: certificatePEM, keyPEM: keyPEM, label: ClientIdentityBuilder.label(for: clusterID))
                    continuation.resume(returning: IdentityBox(built.identity))
                } catch {
                    continuation.resume(throwing: UpstreamError.credentials((error as? ClientIdentityError)?.diagnostic ?? error.localizedDescription))
                }
            }
        }
        identities.withLock { $0[key] = box }
        return box.identity
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
#endif
