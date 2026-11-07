import Foundation
import Synchronization

/// Events produced by an ``ExecSession``.
public enum ExecEvent: Sendable {
    /// The socket is connected (the first frame was written). `protocol` is the negotiated subprotocol when known.
    case opened(protocol: String?)
    /// Bytes for the terminal (stdout and stderr merged).
    case output(Data)
    /// The remote command finished (status channel).
    case exited(ExecStatus)
    /// The socket closed. `error` is nil for a clean close.
    case closed(error: KubeError?)
}

/// Predefined shell choices for the command picker.
public enum ShellChoice: Hashable, Sendable, Identifiable {
    /// bash when present, otherwise sh.
    case auto
    case sh
    case bash
    case ash
    case custom(String)

    public var id: String { title }
    public static var standard: [ShellChoice] { [.auto, .sh, .bash, .ash] }

    public var title: String {
        switch self {
        case .auto: "Auto (bash, else sh)"
        case .sh: "/bin/sh"
        case .bash: "/bin/bash"
        case .ash: "/bin/ash"
        case .custom(let c): c
        }
    }

    public var shortName: String {
        switch self {
        case .auto: "sh"
        case .sh: "sh"
        case .bash: "bash"
        case .ash: "ash"
        case .custom(let c): c.split(separator: " ").first.map(String.init) ?? c
        }
    }

    public var command: [String] {
        switch self {
        case .auto: ["/bin/sh", "-c", "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"]
        case .sh: ["/bin/sh"]
        case .bash: ["/bin/bash"]
        case .ash: ["/bin/ash"]
        case .custom(let c):
            // Split on whitespace, honouring simple single/double quotes.
            ShellChoice.tokenize(c)
        }
    }

    static func tokenize(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        var started = false
        for ch in s {
            if let q = quote {
                if ch == q { quote = nil } else { cur.append(ch) }
            } else if ch == "\"" || ch == "'" {
                quote = ch; started = true
            } else if ch == " " || ch == "\t" {
                if started || !cur.isEmpty { out.append(cur); cur = ""; started = false }
            } else { cur.append(ch) }
        }
        if started || !cur.isEmpty { out.append(cur) }
        return out
    }
}

/// Writes frames to a socket strictly in the order they were enqueued.
///
/// `enqueue` is synchronous and thread-safe (it only yields into an unbounded `AsyncStream`), so callers that fire it from a
/// delegate callback keep their call order. One long-lived consumer task awaits each send before starting the next, which an
/// actor method or a task per write cannot guarantee (actor reentrancy lets later writes overtake earlier ones).
final class OrderedFrameWriter: Sendable {
    private let continuation: AsyncStream<Data>.Continuation
    private let consumer: Task<Void, Never>

    /// - Parameters:
    ///   - send: Writes one frame; the next frame is only started once this returns.
    ///   - onFirstSent: Called once after the first frame was written successfully.
    ///   - onFailure: Called once if a write throws; later frames are dropped.
    init(send: @escaping @Sendable (Data) async throws -> Void,
         onFirstSent: @escaping @Sendable () -> Void = {},
         onFailure: @escaping @Sendable (Error) -> Void) {
        let (stream, cont) = AsyncStream<Data>.makeStream(bufferingPolicy: .unbounded)
        continuation = cont
        consumer = Task {
            var first = true
            for await frame in stream {
                if Task.isCancelled { break }
                do {
                    try await send(frame)
                    if first { first = false; onFirstSent() }
                } catch {
                    if !Task.isCancelled { onFailure(error) }
                    break
                }
            }
            cont.finish()
        }
    }

    func enqueue(_ frame: Data) { continuation.yield(frame) }

    /// Drops everything not yet written and stops the consumer.
    func cancel() {
        continuation.finish()
        consumer.cancel()
    }

    deinit { continuation.finish(); consumer.cancel() }
}

