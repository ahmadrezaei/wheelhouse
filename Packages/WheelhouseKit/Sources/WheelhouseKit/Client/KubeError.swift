import Foundation

/// Errors surfaced by every ``KubeClientProtocol`` implementation.
public enum KubeError: Error, Sendable, Equatable {
    /// DNS / TCP / timeout failure. `cause` is a human-readable reason.
    case unreachable(cause: String)
    /// Server certificate could not be validated. `summary` describes the leaf certificate when known.
    case tlsUntrusted(summary: String?)
    /// The TLS handshake failed for a reason other than server trust (closed connection, rejected client certificate,
    /// protocol mismatch, unusable client key…). `reason` is actionable text; `code` the most specific raw code (SecureTransport / URLError).
    case tlsHandshake(reason: String, code: Int?)
    case unauthorized(message: String?)
    case forbidden(verb: String?, resource: String?, namespace: String?, message: String)
    case notFound(message: String?)
    case conflict(message: String?)
    case invalid(message: String, causes: [Status.Cause])
    /// Cluster is flagged read-only; the request was never sent.
    case readOnly
    /// 410 Gone: resourceVersion too old, relist required.
    case gone
    case server(Status)
    case decoding(String)
    /// Feature not available on this client (e.g. exec in demo mode).
    case unsupported(String)
    case cancelled

    /// Builds the right error from an HTTP status and (optional) decoded `Status` body.
    public static func from(httpStatus code: Int, status: Status?, fallback: String? = nil) -> KubeError {
        let message = status?.message ?? fallback ?? HTTPURLResponse.localizedString(forStatusCode: code)
        switch code {
        case 401:
            return .unauthorized(message: message)
        case 403:
            let d = status?.details
            let resource = [d?.kind, d?.group.flatMap { $0.isEmpty ? nil : $0 }].compactMap { $0 }.joined(separator: ".")
            let parsed = parseForbidden(message)
            return .forbidden(verb: parsed.verb, resource: parsed.resource ?? (resource.isEmpty ? nil : resource),
                              namespace: parsed.namespace, message: message)
        case 404:
            return .notFound(message: message)
        case 409:
            return .conflict(message: message)
        case 410:
            return .gone
        case 422:
            return .invalid(message: message, causes: status?.details?.causes ?? [])
        default:
            var s = status ?? Status(status: "Failure", message: message, code: code)
            if s.code == nil { s.code = code }
            return .server(s)
        }
    }

    /// Parses `pods is forbidden: User "x" cannot list resource "pods" in API group "" in the namespace "kube-system"`.
    static func parseForbidden(_ message: String) -> (verb: String?, resource: String?, namespace: String?) {
        let verb = message.range(of: "cannot ").flatMap { r -> String? in
            message[r.upperBound...].split(separator: " ").first.map(String.init)
        }
        return (verb, capture(of: "resource \"", in: message), capture(of: "namespace \"", in: message))
    }

    private static func capture(of key: String, in s: String) -> String? {
        guard let r = s.range(of: key) else { return nil }
        return s[r.upperBound...].split(separator: "\"", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init)
    }

    static let identityNoteMarker = " | Client certificate: "

    /// Appends the client-identity problem to a 401 message.
    static func appendingIdentityNote(_ note: String, to message: String?) -> String {
        (message ?? "") + identityNoteMarker + note
    }

    /// The client-identity problem attached to a 401 (key unusable, test signature failed…), if any.
    public var identityNote: String? {
        guard case .unauthorized(let m?) = self, let r = m.range(of: Self.identityNoteMarker) else { return nil }
        return String(m[r.upperBound...])
    }

