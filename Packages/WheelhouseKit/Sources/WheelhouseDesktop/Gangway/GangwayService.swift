#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// A cluster list readable from any thread, for Gangway's per-request policy check: the registry is main-actor bound, so a hop per request
/// would put the UI's load into the 2 ms budget. The app updates it from `ClusterEvents.invalidated` and at start.
public final class SnapshotClusterProvider: GangwayClusterProviding {
    public typealias UpstreamResolver = @Sendable (ClusterConfig) async throws -> GangwayUpstream
    /// Digest of a cluster's credentials (never the credentials); nil when they cannot be read right now (a locked Keychain, a missing file).
    public typealias DigestReader = @Sendable (ClusterConfig) -> String?
    private let configs = Mutex<[ClusterID: ClusterConfig]>([:])
    private let digests = Mutex<[ClusterID: String]>([:])
    private let resolver: UpstreamResolver
    private let reader: DigestReader?

    public init(upstream: @escaping UpstreamResolver, digest: DigestReader? = nil) {
        self.resolver = upstream
        self.reader = digest
    }

    public func update(_ clusters: [ClusterConfig]) {
        let ids = Set(clusters.map(\.id))
        configs.withLock { $0 = Dictionary(clusters.map { ($0.id, $0) }, uniquingKeysWith: { _, new in new }) }
        digests.withLock { $0 = $0.filter { ids.contains($0.key) } }
    }
    public func credentialDigest(for id: ClusterID) -> String? { digests.withLock { $0[id] } }

    /// Reads the credential digest of one cluster (off the main actor: the caller is a nonisolated async function) and stores it. A read
    /// that fails keeps the last digest. Returns true when a digest that was known before is now different.
    @discardableResult
    func refreshDigest(for id: ClusterID) -> Bool {
        guard let reader, let config = config(for: id), let new = reader(config) else { return false }
        return digests.withLock { stored in
            defer { stored[id] = new }
            guard let old = stored[id] else { return false }
            return old != new
        }
    }
    public func prepareCredentialDigest(for id: ClusterID) async { refreshDigest(for: id) }

    /// The clusters among `ids` whose credentials changed since the last read. Reads only these (a cluster without a live session is never read).
    public func refreshDigests(for ids: Set<ClusterID>) async -> [ClusterID] { ids.filter { refreshDigest(for: $0) } }

    /// Every cluster id in the snapshot.
    public var knownIDs: Set<ClusterID> { configs.withLock { Set($0.keys) } }
    public func set(_ cluster: ClusterConfig) { configs.withLock { $0[cluster.id] = cluster } }
    public func remove(_ id: ClusterID) { configs.withLock { $0[id] = nil } }

    public func config(for id: ClusterID) -> ClusterConfig? { configs.withLock { $0[id] } }
    public func upstream(for id: ClusterID) async throws -> GangwayUpstream {
        guard let config = config(for: id) else { throw UpstreamError.notReachable("the cluster is no longer available") }
        return try await resolver(config)
    }
}

/// An open guarded session: the kubeconfig a tool uses, and what is needed to end it.
public struct GangwaySessionHandle: Sendable {
    public var session: GangwaySession
    public var kubeconfig: URL
    public var directory: URL
    public var kubeconfigHash: String
}

/// Gangway as the app uses it (ARCHITECTURE-MAC section 3.6): starts lazily when the first session is opened, hands out guarded
/// sessions, and reacts to lock, read-only, Production and revocation by closing streams. Nothing here polls.
public final class GangwayService: Sendable {
    public let context: GangwayContext
    public let paths: AppPaths
    private let server: GangwayServer
    private let writer: SessionKubeconfigWriter
    private let observesEvents: Bool
    private let loopback = Mutex<LoopbackIdentity?>(nil)
    private final class ObserverBox: @unchecked Sendable {
        let token: any NSObjectProtocol
        init(_ token: any NSObjectProtocol) { self.token = token }
    }
    private let observers = Mutex<[ObserverBox]>([])

