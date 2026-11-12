#if os(macOS)
import Darwin
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// A short temporary folder (a Unix socket path holds 103 characters).
final class ShortDir: @unchecked Sendable {
    let url: URL
    init() {
        url = URL(fileURLWithPath: "/tmp/whb-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
    var socket: URL { url.appending(path: "b/s") }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

struct FixedVerifier: BeaconPeerVerifying {
    var result: Result<BeaconPeer, BeaconRejection>
    func verify(fd: Int32) -> Result<BeaconPeer, BeaconRejection> { result }
}

extension BeaconPeer {
    static func fake(key: String = "path:/usr/local/bin/claude", team: String? = nil, signingID: String? = nil) -> BeaconPeer {
        BeaconPeer(pid: 4242, uid: geteuid(), launcher: BeaconLauncher(pid: 4000, path: "/usr/local/bin/claude", signingID: signingID, team: team))
    }
}

/// A test MCP client over the raw socket: the framing the helper speaks, without the helper.
final class SocketClient: @unchecked Sendable {
    let fd: Int32
    init?(path: String) {
        var address = BeaconSocketServer.address(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        let ok = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard ok == 0 else { close(fd); return nil }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
    }
    deinit { close(fd) }

    @discardableResult func send(_ value: JSONValue) -> Bool { BeaconFrame.writeAll(fd: fd, BeaconFrame.encode((try? value.data()) ?? Data())) }
    func sendRaw(_ data: Data) -> Bool { BeaconFrame.writeAll(fd: fd, data) }
    func receive(timeout: TimeInterval = 3) -> JSONValue? {
        BeaconFrame.read(fd: fd, limit: BeaconFrame.maxMessage, deadline: Date().addingTimeInterval(timeout)).flatMap { try? JSONValue.parse($0) }
    }
    /// True when the server closed the connection.
    func isClosed(timeout: TimeInterval = 2) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, Int32(max(1, end.timeIntervalSinceNow * 1000))) > 0 else { return false }
            var buffer = [UInt8](repeating: 0, count: 4096)
            if Darwin.read(fd, &buffer, buffer.count) <= 0 { return true }   // anything still buffered is drained first
        }
        return false
    }
    func hello(secret: String? = nil) {
        var v: JSONValue = ["protocol": 1, "helper": "test", "pid": .int(Int(getpid()))]
        if let secret { v["secret"] = .string(secret) }
        send(v)
    }
    func call(_ id: Int, _ method: String, _ params: JSONValue = [:]) -> JSONValue? {
        send(["jsonrpc": "2.0", "id": .int(id), "method": .string(method), "params": params])
        while let message = receive() { if message["id"]?.intValue == id { return message } }
        return nil
    }
}

@Suite("BeaconSocket", .serialized)
struct BeaconSocketTests {
    private func handlerSession(_ connection: BeaconConnection) -> MCPSession {
        let handler = BeaconToolHandler(client: BeaconClientRef(id: "c", label: "t"), source: EmptySource(), settings: DefaultToolboxSettings(), gate: { .ok })
        return MCPSession(handler: handler, limiter: BeaconLimiter()) { connection.send($0) }
    }

    struct EmptySource: ToolboxClusterSource {
        func clusters() async -> [ClusterConfig] { [] }
        func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? { nil }
    }

    // MARK: Framing

    @Test func framesRoundTripAndRefuseOversize() {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        #expect(BeaconFrame.writeAll(fd: fds[0], BeaconFrame.encode(Data("hello".utf8))))
        #expect(BeaconFrame.read(fd: fds[1], limit: 100) == Data("hello".utf8))
        // One byte over the limit is refused (the length is checked before any payload is read).
        var length = UInt32(BeaconFrame.maxMessage + 1).bigEndian
        #expect(BeaconFrame.writeAll(fd: fds[0], Data(bytes: &length, count: 4)))
        #expect(BeaconFrame.read(fd: fds[1], limit: BeaconFrame.maxMessage) == nil)
    }

    @Test func partialFramesAreAssembledAndTimeOut() async {
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        let frame = BeaconFrame.encode(Data("0123456789".utf8))
        let writer = fds[0]
        Task.detached {
            for byte in frame {
                _ = BeaconFrame.writeAll(fd: writer, Data([byte]))
                try? await Task.sleep(for: .milliseconds(2))
            }
        }
        #expect(BeaconFrame.read(fd: fds[1], limit: 100, deadline: Date().addingTimeInterval(3)) == Data("0123456789".utf8))
        // A frame that never completes times out.
        _ = BeaconFrame.writeAll(fd: fds[0], Data([0, 0, 0, 9, 1]))
        #expect(BeaconFrame.read(fd: fds[1], limit: 100, deadline: Date().addingTimeInterval(0.2)) == nil)
    }

    // MARK: Server

