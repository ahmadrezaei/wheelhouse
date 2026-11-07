import Foundation

/// FROZEN COPY of the iCloud-sync wire types exactly as shipped in 1.0.1 (iOS builds 1-5). Do not edit and do not make it
/// reference the real types: it stands for an older install that is still reading what newer builds write.
enum Frozen_1_0_1 {
    enum ClusterEnvironment: String, Codable, CaseIterable, Sendable { case development, staging, production, personal }
    enum ClusterAuthKind: String, Codable, Sendable, CaseIterable { case token, clientCertificate, none }
    enum ClusterColor: String, Codable, CaseIterable, Sendable { case teal, blue, indigo, purple, pink, orange, green, gray }

    struct ClusterConfig: Identifiable, Codable, Hashable, Sendable {
        var id: String
        var name: String
        var server: URL
        var authKind: ClusterAuthKind
        var environment: ClusterEnvironment
        var readOnly: Bool
        var allowExecInReadOnly: Bool
        var iCloudSync: Bool
        var skipTLSVerify: Bool
        var prometheusURL: URL?
        var tlsServerName: String?
        var defaultNamespace: String?
        var pinnedNamespaces: [String]
        var color: ClusterColor
        var provider: String?
        var region: String?
        var isDemo: Bool
        var createdAt: Date
        var modifiedAt: Date

        init(id: String, name: String, server: URL, authKind: ClusterAuthKind = .token, environment: ClusterEnvironment = .development,
             readOnly: Bool = false, allowExecInReadOnly: Bool = false, iCloudSync: Bool = true, skipTLSVerify: Bool = false,
             prometheusURL: URL? = nil, tlsServerName: String? = nil, defaultNamespace: String? = nil, pinnedNamespaces: [String] = [],
             color: ClusterColor = .teal, provider: String? = nil, region: String? = nil, isDemo: Bool = false,
             createdAt: Date, modifiedAt: Date) {
            self.id = id; self.name = name; self.server = server; self.authKind = authKind; self.environment = environment
            self.readOnly = readOnly; self.allowExecInReadOnly = allowExecInReadOnly; self.iCloudSync = iCloudSync
            self.skipTLSVerify = skipTLSVerify; self.prometheusURL = prometheusURL; self.tlsServerName = tlsServerName
            self.defaultNamespace = defaultNamespace; self.pinnedNamespaces = pinnedNamespaces; self.color = color
            self.provider = provider; self.region = region; self.isDemo = isDemo; self.createdAt = createdAt; self.modifiedAt = modifiedAt
        }
    }

    struct Mirror: Codable, Equatable {
        var clusters: [ClusterConfig] = []
        var deleted: [String: Date] = [:]
    }

    static var decoder: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    static var encoder: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }

    /// 1.0.1 `readMirror()`: all-or-nothing, then the legacy bare array, then an empty mirror.
    static func readMirror(_ data: Data) -> Mirror {
        if let payload = try? decoder.decode(Mirror.self, from: data) { return payload }
        if let legacy = try? decoder.decode([ClusterConfig].self, from: data) { return Mirror(clusters: legacy) }
        return Mirror()
    }
}