    public init(paths: AppPaths, clusters: any GangwayClusterProviding, confirmer: any GangwayConfirming = DecliningConfirmer(),
                activity: any ActivityLogging = NoopActivityLog(), gate: @escaping @Sendable () -> DevSafetyPolicy = { .current },
                resolver: any PeerResolving = PeerResolver(), fixedPort: UInt16? = nil, batchingWindow: Duration = .seconds(2),
                holdTimeout: Duration = .seconds(120), idleTimeout: Duration = .seconds(120), now: @escaping @Sendable () -> Date = { Date() },
                observesClusterEvents: Bool = true) {
        self.observesEvents = observesClusterEvents
        self.paths = paths
        let registry = SessionRegistry(gate: gate)
        let context = GangwayContext(registry: registry, grants: GrantStore(now: now), clusters: clusters, connector: UpstreamConnector(gate: gate),
                                     confirmer: confirmer, activity: activity, resolver: resolver, batchingWindow: batchingWindow,
                                     holdTimeout: holdTimeout, idleTimeout: idleTimeout)
        self.context = context
        self.server = GangwayServer(context: context, portFile: paths.root.appending(path: "gangway.json"), fixedPort: fixedPort)
        self.writer = SessionKubeconfigWriter(paths: paths)
    }

    public var isRunning: Bool { server.isRunning }
    public var port: UInt16? { server.isRunning ? context.listenerPort : nil }
    public var registry: SessionRegistry { context.registry }
    public var grants: GrantStore { context.grants }
    public var metrics: GangwayMetrics { context.metrics }

    /// Starts the listener (idempotent) and watches cluster events.
    @discardableResult
    public func start() async throws -> UInt16 {
        let wasRunning = server.isRunning
        let identity = try loopback.withLock { current -> LoopbackIdentity in
            if let current { return current }
            let made = try LoopbackIdentity.make()
            current = made
            return made
        }
        context.tlsCertificateDER = identity.certificateDER
        let port = try await server.start(identity: identity)
        if !wasRunning { sweepStaleSessions() }
        if observesEvents, observers.withLock({ $0.isEmpty }) { observeClusterEvents() }
        return port
    }

    public func stop() {
        context.registry.revokeAll(reason: "Wheelhouse is quitting")
        server.stop()
        observers.withLock { list in
            list.forEach { NotificationCenter.default.removeObserver($0.token) }
            list.removeAll()
        }
    }

    // MARK: Sessions

    /// Opens a guarded session for `clusterID`: starts the listener if needed, registers the token, writes the 0400 kubeconfig.
    /// Fails closed while the safety gate is active and the cluster's host is not an allowed test host.
    public func openSession(clusterID: ClusterID, origin: GangwayOrigin, scope: GangwayScope = .standard, binding: PeerBinding = .none,
                            namespace: String? = nil) async throws -> GangwaySessionHandle {
        guard let cluster = context.clusters.config(for: clusterID) else { throw GangwaySessionError.invalidCluster }
        await context.clusters.prepareCredentialDigest(for: clusterID)       // the digest a session is fingerprinted with is read before it opens
        let port = try await start()
        guard let identity = loopback.withLock({ $0 }) else { throw GangwaySessionError.invalidCluster }
        let (session, token) = try context.registry.create(cluster: cluster, origin: origin, scope: scope, binding: binding)
        do {
            let written = try writer.write(sessionID: session.id, port: port, clusterID: cluster.id, clusterName: cluster.name, token: token, namespace: namespace, certificateDER: identity.certificateDER)
            session.kubeconfigHash = written.hash
            session.clusterFingerprint = Self.fingerprint(cluster, digest: context.clusters.credentialDigest(for: cluster.id))
            context.registry.attach(directory: written.directory, to: session)
            return GangwaySessionHandle(session: session, kubeconfig: written.file, directory: written.directory, kubeconfigHash: written.hash)
        } catch {
            context.registry.revoke(session, reason: "the session kubeconfig could not be written")
            throw error
        }
    }

    public func closeSession(_ handle: GangwaySessionHandle, reason: String = "session closed") {
        context.grants.revoke(session: handle.session)
        context.registry.revoke(handle.session, reason: reason)
    }

