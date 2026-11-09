#if os(macOS)
import Foundation
import Network
import Synchronization

public enum GangwayServerError: Error, Equatable, LocalizedError {
    case noFreePort
    case listenFailed(String)
    public var errorDescription: String? {
        switch self {
        case .noFreePort: "Gangway could not find a free local port."
        case .listenFailed(let why): "Gangway could not start listening: \(why)"
        }
    }
}

/// The listener (ARCHITECTURE-MAC section 3.6): `NWListener` bound to 127.0.0.1 only, plain HTTP/1.1. The port is random in
/// 49152-65535, chosen on first launch and persisted in `gangway.json`, reused on every launch; when it is busy a new one is chosen and
/// persisted. A fixed port (Settings -> Advanced) wins when set.
public final class GangwayServer: Sendable {
    private let context: GangwayContext
    private let portFile: URL?
    private let fixedPort: UInt16?
    private let queue = DispatchQueue(label: "app.wheelhouse.gangway.listener", qos: .userInitiated)
    private let connectionQueue = DispatchQueue(label: "app.wheelhouse.gangway.connections", qos: .userInitiated)
    private let listener = Mutex<NWListener?>(nil)
    private let connections = Mutex<[ObjectIdentifier: GangwayConnection]>([:])
    static let maxConnections = 512

    public init(context: GangwayContext, portFile: URL?, fixedPort: UInt16? = nil) {
        self.context = context
        self.portFile = portFile
        self.fixedPort = fixedPort
    }

    public var isRunning: Bool { listener.withLock { $0 != nil } }
    public var connectionCount: Int { connections.withLock { $0.count } }

    /// The persisted port, if any.
    static func persistedPort(_ file: URL?) -> UInt16? {
        guard let file, let data = try? Data(contentsOf: file),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let port = object["port"] as? Int,
              (1024...65535).contains(port) else { return nil }
        return UInt16(port)
    }

    private func persist(_ port: UInt16) {
        guard let portFile else { return }
        try? FileManager.default.createDirectory(at: portFile.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try? JSONSerialization.data(withJSONObject: ["port": Int(port)])
        try? data?.write(to: portFile, options: .atomic)
    }

    @discardableResult
    public func start(identity: LoopbackIdentity) async throws -> UInt16 {
        if let port = listener.withLock({ $0?.port?.rawValue }) { return port }
        var candidates: [UInt16] = []
        if let fixedPort { candidates = [fixedPort] } else {
            if let saved = Self.persistedPort(portFile) { candidates.append(saved) }
            candidates += (0..<30).map { _ in UInt16.random(in: 49152...65535) }
        }
        var lastError = "no candidate port"
        for port in candidates {
            do {
                let bound = try await listen(on: port, identity: identity)
                if fixedPort == nil, Self.persistedPort(portFile) != bound { persist(bound) }
                context.listenerPort = bound
                return bound
            } catch { lastError = error.localizedDescription }
        }
        throw fixedPort != nil ? GangwayServerError.listenFailed(lastError) : GangwayServerError.noFreePort
    }

    private func listen(on port: UInt16, identity: LoopbackIdentity) async throws -> UInt16 {
        // TLS 1.3 only, ALPN http/1.1 only, this launch's identity.
        let tls = NWProtocolTLS.Options()
        let options = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(options, .TLSv13)
        sec_protocol_options_add_tls_application_protocol(options, "http/1.1")
        guard let secIdentity = sec_identity_create(identity.identity) else { throw GangwayServerError.listenFailed("identity") }
        sec_protocol_options_set_local_identity(options, secIdentity)
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let parameters = NWParameters(tls: tls, tcp: tcp)
        parameters.allowLocalEndpointReuse = false
        parameters.acceptLocalOnly = true
        guard let nwPort = NWEndpoint.Port(rawValue: port) else { throw GangwayServerError.listenFailed("bad port") }
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: nwPort)
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        let box = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            box.set(continuation)
            listener.stateUpdateHandler = { [box] state in
                switch state {
                case .ready: box.resume(.success(()))
                case .failed(let error): box.resume(.failure(GangwayServerError.listenFailed(error.localizedDescription)))
                case .cancelled: box.resume(.failure(GangwayServerError.listenFailed("cancelled")))
                default: break
                }
            }
            listener.start(queue: queue)
        }
        listener.stateUpdateHandler = nil
        self.listener.withLock { $0 = listener }
        return listener.port?.rawValue ?? port
    }

    private func accept(_ nw: NWConnection) {
        guard connections.withLock({ $0.count }) < Self.maxConnections else {
            nw.cancel()
            return
        }
        let stream = NWStream(nw, queue: connectionQueue)
        let connection = GangwayConnection(downstream: stream, context: context)
        let key = ObjectIdentifier(connection)
        connections.withLock { $0[key] = connection }
        Task { [weak self] in
            do { try await stream.start() } catch {
                stream.cancel()
                self?.connections.withLock { $0[key] = nil }
                return
            }
            await connection.run()
            self?.connections.withLock { $0[key] = nil }
        }
    }

    public func stop() {
        let l = listener.withLock { l -> NWListener? in
            defer { l = nil }
            return l
        }
        l?.cancel()
        let all = connections.withLock { c -> [GangwayConnection] in
            defer { c = [:] }
            return Array(c.values)
        }
        all.forEach { $0.cancel() }
    }
}
#endif
