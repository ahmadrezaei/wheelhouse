#if os(macOS)
import Foundation
import Network
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A plain-HTTP stand-in for an API server on loopback: records every head and body it receives, answers by a closure.
final class FakeUpstream: @unchecked Sendable {
    struct Received: Sendable {
        var head: String
        var body: Data
        var method: String
        var path: String
        var headers: [String: String]
    }
    enum Reply: Sendable {
        case json(Int, String)
        /// 101 then echo every byte back until the client closes.
        case upgradeEcho
        /// A response with headers only, then silence (a watch).
        case hang
        /// Close without answering.
        case close
        /// Read the request and never answer (the connection stays open).
        case silent
    }

    private let state = Mutex<[Received]>([])
    private let connectionCount = Mutex(0)
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "fake-upstream")
    var handler: @Sendable (Received) -> Reply = { _ in .json(200, "{}") }
    private(set) var port: UInt16 = 0

    var received: [Received] { state.withLock { $0 } }
    var connections: Int { connectionCount.withLock { $0 } }
    func reset() { state.withLock { $0.removeAll() } }

    func start() async throws {
        let l = try NWListener(using: .tcp, on: .any)
        listener = l
        l.newConnectionHandler = { [weak self] c in self?.serve(c) }
        let box = ResumeOnce()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            box.set(cont)
            l.stateUpdateHandler = { [box] s in
                if case .ready = s { box.resume(.success(())) }
                if case .failed(let e) = s { box.resume(.failure(e)) }
            }
            l.start(queue: queue)
        }
        port = l.port!.rawValue
    }

    func stop() { listener?.cancel() }

    private func serve(_ nw: NWConnection) {
        connectionCount.withLock { $0 += 1 }
        let stream = NWStream(nw, queue: queue)
        Task {
            guard (try? await stream.start()) != nil else { return }
            var buffer = Data()
            let terminator = Data("\r\n\r\n".utf8)
            while true {
                while buffer.range(of: terminator) == nil {
                    guard let d = try? await stream.receive() else { stream.cancel(); return }
                    buffer.append(d)
                }
                let end = buffer.range(of: terminator)!
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                var headers: [String: String] = [:]
                let lines = head.components(separatedBy: "\r\n")
                for line in lines.dropFirst() {
                    if let c = line.firstIndex(of: ":") { headers[line[line.startIndex..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
                }
                var body = Data()
                if let n = headers["content-length"].flatMap({ Int($0) }) {
                    while buffer.count < n {
                        guard let d = try? await stream.receive() else { stream.cancel(); return }
                        buffer.append(d)
                    }
                    body = buffer.prefix(n)
                    buffer.removeFirst(n)
                } else if headers["transfer-encoding"] == "chunked" {
                    // read until the terminating chunk
                    while buffer.range(of: Data("0\r\n\r\n".utf8)) == nil {
                        guard let d = try? await stream.receive() else { stream.cancel(); return }
                        buffer.append(d)
                    }
                    body = buffer
                    buffer.removeAll()
                }
                let parts = lines[0].split(separator: " ")
                let received = Received(head: head, body: body, method: String(parts[0]), path: String(parts[1]), headers: headers)
                state.withLock { $0.append(received) }
                switch handler(received) {
                case .json(let status, let text):
                    let payload = Data(text.utf8)
                    try? await stream.send(Data("HTTP/1.1 \(status) X\r\nContent-Type: application/json\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload)
                case .upgradeEcho:
                    try? await stream.send(Data("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\n\r\n".utf8))
                    while let d = try? await stream.receive() { try? await stream.send(d) }
                    stream.cancel()
                    return
                case .hang:
                    try? await stream.send(Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\n".utf8))
                    while let _ = try? await stream.receive() {}
                    return
                case .close:
                    stream.cancel()
                    return
                case .silent:
                    while let _ = try? await stream.receive() {}
                    return
                }
            }
        }
    }
}

/// A minimal raw HTTP client on loopback: sends bytes, reads what comes back.
final class RawClient: @unchecked Sendable {
    let stream: NWStream
    private var buffer = Data()

    /// Gangway's loopback leg is TLS: the client trusts exactly the certificate of this launch (what a session kubeconfig carries), and
    /// asks for TLS 1.3 with ALPN http/1.1 like kubectl does.
    init(port: UInt16, certificateDER: Data, maxTLS: tls_protocol_version_t = .TLSv13, alpn: String = "http/1.1") async throws {
        let tls = NWProtocolTLS.Options()
        let sec = tls.securityProtocolOptions
        sec_protocol_options_set_max_tls_protocol_version(sec, maxTLS)
        sec_protocol_options_add_tls_application_protocol(sec, alpn)
        sec_protocol_options_set_peer_authentication_required(sec, true)
        sec_protocol_options_set_verify_block(sec, { _, trust, complete in
            let secTrust = sec_trust_copy_ref(trust).takeRetainedValue()
            let leaf = (SecTrustCopyCertificateChain(secTrust) as? [SecCertificate])?.first
            complete(leaf.map { SecCertificateCopyData($0) as Data == certificateDER } ?? false)
        }, DispatchQueue(label: "raw-client-tls"))
        let nw = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
        stream = NWStream(nw, queue: DispatchQueue(label: "raw-client"))
        try await stream.start()
    }

    func send(_ text: String) async throws { try await stream.send(Data(text.utf8)) }
    func send(_ data: Data) async throws { try await stream.send(data) }
    func close() { stream.cancel() }

    /// Reads one HTTP response (Content-Length framed). nil when the connection closed first.
    func readResponse(timeout: Duration = .seconds(10)) async -> (status: Int, headers: [String: String], body: String)? {
        await withTaskGroup(of: (Int, [String: String], String)?.self) { group in
            group.addTask { [self] in
                let terminator = Data("\r\n\r\n".utf8)
                while buffer.range(of: terminator) == nil {
                    guard let d = try? await stream.receive() else { return nil }
                    buffer.append(d)
                }
                let end = buffer.range(of: terminator)!
                let head = String(decoding: buffer[buffer.startIndex..<end.lowerBound], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex..<end.upperBound)
                let lines = head.components(separatedBy: "\r\n")
                let status = Int(lines[0].split(separator: " ")[1]) ?? 0
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    if let c = line.firstIndex(of: ":") { headers[line[line.startIndex..<c].lowercased()] = line[line.index(after: c)...].trimmingCharacters(in: .whitespaces) }
                }
                let n = headers["content-length"].flatMap { Int($0) } ?? 0
                while buffer.count < n {
                    guard let d = try? await stream.receive() else { return nil }
                    buffer.append(d)
                }
                let body = String(decoding: buffer.prefix(n), as: UTF8.self)
                buffer.removeFirst(n)
                return (status, headers, body)
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            guard let first else { return nil }
            return (first.0, first.1, first.2)
        }
    }

    /// Reads raw bytes (the upgraded leg).
    func readBytes(count: Int, timeout: Duration = .seconds(10)) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask { [self] in
                while buffer.count < count {
                    guard let d = try? await stream.receive() else { return nil }
                    buffer.append(d)
                }
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                return out
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// True when the peer closed the connection within `timeout` (reads nothing else).
    func isClosedByPeer(timeout: Duration = .seconds(5)) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { [self] in
                while true {
                    do { guard try await stream.receive() != nil else { return true } } catch { return true }
                }
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
    }
}

struct ScriptedConfirmer: GangwayConfirming {
    var answer: @Sendable (GangwaySheet) async -> Bool
    let sheets: Sheets
    final class Sheets: @unchecked Sendable {
        private let list = Mutex<[GangwaySheet]>([])
        var all: [GangwaySheet] { list.withLock { $0 } }
        func add(_ s: GangwaySheet) { list.withLock { $0.append(s) } }
    }
    init(sheets: Sheets = Sheets(), answer: @escaping @Sendable (GangwaySheet) async -> Bool) {
        self.sheets = sheets
        self.answer = answer
    }
    func confirm(_ sheet: GangwaySheet) async -> Bool {
        sheets.add(sheet)
        return await answer(sheet)
    }
}

/// A Gangway in front of a `FakeUpstream`, with injectable policy configuration.
final class GangwayRig: @unchecked Sendable {
    let scratch: Scratch
    let upstream = FakeUpstream()
    let provider: SnapshotClusterProvider
    let service: GangwayService
    let activity = InMemoryActivityLog()
    let policyCluster = Mutex<ClusterConfig>(ClusterConfig(id: "kc-test1", name: "test-one", server: URL(string: "https://x.test:6443")!))
    let paths: AppPaths

    init(environment: ClusterEnvironment = .development, readOnly: Bool = false, confirmer: any GangwayConfirming = DecliningConfirmer(),
         idleTimeout: Duration = .seconds(120), basePath: String = "", token: String? = "backend-token", window: Duration = .zero,
         resolver: any PeerResolving = PeerResolver(), holdTimeout: Duration = .seconds(20)) async throws {
        scratch = try Scratch()
        paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: scratch.root, temporaryDirectory: scratch.root.appending(path: "tmp"))
        try await upstream.start()
        let port = upstream.port
        var cluster = ClusterConfig(id: "kc-test1", name: "test-one", server: URL(string: "http://127.0.0.1:\(port)")!, environment: environment, readOnly: readOnly)
        // The upstream leg is plain HTTP, which Production refuses: the policy sees the real environment, the connector a development twin.
        var wire = cluster
        wire.environment = .development
        wire.server = URL(string: "http://127.0.0.1:\(port)\(basePath)")!
        cluster.server = wire.server
        let secrets = ClusterSecrets(token: token)
        let wired = wire
        provider = SnapshotClusterProvider { _ in GangwayUpstream(config: wired, secrets: secrets) }
        provider.update([cluster])
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"], home: scratch.root)
        service = GangwayService(paths: paths, clusters: provider, confirmer: confirmer, activity: activity, gate: { gate }, resolver: resolver,
                                 batchingWindow: window, holdTimeout: holdTimeout, idleTimeout: idleTimeout)
    }

    var clusterID: ClusterID { "kc-test1" }

    func setCluster(_ change: (inout ClusterConfig) -> Void) {
        var c = provider.config(for: clusterID)!
        change(&c)
        provider.set(c)
        service.clusterChanged(clusterID)
    }

    func open(scope: GangwayScope = .standard, binding: PeerBinding = .none) async throws -> (GangwaySessionHandle, String) {
        let handle = try await service.openSession(clusterID: clusterID, origin: .harness("test"), scope: scope, binding: binding, namespace: "shop")
        let text = try String(contentsOf: handle.kubeconfig, encoding: .utf8)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        let users = try #require(object["users"] as? [[String: Any]])
        let token = try #require((users[0]["user"] as? [String: String])?["token"])
        return (handle, token)
    }

    func client() async throws -> RawClient { try await RawClient(port: try #require(service.port), certificateDER: try #require(service.context.tlsCertificateDER)) }

    func request(_ method: String, _ path: String, token: String, extra: String = "", body: String? = nil, host: String? = nil) -> String {
        let port = service.port ?? 0
        var s = "\(method) /c/\(clusterID)\(path) HTTP/1.1\r\nHost: \(host ?? "127.0.0.1:\(port)")\r\nAuthorization: Bearer \(token)\r\n\(extra)"
        if let body { s += "Content-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)" } else { s += "\r\n" }
        return s
    }

    func stop() {
        service.stop()
        upstream.stop()
        scratch.cleanup()
    }
}

#endif
