import Foundation

/// Editable state behind the Add / Edit cluster form. Pure value type so validation and the
/// config/secret construction can be unit tested without UI.
public struct ClusterDraft: Equatable, Sendable {
    public var id: ClusterID
    public var name = ""
    public var serverText = ""
    public var authKind: ClusterAuthKind = .token
    public var token = ""
    public var caPEM = ""
    public var skipTLSVerify = false
    public var tlsServerName = ""
    public var environment: ClusterEnvironment = .development
    public var color: ClusterColor = .teal
    public var readOnly = false
    public var allowExecInReadOnly = false
    public var iCloudSync = false
    public var prometheusText = ""
    public var prometheusToken = ""
    public var defaultNamespace = ""
    /// Existing cluster being edited (keeps createdAt, provider, pinned namespaces…).
    public var original: ClusterConfig?
    /// Client-certificate material carried over from a kubeconfig import / existing cluster.
    public var clientCertificatePEM: String?
    public var clientKeyPEM: String?

    public init(id: ClusterID = UUID().uuidString.lowercased()) { self.id = id }

    public init(editing config: ClusterConfig, secrets: ClusterSecrets) {
        id = config.id
        name = config.name
        serverText = config.server.absoluteString
        authKind = config.authKind
        caPEM = secrets.caPEM ?? ""
        skipTLSVerify = config.skipTLSVerify
        tlsServerName = config.tlsServerName ?? ""
        environment = config.environment
        color = config.color
        readOnly = config.readOnly
        allowExecInReadOnly = config.allowExecInReadOnly
        iCloudSync = config.iCloudSync
        prometheusText = config.prometheusURL?.absoluteString ?? ""
        defaultNamespace = config.defaultNamespace ?? ""
        original = config
        clientCertificatePEM = secrets.clientCertificatePEM
        clientKeyPEM = secrets.clientKeyPEM
        token = ""
    }

    // MARK: Validation

    /// Normalises user input such as `my.cluster:6443` into `https://my.cluster:6443`.
    public static func normalizedURL(_ text: String) -> URL? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if !t.contains("://") { t = "https://" + t }
        while t.hasSuffix("/") { t.removeLast() }
        guard let url = URL(string: t), let scheme = url.scheme?.lowercased(), ["https", "http"].contains(scheme),
              let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    public var serverURL: URL? { Self.normalizedURL(serverText) }
    public var prometheusURL: URL? { prometheusText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Self.normalizedURL(prometheusText) }
    public var isEditing: Bool { original != nil }

    public var serverIsPlainHTTP: Bool { serverURL?.scheme?.lowercased() == "http" }
    public var serverIsLocalhost: Bool {
        guard let url = serverURL else { return false }
        return ClusterConfig(name: "x", server: url).isLocalhostServer
    }

    /// Production clusters can never skip TLS verification.
    public var skipTLSAllowed: Bool { environment != .production }

    public enum Problem: Equatable, Sendable {
        case nameMissing, serverInvalid, prometheusInvalid, tokenMissing, caInvalid, httpNotAllowedForProduction
        public var message: String {
            switch self {
            case .nameMissing: "Give the cluster a name."
            case .serverInvalid: "Enter a valid API server URL, e.g. https://api.example.com:6443"
            case .prometheusInvalid: "The Prometheus URL is not valid."
            case .tokenMissing: "A bearer token is required."
            case .caInvalid: "The CA certificate is not valid PEM."
            case .httpNotAllowedForProduction: "Production clusters require https://. The token would otherwise travel unencrypted."
            }
        }
    }

    public var problems: [Problem] {
        var out: [Problem] = []
        if name.trimmingCharacters(in: .whitespaces).isEmpty { out.append(.nameMissing) }
        if serverURL == nil { out.append(.serverInvalid) }
        if serverIsPlainHTTP, environment == .production { out.append(.httpNotAllowedForProduction) }
        if !prometheusText.trimmingCharacters(in: .whitespaces).isEmpty, prometheusURL == nil { out.append(.prometheusInvalid) }
        if authKind == .token, token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !isEditing { out.append(.tokenMissing) }
        if !caPEM.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !Self.isValidCAPEM(caPEM) { out.append(.caInvalid) }
        return out
    }
    public var isValid: Bool { problems.isEmpty }

    public static func isValidCAPEM(_ text: String) -> Bool {
        !PEM.decode(text).filter { $0.label == "CERTIFICATE" }.isEmpty
    }

    // MARK: Output

    public func makeConfig() -> ClusterConfig? {
        guard let server = serverURL else { return nil }
        var c = original ?? ClusterConfig(id: id, name: name, server: server)
        c.name = name.trimmingCharacters(in: .whitespaces)
        c.server = server
        c.authKind = authKind
        c.environment = environment
        c.color = color
        c.readOnly = readOnly
        c.allowExecInReadOnly = readOnly && allowExecInReadOnly
        c.iCloudSync = iCloudSync
        c.skipTLSVerify = skipTLSVerify && environment != .production
        c.prometheusURL = prometheusURL
        let sni = tlsServerName.trimmingCharacters(in: .whitespaces)
        c.tlsServerName = sni.isEmpty ? nil : sni
        let ns = defaultNamespace.trimmingCharacters(in: .whitespaces)
        c.defaultNamespace = ns.isEmpty ? nil : ns
        return c
    }

    /// Secrets to store. When editing, blank fields keep the values already in `existing`.
    public func makeSecrets(existing: ClusterSecrets = ClusterSecrets()) -> ClusterSecrets {
        var s = existing
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if authKind == .token { if !t.isEmpty { s.token = t } } else if authKind == .none { s.token = nil }
        if authKind != .clientCertificate && authKind != .none { s.clientCertificatePEM = nil; s.clientKeyPEM = nil }
        if let c = clientCertificatePEM, let k = clientKeyPEM, authKind == .clientCertificate { s.clientCertificatePEM = c; s.clientKeyPEM = k }
        let ca = caPEM.trimmingCharacters(in: .whitespacesAndNewlines)
        s.caPEM = ca.isEmpty ? nil : ca
        return s
    }

    /// Prefills a draft from an imported kubeconfig context.
    public init(context: KubeconfigContext) {
        self.init()
        name = context.name
        serverText = context.server?.absoluteString ?? ""
        caPEM = context.caPEM ?? ""
        environment = context.suggestedEnvironment
        defaultNamespace = context.namespace ?? ""
        skipTLSVerify = context.insecureSkipTLSVerify && environment != .production
        tlsServerName = context.tlsServerName ?? ""
    }
}

/// Reads the `exp` claim of a JWT bearer token (no verification; display only).
public enum JWTInfo {
    public static func expiry(of token: String) -> Date? {
        let parts = token.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".")
        guard parts.count == 3 else { return nil }
        var b64 = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while b64.count % 4 != 0 { b64 += "=" }
        guard let data = Data(base64Encoded: b64),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = (obj["exp"] as? NSNumber)?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: exp)
    }
}

/// Human summary of the first certificate in a PEM bundle.
public enum CertificateSummary {
    public static func subject(of pem: String) -> String? {
        guard let block = PEM.decode(pem).first(where: { $0.label == "CERTIFICATE" }),
              let cert = SecCertificateCreateWithData(nil, block.der as CFData) else { return nil }
        return SecCertificateCopySubjectSummary(cert) as String?
    }
    public static func count(in pem: String) -> Int { PEM.decode(pem).filter { $0.label == "CERTIFICATE" }.count }
}
