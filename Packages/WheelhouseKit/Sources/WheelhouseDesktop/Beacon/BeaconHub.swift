#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// How a connecting helper relates to the approvals on file.
public enum BeaconSecretState: Sendable, Equatable {
    /// No secret in the hello.
    case none
    /// A secret nobody owns.
    case unknown
    /// A known secret that was never claimed: this is its first use.
    case unbound
    /// A known secret presented from a different program or under a different name than the one it was approved for.
    case mismatch(approvedFor: String)
}

public struct BeaconApprovalRequest: Sendable {
    public var clientName: String
    public var launcher: BeaconLauncher
    public var secretState: BeaconSecretState
    /// Candidates for read access. Change requests are never offered here: enabling them needs Touch ID in Settings.
    public var clusters: [ClusterConfig]
    public init(clientName: String, launcher: BeaconLauncher, secretState: BeaconSecretState, clusters: [ClusterConfig]) {
        self.clientName = clientName
        self.launcher = launcher
        self.secretState = secretState
        self.clusters = clusters
    }
}

public enum BeaconApprovalDecision: Sendable, Equatable {
    case deny
    /// The sheet was withdrawn (the app locked, Beacon stopped): not the person's answer, so no cooldown.
    case withdrawn
    /// `remember` binds a known secret to this client; otherwise the approval lasts for this connection only.
    case allow(readClusters: Set<ClusterID>, remember: Bool)
}

/// Shows the approval sheet (DESIGN-MAC section 6.13). Returns when the person decides, or `.deny` when cancelled.
public protocol BeaconApproving: Sendable {
    func approve(_ request: BeaconApprovalRequest) async -> BeaconApprovalDecision
}

/// Touch ID or the account password. Called on EVERY turn-on and before change requests are enabled for a cluster.
public protocol BeaconAuthenticating: Sendable {
    func authenticate(reason: String) async throws
}

public struct BeaconAuthenticationFailed: Error, Equatable, LocalizedError {
    public var errorDescription: String? { "Authentication was cancelled or failed, so Beacon stays off." }
    public init() {}
}

/// Runs the Beacon service: the socket, client approval, sessions and the gate every call passes (ARCHITECTURE-MAC section 10).
///
/// Beacon is off at every launch (`-WHBeaconLaunch` only starts the app) and every turn-on authenticates. Turning it off, a
/// revoke, or the app lock closes what they must at once.
public final class BeaconHub: Sendable {
    public static let denyCooldown: TimeInterval = 60
    public static let maxPendingApprovals = 8
    public static let sheetThrottle: TimeInterval = 10

    private final class Entry: Sendable {
        struct State {
            var status: BeaconGateStatus = .awaitingApproval
            var client = BeaconClientRef(id: "pending", label: "Unnamed client")
            var deferredName: String?
        }
        let id = UUID()
        let peer: BeaconPeer
        let secret: BeaconClientRecord?
        let hello: BeaconHello
        let connection: BeaconConnection
        let state = Mutex(State())
        let sessionBox = Mutex<MCPSession?>(nil)
        let approvalTask = Mutex<Task<Void, Never>?>(nil)
        let limiterKey: String
        init(peer: BeaconPeer, secret: BeaconClientRecord?, hello: BeaconHello, connection: BeaconConnection) {
            self.peer = peer
            self.secret = secret
            self.hello = hello
            self.connection = connection
            self.limiterKey = secret?.id ?? "session-\(id.uuidString)"
        }
    }

    private struct HubState {
        var on = false
        var entries: [UUID: Entry] = [:]
        var denied: [String: Date] = [:]
        var pendingApprovals = 0
        var rejectionsLogged: Date?
        var generation = 0
        /// When a sheet last ended unanswered or denied: a new sheet right after it is refused (launcher keys are easy to vary).
        var lastUnansweredSheet: Date?
    }

    private let store: BeaconClientStore
    private let source: any ToolboxClusterSource
    private let socketURL: URL
    private let approver: any BeaconApproving
    private let authenticator: any BeaconAuthenticating
    private let changes: (any BeaconChangeHandling)?
    private let activity: any ActivityLogging
    private let isLocked: @Sendable () -> Bool
    private let clock: @Sendable () -> Date
    private let pending = BeaconPendingRequests()
    private let limiters = Mutex<[String: BeaconLimiter]>([:])
    private let state = Mutex(HubState())
    private let gate = ApprovalGate()
    private let limiterFactory: @Sendable () -> BeaconLimiter
    private let socketBox = Mutex<BeaconSocketServer?>(nil)
    private let verifier: any BeaconPeerVerifying
    private let helloTimeout: TimeInterval

