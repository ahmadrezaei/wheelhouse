#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

public enum CompositeStoreError: Error, Equatable, Sendable, LocalizedError {
    /// A discovered cluster has no Keychain credentials: use Adopt instead.
    case notAdopted
    public var errorDescription: String? { "This cluster is read from a kubeconfig file. Adopt it into Wheelhouse to store its credentials." }
}

/// `ClusterMetadataStoring` for the Mac (ARCHITECTURE-MAC §4.4): the Keychain-backed store (iCloud mirror) UNION the clusters of the
/// current Moorings scan.
///
/// - `save` splits by `origin`: nil goes to the Keychain store, the rest to the overlay store `DiscoveredClusterStore`.
/// - Discovered clusters never reach the iCloud mirror. The sync blocks are enforced HERE, not only in the UI: an exec-adopted
///   cluster and a cluster whose server is on this Mac are saved with `iCloudSync = false`.
/// - Allowing changes on a discovered cluster needs an explicitly chosen environment.
public final class CompositeMetadataStore: ClusterMetadataStoring {
    private let keychain: any ClusterMetadataStoring
    private let credentials: any CredentialStoring
    private let state: MooringsState
    private let settings: MacClusterSettingsStore
    private let gate: DevSafetyPolicy
    /// The discovered clusters the registry was last given by `load()`: only those can be "removed by the user" in `save`.
    /// (A context found after that load is not in the registry's list yet; it must not be mistaken for a removal.)
    private let lastLoaded = Mutex<Set<ClusterID>>([])
    /// Server of every Keychain cluster seen by `load`/`save`, for the credential store's sync block.
    public let servers = ServerIndex()

    public init(keychain: any ClusterMetadataStoring, credentials: any CredentialStoring, state: MooringsState, settings: MacClusterSettingsStore,
                gate: DevSafetyPolicy = .current) {
        self.gate = gate
        self.keychain = keychain
        self.credentials = credentials
        self.state = state
        self.settings = settings
    }

    public func load() -> [ClusterConfig] {
        let keychainClusters = keychain.load()
        resolveDuplicates(against: keychainClusters)
        let discovered = state.listedConfigs()
        lastLoaded.withLock { $0 = Set(discovered.map(\.id)) }
        let sanitized = keychainClusters.map(sanitizedForSync)
        sanitized.forEach { servers.set($0.server, for: $0.id) }
        return sanitized + discovered
    }

    /// Decision 11: a context with the same server and identity as a Keychain cluster is one row with two sources; the Keychain
    /// entry wins, so the context is dropped from the list and remembered as its secondary source.
    private func resolveDuplicates(against keychainClusters: [ClusterConfig]) {
        var found: [ClusterID: ClusterID] = [:]
        guard !keychainClusters.isEmpty else { state.setDuplicates([:]); return }
        for ctx in state.contexts {
            guard let server = ctx.server else { continue }
            let candidates = keychainClusters.filter { ServerURL.normalized($0.server) == ServerURL.normalized(server) }
            guard !candidates.isEmpty else { continue }
            let mine = DiscoveredSecrets.resolve(ctx.context, gate: gate)
            for k in candidates {
                let theirs = (try? credentials.load(clusterID: k.id)) ?? ClusterSecrets()
                if DuplicateMatcher.isDuplicate(discoveredServer: server, discoveredSecrets: mine, discoveredExecHash: ctx.execSpecHash,
                                                keychainServer: k.server, keychainSecrets: theirs,
                                                keychainExecHash: settings.execAdoption(for: k.id)?.specHash) {
                    found[ctx.id] = k.id
                    break
                }
            }
        }
        state.setDuplicates(found)
    }

    public func save(_ clusters: [ClusterConfig]) throws {
        let keychainClusters = clusters.filter { $0.origin == nil }.map(sanitizedForSync)
        let discovered = clusters.filter { $0.origin != nil }
        keychainClusters.forEach { servers.set($0.server, for: $0.id) }
        try keychain.save(keychainClusters)
        try saveOverlay(discovered)
    }

    /// Forces `iCloudSync = false` for an exec-adopted cluster (iOS cannot run plugins) and for a loopback server.
    func sanitizedForSync(_ config: ClusterConfig) -> ClusterConfig {
        var c = config
        if c.iCloudSync, settings.execAdoption(for: c.id) != nil || ServerURL.isLoopback(c.server) { c.iCloudSync = false }
        return c
    }