/// An interactive exec session speaking the Kubernetes WebSocket channel protocol (`v5.channel.k8s.io`, falling back to v4).
public actor ExecSession {
    public nonisolated let events: AsyncStream<ExecEvent>
    private nonisolated let continuation: AsyncStream<ExecEvent>.Continuation
    private let client: any KubeClientProtocol
    public nonisolated let namespace: String
    public nonisolated let pod: String
    public nonisolated let options: ExecOptions

    private var socket: KubeWebSocket?
    private var receiveTask: Task<Void, Never>?
    /// Ordered stdin / resize queue; set in `start`, read from the nonisolated `send` / `resize`.
    private nonisolated let writer = Mutex<OrderedFrameWriter?>(nil)
    private var finished = false
    private var gotStatus = false
    public private(set) var negotiatedProtocol: String?

    public init(client: any KubeClientProtocol, namespace: String, pod: String, options: ExecOptions) {
        self.client = client
        self.namespace = namespace
        self.pod = pod
        self.options = options
        let (stream, cont) = AsyncStream<ExecEvent>.makeStream(bufferingPolicy: .unbounded)
        self.events = stream
        self.continuation = cont
    }

    deinit {
        writer.withLock { $0?.cancel() }
        receiveTask?.cancel()
        socket?.close()
        continuation.finish()
    }

    /// Opens the socket and starts reading. Throws immediately for errors known before connecting
    /// (read-only cluster, demo mode, invalid credentials); connection failures arrive as `.closed(error:)`.
    public func start(cols: Int = 80, rows: Int = 24) async throws {
        guard socket == nil else { return }
        // A dynamic credential (exec plugin) is resolved before the synchronous socket builder runs. No-op for stored tokens.
        try await client.prepareStreaming()
        // The actor was released at the await: another start or a close may have run meanwhile.
        guard socket == nil, !finished else { return }
        let ws = try client.execWebSocket(namespace: namespace, pod: pod, options: options)
        socket = ws
        ws.resume()
        receiveTask = Task { [weak self] in await self?.receiveLoop(ws) }
        // The first write only completes once the upgrade succeeded, so it doubles as the "opened" signal.
        // Every later frame (stdin, resize) goes through the same ordered queue.
        let w = OrderedFrameWriter(
            send: { try await ws.send($0) },
            onFirstSent: { [weak self] in Task { await self?.markOpened(ws) } },
            onFailure: { [weak self] error in Task { await self?.finish(error: Self.map(error, ws)) } })
        writer.withLock { $0 = w }
        w.enqueue(ChannelFrame.resize(cols: cols, rows: rows).encoded())
    }

    private func markOpened(_ ws: KubeWebSocket) {
        guard !finished else { return }
        negotiatedProtocol = (ws.task.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Sec-WebSocket-Protocol")
        continuation.yield(.opened(protocol: negotiatedProtocol))
    }

    /// Queues keyboard input. Synchronous: bytes are written to the socket in exactly the order this is called.
    public nonisolated func send(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        writer.withLock { $0 }?.enqueue(ChannelFrame.stdin(bytes).encoded())
    }

    /// Queues a terminal resize behind any stdin already queued.
    public nonisolated func resize(cols: Int, rows: Int) {
        writer.withLock { $0 }?.enqueue(ChannelFrame.resize(cols: cols, rows: rows).encoded())
    }

    /// Ends the session locally.
    public func close() {
        guard !finished else { return }
        finished = true
        writer.withLock { $0?.cancel() }
        receiveTask?.cancel()
        socket?.close()
        continuation.yield(.closed(error: nil))
        continuation.finish()
    }

    private func receiveLoop(_ ws: KubeWebSocket) async {
        while !Task.isCancelled {
            do {
                switch try await ws.receive() {
                case .data(let data): handle(data)
                case .string(let text): handle(Data(text.utf8))
                @unknown default: break
                }
            } catch {
                if gotStatus || Task.isCancelled { finish(error: nil) } else { finish(error: Self.map(error, ws)) }
                return
            }
        }
    }

    private func handle(_ message: Data) {
        guard let frame = ChannelFrame.decode(message) else { return }
        switch frame.channel {
        case ExecChannel.stdout, ExecChannel.stderr:
            if !frame.payload.isEmpty { continuation.yield(.output(frame.payload)) }
        case ExecChannel.status:
            if let status = ExecStatus.parse(frame.payload) {
                gotStatus = true
                continuation.yield(.exited(status))
            }
        default: break
        }
    }

    private func finish(error: KubeError?) {
        guard !finished else { return }
        finished = true
        writer.withLock { $0?.cancel() }
        receiveTask?.cancel()
        socket?.close()
        continuation.yield(.closed(error: error))
        continuation.finish()
    }

    /// Maps WebSocket failures to a ``KubeError``, using the HTTP response of the failed upgrade when available.
    static func map(_ error: Error, _ ws: KubeWebSocket) -> KubeError {
        if let kube = error as? KubeError { return kube }
        if let http = ws.task.response as? HTTPURLResponse, http.statusCode >= 400 {
            switch http.statusCode {
            case 401: return .unauthorized(message: nil)
            case 403: return .forbidden(verb: "create", resource: "pods/exec", namespace: nil, message: "The API server refused the connection (403).")
            case 404: return .notFound(message: "The pod or container no longer exists.")
            case 400: return .invalid(message: "The container is not running or the command could not start (400).", causes: [])
            default: return .server(Status(status: "Failure", message: "Upgrade failed with HTTP \(http.statusCode)", code: http.statusCode))
            }
        }
        if let url = error as? URLError {
            let failure = ws.tlsFailure()
            // The upgrade response already arrived: the TLS handshake is over, so a later SSL-domain / -1005 error is a dropped socket.
            let upgraded = ws.task.response != nil
            let identityFailure = ws.identityFailure()
            let certMissing = ws.clientCertificateMissing()
            switch url.code {
            case .cancelled: return failure == nil ? .cancelled : .tlsUntrusted(summary: failure?.summary)
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
                 .serverCertificateNotYetValid:
                return .tlsUntrusted(summary: failure?.summary)
            case .secureConnectionFailed, .clientCertificateRejected, .clientCertificateRequired:
                if upgraded { return .unreachable(cause: url.localizedDescription) }
                if failure != nil { return .tlsUntrusted(summary: failure?.summary) }
                return TLSDiagnostics.handshakeError(for: url, clientIdentityFailure: identityFailure, clientCertificateMissing: certMissing) ?? .unreachable(cause: url.localizedDescription)
            case .networkConnectionLost:
                if !upgraded, failure == nil, TLSDiagnostics.extract(from: url).isSSLDomain,
                   let e = TLSDiagnostics.handshakeError(for: url, clientIdentityFailure: identityFailure, clientCertificateMissing: certMissing) { return e }
                return .unreachable(cause: url.localizedDescription)
            default: return .unreachable(cause: url.localizedDescription)
            }
        }
        return .unreachable(cause: error.localizedDescription)
    }
}