    public init(store: BeaconClientStore, source: any ToolboxClusterSource, socketURL: URL, verifier: any BeaconPeerVerifying,
                approver: any BeaconApproving, authenticator: any BeaconAuthenticating, changes: (any BeaconChangeHandling)? = nil,
                activity: any ActivityLogging = NoopActivityLog(), isLocked: @escaping @Sendable () -> Bool = { false },
                clock: @escaping @Sendable () -> Date = { Date() }, helloTimeout: TimeInterval = 5,
                limiterFactory: @escaping @Sendable () -> BeaconLimiter = { BeaconLimiter() }) {
        self.store = store
        self.source = source
        self.socketURL = socketURL
        self.verifier = verifier
        self.approver = approver
        self.authenticator = authenticator
        self.changes = changes
        self.activity = activity
        self.isLocked = isLocked
        self.clock = clock
        self.helloTimeout = helloTimeout
        self.limiterFactory = limiterFactory
        store.onChange { [weak self] in self?.scopeChanged() }
    }

    public var isOn: Bool { state.withLock { $0.on } }
    public var sessionCount: Int { state.withLock { $0.entries.count } }
    public var socketPath: String { socketURL.path }

    // MARK: On and off

    /// Authenticates (every time), then starts listening.
    public func turnOn() async throws {
        do { try await authenticator.authenticate(reason: "Turn on Beacon, which lets AI tools read your clusters through Wheelhouse") } catch {
            activity.record(ActivityEntry(origin: .ui, verb: "beacon.on", result: "refused: authentication"))
            throw BeaconAuthenticationFailed()
        }
        guard !isOn else { return }
        let server = BeaconSocketServer(verifier: verifier, helloTimeout: helloTimeout, rejected: { [weak self] in self?.logRejection($0) },
                                        closed: { [weak self] in self?.connectionClosed($0) },
                                        connect: { [weak self] peer, hello, connection in self?.accept(peer: peer, hello: hello, connection: connection) })
        try server.start(at: socketURL)
        socketBox.withLock { $0 = server }
        state.withLock { $0.on = true }
        activity.record(ActivityEntry(origin: .ui, verb: "beacon.on", result: "ok"))
    }

    /// Stop Beacon: closes the socket and every connection, and withdraws approvals and change requests that wait.
    public func turnOff() {
        let (entries, wasOn) = state.withLock { s -> ([Entry], Bool) in
            defer { s.on = false; s.entries = [:]; s.generation += 1; s.pendingApprovals = 0 }
            return (Array(s.entries.values), s.on)
        }
        entries.forEach { end($0) }
        socketBox.withLock { server -> Void in
            server?.stop()
            server = nil
        }
        if wasOn { activity.record(ActivityEntry(origin: .ui, verb: "beacon.off", result: "ok")) }
    }

    /// Disconnects the live sessions of a client and removes it.
    public func revoke(clientID: String) throws {
        try store.revoke(id: clientID)
        let doomed = state.withLock { s -> [Entry] in
            let hit = s.entries.values.filter { $0.state.withLock { $0.client.id } == clientID }
            hit.forEach { s.entries[$0.id] = nil }
            return hit
        }
        doomed.forEach { end($0) }
    }

    /// Enabling change requests for a cluster needs Touch ID or the password too.
    public func setScope(clientID: String, read: Set<ClusterID>, changeRequests: Set<ClusterID>) async throws {
        let before = store.record(id: clientID)?.changeRequestClusters ?? []
        if !changeRequests.subtracting(before).isEmpty {
            do { try await authenticator.authenticate(reason: "Allow change requests from an AI tool") } catch { throw BeaconAuthenticationFailed() }
        }
        try store.setScope(id: clientID, read: read, changeRequests: changeRequests)
    }

    /// The app locked or unlocked. Locking needs nothing more (every call reads the gate); unlocking starts approvals that waited.
    public func lockChanged() {
        guard !isLocked() else { return }
        let waiting = state.withLock { s in s.entries.values.filter { $0.state.withLock { $0.deferredName } != nil } }
        for entry in waiting {
            guard let name = entry.state.withLock({ s -> String? in defer { s.deferredName = nil }; return s.deferredName }) else { continue }
            beginApproval(entry, name: name)
        }
    }

