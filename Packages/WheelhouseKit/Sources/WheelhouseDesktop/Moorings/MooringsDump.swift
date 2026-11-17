#if os(macOS)
import Foundation

/// A secret-free JSON picture of what Moorings found, for development runs that read state without a screen (`-WHMooringsDump`, honoured
/// only while the safety gate is active). It is an explicit allow-list: no token, certificate, key, file content or bookmark ever
/// reaches it (`KubeconfigContext.auth` holds raw credentials, so a context is never encoded as a whole).
public struct MooringsDump: Codable, Equatable, Sendable {
    public struct Context: Codable, Equatable, Sendable {
        public var name: String
        public var definingFile: String
        public var serverHost: String?
        public var auth: String
        public var accessFolders: [String]
    }
    public struct Grant: Codable, Equatable, Sendable {
        public var kind: String
        public var path: String
        public var problem: String?
    }
    public var sandboxed: Bool
    public var contexts: [Context]
    public var issues: [String: String]
    public var accessNeeded: [String: String]
    public var grants: [Grant]

    public static func make(sandboxed: Bool, contexts: [DiscoveredContext], issues: [String: String], accessNeeded: [String: String],
                            grants: [GrantedFolder]) -> MooringsDump {
        MooringsDump(
            sandboxed: sandboxed,
            contexts: contexts.map {
                Context(name: $0.context.name, definingFile: $0.key.definingFile, serverHost: $0.server?.host(), auth: $0.authSummary.label,
                        accessFolders: $0.accessFolders)
            },
            issues: issues, accessNeeded: accessNeeded,
            grants: grants.map { Grant(kind: $0.source.kind.rawValue, path: $0.source.path ?? "", problem: $0.problem.map { "\($0)" }) })
    }

    public func json() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        return try encoder.encode(self)
    }
}
#endif
