#if os(macOS)
import Foundation
import Security
import Synchronization
import WheelhouseKit

public enum GangwaySessionError: Error, Equatable, LocalizedError {
    case randomFailed
    case invalidCluster
    public var errorDescription: String? {
        switch self {
        case .randomFailed: "A session token could not be generated."
        case .invalidCluster: "This cluster can't be reached through Gangway."
        }
    }
}

/// Token to session map. Tokens are random (32 bytes from `SecRandomCopyBytes`, base64url, prefix `whg_`); only the SHA-256 of a token
/// is kept, so a memory dump of the registry holds no usable token.
public final class SessionRegistry: Sendable {
    private struct State {
        var byDigest: [String: GangwaySession] = [:]
        var byID: [UUID: GangwaySession] = [:]
        var directories: [UUID: URL] = [:]
    }
    private let state = Mutex(State())
    private let gate: @Sendable () -> DevSafetyPolicy

    public init(gate: @escaping @Sendable () -> DevSafetyPolicy = { .current }) { self.gate = gate }

    static func makeToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw GangwaySessionError.randomFailed }
        let b64 = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "whg_" + b64
    }

    static func digest(of token: String) -> String { Hashing.sha256Hex(Data(token.utf8)) }

    /// Creates a session. Fails closed while the safety gate is active and the cluster's server host is not allowed.
    public func create(cluster: ClusterConfig, origin: GangwayOrigin, scope: GangwayScope = .standard, binding: PeerBinding = .none,
                       now: Date = Date()) throws -> (session: GangwaySession, token: String) {
        try gate().validate(server: cluster.server)
        guard SessionKubeconfigWriter.isValid(clusterID: cluster.id) else { throw GangwaySessionError.invalidCluster }
        let token = try Self.makeToken()
        let session = GangwaySession(id: UUID(), clusterID: cluster.id, origin: origin, scope: scope, binding: binding, createdAt: now,
                                     tokenDigest: Self.digest(of: token))
        state.withLock { s in
            s.byDigest[session.tokenDigest] = session
            s.byID[session.id] = session
        }
        return (session, token)
    }

    /// The live session for a bearer token, or nil when unknown or revoked.
    public func session(forToken token: String) -> GangwaySession? {
        guard token.hasPrefix("whg_"), token.utf8.count <= 128 else { return nil }
        let found = state.withLock { $0.byDigest[Self.digest(of: token)] }
        return found?.isRevoked == false ? found : nil
    }

    public func session(id: UUID) -> GangwaySession? { state.withLock { $0.byID[id] } }
    public var sessions: [GangwaySession] { state.withLock { Array($0.byID.values) } }
    public var liveSessionCount: Int { state.withLock { $0.byID.values.filter { !$0.isRevoked }.count } }

    func attach(directory: URL, to session: GangwaySession) { state.withLock { $0.directories[session.id] = directory } }

    /// Revokes a session: its token stops working, its connections close, its kubeconfig folder is deleted.
    public func revoke(_ session: GangwaySession, reason: String) {
        let directory = state.withLock { s -> URL? in
            s.byDigest[session.tokenDigest] = nil
            s.byID[session.id] = nil
            return s.directories.removeValue(forKey: session.id)
        }
        session.revoke(reason: reason)
        if let directory { SessionKubeconfigWriter.remove(directory: directory) }
    }

    @discardableResult
    public func revokeSessions(forCluster id: ClusterID, reason: String) -> Int {
        let list = sessions.filter { $0.clusterID == id }
        list.forEach { revoke($0, reason: reason) }
        return list.count
    }

    public func revokeAll(reason: String) {
        sessions.forEach { revoke($0, reason: reason) }
    }
}
#endif