    private func end(_ entry: Entry) {
        entry.approvalTask.withLock { $0 }?.cancel()
        entry.state.withLock { $0.status = .stopped }
        entry.sessionBox.withLock { $0 }?.close()
        entry.connection.close()
        let id = entry.state.withLock { $0.client.id }
        if id.hasPrefix("session-") { store.dropSession(id) }
    }

    private func connectionClosed(_ connection: BeaconConnection) {
        let gone = state.withLock { s -> Entry? in
            guard let entry = s.entries.values.first(where: { $0.connection.id == connection.id }) else { return nil }
            s.entries[entry.id] = nil
            return entry
        }
        if let gone {
            // A sheet for a connection that is gone is withdrawn, and counts as an unanswered one.
            if gone.approvalTask.withLock({ $0 }) != nil {
                gone.approvalTask.withLock { $0 }?.cancel()
                state.withLock { $0.lastUnansweredSheet = clock() }
            }
            let id = gone.state.withLock { $0.client.id }
            if id.hasPrefix("session-") { store.dropSession(id) }
            releaseLimiter(gone.limiterKey)
        }
    }

    private func logRejection(_ reason: BeaconRejection) {
        let now = clock()
        // A connect loop must not flood the log: at most one entry a minute.
        let log = state.withLock { s -> Bool in
            if let last = s.rejectionsLogged, now.timeIntervalSince(last) < 60 { return false }
            s.rejectionsLogged = now
            return true
        }
        if log { activity.record(ActivityEntry(origin: .ui, verb: "beacon.connect", result: "rejected: \(reason.rawValue)")) }
    }

    // MARK: Connections

    private func accept(peer: BeaconPeer, hello: BeaconHello, connection: BeaconConnection) -> MCPSession? {
        guard isOn else { return nil }
        let owner = hello.secret.flatMap { store.match(secret: $0) }
        let entry = Entry(peer: peer, secret: owner, hello: hello, connection: connection)
        let limiter = limiterFor(entry.limiterKey)
        let handler = BeaconToolHandler(
            client: { entry.state.withLock { $0.client } }, source: source, settings: store,
            gate: { [weak self] in
                guard let self, self.isOn else { return .stopped }
                let status = entry.state.withLock { $0.status }
                if status == .stopped { return .stopped }
                return self.isLocked() ? .locked : status
            },
            changes: changes, pending: pending, activity: activity,
            onInitialize: { [weak self] name, _ in self?.initialized(entry, name: name) })
        let session = MCPSession(handler: handler, limiter: limiter) { connection.send($0) }
        entry.sessionBox.withLock { $0 = session }
        state.withLock { $0.entries[entry.id] = entry }
        return session
    }

    /// A limiter lives as long as a session of its client does.
    private func releaseLimiter(_ key: String) {
        let inUse = state.withLock { s in s.entries.values.contains { $0.limiterKey == key } }
        if !inUse { limiters.withLock { _ = $0.removeValue(forKey: key) } }
    }

    private func limiterFor(_ key: String) -> BeaconLimiter {
        limiters.withLock { dictionary in
            if let existing = dictionary[key] { return existing }
            let made = limiterFactory()
            dictionary[key] = made
            return made
        }
    }

    private func initialized(_ entry: Entry, name: String?) {
        let label = BeaconClientRef.sanitize(name)
        entry.state.withLock { $0.client.label = label }
        // Bound and matching: the stored approval applies, silently.
        if let record = entry.secret, record.isBound, record.launcherKey == entry.peer.launcher.identityKey, record.boundName == label {
            entry.state.withLock {
                $0.client = BeaconClientRef(id: record.id, label: label)
                $0.status = .ok
            }
            store.touch(id: record.id)
            entry.sessionBox.withLock { $0 }?.notifyToolsListChanged()
            return
        }
        // A locked app queues no sheet: the approval waits for the unlock.
        if isLocked() {
            entry.state.withLock { $0.deferredName = label }
            return
        }
        beginApproval(entry, name: label)
    }

