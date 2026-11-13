import Foundation
import Darwin

/// One remote port a person can forward to.
public struct ForwardablePort: Identifiable, Hashable, Sendable {
    public var port: Int
    public var name: String?
    public var detail: String?
    public var id: Int { port }

    public init(port: Int, name: String? = nil, detail: String? = nil) {
        self.port = port
        self.name = name
        self.detail = detail
    }

    /// `3306 · mariadb`.
    public var title: String { [String(port), name].compactMap { $0 }.joined(separator: " · ") }

    /// Whether a browser is a sensible way to open this port (well-known web ports, or a port named like one).
    public var isHTTP: Bool {
        if Self.webPorts.contains(port) { return true }
        let lower = (name ?? "").lowercased()
        return ["http", "https", "web", "ui", "dashboard", "admin", "metrics"].contains { lower.contains($0) }
    }

    private static let webPorts: Set<Int> = [80, 443, 3000, 5000, 5601, 8000, 8080, 8081, 8443, 8888, 9000, 9090, 9093, 9200, 15672]
}

/// Reads the forwardable (TCP) ports of a service or a pod from its raw object.
public enum ForwardablePorts {
    public static func ports(kind: ResourceKind, raw: JSONValue) -> [ForwardablePort] {
        switch kind {
        case .service:
            return (raw.value(at: "spec.ports")?.arrayValue ?? []).compactMap { p in
                guard (p["protocol"]?.stringValue ?? "TCP") == "TCP", let port = p["port"]?.intValue else { return nil }
                let target: String? = switch p["targetPort"] {
                case .int(let n)?: "target port \(n)"
                case .string(let s)?: "target port \(s)"
                default: nil
                }
                return ForwardablePort(port: port, name: p["name"]?.stringValue, detail: target)
            }
        case .pod:
            var seen = Set<Int>()
            return (raw.value(at: "spec.containers")?.arrayValue ?? []).flatMap { c in
                (c["ports"]?.arrayValue ?? []).compactMap { p -> ForwardablePort? in
                    guard (p["protocol"]?.stringValue ?? "TCP") == "TCP", let port = p["containerPort"]?.intValue, seen.insert(port).inserted else { return nil }
                    return ForwardablePort(port: port, name: p["name"]?.stringValue, detail: c["name"]?.stringValue.map { "container \($0)" })
                }
            }
        default:
            return []
        }
    }
}

extension LocalPort {
    /// Stricter than ``isFree``: nothing may be listening on the port on any local address. A bind with SO_REUSEADDR succeeds
    /// next to a wildcard listener (a local database on `*:3306`) and would silently shadow it, so this also tries a connection
    /// over IPv4 and IPv6 loopback.
    public static func isAvailable(_ port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        return canBindLoopback(port) && !acceptsConnections(port, ipv6: false) && !acceptsConnections(port, ipv6: true)
    }

    private static func canBindLoopback(_ port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // SO_REUSEADDR so a port in TIME_WAIT after a stopped forward reads as free again; a live listener (wildcard or
        // loopback) is caught by the connection probes in `isAvailable`.
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }

    private static func acceptsConnections(_ port: Int, ipv6: Bool) -> Bool {
        let fd = socket(ipv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if ipv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr.sin6_addr = in6addr_loopback
            return withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            } == 0
        }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(UInt16(port).bigEndian)
        addr.sin_addr = in_addr(s_addr: UInt32(0x7F00_0001).bigEndian)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        } == 0
    }
}

/// Picks the local port for a forward.
public enum ForwardPlanner {
    /// The remote port's own number when it is available and at least 1024; otherwise the next available port (a remote port below
    /// 1024 starts from `port + 8000`). Ports in `used` (live forwards) are skipped. nil when nothing is available.
    public static func localPort(remote: Int, used: Set<Int>, isAvailable: (Int) -> Bool = LocalPort.isAvailable) -> Int? {
        var port = remote >= 1024 ? remote : (remote + 8000 <= 65000 ? remote + 8000 : 8080)
        for _ in 0..<500 where port <= 65535 {
            if !used.contains(port), isAvailable(port) { return port }
            port += 1
        }
        return nil
    }
}

