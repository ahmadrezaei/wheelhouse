#if os(macOS)
import Darwin
import Dispatch
import Foundation
import Synchronization
import WheelhouseKit

/// The first frame a helper sends.
public struct BeaconHello: Sendable, Equatable {
    public var protocolVersion: Int
    public var helperVersion: String
    /// What the helper claims; the verified pid comes from the audit token and is the only one used.
    public var claimedPID: Int
    public var secret: String?

    static func parse(_ data: Data) -> BeaconHello? {
        guard let value = try? JSONValue.parse(data), case .object = value, let version = value["protocol"]?.intValue else { return nil }
        let secret = value["secret"]?.stringValue
        return BeaconHello(protocolVersion: version, helperVersion: value["helper"]?.stringValue ?? "", claimedPID: value["pid"]?.intValue ?? 0,
                           secret: (secret?.isEmpty ?? true) ? nil : secret)
    }
}

/// Length-prefixed frames: 4 bytes big-endian, then the payload (one JSON-RPC message, or the hello).
public enum BeaconFrame {
    public static let maxHello = 4 * 1024
    public static let maxMessage = 1024 * 1024

    public static func encode(_ payload: Data) -> Data {
        var length = UInt32(payload.count).bigEndian
        return Data(bytes: &length, count: 4) + payload
    }

    /// Reads one frame. nil on end of stream, an error, a timeout (`deadline`) or a frame longer than `limit`.
    public static func read(fd: Int32, limit: Int, deadline: Date? = nil) -> Data? {
        guard let header = readExactly(fd: fd, count: 4, deadline: deadline) else { return nil }
        let length = Int(UInt32(bigEndian: header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }))
        guard length <= limit else { return nil }
        if length == 0 { return Data() }
        return readExactly(fd: fd, count: length, deadline: deadline)
    }

    static func readExactly(fd: Int32, count: Int, deadline: Date?) -> Data? {
        var out = Data(count: count)
        var got = 0
        while got < count {
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else { return nil }
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let r = poll(&p, 1, Int32(min(remaining * 1000, 60_000)))
                if r < 0 { if errno == EINTR { continue }; return nil }
                if r == 0 { continue }
            }
            let n = out.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress! + got, count - got) }
            if n > 0 { got += n } else if n < 0 && (errno == EINTR || errno == EAGAIN) { continue } else { return nil }
        }
        return out
    }

    static func writeAll(fd: Int32, _ data: Data) -> Bool {
        var sent = 0
        return data.withUnsafeBytes { buffer in
            while sent < data.count {
                let n = Darwin.write(fd, buffer.baseAddress! + sent, data.count - sent)
                if n > 0 { sent += n } else if n < 0 && errno == EINTR { continue } else { return false }
            }
            return true
        }
    }
}

public enum BeaconSocketError: Error, Equatable, LocalizedError {
    case pathTooLong(Int)
    case alreadyRunning
    case failed(String)
    public var errorDescription: String? {
        switch self {
        case .pathTooLong(let n): "The Beacon socket path is \(n) characters; the limit is \(BeaconSocketServer.maxPathLength)."
        case .alreadyRunning: "Another process is already listening on the Beacon socket."
        case .failed(let why): "Beacon could not start: \(why)"
        }
    }
}

/// One accepted connection that passed verification.
public final class BeaconConnection: Sendable {
    public let id = UUID()
    private let fd: Int32
    private let writeLock = NSLock()
    private let closed = Mutex(false)
    private nonisolated(unsafe) var descriptorClosed = false   // guarded by writeLock

    init(fd: Int32) { self.fd = fd }

    /// Sends one frame. Safe to call from any thread; does nothing once closed. A write that fails or times out (the peer stopped
    /// reading) ends the connection instead of holding a thread.
    public func send(_ payload: Data) {
        let ok = writeLock.withLock { () -> Bool in
            guard !descriptorClosed else { return true }
            return BeaconFrame.writeAll(fd: fd, BeaconFrame.encode(payload))
        }
        if !ok { close() }
    }

    /// Wakes the reader and ends the connection at once. The reading thread releases the descriptor with ``finish()``.
    public func close() {
        let first = closed.withLock { c -> Bool in
            defer { c = true }
            return !c
        }
        if first { shutdown(fd, SHUT_RDWR) }
    }

    /// Releases the descriptor, under the write lock, so no write can reach a reused descriptor number.
    func finish() {
        close()
        writeLock.withLock {
            guard !descriptorClosed else { return }
            descriptorClosed = true
            Darwin.close(fd)
        }
    }

    var isClosed: Bool { closed.withLock { $0 } }
}

/// The Beacon socket (ARCHITECTURE-MAC section 10.1): a Unix domain socket in a 0700 folder, mode 0600, accepted through a
/// dispatch source (no timers, no polling: an idle Beacon with no clients wakes nothing). Every connection is verified before a
/// byte is read from it.
public final class BeaconSocketServer: Sendable {
    /// `sockaddr_un.sun_path` holds 104 bytes including the terminator.
    public static let maxPathLength = 103
    public static let maxUnverified = 8
    public static let backlog: Int32 = 32