    private func saveOverlay(_ configs: [ClusterConfig]) throws {
        let present = Set(configs.map(\.id))
        var changes: [ClusterID: DiscoveredOverride?] = [:]
        // A previously listed cluster that is not in the list any more was removed by the user: hidden (overrides kept 30 days).
        let known = lastLoaded.withLock { $0 }
        for id in state.listedConfigs().map(\.id) where known.contains(id) && !present.contains(id) {
            var o = state.overrides.override(for: id) ?? DiscoveredOverride()
            o.hidden = true
            changes[id] = o
        }
        for config in configs {
            guard var o = state.overrides.override(for: config.id) else { continue }
            let computed = state.context(for: config.id).flatMap { ctx -> ClusterConfig? in
                var probe = o; probe.environment = nil
                return state.makeConfig(for: ctx, override: probe)
            }
            let defaultName = state.context(for: config.id)?.displayName ?? o.lastKnown?.displayName
            o.name = config.name == defaultName ? nil : config.name
            if let computed, config.environment != (o.environment ?? computed.environment) {
                o.environment = config.environment
                o.environmentChosen = true
            }
            // Saving never leaves read-only: only `MooringsService.allowChanges` does (explicit environment, Touch ID for Production).
            // It can still turn read-only ON. M1b's Cluster Settings toggle must call `allowChanges` to turn it off.
            o.readOnly = o.readOnly || config.readOnly || !o.environmentChosen
            o.allowExecInReadOnly = config.allowExecInReadOnly
            o.color = config.color
            o.pinnedNamespaces = config.pinnedNamespaces
            o.defaultNamespace = config.defaultNamespace
            changes[config.id] = o
        }
        if !changes.isEmpty { try state.overrides.apply(changes) }
    }
}

/// `CredentialStoring` for the Mac: a Keychain cluster reads the Keychain; a discovered cluster resolves from its file each time.
public final class CompositeCredentialStore: CredentialStoring {
    private let keychain: any CredentialStoring
    private let state: MooringsState
    private let gate: DevSafetyPolicy
    private let settings: MacClusterSettingsStore?
    private let serverLookup: @Sendable (ClusterID) -> URL?

    /// `settings` and `serverLookup` enforce the sync blocks for Keychain secrets: an exec-adopted cluster and a loopback server are
    /// always stored with `synchronizable = false`, whatever the caller asks for.
    public init(keychain: any CredentialStoring, state: MooringsState, gate: DevSafetyPolicy = .current,
                settings: MacClusterSettingsStore? = nil, serverLookup: @escaping @Sendable (ClusterID) -> URL? = { _ in nil }) {
        self.keychain = keychain
        self.state = state
        self.gate = gate
        self.settings = settings
        self.serverLookup = serverLookup
    }

    static func isDiscovered(_ id: ClusterID) -> Bool { id.hasPrefix("kc-") }

    public func load(clusterID: ClusterID) throws -> ClusterSecrets {
        guard Self.isDiscovered(clusterID) else { return try keychain.load(clusterID: clusterID) }
        // A context that vanished from its file has nothing left to read: Source removed.
        guard let ctx = state.context(for: clusterID) else { return ClusterSecrets() }
        return DiscoveredSecrets.resolve(ctx.context, gate: gate)
    }

    public func save(_ secrets: ClusterSecrets, clusterID: ClusterID, synchronizable: Bool) throws {
        guard !Self.isDiscovered(clusterID) else { throw CompositeStoreError.notAdopted }
        var sync = synchronizable
        if sync {
            if settings?.execAdoption(for: clusterID) != nil { sync = false }
            if let server = serverLookup(clusterID), ServerURL.isLoopback(server) { sync = false }
        }
        try keychain.save(secrets, clusterID: clusterID, synchronizable: sync)
    }

    public func delete(clusterID: ClusterID) throws {
        // Removing a discovered cluster hides it (see CompositeMetadataStore.save); there is nothing in the Keychain.
        guard !Self.isDiscovered(clusterID) else { return }
        try keychain.delete(clusterID: clusterID)
    }
}
#endif

/// A thread-safe `ClusterID` to server map.
public final class ServerIndex: Sendable {
    private let state = Mutex<[ClusterID: URL]>([:])
    public init() {}
    public func set(_ url: URL, for id: ClusterID) { state.withLock { $0[id] = url } }
    public func server(for id: ClusterID) -> URL? { state.withLock { $0[id] } }
}