    /// Short single-line description suitable for banners.
    public var summary: String {
        switch self {
        case .unreachable(let cause): "Unreachable: \(cause)"
        case .tlsUntrusted: "The server certificate is not trusted"
        case .tlsHandshake(let reason, let code): code.map { "\(reason) (code \($0))" } ?? reason
        case .unauthorized: identityNote.map { "Credentials were rejected (401). Client certificate: \($0)" } ?? "Credentials were rejected (401)"
        case .forbidden(let verb, let resource, let ns, _):
            "Forbidden: cannot \(verb ?? "access") \(resource ?? "resource")\(ns.map { " in \($0)" } ?? "")"
        case .notFound: "Not found"
        case .conflict: "The object was modified by someone else"
        case .invalid(let m, _): "Invalid: \(m)"
        case .readOnly: "This cluster is read-only"
        case .gone: "Watch expired; reloading"
        case .server(let s): s.message ?? "Server error"
        case .decoding(let m): "Unexpected response: \(m)"
        case .unsupported(let m): m
        case .cancelled: "Cancelled"
        }
    }

    public var isTransient: Bool {
        switch self {
        case .unreachable, .gone: true
        case .server(let s): (s.code ?? 500) >= 500
        // A connection closed mid-handshake is usually a flaky network or middlebox, worth retrying.
        case .tlsHandshake(let reason, let code): reason == TLSDiagnostics.closedMessage || code.map(TLSDiagnostics.closedCodes.contains) == true
        default: false
        }
    }
}

extension KubeError: LocalizedError {
    public var errorDescription: String? { summary }
}

public extension Status {
    /// Decodes a metav1.Status body and maps it to an error; falls back to a plain message when the body isn't a Status.
    static func decodeError(code: Int, body: Data) -> KubeError {
        let status = try? KubeJSON.decoder.decode(Status.self, from: body)
        let usable = status?.kind == "Status" ? status : nil
        let fallback = usable == nil ? String(data: body.prefix(300), encoding: .utf8) : nil
        return KubeError.from(httpStatus: code, status: usable, fallback: fallback)
    }
}


// MARK: - TLS diagnostics

/// Extracts SecureTransport / CFStream codes from a transport error and maps them to actionable text.
/// Numeric values come from `SecBase.h` (iOS 27.1 SDK).
public enum TLSDiagnostics {
    public struct Extracted: Sendable, Equatable {
        /// `URLError.Code` raw value (or the NSError code of a non-URLError).
        public var urlErrorCode: Int?
        /// `_kCFStreamErrorCodeKey` / `_kCFStreamErrorDomainKey` found anywhere in the chain (domain 3 = SSL).
        public var streamCode: Int?
        public var streamDomain: Int?
        /// OSStatus-style codes in the SecureTransport range found in nested errors.
        public var sslCode: Int?
        /// The most specific code: SSL code, else stream code, else the URLError code.
        public var bestCode: Int? { sslCode ?? streamCode ?? urlErrorCode }
        public var isSSLDomain: Bool { streamDomain == 3 || sslCode != nil }
    }

    public static let streamCodeKey = "_kCFStreamErrorCodeKey"
    public static let streamDomainKey = "_kCFStreamErrorDomainKey"

    static func isSSLRange(_ c: Int) -> Bool { (-9899 ... -9800).contains(c) }

    /// Domain of the nested OSStatus errors SecureTransport reports (`NSOSStatusErrorDomain`).
    static let osStatusDomain = "NSOSStatusErrorDomain"
    /// `kCFStreamErrorDomainSSL`
    static let sslStreamDomain = 3

