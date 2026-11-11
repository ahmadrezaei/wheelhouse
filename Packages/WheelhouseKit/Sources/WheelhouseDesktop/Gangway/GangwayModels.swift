#if os(macOS)
import CryptoKit
import Foundation
import Synchronization
import WheelhouseKit

/// Who a session belongs to.
public enum GangwayOrigin: Hashable, Sendable {
    case terminal(paneID: String)
    case chartRoom(operation: String)
    case tides
    case rigging(pack: String)
    /// The headless harness and tests.
    case harness(String)

    public var changeOrigin: ChangeOrigin {
        switch self {
        case .terminal(let pane): .terminal(session: pane, reportedCommand: nil)
        case .chartRoom: .chartRoom
        case .tides: .tides
        case .rigging(let pack): .rigging(pack: pack)
        case .harness(let name): .terminal(session: name, reportedCommand: nil)
        }
    }
}

/// How a session's requests are judged.
public enum GangwayScope: Sendable, Equatable {
    /// The normal table: reads pass, everything else follows `MutationPolicy.decide(gangway:)` and holds.
    case standard
    /// `flux diff`, `helm template` against the server: reads, reviews and dry-runs only. A change, stream or proxy is refused, never held.
    case dryRunOnly
    /// A Chart Room or Tides run after its review flow: mutations covered by the grant pass, any other request that changes anything is
    /// refused (never held).
    case objects
}

/// How a session's client process is found (ARCHITECTURE-MAC section 3.6, "Binding to the PTY").
public enum PeerBinding: Sendable {
    case none
    /// A Deck Terminal: the shell's session id, the PTY device, and the foreground process group (tcgetpgrp of the master).
    case pty(device: dev_t, session: pid_t, foreground: @Sendable () -> pid_t?)
    /// A helm or flux run: the spawned process group.
    case processGroup(pid_t)
    /// A Chart Room helm run started in its own session (`ProcessSpec.newSession`): the peer must be in that session AND that group, so a
    /// child of the app cannot join the group with `setpgid` (that fails across sessions).
    case isolatedGroup(pid_t)
}

/// A guarded session. In memory only. The token itself is never stored: only its SHA-256.
public final class GangwaySession: Sendable {
    public let id: UUID
    public let clusterID: ClusterID
    public let origin: GangwayOrigin
    public let scope: GangwayScope
    /// How the client process is found. Set once, from `.none`: by ``bind(_:)`` for a terminal's PTY, by ``bindIsolatedGroup(_:)`` for a helm run.
    public var binding: PeerBinding { state.withLock { $0.binding } }
    public let createdAt: Date
    let tokenDigest: String
    /// What the session was opened against (server, auth, TLS settings, credential digest). A change ends the session.
    public var clusterFingerprint: String? {
        get { state.withLock { $0.fingerprint } }
        set { state.withLock { $0.fingerprint = newValue } }
    }

    private struct State {
        var binding: PeerBinding
        var kubeconfigHash: String?
        var fingerprint: String?
        var revoked = false
        var revokedReason: String?
        var reportedCommand: ReportedCommand?
        var closers: [UUID: @Sendable () -> Void] = [:]
    }
    private let state: Mutex<State>

    init(id: UUID, clusterID: ClusterID, origin: GangwayOrigin, scope: GangwayScope, binding: PeerBinding, createdAt: Date, tokenDigest: String) {
        self.id = id
        self.clusterID = clusterID
        self.origin = origin
        self.scope = scope
        self.state = Mutex(State(binding: binding))
        self.createdAt = createdAt
        self.tokenDigest = tokenDigest
    }

    /// Binds a terminal session to its PTY. Accepted once, from `.none`, for a terminal origin; until then requests fall to per-request sheets.
    @discardableResult
    public func bind(_ new: PeerBinding) -> Bool {
        guard case .terminal = origin else { return false }
        return state.withLock { s in
            guard !s.revoked, case .none = s.binding else { return false }
            s.binding = new
            return true
        }
    }

