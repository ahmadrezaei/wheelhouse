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

/// Coding key for arbitrary (unknown) JSON object keys.
struct DynamicCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ s: String) { stringValue = s }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
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
    public var color: ClusterColor { didSet { if color != oldValue { unknownColorRaw = nil } } }
    public var provider: String?
    public var region: String?
    public var isDemo: Bool
    public var createdAt: Date
    public var modifiedAt: Date
    /// Mac only: where a discovered cluster comes from. `nil` = a Keychain or imported cluster (the iOS meaning). Deliberately NOT a
    /// coding key: it is never encoded, so no mirror, file or older decoder ever sees it (see ``ClusterOrigin``).
    public var origin: ClusterOrigin? = nil
    /// Keys this build does not know (written by a newer app). Ignored when reading, written back unchanged when the config is
    /// re-saved, so an older device never strips data another device added.
    public internal(set) var unknownFields: [String: JSONValue] = [:]
    /// Raw `color` string when it is a value this build does not know (cosmetic only, shown as gray). Written back unchanged until
    /// the user picks a colour here. Unknown values of any other enum are NOT tolerated (see `init(from:)`).
    var unknownColorRaw: String?

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

    // MARK: Codable (tolerant of newer writers)

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, name, server, authKind, environment, readOnly, allowExecInReadOnly, iCloudSync, skipTLSVerify, prometheusURL
        case tlsServerName, defaultNamespace, pinnedNamespaces, color, provider, region, isDemo, createdAt, modifiedAt
    }

    /// Compatibility policy: unknown KEYS are ignored on read and kept in ``unknownFields``. An unknown raw value of a
    /// safety-relevant enum (`environment`, `authKind`) deliberately FAILS the decode instead of being mapped to a guess: the
    /// caller (`ClusterMetadataStore`) then keeps the whole element as raw JSON, hidden on this device and written back untouched,
    /// so a future environment can never be treated as less safe than it is. Only `color` (cosmetic) falls back (to gray).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(ClusterID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        server = try c.decode(URL.self, forKey: .server)
        authKind = try c.decode(ClusterAuthKind.self, forKey: .authKind)
        environment = try c.decode(ClusterEnvironment.self, forKey: .environment)
        readOnly = try c.decode(Bool.self, forKey: .readOnly)
        allowExecInReadOnly = try c.decode(Bool.self, forKey: .allowExecInReadOnly)
        iCloudSync = try c.decode(Bool.self, forKey: .iCloudSync)
        skipTLSVerify = try c.decode(Bool.self, forKey: .skipTLSVerify)
        prometheusURL = try c.decodeIfPresent(URL.self, forKey: .prometheusURL)
        tlsServerName = try c.decodeIfPresent(String.self, forKey: .tlsServerName)
        defaultNamespace = try c.decodeIfPresent(String.self, forKey: .defaultNamespace)
        pinnedNamespaces = try c.decode([String].self, forKey: .pinnedNamespaces)
        let rawColor = try c.decode(String.self, forKey: .color)
        if let known = ClusterColor(rawValue: rawColor) { color = known } else { color = .gray; unknownColorRaw = rawColor }
        provider = try c.decodeIfPresent(String.self, forKey: .provider)
        region = try c.decodeIfPresent(String.self, forKey: .region)
        isDemo = try c.decode(Bool.self, forKey: .isDemo)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        modifiedAt = try c.decode(Date.self, forKey: .modifiedAt)
        let all = try decoder.container(keyedBy: DynamicCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        for key in all.allKeys where !known.contains(key.stringValue) {
            unknownFields[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var extra = encoder.container(keyedBy: DynamicCodingKey.self)
        for (k, v) in unknownFields { try extra.encode(v, forKey: DynamicCodingKey(k)) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(server, forKey: .server)
        try c.encode(authKind, forKey: .authKind)
        try c.encode(environment, forKey: .environment)
        try c.encode(readOnly, forKey: .readOnly)
        try c.encode(allowExecInReadOnly, forKey: .allowExecInReadOnly)
        try c.encode(iCloudSync, forKey: .iCloudSync)
        try c.encode(skipTLSVerify, forKey: .skipTLSVerify)
        try c.encodeIfPresent(prometheusURL, forKey: .prometheusURL)
        try c.encodeIfPresent(tlsServerName, forKey: .tlsServerName)
        try c.encodeIfPresent(defaultNamespace, forKey: .defaultNamespace)
        try c.encode(pinnedNamespaces, forKey: .pinnedNamespaces)
        try c.encode(unknownColorRaw ?? color.rawValue, forKey: .color)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(region, forKey: .region)
        try c.encode(isDemo, forKey: .isDemo)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(modifiedAt, forKey: .modifiedAt)
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
    /// Keys written by a newer app: ignored here, written back unchanged on re-save.
    public internal(set) var unknownFields: [String: JSONValue] = [:]
    public init(token: String? = nil, clientCertificatePEM: String? = nil, clientKeyPEM: String? = nil, caPEM: String? = nil) {
        self.token = token
        self.clientCertificatePEM = clientCertificatePEM
        self.clientKeyPEM = clientKeyPEM
        self.caPEM = caPEM
    }
    public var isEmpty: Bool { token == nil && clientCertificatePEM == nil && clientKeyPEM == nil && caPEM == nil }

    private enum CodingKeys: String, CodingKey, CaseIterable { case token, clientCertificatePEM, clientKeyPEM, caPEM }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        token = try c.decodeIfPresent(String.self, forKey: .token)
        clientCertificatePEM = try c.decodeIfPresent(String.self, forKey: .clientCertificatePEM)
        clientKeyPEM = try c.decodeIfPresent(String.self, forKey: .clientKeyPEM)
        caPEM = try c.decodeIfPresent(String.self, forKey: .caPEM)
        let all = try decoder.container(keyedBy: DynamicCodingKey.self)
        let known = Set(CodingKeys.allCases.map(\.stringValue))
        for key in all.allKeys where !known.contains(key.stringValue) {
            unknownFields[key.stringValue] = try all.decode(JSONValue.self, forKey: key)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var extra = encoder.container(keyedBy: DynamicCodingKey.self)
        for (k, v) in unknownFields { try extra.encode(v, forKey: DynamicCodingKey(k)) }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(token, forKey: .token)
        try c.encodeIfPresent(clientCertificatePEM, forKey: .clientCertificatePEM)
        try c.encodeIfPresent(clientKeyPEM, forKey: .clientKeyPEM)
        try c.encodeIfPresent(caPEM, forKey: .caPEM)
    }
}