    public static func extract(from error: Error) -> Extracted {
        var out = Extracted()
        let top = error as NSError
        out.urlErrorCode = top.code
        var current: NSError? = top
        var depth = 0
        while let ns = current, depth < 8 {
            if let c = (ns.userInfo[streamCodeKey] as? NSNumber)?.intValue {
                let domain = (ns.userInfo[streamDomainKey] as? NSNumber)?.intValue
                if out.streamCode == nil { out.streamCode = c; out.streamDomain = domain }
                // A number in the SecureTransport range only means SSL when it comes from the SSL stream domain.
                if isSSLRange(c), domain == sslStreamDomain, out.sslCode == nil { out.sslCode = c }
            }
            if depth > 0, ns.domain == osStatusDomain, isSSLRange(ns.code), out.sslCode == nil { out.sslCode = ns.code }
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return out
    }

    /// `domain:code` pairs for the error and its underlying chain, outermost first (no messages, so nothing sensitive).
    public static func errorChain(from error: Error) -> [String] {
        var out: [String] = []
        var current: NSError? = error as NSError
        var depth = 0
        while let ns = current, depth < 8 {
            out.append("\(ns.domain):\(ns.code)")
            current = ns.userInfo[NSUnderlyingErrorKey] as? NSError
            depth += 1
        }
        return out
    }

    static let closedMessage = "The connection was closed during the TLS handshake. A firewall, proxy, VPN or carrier network may be blocking or intercepting traffic to this server."
    static let rejectedClientCertMessage = "The server rejected the client certificate."
    static let negotiationMessage = "TLS version/cipher negotiation failed."
    static let badCertFormatMessage = "A certificate in the TLS handshake has an invalid format (checked on this device, not rejected by the server). Check the CA and client certificate PEM."
    static let keyMismatchMessage = "The server could not verify the client certificate's signature. The client key probably does not match the client certificate."
    static let certRequiredMessage = "The server requires a client certificate and none was accepted."
    static let unrecognizedNameMessage = "The server did not recognise the host name sent during the handshake (SNI). Check the server address or the kubeconfig tls-server-name."
    static let cryptoMessage = "A cryptographic operation failed during the TLS handshake (for example the client key could not sign)."
    /// SecureTransport codes meaning "closed during the handshake" (ClosedAbort, ClosedGraceful, ClosedNoNotify, TransportReset).
    static let closedCodes: Set<Int> = [-9806, -9805, -9816, -9852]

    /// Actionable text for a SecureTransport code, or nil if unknown.
    public static func message(forSSLCode code: Int) -> String? {
        switch code {
        case -9806, -9805, -9816, -9852: closedMessage
        case -9808: badCertFormatMessage                      // errSSLBadCert: local "bad certificate format"
        case -9809: cryptoMessage                             // errSSLCrypto
        case -9825, -9829, -9826, -9832, -9831: rejectedClientCertMessage // PeerBadCert, PeerCertUnknown, PeerUnsupportedCert, PeerAccessDenied, PeerUnknownCA
        case -9834: keyMismatchMessage                        // PeerDecryptError
        case -9863: certRequiredMessage                       // errSSLCertificateRequired
        case -9865: unrecognizedNameMessage                   // errSSLUnrecognizedName
        case -9824, -9836, -9830, -9801, -9818, -9837, -9858: negotiationMessage // PeerHandshakeFail, PeerProtocolVersion, IllegalParam, Negotiation, BadCipherSuite, InsufficientSecurity, HandshakeFail
        case -9802: "The TLS connection was aborted by a fatal alert from the server or the network."
        case -9842: "The server asked for a client certificate but none was presented."
        case -9853: "The TLS handshake timed out."
        case -9844: "The server refused the TLS connection."
        default: nil
        }
    }

    /// Maps a transport error that is TLS-related. A provider failure (`clientIdentityFailure`: key unusable on this device) takes
    /// precedence. `clientCertificateMissing` (server asked for a certificate, cluster has none) only explains
    /// `.clientCertificateRequired` / -9863. `neverConnected` marks "connection lost" on a client that has not yet completed any
    /// request as a handshake failure.
    public static func handshakeError(for error: Error, clientIdentityFailure: String? = nil, clientCertificateMissing: Bool = false, neverConnected: Bool = false) -> KubeError? {
        let x = extract(from: error)
        let url = (error as? URLError)?.code
        let isTLSURLCode = url == .secureConnectionFailed || url == .clientCertificateRejected || url == .clientCertificateRequired
        let lostDuringHandshake = url == .networkConnectionLost && (x.isSSLDomain || neverConnected)
        guard isTLSURLCode || lostDuringHandshake || (x.sslCode != nil && url != .cancelled) else { return nil }
        if let f = clientIdentityFailure { return .tlsHandshake(reason: f, code: x.bestCode) }
        if clientCertificateMissing, url == .clientCertificateRequired || (x.sslCode ?? x.streamCode) == -9863 {
            return .tlsHandshake(reason: "The server requires a client certificate but this cluster has none configured.", code: x.bestCode)
        }
        if let c = x.sslCode ?? x.streamCode, let m = message(forSSLCode: c), x.sslCode != nil || x.streamDomain == sslStreamDomain {
            return .tlsHandshake(reason: m, code: c)
        }
        let domainNote = x.streamCode != nil && x.streamDomain != sslStreamDomain ? " (stream domain \(x.streamDomain ?? -1), code \(x.streamCode ?? 0))" : ""
        switch url {
        case .clientCertificateRejected: return .tlsHandshake(reason: rejectedClientCertMessage, code: x.bestCode)
        case .clientCertificateRequired: return .tlsHandshake(reason: certRequiredMessage, code: x.bestCode)
        case .networkConnectionLost: return .tlsHandshake(reason: closedMessage, code: x.bestCode)
        default: return .tlsHandshake(reason: "TLS handshake failed." + domainNote, code: x.bestCode)
        }
    }
}

/// Plain-text connection report the user can copy. Never contains tokens, keys or certificate bodies.
public enum ConnectionDiagnosticsReport {
    public static func make(host: String, port: Int?, authKind: String, error: KubeError, trace: TLSTrace? = nil, osVersion: String, appVersion: String, build: String, date: Date = Date()) -> String {
        var lines = [
            "Wheelhouse connection diagnostics",
            "Time: \(ISO8601DateFormatter().string(from: date))",
            "Host: \(host)",
            "Port: \(port.map(String.init) ?? "default")",
            "Auth: \(authKind)",
            "Error: \(redact(error.summary))",
        ]
        switch error {
        case .tlsHandshake(let reason, let code):
            lines.append("TLS: handshake failure")
            lines.append("Reason: \(redact(reason))")
            lines.append("Code: \(code.map(String.init) ?? "none")")
        case .tlsUntrusted(let summary):
            lines.append("TLS: server certificate not trusted")
            if let summary { lines.append("Certificate: \(redact(summary))") }
        case .unreachable(let cause):
            lines.append("Cause: \(redact(cause))")
        default: break
        }
        if let note = error.identityNote { lines.append("Client identity: \(redact(note))") }
        if let t = trace { lines += traceLines(t) }
        lines.append("iOS: \(osVersion)")
        lines.append("App: \(appVersion) (\(build))")
        return lines.joined(separator: "\n")
    }