    /// Binds an object-grant session to the helm process it was opened for, once. The process group is only known after the spawn, and
    /// the process must already hold the session kubeconfig, so the session starts unbound and covers nothing until this succeeds.
    /// Refused for a standard session, a second bind, a revoked session or a pgid of 0 or 1.
    @discardableResult
    public func bindIsolatedGroup(_ pgid: pid_t) -> Bool {
        state.withLock { s in
            guard scope == .objects, !s.revoked, pgid > 1, case .none = s.binding else { return false }
            s.binding = .isolatedGroup(pgid)
            return true
            return true
        }
    }

    public var kubeconfigHash: String? {
        get { state.withLock { $0.kubeconfigHash } }
        set { state.withLock { $0.kubeconfigHash = newValue } }
    }
    public var isRevoked: Bool { state.withLock { $0.revoked } }
    public var revokedReason: String? { state.withLock { $0.revokedReason } }

    /// The command line the shell reported for the running command (nonce-verified by the terminal, M5b).
    public var reportedCommand: ReportedCommand? {
        get { state.withLock { $0.reportedCommand } }
        set { state.withLock { $0.reportedCommand = newValue } }
    }

    /// Registers something to run when the session is revoked (closing a connection). Returns a token for ``unregister(_:)``; runs the
    /// closer immediately when the session is already revoked.
    func register(closer: @escaping @Sendable () -> Void) -> UUID {
        let key = UUID()
        let runNow = state.withLock { s -> Bool in
            if s.revoked { return true }
            s.closers[key] = closer
            return false
        }
        if runNow { closer() }
        return key
    }

    func unregister(_ key: UUID) { state.withLock { $0.closers[key] = nil } }

    /// Marks the session revoked and closes every connection that belongs to it.
    func revoke(reason: String) {
        let closers = state.withLock { s -> [@Sendable () -> Void] in
            guard !s.revoked else { return [] }
            s.revoked = true
            s.revokedReason = reason
            defer { s.closers = [:] }
            return Array(s.closers.values)
        }
        closers.forEach { $0() }
    }
}

/// A command line reported by the shell.
public struct ReportedCommand: Sendable, Equatable {
    public var id: String
    public var line: String
    public init(id: String, line: String) {
        self.id = id
        self.line = line
    }
}

/// Everything Gangway needs about a cluster to talk to its API server.
public struct GangwayUpstream: Sendable {
    public var config: ClusterConfig
    public var secrets: ClusterSecrets
    /// nil keeps the stored token (`.static`).
    public var tokenSource: BearerTokenSource?
    /// A Production-suggested cluster the person has not checked yet (decision 10): never contacted.
    public var contactHeld: Bool

    public init(config: ClusterConfig, secrets: ClusterSecrets, tokenSource: BearerTokenSource? = nil, contactHeld: Bool = false) {
        self.config = config
        self.secrets = secrets
        self.tokenSource = tokenSource
        self.contactHeld = contactHeld
    }
}

/// Where Gangway reads clusters from. `config(for:)` is synchronous and cheap (a snapshot), because every request evaluates it.
public protocol GangwayClusterProviding: Sendable {
    /// The live configuration (read-only, Production, exec permission) right now.
    func config(for id: ClusterID) -> ClusterConfig?
    /// Credentials and token source, resolved when an upstream connection is opened.
    func upstream(for id: ClusterID) async throws -> GangwayUpstream
    /// A digest of the cluster's credentials (never the credentials), so a replaced credential can end the sessions that used the old one.
    func credentialDigest(for id: ClusterID) -> String?
    /// Reads the digest now (a session opening needs it). Runs off the main actor.
    func prepareCredentialDigest(for id: ClusterID) async
}

public extension GangwayClusterProviding {
    func credentialDigest(for id: ClusterID) -> String? { nil }
    func prepareCredentialDigest(for id: ClusterID) async {}
}

/// One request waiting for a person's decision.
public struct GangwayHold: Sendable, Identifiable {
    public var id: UUID
    public var sessionID: UUID
    public var clusterID: ClusterID
    public var clusterName: String
    public var request: GangwayRequestClass
    public var method: String
    public var path: String
    public var query: String?
    /// SHA-256 of the body, only when the body was buffered (deletes and evictions).
    public var bodySHA256: String?
    /// The command line as reported by the shell (a hint, never the thing that is confirmed).
    public var reportedCommand: String?
    /// The `command=` values of a non-interactive exec, so the sheet can show what runs.
    public var execCommand: [String]
    public var requiresTyping: Bool
    public var origin: GangwayOrigin
    public var isStream: Bool { if case .stream = request.kind { true } else { false } }