    @Test func socketAndFolderArePrivateAndRemovedOnStop() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, _ in nil }
        try server.start(at: dir.socket)
        var st = stat()
        stat(dir.socket.path, &st)
        #expect(st.st_mode & 0o777 == 0o600)
        stat(dir.socket.deletingLastPathComponent().path, &st)
        #expect(st.st_mode & 0o777 == 0o700)
        server.stop()
        #expect(!FileManager.default.fileExists(atPath: dir.socket.path))
        #expect(!server.isRunning)
    }

    @Test func pathLengthIsGuarded() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "a", count: 120) + "/s")
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, _ in nil }
        #expect(throws: BeaconSocketError.pathTooLong(long.path.utf8.count)) { try server.start(at: long) }
        // The real paths are short enough for any user name up to 20 characters.
        let release = "/Users/" + String(repeating: "u", count: 20) + "/Library/Group Containers/JCZY58QP3L.com.ahmadrezaei.wheelhouse/b/s"
        #expect(release.utf8.count <= BeaconSocketServer.maxPathLength + 12)
    }

    @Test func aStaleSocketFileIsReplacedAndALiveOneIsNotStolen() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        try FileManager.default.createDirectory(at: dir.socket.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: dir.socket.path, contents: Data())
        let first = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, _ in nil }
        try first.start(at: dir.socket)
        let second = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, _ in nil }
        #expect(throws: BeaconSocketError.alreadyRunning) { try second.start(at: dir.socket) }
        first.stop()
    }

    @Test func aVerifiedClientCompletesHelloInitializeAndToolsList() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let received = Mutex<BeaconHello?>(nil)
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, hello, connection in
            received.withLock { $0 = hello }
            return self.handlerSession(connection)
        }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let client = try #require(SocketClient(path: dir.socket.path))
        client.hello(secret: "s3cret")
        #expect(client.receive()?["ok"]?.boolValue == true)
        #expect(received.withLock { $0?.secret } == "s3cret")
        let initialized = client.call(1, "initialize", ["protocolVersion": "2025-11-25"])
        #expect(initialized?.value(at: "result.serverInfo.name")?.stringValue == "wheelhouse")
        let tools = client.call(2, "tools/list")?.value(at: "result.tools")?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(tools.contains("list_clusters"))
        #expect(!tools.contains { $0.hasPrefix("request_") })
    }

    @Test func aRejectedPeerIsClosedWithoutItsHelloBeingRead() throws {
        for reason in [BeaconRejection.badSignature, .wrongUser, .noCredentials, .changedWhileChecking] {
            let dir = ShortDir()
            defer { dir.cleanup() }
            let reasons = Mutex<[BeaconRejection]>([])
            let connected = Mutex(false)
            let server = BeaconSocketServer(verifier: FixedVerifier(result: .failure(reason)), rejected: { r in reasons.withLock { $0.append(r) } }) { _, _, _ in
                connected.withLock { $0 = true }
                return nil
            }
            try server.start(at: dir.socket)
            let client = try #require(SocketClient(path: dir.socket.path))
            client.hello(secret: "stolen")
            #expect(client.isClosed())
            #expect(reasons.withLock { $0 } == [reason])
            #expect(!connected.withLock { $0 })
            server.stop()
        }
    }

    @Test func theRealVerifierRejectsAProcessThatIsNotTheSignedHelper() throws {
        // This test process is not signed as the helper, so the code requirement fails (wrong signature).
        let dir = ShortDir()
        defer { dir.cleanup() }
        let reasons = Mutex<[BeaconRejection]>([])
        let verifier = SecurityPeerVerifier(requirement: BeaconRequirements.helper(identifier: "com.ahmadrezaei.wheelhouse.mac.mcp.debug"))
        let server = BeaconSocketServer(verifier: verifier, rejected: { r in reasons.withLock { $0.append(r) } }) { _, _, _ in nil }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let client = try #require(SocketClient(path: dir.socket.path))
        client.hello()
        #expect(client.isClosed())
        #expect(reasons.withLock { $0 } == [.badSignature])
    }

    @Test func theRealVerifierIdentifiesThisProcessWhenTheRequirementMatchesIt() throws {
        // Requirement "anchor apple" fails for an ad hoc test runner; a requirement that any code satisfies shows the positive path
        // reads the user, the token and the launcher. "identifier X" matches whatever this binary's identifier is.
        var fds: [Int32] = [0, 0]
        socketpair(AF_UNIX, SOCK_STREAM, 0, &fds)
        defer { close(fds[0]); close(fds[1]) }
        let token = try #require(SecurityPeerVerifier.peerToken(fds[0]))
        #expect(pid_t(token.val.5) == getpid())
        let result = SecurityPeerVerifier(requirement: "anchor apple generic and identifier \"no.such.identifier\"").verify(fd: fds[0])
        #expect(result == .failure(.badSignature))
        let launcher = SecurityPeerVerifier.launcher(of: getpid())
        #expect(launcher?.pid == getppid())
        #expect(!(launcher?.path.isEmpty ?? true))
    }

    @Test func requirementsParse() {
        for id in ["com.ahmadrezaei.wheelhouse.mac.mcp", "com.ahmadrezaei.wheelhouse.mac.mcp.debug"] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(BeaconRequirements.helper(identifier: id) as CFString, [], &requirement) == errSecSuccess)
        }
        for id in ["com.ahmadrezaei.wheelhouse.mac", "com.ahmadrezaei.wheelhouse.mac.debug"] {
            var requirement: SecRequirement?
            #expect(SecRequirementCreateWithString(BeaconRequirements.app(team: "JCZY58QP3L", bundleID: id) as CFString, [], &requirement) == errSecSuccess)
        }
        // Release helpers must be Developer ID signed; development helpers need only the team.
        #expect(BeaconRequirements.helper(identifier: "com.ahmadrezaei.wheelhouse.mac.mcp").contains("1.2.840.113635.100.6.1.13"))
        #expect(!BeaconRequirements.helper(identifier: "com.ahmadrezaei.wheelhouse.mac.mcp.debug").contains("1.2.840.113635.100.6.1.13"))
    }

    @Test func aSilentConnectionTimesOutAtTheHello() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let reasons = Mutex<[BeaconRejection]>([])
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake())), helloTimeout: 0.2, rejected: { r in reasons.withLock { $0.append(r) } }) { _, _, _ in nil }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let client = try #require(SocketClient(path: dir.socket.path))
        #expect(client.isClosed(timeout: 2))
        #expect(reasons.withLock { $0 } == [.badHello])
    }

    @Test func anOversizedHelloIsRefused() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, _ in nil }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let client = try #require(SocketClient(path: dir.socket.path))
        client.send(["protocol": 1, "pad": .string(String(repeating: "x", count: BeaconFrame.maxHello))])
        #expect(client.isClosed())
    }

    @Test func tooManyUnverifiedConnectionsAreDropped() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let drops = Mutex(0)
        // A verifier that takes its time keeps connections "unverified".
        struct Slow: BeaconPeerVerifying {
            func verify(fd: Int32) -> Result<BeaconPeer, BeaconRejection> { Thread.sleep(forTimeInterval: 0.6); return .failure(.badSignature) }
        }
        let server = BeaconSocketServer(verifier: Slow(), rejected: { r in if r == .tooManyConnections { drops.withLock { $0 += 1 } } }) { _, _, _ in nil }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let clients = (0..<12).compactMap { _ in SocketClient(path: dir.socket.path) }
        Thread.sleep(forTimeInterval: 0.3)
        #expect(drops.withLock { $0 } >= 1)
        _ = clients
    }

    @Test func stopDisconnectsWithinOneHundredMilliseconds() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, connection in self.handlerSession(connection) }
        try server.start(at: dir.socket)
        let clients = try (0..<4).map { _ -> SocketClient in
            let c = try #require(SocketClient(path: dir.socket.path))
            c.hello()
            _ = c.receive()
            return c
        }
        #expect(server.connectionCount == 4)
        let start = ContinuousClock.now
        server.stop()
        let stopped = start.duration(to: .now)
        #expect(stopped < .milliseconds(100))
        for c in clients { #expect(c.isClosed(timeout: 0.1)) }
        #expect(start.duration(to: .now) < .milliseconds(100) + .milliseconds(100))
    }

    @Test func deeplyNestedJSONIsRefusedBeforeDecoding() throws {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        let dir = ShortDir()
        defer { dir.cleanup() }
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, connection in self.handlerSession(connection) }
        try server.start(at: dir.socket)
        defer { server.stop() }
        // As the hello: closed, no crash.
        let first = try #require(SocketClient(path: dir.socket.path))
        first.sendRaw(BeaconFrame.encode(Data("{\"protocol\":1,\"x\":\(deep)}".utf8)))
        #expect(first.isClosed())
        // After a good hello: the message gets a parse error and the connection stays usable.
        let second = try #require(SocketClient(path: dir.socket.path))
        second.hello()
        _ = second.receive()
        second.sendRaw(BeaconFrame.encode(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\",\"params\":\(deep)}".utf8)))
        #expect(second.receive()?.value(at: "error.code")?.intValue == JSONRPCMessage.parseErrorCode)
        #expect(second.call(2, "ping")?["result"] != nil)
        #expect(JSONDepth.exceeds(Data(deep.utf8)) && !JSONDepth.exceeds(Data("[[[\"]]]\"]]]".utf8)))
    }

    @Test func aFrameAboveTheLimitEndsTheConnection() throws {
        let dir = ShortDir()
        defer { dir.cleanup() }
        let server = BeaconSocketServer(verifier: FixedVerifier(result: .success(.fake()))) { _, _, connection in self.handlerSession(connection) }
        try server.start(at: dir.socket)
        defer { server.stop() }
        let client = try #require(SocketClient(path: dir.socket.path))
        client.hello()
        _ = client.receive()
        var length = UInt32(BeaconFrame.maxMessage + 1).bigEndian
        #expect(client.sendRaw(Data(bytes: &length, count: 4)))
        #expect(client.isClosed())
    }
}
#endif
