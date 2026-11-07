import Foundation
import Synchronization

/// What a caller may do with one cluster.
public enum ClusterAccess: String, Codable, Sendable, CaseIterable {
    case allowed
    /// First Mate only: reading needs the user's grant for this conversation and this cluster.
    case ask
    case never
}

/// Who is calling the toolbox.
public enum ToolboxCaller: Hashable, Sendable {
    case firstMate(conversation: String)
    case beacon(client: String)

    /// The ``ChangeOrigin`` that any change this caller causes carries.
    public var origin: ChangeOrigin {
        switch self {
        case .firstMate(let conversation): .firstMate(conversation: conversation)
        case .beacon(let client): .beacon(client: client)
        }
    }
}

/// A Beacon client's approved scope (DESIGN-MAC section 6.13). Change requests are opt-in per cluster.
public struct BeaconScope: Sendable, Equatable {
    public var readClusters: Set<ClusterID>
    public var changeRequestClusters: Set<ClusterID>
    public init(readClusters: Set<ClusterID> = [], changeRequestClusters: Set<ClusterID> = []) {
        self.readClusters = readClusters
        self.changeRequestClusters = changeRequestClusters
    }
}

/// Per-cluster permissions, read live on every call so a change in Settings (or a cluster that became Production meanwhile)
/// applies at once. The Mac app implements this over `MacClusterSettingsStore`.
public protocol ToolboxClusterSettings: Sendable {
    /// The user's explicit First Mate setting for the cluster, or nil to use the default for its environment.
    func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess?
    func beaconScope(client: String) -> BeaconScope
}

/// Settings with no explicit choices: environment defaults for First Mate, an empty scope for Beacon clients.
public struct DefaultToolboxSettings: ToolboxClusterSettings {
    public init() {}
    public func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess? { nil }
    public func beaconScope(client: String) -> BeaconScope { BeaconScope() }
}

/// The Production clusters the user has allowed First Mate to read in one conversation. Held per conversation; the Allow
/// prompt calls ``grant(_:)``. Never persisted: a new conversation asks again (owner decision 14).
public final class ConversationGrants: Sendable {
    /// The conversation these grants belong to. A policy for another conversation ignores them.
    public let conversation: String
    private let granted = Mutex<Set<ClusterID>>([])
    public init(conversation: String) { self.conversation = conversation }
    public func grant(_ cluster: ClusterID) { granted.withLock { _ = $0.insert(cluster) } }
    public func revoke(_ cluster: ClusterID) { granted.withLock { _ = $0.remove(cluster) } }
    public func isGranted(_ cluster: ClusterID) -> Bool { granted.withLock { $0.contains(cluster) } }
}

/// What the caller sees of one cluster.
public enum ClusterVisibility: Sendable, Equatable {
    /// Every tool works.
    case full
    /// Name and environment only, with `"access": "ask"`; contributes nothing to `search`; per-cluster tools answer
    /// `permission_required`.
    case askPending
    /// Absent from every result, total and "omitted" count.
    case hidden
}

/// Who may see and do what (ARCHITECTURE-MAC section 9.3). Enforced inside the toolbox, not by callers, and it applies to every
/// tool including the cross-cluster ones.
public struct ToolboxPolicy: Sendable {
    public let caller: ToolboxCaller
    public let settings: any ToolboxClusterSettings
    public let grants: ConversationGrants

    /// `grants` must belong to the caller's conversation; grants made for any other conversation are ignored (a shared instance
    /// cannot leak an Allow across conversations). Omit it to start with none.
    public init(caller: ToolboxCaller, settings: any ToolboxClusterSettings = DefaultToolboxSettings(), grants: ConversationGrants? = nil) {
        self.caller = caller
        self.settings = settings
        var id = ""
        if case .firstMate(let conversation) = caller { id = conversation }
        self.grants = grants ?? ConversationGrants(conversation: id)
    }

    private var grantsApply: Bool {
        if case .firstMate(let conversation) = caller { return grants.conversation == conversation }
        return false
    }

    /// Defaults by environment: Development, Personal and Staging are allowed, Production asks.
    public static func defaultAccess(for environment: ClusterEnvironment) -> ClusterAccess {
        switch environment {
        case .development, .personal, .staging: .allowed
        case .production: .ask
        }
    }

    /// The effective First Mate setting (explicit, else the environment default).
    public func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess {
        settings.firstMateAccess(for: cluster) ?? Self.defaultAccess(for: cluster.environment)
    }

    public func visibility(of cluster: ClusterConfig) -> ClusterVisibility {
        switch caller {
        case .firstMate:
            switch firstMateAccess(for: cluster) {
            case .allowed: return .full
            case .never: return .hidden
            case .ask: return grantsApply && grants.isGranted(cluster.id) ? .full : .askPending
            }
        case .beacon(let client):
            // Beacon has no Ask: a cluster is inside the approved scope or it does not exist for that client.
            return settings.beaconScope(client: client).readClusters.contains(cluster.id) ? .full : .hidden
        }
    }

    /// Clusters this caller may see at all (full or ask-pending), in the given order.
    public func visible(_ clusters: [ClusterConfig]) -> [ClusterConfig] {
        clusters.filter { visibility(of: $0) != .hidden }
    }

    /// Clusters whose contents this caller may read now.
    public func readable(_ clusters: [ClusterConfig]) -> [ClusterConfig] {
        clusters.filter { visibility(of: $0) == .full }
    }

    /// Whether change-request tools are offered for a cluster. A hard rule, not a default: never for Production or read-only
    /// clusters, and only inside a Beacon client's opted-in set. First Mate does not use change requests: it proposes, and the
    /// person reviews in the normal editor, so it answers false here.
    public func allowsChangeRequests(on cluster: ClusterConfig) -> Bool {
        guard case .beacon(let client) = caller else { return false }
        guard cluster.environment != .production, !cluster.readOnly else { return false }
        let scope = settings.beaconScope(client: client)
        return scope.readClusters.contains(cluster.id) && scope.changeRequestClusters.contains(cluster.id)
    }
}

/// Where the toolbox gets clusters and read access. The Mac app uses ``RegistryToolboxSource``; tests supply fakes.
public protocol ToolboxClusterSource: Sendable {
    func clusters() async -> [ClusterConfig]
    func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess?
    /// `"reachable"`, `"unreachable"` or `"unknown"`, for `list_clusters`.
    func reachability(of cluster: ClusterID) async -> String
}

public extension ToolboxClusterSource {
    func reachability(of cluster: ClusterID) async -> String { "unknown" }
}

/// ``ToolboxClusterSource`` over the app's ``ClusterRegistry`` (Demo mode included).
public struct RegistryToolboxSource: ToolboxClusterSource {
    private let registry: ClusterRegistry
    public init(registry: ClusterRegistry) { self.registry = registry }

    public func clusters() async -> [ClusterConfig] { await MainActor.run { registry.clusters } }

    public func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? {
        await MainActor.run { registry.session(for: cluster).map { ReadOnlyKubeAccess($0.client) } }
    }

    public func reachability(of cluster: ClusterID) async -> String {
        await MainActor.run {
            guard let session = registry.session(for: cluster) else { return "unknown" }
            switch session.connection {
            case .connected: return "reachable"
            case .failed: return "unreachable"
            case .unknown, .connecting: return "unknown"
            }
        }
    }
}