/// Which services and pods have a live forward. Coarse on purpose: byte counters and state ticks are not part of it, so a view
/// that reads it only refreshes when a forward starts or stops.
public struct ForwardIndex: Equatable, Sendable {
    public struct Entry: Hashable, Sendable {
        public var id: UUID
        public var clusterID: ClusterID
        public var kind: PortForwardTarget.Kind
        public var namespace: String
        public var name: String
        public var remotePort: Int
        public var localPort: Int
    }

    public private(set) var entries: [Entry]

    public init(_ forwards: [PortForwardInfo]) {
        entries = forwards.filter { $0.state.isLive }.map {
            Entry(id: $0.id, clusterID: $0.clusterID, kind: $0.target.kind, namespace: $0.target.namespace, name: $0.target.name,
                  remotePort: $0.target.remotePort, localPort: $0.localPort)
        }.sorted { ($0.remotePort, $0.localPort) < ($1.remotePort, $1.localPort) }
    }

    public var isEmpty: Bool { entries.isEmpty }

    public func entries(for ref: ResourceRef) -> [Entry] {
        let kind: PortForwardTarget.Kind
        switch ref.kind {
        case .service: kind = .service
        case .pod: kind = .pod
        default: return []
        }
        return entries.filter { $0.clusterID == ref.clusterID && $0.kind == kind && $0.name == ref.name && $0.namespace == (ref.namespace ?? "") }
    }

    public func isForwarding(_ ref: ResourceRef, remotePort: Int) -> Bool { entries(for: ref).contains { $0.remotePort == remotePort } }
}

/// What may happen when someone asks to forward on a cluster. One answer for every entry point.
public enum PortForwardGate: Equatable, Sendable {
    case refused(String)
    /// `confirmation` is a button confirmation (never typing): Production only.
    case allowed(confirmation: Bool)

    public static func decide(_ config: ClusterConfig) -> PortForwardGate {
        if config.isDemo { return .refused("Demo mode has no real pods to tunnel to. Add a cluster to forward ports.") }
        switch MutationPolicy.decide(.portForward, cluster: config, origin: nil) {
        case .refuse(let reason): return .refused(reason)
        case .pass, .confirm: return .allowed(confirmation: config.isProduction)
        }
    }
}

/// State of the advanced "Port Forward…" form.
public struct PortForwardFormState: Equatable, Sendable {
    public var options: [ForwardablePort] = []
    public var remotePort: Int?
    public var useCustomRemote = false
    public var customRemote = ""
    /// Empty means automatic.
    public var localText = ""

    public init() {}

    public mutating func load(_ options: [ForwardablePort]) {
        self.options = options
        remotePort = options.first?.port
        useCustomRemote = options.isEmpty
    }

    public var effectiveRemote: Int? {
        let value = useCustomRemote ? Int(customRemote.trimmingCharacters(in: .whitespaces)) : remotePort
        return value.flatMap { (1...65535).contains($0) ? $0 : nil }
    }

    /// The typed local port, nil when automatic or not a number.
    public var localOverride: Int? { Int(localText.trimmingCharacters(in: .whitespaces)) }

    public func localProblem(used: Set<Int>, isAvailable: (Int) -> Bool = LocalPort.isAvailable) -> String? {
        let text = localText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return nil }
        guard let port = Int(text), (1024...65535).contains(port) else { return "Enter a port between 1024 and 65535." }
        if used.contains(port) { return "Another forward already uses this port." }
        if !isAvailable(port) { return "Port \(port) is in use on this Mac." }
        return nil
    }

    public func canForward(used: Set<Int>, isAvailable: (Int) -> Bool = LocalPort.isAvailable) -> Bool {
        effectiveRemote != nil && localProblem(used: used, isAvailable: isAvailable) == nil
    }

    /// The local port to listen on: the typed one, or the planner's choice.
    public func resolvedLocal(used: Set<Int>, isAvailable: (Int) -> Bool = LocalPort.isAvailable) -> Int? {
        guard let remote = effectiveRemote else { return nil }
        return localOverride ?? ForwardPlanner.localPort(remote: remote, used: used, isAvailable: isAvailable)
    }
}