    /// Revokes a session whose kubeconfig was changed, replaced or made writable (checked by the terminal before every hold decision).
    @discardableResult
    public func verifyIntegrity(_ handle: GangwaySessionHandle) -> SessionKubeconfigWriter.Integrity {
        let result = SessionKubeconfigWriter.verify(file: handle.kubeconfig, hash: handle.kubeconfigHash)
        if result != .intact { closeSession(handle, reason: "the session kubeconfig was changed") }
        return result
    }

    // MARK: Lock, cluster changes

    /// The app locked: open streams close, and new streams, proxies and changes are refused until `unlock()`. Reads continue.
    public func lock() {
        context.setLocked(true)
        context.closeStreams(reason: "the app locked") { _ in true }
        context.grants.revokeAll()
    }
    public func unlock() { context.setLocked(false) }

    /// The app lock timeout passed: every session ends (its token fails with `401 Wheelhouse: session ended`).
    public func revokeAllSessions() {
        context.grants.revokeAll()
        context.registry.revokeAll(reason: "the app locked")
    }

    /// The parts of a cluster a session depends on to reach it: where it is, how it authenticates, how TLS is checked, and a digest of its
    /// credentials. Read-only, Production and exec permission are not in it (they change streams and grants, not who the session is).
    public static func fingerprint(_ config: ClusterConfig, digest: String?) -> String {
        [config.server.absoluteString, config.authKind.rawValue, config.tlsServerName ?? "", config.skipTLSVerify ? "skip" : "verify", digest ?? ""].joined(separator: "\u{1F}")
    }

    /// A cluster's configuration changed. Streams that are no longer allowed close; grants end when the cluster became read-only or
    /// Production; sessions of a removed cluster are revoked.
    public func clusterChanged(_ id: ClusterID, removed: Bool = false) {
        guard !removed, let config = context.clusters.config(for: id) else {
            context.closeStreams(reason: "the cluster was removed") { $0.clusterID == id }
            context.registry.revokeSessions(forCluster: id, reason: "the cluster was removed or its credentials changed")
            return
        }
        // The server, the authentication or the credentials changed: the sessions end, and with them their upstream connections.
        let now = Self.fingerprint(config, digest: context.clusters.credentialDigest(for: id))
        for session in context.registry.sessions where session.clusterID == id {
            if let was = session.clusterFingerprint, was != now {
                context.grants.revoke(session: session)
                context.registry.revoke(session, reason: "the cluster's server, authentication or credentials changed")
            }
        }
        let production = config.environment.requiresTypeToConfirm
        context.closeStreams(reason: config.readOnly ? "the cluster became read-only" : "the cluster became Production") { record in
            guard record.clusterID == id else { return false }
            if config.readOnly, !(config.allowExecInReadOnly && record.kind != .otherUpgrade) { return true }
            return production && !record.openedOnProduction
        }
        if config.readOnly || production {
            for session in context.registry.sessions where session.clusterID == id && session.scope == .standard {
                // A grant given while the cluster was a normal one ends; the Production confirmation applies again.
                context.grants.revoke(session: session)
            }
        }
    }

    /// Session folders left by a run that did not quit cleanly: their tokens died with that process, so the files are dead weight.
    private func sweepStaleSessions() {
        let live = Set(context.registry.sessions.map { $0.id.uuidString.lowercased() })
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.sessions.path)) ?? []
        for name in names where !live.contains(name) && UUID(uuidString: name) != nil {
            SessionKubeconfigWriter.remove(directory: paths.sessions.appending(path: name, directoryHint: .isDirectory))
        }
    }

    private func observeClusterEvents() {
        let token = NotificationCenter.default.addObserver(forName: ClusterEvents.invalidated, object: nil, queue: nil) { [weak self] note in
            guard let self, let id = ClusterEvents.clusterID(from: note) else { return }
            self.clusterChanged(id, removed: ClusterEvents.wasRemoved(note))
        }
        observers.withLock { $0.append(ObserverBox(token)) }
    }
}
#endif
