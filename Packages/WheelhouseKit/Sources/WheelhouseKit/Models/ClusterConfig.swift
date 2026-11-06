import Foundation

public enum ClusterEnvironment: String, Codable, CaseIterable, Sendable, Identifiable {
    case development, staging, production, personal
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .development: "Development"
        case .staging: "Staging"
        case .production: "Production"
        case .personal: "Personal"
        }
    }
    public var badgeText: String {
        switch self {
        case .development: "DEV"
        case .staging: "STAGING"
        case .production: "PRODUCTION"
        case .personal: "HOME"
        }
    }
    /// Production clusters always require type-to-confirm for disruptive actions and never allow skipping TLS verification.
    public var requiresTypeToConfirm: Bool { self == .production }

    /// Suggests an environment from a context/cluster name (`prod` → production, etc.).
    public static func suggested(forName name: String) -> ClusterEnvironment {
        let n = name.lowercased()
        if n.contains("prod") || n.contains("prd") { return .production }
        if n.contains("stag") || n.contains("stg") || n.contains("uat") { return .staging }
        if n.contains("home") || n.contains("k3s") || n.contains("lab") || n.contains("minikube") || n.contains("personal") { return .personal }
        return .development
    }
}

public enum ClusterAuthKind: String, Codable, Sendable, CaseIterable {
    case token
    case clientCertificate
    case none
}

public enum ClusterColor: String, Codable, CaseIterable, Sendable, Identifiable {
    case teal, blue, indigo, purple, pink, orange, green, gray
    public var id: String { rawValue }
}

public struct ClusterConfig: Identifiable, Codable, Hashable, Sendable {
    public var id: ClusterID
    public var name: String
    public var server: URL
    public var authKind: ClusterAuthKind
    public var environment: ClusterEnvironment
    public var readOnly: Bool
    /// Allows exec / port-forward even when `readOnly` is on.
    public var allowExecInReadOnly: Bool
    public var iCloudSync: Bool
    /// Requested by the user. Use ``allowsInsecureTLS`` for the effective value; production clusters ignore it.
    public var skipTLSVerify: Bool
    public var prometheusURL: URL?
    /// Name the server certificate must be valid for when it differs from the URL host (kubeconfig `tls-server-name`). Optional Codable, so older saved configs decode as nil.
    public var tlsServerName: String?
    public var defaultNamespace: String?
    public var pinnedNamespaces: [String]
    public var color: ClusterColor
    public var provider: String?
    public var region: String?
    public var isDemo: Bool
    public var createdAt: Date
    public var modifiedAt: Date

    public init(id: ClusterID = UUID().uuidString.lowercased(), name: String, server: URL,
                authKind: ClusterAuthKind = .token, environment: ClusterEnvironment = .development,
                readOnly: Bool = false, allowExecInReadOnly: Bool = false, iCloudSync: Bool = false,
                skipTLSVerify: Bool = false, prometheusURL: URL? = nil, defaultNamespace: String? = nil,
                pinnedNamespaces: [String] = [], color: ClusterColor = .teal, provider: String? = nil,
                region: String? = nil, isDemo: Bool = false, createdAt: Date = Date(), modifiedAt: Date = Date(), tlsServerName: String? = nil) {
        self.id = id
        self.name = name
        self.server = server
        self.authKind = authKind
        self.environment = environment
        self.readOnly = readOnly
        self.allowExecInReadOnly = allowExecInReadOnly
        self.iCloudSync = iCloudSync
        self.skipTLSVerify = skipTLSVerify
        self.prometheusURL = prometheusURL
        self.tlsServerName = tlsServerName
        self.defaultNamespace = defaultNamespace
        self.pinnedNamespaces = pinnedNamespaces
        self.color = color
        self.provider = provider
        self.region = region
        self.isDemo = isDemo
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
    }

    public var isProduction: Bool { environment == .production }

    /// The effective skip-TLS flag: never true for production-tagged clusters.
    public var allowsInsecureTLS: Bool { skipTLSVerify && environment != .production }

    /// True if the user asked to skip verification but it is being ignored (production).
    public var insecureTLSBlocked: Bool { skipTLSVerify && environment == .production }

    public var host: String { server.host() ?? server.absoluteString }

    /// Whether the server URL looks like a loopback / local address that is unreachable from a phone.
    public var isLocalhostServer: Bool {
        let h = host.lowercased()
        return ["127.0.0.1", "localhost", "::1", "host.docker.internal"].contains(h) || h.hasSuffix(".localhost")
    }
}

/// Secret material for one cluster. Stored only in the Keychain.
public struct ClusterSecrets: Codable, Hashable, Sendable {
    public var token: String?
    public var clientCertificatePEM: String?
    public var clientKeyPEM: String?
    public var caPEM: String?
    public init(token: String? = nil, clientCertificatePEM: String? = nil, clientKeyPEM: String? = nil, caPEM: String? = nil) {
        self.token = token
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.caPEM = caPEM
    }
    public var isEmpty: Bool { token == nil && clientCertificatePEM == nil && clientKeyPEM == nil && caPEM == nil }
}