    public init(id: UUID = UUID(), sessionID: UUID, clusterID: ClusterID, clusterName: String, request: GangwayRequestClass, method: String, path: String, query: String? = nil,
                bodySHA256: String? = nil, reportedCommand: String? = nil, execCommand: [String] = [], requiresTyping: Bool, origin: GangwayOrigin) {
        self.id = id
        self.sessionID = sessionID
        self.clusterID = clusterID
        self.clusterName = clusterName
        self.request = request
        self.method = method
        self.path = path
        self.query = query
        self.bodySHA256 = bodySHA256
        self.reportedCommand = reportedCommand
        self.execCommand = execCommand
        self.requiresTyping = requiresTyping
        self.origin = origin
    }
}

/// What a sheet asks the person: a command approval (one grant), a batch of listed requests, or one stream.
public struct GangwaySheet: Sendable {
    public enum Kind: Sendable, Equatable {
        /// Creates a command grant (only for a grant-eligible command in a terminal with working shell integration).
        case command(line: String)
        case requests
        case stream
    }
    public var kind: Kind
    public var holds: [GangwayHold]
    public var requiresTyping: Bool { holds.contains { $0.requiresTyping } }

    public init(kind: Kind, holds: [GangwayHold]) {
        self.kind = kind
        self.holds = holds
    }
}

/// Shows the confirmation. M5b supplies the real sheets; the default declines everything.
public protocol GangwayConfirming: Sendable {
    func confirm(_ sheet: GangwaySheet) async -> Bool
}

public struct DecliningConfirmer: GangwayConfirming {
    public init() {}
    public func confirm(_ sheet: GangwaySheet) async -> Bool { false }
}

enum GangwayStatusBody {
    /// A Kubernetes `Status` object kubectl prints as `Error from server (Forbidden): <message>`.
    static func json(code: Int, message: String) -> Data {
        let reason: String
        switch code {
        case 400: reason = "BadRequest"
        case 401: reason = "Unauthorized"
        case 403: reason = "Forbidden"
        case 413: reason = "RequestEntityTooLarge"
        case 502: reason = "InternalError"
        default: reason = "InternalError"
        }
        let object: [String: Any] = ["kind": "Status", "apiVersion": "v1", "metadata": [String: Any](), "status": "Failure",
                                     "message": message, "reason": reason, "code": code]
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    }

    static func statusText(_ code: Int) -> String {
        switch code {
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 413: "Payload Too Large"
        case 502: "Bad Gateway"
        default: "Error"
        }
    }

    /// A complete HTTP response.
    static func response(code: Int, message: String, close: Bool) -> Data {
        let body = json(code: code, message: message)
        var head = "HTTP/1.1 \(code) \(statusText(code))\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n"
        if close { head += "Connection: close\r\n" }
        head += "\r\n"
        return Data(head.utf8) + body
    }
}

/// Latency samples of the proxy's own work, for the 2 ms p50 budget.
public final class GangwayMetrics: Sendable {
    private let samples = Mutex<[Double]>([])
    public init() {}
    func record(microseconds: Double) {
        samples.withLock { s in
            s.append(microseconds)
            if s.count > 8192 { s.removeFirst(s.count - 4096) }
        }
    }
    public var count: Int { samples.withLock { $0.count } }
    public func reset() { samples.withLock { $0.removeAll() } }
    /// The `fraction` quantile in milliseconds (0.5 = p50).
    public func quantileMilliseconds(_ fraction: Double) -> Double? {
        let sorted = samples.withLock { $0.sorted() }
        guard !sorted.isEmpty else { return nil }
        let index = min(sorted.count - 1, Int(Double(sorted.count) * fraction))
        return sorted[index] / 1000
    }
}

extension Duration {
    var microseconds: Double { Double(components.seconds) * 1_000_000 + Double(components.attoseconds) / 1_000_000_000_000 }
}

enum Hashing {
    static func sha256Hex(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
}
#endif