    public typealias Connect = @Sendable (BeaconPeer, BeaconHello, BeaconConnection) -> MCPSession?
    public typealias Rejected = @Sendable (BeaconRejection) -> Void
    public typealias Closed = @Sendable (BeaconConnection) -> Void

    private struct State {
        var listener: DispatchSourceRead?
        var path: String?
        var unverified = 0
        var connections: [UUID: BeaconConnection] = [:]
    }

    private let verifier: any BeaconPeerVerifying
    private let helloTimeout: TimeInterval
    private let connect: Connect
    private let rejected: Rejected
    private let closed: Closed
    private let queue = DispatchQueue(label: "app.wheelhouse.beacon.accept", qos: .userInitiated)
    private let state = Mutex(State())

    public init(verifier: any BeaconPeerVerifying, helloTimeout: TimeInterval = 5, rejected: @escaping Rejected = { _ in }, closed: @escaping Closed = { _ in }, connect: @escaping Connect) {
        self.verifier = verifier
        self.helloTimeout = helloTimeout
        self.rejected = rejected
        self.closed = closed
        self.connect = connect
    }

    public var isRunning: Bool { state.withLock { $0.listener != nil } }
    public var connectionCount: Int { state.withLock { $0.connections.count } }

    // MARK: Start and stop

    public func start(at url: URL) throws {
        guard !isRunning else { return }
        let path = url.path
        guard path.utf8.count <= Self.maxPathLength else { throw BeaconSocketError.pathTooLong(path.utf8.count) }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        chmod(directory.path, 0o700)
        // A stale socket file is removed only when nothing answers on it.
        if FileManager.default.fileExists(atPath: path) {
            if Self.probe(path) { throw BeaconSocketError.alreadyRunning }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BeaconSocketError.failed("socket: \(String(cString: strerror(errno)))") }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0 else {
            let why = String(cString: strerror(errno))
            close(fd)
            throw BeaconSocketError.failed("bind: \(why)")
        }
        chmod(path, 0o600)
        guard listen(fd, Self.backlog) == 0 else {
            close(fd)
            unlink(path)
            throw BeaconSocketError.failed("listen")
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptPending(on: fd) }
        // The descriptor is closed only here, after the source is cancelled, so its number cannot be reused under it.
        source.setCancelHandler { close(fd) }
        state.withLock {
            $0.listener = source
            $0.path = path
        }
        source.resume()
    }

    /// Closes the listener and every connection. Returns when the work is done (a few milliseconds).
    public func stop() {
        let (listener, path, connections) = state.withLock { s -> (DispatchSourceRead?, String?, [BeaconConnection]) in
            defer { s.listener = nil; s.path = nil; s.connections = [:] }
            return (s.listener, s.path, Array(s.connections.values))
        }
        listener?.cancel()
        if let path { unlink(path) }
        connections.forEach { $0.close() }
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (i, byte) in path.utf8.enumerated() { buffer[i] = byte }
        }
        return address
    }

    private static func probe(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = Self.address(path)
        return withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } } == 0
    }

    // MARK: Accept

    private func acceptPending(on listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            if fd < 0 { return }   // EAGAIN: nothing more waiting
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var sendTimeout = timeval(tv_sec: 5, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, socklen_t(MemoryLayout<timeval>.size))
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            let admitted = state.withLock { s -> Bool in
                guard s.unverified < Self.maxUnverified else { return false }
                s.unverified += 1
                return true
            }
            guard admitted else {
                close(fd)
                rejected(.tooManyConnections)
                continue
            }
            let thread = Thread { [self] in serve(fd) }
            thread.name = "app.wheelhouse.beacon.connection"
            thread.stackSize = 512 * 1024
            thread.start()
        }
    }

    private func serve(_ fd: Int32) {
        let result = verifier.verify(fd: fd)
        guard case .success(let peer) = result else {
            state.withLock { $0.unverified -= 1 }
            if case .failure(let reason) = result { rejected(reason) }
            close(fd)
            return
        }
        // Only now is the peer's first byte read.
        guard let frame = BeaconFrame.read(fd: fd, limit: BeaconFrame.maxHello, deadline: Date().addingTimeInterval(helloTimeout)),
              let hello = BeaconHello.parse(frame) else {
            state.withLock { $0.unverified -= 1 }
            rejected(.badHello)
            close(fd)
            return
        }
        let connection = BeaconConnection(fd: fd)
        let registered = state.withLock { s -> Bool in
            s.unverified -= 1
            guard s.listener != nil else { return false }
            s.connections[connection.id] = connection
            return true
        }
        guard registered else { close(fd); return }
        let session = connect(peer, hello, connection)
        guard let session else {
            state.withLock { _ = $0.connections.removeValue(forKey: connection.id) }
            connection.finish()
            return
        }
        connection.send(Data("{\"ok\":true}".utf8))
        while !connection.isClosed, let message = BeaconFrame.read(fd: fd, limit: BeaconFrame.maxMessage) { session.receive(message) }
        session.close()
        state.withLock { _ = $0.connections.removeValue(forKey: connection.id) }
        closed(connection)
        connection.finish()
    }
}
#endif