    private func beginApproval(_ entry: Entry, name: String) {
        let key = entry.peer.launcher.identityKey
        let now = clock()
        // After a Deny, the same program does not get a new sheet for a while.
        let verdict = state.withLock { s -> String? in
            if let at = s.denied[key], now.timeIntervalSince(at) < Self.denyCooldown { return "denied" }
            if let at = s.lastUnansweredSheet, now.timeIntervalSince(at) < Self.sheetThrottle { return "throttled" }
            if s.pendingApprovals >= Self.maxPendingApprovals { return "busy" }
            s.pendingApprovals += 1
            return nil
        }
        if verdict != nil {
            activity.record(ActivityEntry(origin: .ui, verb: "beacon.approval", object: name, result: "refused: \(verdict ?? "")"))
            end(entry)
            state.withLock { $0.entries[entry.id] = nil }
            return
        }
        let generation = state.withLock { $0.generation }
        let task = Task { [self] in
            await gate.enter()
            defer { Task { await gate.leave() } }
            let still = state.withLock { s -> Bool in
                s.pendingApprovals = max(0, s.pendingApprovals - 1)
                return s.on && s.generation == generation && s.entries[entry.id] != nil && !entry.connection.isClosed
            }
            guard still else { return }
            // A locked app queues no sheet: this approval waits for the unlock too.
            if isLocked() { entry.state.withLock { $0.deferredName = name }; return }
            let secretState: BeaconSecretState
            switch (entry.hello.secret, entry.secret) {
            case (nil, _): secretState = .none
            case (_, nil): secretState = .unknown
            case (_, let record?) where !record.isBound: secretState = .unbound
            case (_, let record?): secretState = .mismatch(approvedFor: "\(record.boundName ?? "?") from \(record.launcherDescription ?? "?")")
            }
            let clusters = await source.clusters()
            let decision = await approver.approve(BeaconApprovalRequest(clientName: name, launcher: entry.peer.launcher, secretState: secretState, clusters: clusters))
            // A Deny counts even when the connection is already gone (the person did answer).
            if decision == .deny {
                state.withLock {
                    $0.denied[entry.peer.launcher.identityKey] = clock()
                    $0.lastUnansweredSheet = clock()
                }
            }
            guard state.withLock({ $0.on && $0.generation == generation && $0.entries[entry.id] != nil }), !entry.connection.isClosed else { return }
            if decision == .withdrawn {
                if isLocked() { entry.state.withLock { $0.deferredName = name } }
                return
            }
            apply(decision, to: entry, name: name, secretState: secretState)
        }
        entry.approvalTask.withLock { $0 = task }
    }

    private func apply(_ decision: BeaconApprovalDecision, to entry: Entry, name: String, secretState: BeaconSecretState) {
        switch decision {
        case .withdrawn: break
        case .deny:
            state.withLock { $0.denied[entry.peer.launcher.identityKey] = clock() }
            activity.record(ActivityEntry(origin: .ui, verb: "beacon.approval", object: name, result: "denied"))
            end(entry)
            state.withLock { $0.entries[entry.id] = nil }
        case .allow(let read, let remember):
            // Only readable clusters that exist now; Production is whatever the person ticked (it is unchecked by default).
            if remember, let record = entry.secret, secretState == .unbound {
                try? store.bind(id: record.id, name: name, launcher: entry.peer.launcher, readClusters: read)
                entry.state.withLock { $0.client = BeaconClientRef(id: record.id, label: name) }
            } else if remember, let record = entry.secret, case .mismatch = secretState {
                try? store.bind(id: record.id, name: name, launcher: entry.peer.launcher, readClusters: read)
                entry.state.withLock { $0.client = BeaconClientRef(id: record.id, label: name) }
            } else {
                let id = "session-\(entry.id.uuidString)"
                store.setSessionScope(BeaconScope(readClusters: read), for: id)
                entry.state.withLock { $0.client = BeaconClientRef(id: id, label: name) }
            }
            entry.state.withLock { $0.status = .ok }
            activity.record(ActivityEntry(origin: .ui, verb: "beacon.approval", object: name, result: remember ? "approved" : "approved for this session"))
            entry.sessionBox.withLock { $0 }?.notifyToolsListChanged()
        }
    }

    private func scopeChanged() {
        let sessions = state.withLock { s in s.entries.values.compactMap { e in e.state.withLock { $0.status } == .ok ? e.sessionBox.withLock { $0 } : nil } }
        sessions.forEach { $0.notifyToolsListChanged() }
    }
}

/// Lets one approval sheet at a time through.
actor ApprovalGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func enter() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    func leave() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}
#endif
