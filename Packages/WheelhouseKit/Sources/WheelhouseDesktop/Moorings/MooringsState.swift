#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// The current Moorings scan, readable synchronously (the composite stores and the client factory need answers without awaiting).
/// Written only by ``MooringsService``.
public final class MooringsState: Sendable {
    struct Snapshot {
        var contexts: [ClusterID: DiscoveredContext] = [:]
        var order: [ClusterID] = []
        /// Discovered cluster -> the Keychain cluster it duplicates.
        var duplicates: [ClusterID: ClusterID] = [:]
        var checks: [ClusterID: ClusterCheckState] = [:]
        /// Clusters whose contact the user approved by clicking Check (also for undecided rows that have no override yet).
        var approved: Set<ClusterID> = []
    }
    private let state = Mutex(Snapshot())
    public let overrides: DiscoveredClusterStore
    public let preferences: MooringsPreferencesStore
    private let gate: DevSafetyPolicy

    public init(overrides: DiscoveredClusterStore, preferences: MooringsPreferencesStore, gate: DevSafetyPolicy = .current) {
        self.overrides = overrides
        self.preferences = preferences
        self.gate = gate
    }

    // MARK: Snapshot

    public var contexts: [DiscoveredContext] { state.withLock { s in s.order.compactMap { s.contexts[$0] } } }
    public func context(for id: ClusterID) -> DiscoveredContext? { state.withLock { $0.contexts[id] } }
    public func duplicateOf(_ id: ClusterID) -> ClusterID? { state.withLock { $0.duplicates[id] } }
    public func checkState(for id: ClusterID) -> ClusterCheckState { state.withLock { $0.checks[id] ?? .notChecked } }

    func replace(contexts list: [DiscoveredContext]) {
        state.withLock { s in
            s.contexts = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            s.order = list.map(\.id)
        }
    }
    func approveContact(_ id: ClusterID) { state.withLock { _ = $0.approved.insert(id) } }
    func setDuplicates(_ d: [ClusterID: ClusterID]) { state.withLock { $0.duplicates = d } }
    func setCheck(_ c: ClusterCheckState, for id: ClusterID) { state.withLock { $0.checks[id] = c } }

    // MARK: Derived

    /// True for an added cluster whose environment is suggested as Production until the user clicked Check or opened it
    /// (owner decision 10). The client factory then refuses to connect.
    public func isContactHeld(_ id: ClusterID) -> Bool {
        guard id.hasPrefix("kc-") else { return false }
        let o = overrides.override(for: id)
        // Only an explicit Check, Allow Changes or opening the cluster releases the hold. Choosing or changing the environment never does,
        // and a cluster with no override yet is held too (fail closed).
        if o?.contactApproved == true || state.withLock({ $0.approved.contains(id) }) { return false }
        let suggestedProduction = context(for: id)?.isSuggestedProduction ?? (o?.lastKnown?.suggestedEnvironment == .production)
        return suggestedProduction || o?.environment == .production
    }

    /// The Mac-only details of a cluster, or nil when it is not discovered.
    public func info(for id: ClusterID) -> DesktopClusterInfo? {
        let o = overrides.override(for: id)
        if let ctx = context(for: id) {
            return DesktopClusterInfo(authSummary: ctx.authSummary, execSpecHash: ctx.execSpecHash, lastFingerprint: ctx.fingerprint,
                                      environmentSuggested: ctx.suggestion, isNew: o?.isNew ?? false, hidden: o?.hidden ?? false,
                                      checkState: checkState(for: id), sourceRemovedAt: o?.sourceRemovedAt, definingFile: ctx.key.definingFile,
                                      contextName: ctx.key.contextName, isCurrentContext: ctx.isCurrent,
                                      blockedInDevelopment: ctx.blockedInDevelopment, duplicateOf: duplicateOf(id))
        }
        guard let o, let last = o.lastKnown else { return nil }
        return DesktopClusterInfo(authSummary: .none, execSpecHash: nil, lastFingerprint: "", environmentSuggested: nil, isNew: false,
                                  hidden: o.hidden, checkState: checkState(for: id), sourceRemovedAt: o.sourceRemovedAt ?? Date(),
                                  definingFile: last.definingFile, contextName: last.contextName, isCurrentContext: false,
                                  blockedInDevelopment: false, duplicateOf: nil)
    }

    // MARK: Config building

    /// The `ClusterConfig` of a discovered cluster: read-only unless the user allowed changes after choosing an environment.
    /// The environment is the user's choice, else the suggestion (so a Production-suggested context is guarded as Production),
    /// else Development.
    func makeConfig(for ctx: DiscoveredContext, override o: DiscoveredOverride) -> ClusterConfig? {
        guard let server = ctx.context.server else { return nil }
        let environment = o.environment ?? ctx.suggestion?.environment ?? .development
        var config = ClusterConfig(
            id: ctx.id, name: o.name ?? ctx.displayName, server: server, authKind: DiscoveredSecrets.authKind(of: ctx.context),
            environment: environment, readOnly: o.readOnly || !o.environmentChosen, allowExecInReadOnly: o.allowExecInReadOnly, iCloudSync: false,
            skipTLSVerify: ctx.context.insecureSkipTLSVerify && environment != .production,
            defaultNamespace: o.defaultNamespace ?? ctx.context.namespace, pinnedNamespaces: o.pinnedNamespaces, color: o.color ?? .teal,
            createdAt: o.addedAt, modifiedAt: o.addedAt, tlsServerName: ctx.context.tlsServerName)
        config.origin = .kubeconfig(path: ctx.key.definingFile, context: ctx.key.contextName, sourceID: ctx.sourceIDs.first ?? "")
        return config
    }

    /// The config of an added cluster whose context disappeared from its file (Source removed).
    func makeRemovedConfig(id: ClusterID, override o: DiscoveredOverride) -> ClusterConfig? {
        guard let last = o.lastKnown, let server = URL(string: last.server) else { return nil }
        let environment = o.environment ?? last.suggestedEnvironment ?? .development
        var config = ClusterConfig(
            id: id, name: o.name ?? last.displayName, server: server, authKind: last.authKind, environment: environment,
            readOnly: true, allowExecInReadOnly: false, iCloudSync: false,
            skipTLSVerify: last.insecureSkipTLSVerify && environment != .production, defaultNamespace: o.defaultNamespace ?? last.namespace,
            pinnedNamespaces: o.pinnedNamespaces, color: o.color ?? .gray, createdAt: o.addedAt, modifiedAt: o.addedAt, tlsServerName: last.tlsServerName)
        config.origin = .kubeconfig(path: last.definingFile, context: last.contextName, sourceID: "")
        return config
    }

    /// Every discovered cluster that should be listed: added, not hidden, and not a duplicate of a Keychain cluster.
    func listedConfigs() -> [ClusterConfig] {
        let snapshot = state.withLock { $0 }
        var out: [ClusterConfig] = []
        var seen = Set<ClusterID>()
        for id in snapshot.order {
            guard let ctx = snapshot.contexts[id], let o = overrides.override(for: id), o.added, !o.hidden,
                  snapshot.duplicates[id] == nil, ctx.isUsable, o.sourceRemovedAt == nil else { continue }
            if let config = makeConfig(for: ctx, override: o) { out.append(config); seen.insert(id) }
        }
        // Added clusters whose context disappeared.
        for (id, o) in overrides.all.sorted(by: { $0.key < $1.key }) where o.added && !o.hidden && !seen.contains(id) && snapshot.contexts[id] == nil {
            if let config = makeRemovedConfig(id: id, override: o) { out.append(config) }
        }
        return out
    }
}
#endif
