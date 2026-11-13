import Foundation
import Darwin

/// What a port-forward points at.
public struct PortForwardTarget: Hashable, Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case pod, service }
    public var kind: Kind
    public var namespace: String
    public var name: String
    /// Pod container port, or the service port (not the target port).
    public var remotePort: Int

    public init(kind: Kind, namespace: String, name: String, remotePort: Int) {
        self.kind = kind
        self.namespace = namespace
        self.name = name
        self.remotePort = remotePort
    }

    /// `svc/web:80`, `pod/web-abc:8080`.
    public var title: String { "\(kind == .service ? "svc" : "pod")/\(name):\(remotePort)" }
    /// Ports that conventionally speak TLS.
    public var looksLikeHTTPS: Bool { [443, 8443, 9443, 6443].contains(remotePort) }
}

public enum PortForwardState: Hashable, Sendable {
    case starting
    case active
    case reconnecting
    case suspended
    case failed(String)
    case stopped

    public var title: String {
        switch self {
        case .starting: "Starting"
        case .active: "Active"
        case .reconnecting: "Reconnecting"
        case .suspended: "Suspended"
        case .failed: "Failed"
        case .stopped: "Stopped"
        }
    }
    public var isLive: Bool { switch self { case .starting, .active, .reconnecting, .suspended: true; default: false } }
}

/// Immutable snapshot of one forward for the UI.
public struct PortForwardInfo: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var clusterID: ClusterID
    public var clusterName: String
    public var target: PortForwardTarget
    public var localPort: Int
    public var state: PortForwardState
    public var startedAt: Date
    public var endedAt: Date?
    /// Bytes received from the cluster (towards local clients).
    public var bytesDown: Int
    /// Bytes sent to the cluster.
    public var bytesUp: Int
    public var openConnections: Int
    public var totalConnections: Int
    public var resolvedPod: String?
    public var lastError: String?

    public init(id: UUID, clusterID: ClusterID, clusterName: String, target: PortForwardTarget, localPort: Int, state: PortForwardState, startedAt: Date,
                endedAt: Date? = nil, bytesDown: Int = 0, bytesUp: Int = 0, openConnections: Int = 0, totalConnections: Int = 0,
                resolvedPod: String? = nil, lastError: String? = nil) {
        self.id = id; self.clusterID = clusterID; self.clusterName = clusterName; self.target = target; self.localPort = localPort
        self.state = state; self.startedAt = startedAt; self.endedAt = endedAt; self.bytesDown = bytesDown; self.bytesUp = bytesUp
        self.openConnections = openConnections; self.totalConnections = totalConnections; self.resolvedPod = resolvedPod; self.lastError = lastError
    }

    public var localAddress: String { "127.0.0.1:\(localPort)" }
    public var url: URL? { URL(string: "\(target.looksLikeHTTPS ? "https" : "http")://127.0.0.1:\(localPort)") }
}

public enum PortForwardError: Error, Equatable, Sendable, LocalizedError {
    case portInUse(Int)
    case noReadyPod(String)
    case listenerFailed(String)
    case alreadyForwarding(UUID)

    public var errorDescription: String? {
        switch self {
        case .portInUse(let p): "Local port \(p) is already in use."
        case .noReadyPod(let s): s
        case .listenerFailed(let s): "Couldn’t open the local listener: \(s)"
        case .alreadyForwarding: "That port is already being forwarded."
        }
    }
}

/// Helpers for picking local ports.
public enum LocalPort {
    /// True when nothing is bound to 127.0.0.1:`port`.
    public static func isFree(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return result == 0
    }

    /// The preferred port if free and >= 1024, otherwise the next free port at or above `max(preferred, 1024)`.
    public static func suggest(preferred: Int, excluding used: Set<Int> = []) -> Int {
        var port = preferred >= 1024 ? preferred : (preferred + 8000 <= 65000 ? preferred + 8000 : 8080)
        var tries = 0
        while tries < 500 {
            if !used.contains(port) && isFree(port) { return port }
            port += 1
            tries += 1
        }
        return 0
    }
}