    static func traceLines(_ t: TLSTrace) -> [String] {
        var l = ["Server trust challenge: \(t.serverTrust.rawValue)",
                 "Client certificate challenge: \(t.clientCertificateRequested ? "received" : "not received")"]
        if t.noIdentityConfigured { l.append("Client identity: none configured (challenge declined)") }
        else if t.clientCertificateRequested { l.append("Client identity presented: \(t.identityPresented ? "yes" : "no")") }
        if let e = t.identityError { l.append("Client identity error: \(redact(e))") }
        if let s = t.signTest { l.append("Sign test: \(redact(s))") }
        if let sha = t.clientLeafSHA256 { l.append("Client leaf SHA-256: \(sha)") }
        if let d = t.clientLeafNotAfter { l.append("Client leaf notAfter: \(ISO8601DateFormatter().string(from: d))") }
        if let k = t.keyType { l.append("Client key: \(k)\(t.keySizeBits.map { " \($0)-bit" } ?? "")") }
        if let c = t.streamCode { l.append("Stream: domain \(t.streamDomain.map(String.init) ?? "?"), code \(c)") }
        if !t.errorChain.isEmpty { l.append("Error chain: \(t.errorChain.joined(separator: " > "))") }
        return l
    }

    /// Removes PEM blocks, bearer tokens and long base64 runs from free text.
    public static func redact(_ text: String) -> String {
        var t = text
        let patterns = [
            #"-----BEGIN [A-Z ]+-----[\s\S]*?-----END [A-Z ]+-----"#,
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]+"#,
            #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.?[A-Za-z0-9_-]*"#,
            #"[A-Za-z0-9+/=]{80,}"#,
        ]
        for p in patterns { t = t.replacingOccurrences(of: p, with: "<redacted>", options: .regularExpression) }
        return t
    }
}
