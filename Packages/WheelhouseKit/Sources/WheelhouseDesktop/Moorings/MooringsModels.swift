#if os(macOS)
import CryptoKit
import Foundation
import WheelhouseKit

// MARK: - Identity

/// A context is identified by the file that DEFINES it and its name (ARCHITECTURE-MAC §4.4). Renaming the context or moving the file
/// yields a new cluster; the old one shows "Source removed" with Re-link.
public struct DiscoveredContextKey: Hashable, Codable, Sendable {
    /// Canonical path (symlinks resolved).
    public var definingFile: String
    public var contextName: String

    public init(definingFile: String, contextName: String) {
        self.definingFile = definingFile
        self.contextName = contextName
    }

    /// `"kc-" + hex(SHA-256(path + NUL + name)).prefix(20)`.
    public var clusterID: ClusterID {
        var data = Data(definingFile.utf8)
        data.append(0)
        data.append(Data(contextName.utf8))
        return "kc-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined().prefix(20)
    }
}

public extension Data {
    var sha256Hex: String { SHA256.hash(data: self).map { String(format: "%02x", $0) }.joined() }
}

public extension String {
    var sha256Hex: String { Data(utf8).sha256Hex }
}

// MARK: - Sources

/// Where contexts come from (ARCHITECTURE-MAC §4.1).
public struct MooringsSource: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// `KUBECONFIG` from the login-shell snapshot, or `~/.kube/config` when it is empty.
        case defaultSet
        /// `~/.kube/*.yaml` and `~/.kube/configs/*` (asked on first run).
        case homeFiles
        case userFolder
        case userFile
        case landfall
        /// The explicit test file (development builds).
        case explicitTest
    }
    public var kind: Kind
    /// For folders and files.
    public var path: String?
    public var recursive: Bool = false

    public var id: String { path.map { "\(kind.rawValue):\($0)" } ?? kind.rawValue }

    public init(kind: Kind, path: String? = nil, recursive: Bool = false) {
        self.kind = kind
        self.path = path
        self.recursive = recursive
    }
}

/// The user's choices in Settings → Moorings (persisted as JSON under `AppPaths.root`).
public struct MooringsPreferences: Codable, Equatable, Sendable {
    public var shellKubeconfigEnabled = true
    /// nil = not asked yet.
    public var homeFilesEnabled: Bool?
    public var userSources: [MooringsSource] = []
    /// False until the first-run sheet was answered (Add or Choose Later does not count as done until the sheet is dismissed).
    public var firstRunCompleted = false
    public init() {}
}

// MARK: - Contexts

public enum AuthSummary: Sendable, Equatable {
    case token, tokenFile, clientCertificate
    case exec(command: String)
    case legacyProvider(String)
    case unsupported
    case none

    public var label: String {
        switch self {
        case .token, .tokenFile: "Token"
        case .clientCertificate: "Client cert"
        case .exec(let command): "Exec \((command as NSString).lastPathComponent)"
        case .legacyProvider(let name): name == "oidc" ? "OIDC" : name
        case .unsupported: "Unsupported"
        case .none: "None"
        }
    }
}

public struct DiscoveredContext: Sendable, Identifiable, Equatable {
    public var key: DiscoveredContextKey
    public var id: ClusterID { key.clusterID }
    /// Every source that found this context (the same file can be reached through two sources).
    public var sourceIDs: [String]
    public var context: KubeconfigContext
    /// The `current-context` tag of its file (displayed, never changed).
    public var isCurrent: Bool
    /// File name of the earlier file that defines the same name in the default set ("shadowed by work.yaml").
    public var shadowedBy: String?
    /// Name shown in the UI (disambiguated with the file name when standalone sources define the same name).
    public var displayName: String
    public var suggestion: EnvironmentSuggestion?
    /// The server is not an allowed test host (development builds).
    public var blockedInDevelopment: Bool
    public var fingerprint: String
    public var authSummary: AuthSummary
    /// A hash of the exec stanza, for duplicate detection.
    public var execSpecHash: String?

    public var server: URL? { context.server }
    public var fileName: String { (key.definingFile as NSString).lastPathComponent }
    /// Usable as a cluster: valid server and a supported auth kind, not shadowed.
    public var isUsable: Bool { context.status == .ready && shadowedBy == nil }
    public var isSuggestedProduction: Bool { suggestion?.environment == .production }
}

public extension DiscoveredContext {
    static func make(key: DiscoveredContextKey, sourceID: String, context: KubeconfigContext, isCurrent: Bool, shadowedBy: String?,
                     gate: DevSafetyPolicy) -> DiscoveredContext {
        let suggestion = EnvironmentSuggester.suggest(SuggestionInput(contextName: context.name, clusterName: context.clusterName,
                                                                      userName: context.userName, serverHost: context.server?.host()))
        let summary: AuthSummary
        switch context.auth {
        case .exec(let command, _): summary = .exec(command: command)
        case .token: summary = .token
        case .clientCertificate: summary = .clientCertificate
        case .authProvider(let name): summary = .legacyProvider(name)
        case .basic, .missingFiles: summary = .unsupported
        case .none:
            if context.files?.tokenFile != nil { summary = .tokenFile }
            else if context.files?.clientCertificate != nil || context.files?.clientKey != nil { summary = .clientCertificate }
            else { summary = .none }
        }
        return DiscoveredContext(key: key, sourceIDs: [sourceID], context: context, isCurrent: isCurrent, shadowedBy: shadowedBy,
                                 displayName: context.name, suggestion: suggestion,
                                 blockedInDevelopment: !gate.isAllowed(server: context.server),
                                 fingerprint: fingerprint(of: context), authSummary: summary,
                                 execSpecHash: context.exec.map(execHash))
    }

    /// SHA-256 of the canonical JSON of what a client is built from: the resolved server, CA, TLS name and the user stanza (the
    /// exec spec, or file paths and inline-data hashes). A change invalidates sessions; a namespace change does not.
    static func fingerprint(of c: KubeconfigContext) -> String {
        struct Material: Encodable {
            var server: String?
            var ca: String?
            var tlsServerName: String?
            var insecure: Bool
            var token: String?
            var certificate: String?
            var key: String?
            var files: KubeconfigFileReferences?
            var exec: KubeconfigExecSpec?
        }
        var m = Material(server: c.server?.absoluteString, ca: c.caPEM?.sha256Hex, tlsServerName: c.tlsServerName,
                         insecure: c.insecureSkipTLSVerify, files: c.files, exec: c.exec)
        switch c.auth {
        case .token(let t): m.token = t.sha256Hex
        case .clientCertificate(let cert, let key): m.certificate = cert.sha256Hex; m.key = key.sha256Hex
        default: break
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ((try? encoder.encode(m)) ?? Data()).sha256Hex
    }

    static func execHash(_ spec: KubeconfigExecSpec) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var canonical = spec
        canonical.baseDirectory = nil
        return ((try? encoder.encode(canonical)) ?? Data()).sha256Hex
    }
}

// MARK: - Per-cluster Mac-only details (never persisted into the mirror)

public enum ClusterCheckResult: Sendable, Equatable {
    case reachable(latencyMilliseconds: Int, version: String?)
    case needsSignIn
    case unreachable(String)
    case pluginMissing(String)
    case blocked(String)
}

public enum ClusterCheckState: Sendable, Equatable {
    case notChecked
    case checking
    case result(ClusterCheckResult)
}

/// Mac-only facts about a discovered cluster (ARCHITECTURE-MAC §4.4 `DesktopClusterInfo`), keyed by `ClusterID`.
public struct DesktopClusterInfo: Sendable, Equatable {
    public var authSummary: AuthSummary
    public var execSpecHash: String?
    public var lastFingerprint: String
    public var environmentSuggested: EnvironmentSuggestion?
    public var isNew: Bool
    public var hidden: Bool
    public var checkState: ClusterCheckState
    public var sourceRemovedAt: Date?
    public var definingFile: String
    public var contextName: String
    public var isCurrentContext: Bool
    public var blockedInDevelopment: Bool
    /// The Keychain cluster this context duplicates (decision 11: that entry wins, this is its secondary source).
    public var duplicateOf: ClusterID?
}

// MARK: - Persistence of user choices

/// What the user changed about a discovered cluster (the overlay of ARCHITECTURE-MAC §4.4). Stored in `discovered-clusters.json`.
public struct DiscoveredOverride: Codable, Equatable, Sendable {
    public var name: String?
    public var environment: ClusterEnvironment?
    /// True when the user picked the environment in the sheet (a suggestion alone never allows changes).
    public var environmentChosen = false
    public var readOnly = true
    public var allowExecInReadOnly = false
    public var color: ClusterColor?
    public var pinnedNamespaces: [String] = []
    public var defaultNamespace: String?
    /// The user pressed Add (or the context was auto-added after the first run).
    public var added = false
    public var hidden = false
    /// Found after the first run: shows a "New" badge until opened.
    public var isNew = false
    public var addedAt = Date(timeIntervalSince1970: 0)
    /// Kept for 30 days after the context disappeared from its file.
    public var sourceRemovedAt: Date?
    /// The user clicked Check or opened the cluster: Production-suggested clusters may be contacted from now on.
    public var contactApproved = false
    /// What a client needs, remembered so a cluster whose context disappeared still shows (Source removed).
    public var lastKnown: LastKnownContext?

    public init() {}
}

/// The facts of a context at the time it was last seen.
public struct LastKnownContext: Codable, Equatable, Sendable {
    public var definingFile: String
    public var contextName: String
    public var server: String
    public var tlsServerName: String?
    public var authKind: ClusterAuthKind
    public var insecureSkipTLSVerify: Bool
    public var namespace: String?
    public var displayName: String
    public var suggestedEnvironment: ClusterEnvironment?
}
#endif
