import Foundation
import Network
import Synchronization

/// Thread-safe byte counters shared between connection tasks.
final class ForwardCounters: Sendable {
    private let state = Mutex<(down: Int, up: Int, open: Int, total: Int)>((0, 0, 0, 0))
    func addDown(_ n: Int) { state.withLock { $0.down += n } }
    func addUp(_ n: Int) { state.withLock { $0.up += n } }
    func opened() { state.withLock { $0.open += 1; $0.total += 1 } }
    func closed() { state.withLock { $0.open = max(0, $0.open - 1) } }
    var snapshot: (down: Int, up: Int, open: Int, total: Int) { state.withLock { $0 } }
}

/// Manages local-port → pod/service forwards. Each accepted TCP connection on `127.0.0.1:<local>` is tunnelled over
/// its own `v4.channel.k8s.io` WebSocket to the pod's `portforward` subresource.
public actor PortForwardManager {
    private final class Entry {
        let id: UUID
        let clusterID: ClusterID
        let clusterName: String
        let client: any KubeClientProtocol
        let target: PortForwardTarget
        var localPort: Int
        var state: PortForwardState = .starting
        let startedAt = Date()
        var endedAt: Date?
        var listener: NWListener?
        var connectionTasks: [UUID: Task<Void, Never>] = [:]
        var resolved: (endpoint: ResolvedEndpoint, at: Date)?
        var lastError: String?
        var retryTask: Task<Void, Never>?
        let counters = ForwardCounters()

        init(id: UUID, clusterID: ClusterID, clusterName: String, client: any KubeClientProtocol, target: PortForwardTarget, localPort: Int) {
            self.id = id; self.clusterID = clusterID; self.clusterName = clusterName
            self.client = client; self.target = target; self.localPort = localPort
        }
    }

    private var entries: [UUID: Entry] = [:]
    /// Bumped by ``stopAll(clusterID:)`` so in-flight `start` calls for that cluster abort.
    private var clusterEpoch: [ClusterID: Int] = [:]
    private var order: [UUID] = []
    private let queue = DispatchQueue(label: "app.wheelhouse.portforward")
    private var tickTask: Task<Void, Never>?
    private var continuations: [UUID: AsyncStream<[PortForwardInfo]>.Continuation] = [:]
    /// How long a service → pod resolution is reused before checking endpoints again.
    private let resolutionTTL: TimeInterval = 10

    public init() {}

    // MARK: Observation

    /// Emits the list of forwards whenever something changes and about twice a second while forwards are live (byte counters).
    public func updates() -> AsyncStream<[PortForwardInfo]> {
        let id = UUID()
        let (stream, cont) = AsyncStream<[PortForwardInfo]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuations[id] = cont
        cont.onTermination = { [weak self] _ in Task { await self?.removeContinuation(id) } }
        cont.yield(snapshot())
        return stream
    }

    private func removeContinuation(_ id: UUID) { continuations[id] = nil }

    public func snapshot() -> [PortForwardInfo] { order.compactMap { entries[$0].map(info(for:)) } }

    private func info(for e: Entry) -> PortForwardInfo {
        let c = e.counters.snapshot
        return PortForwardInfo(id: e.id, clusterID: e.clusterID, clusterName: e.clusterName, target: e.target, localPort: e.localPort,
                               state: e.state, startedAt: e.startedAt, endedAt: e.endedAt, bytesDown: c.down, bytesUp: c.up,
                               openConnections: c.open, totalConnections: c.total, resolvedPod: e.resolved?.endpoint.pod, lastError: e.lastError)
    }

    private func publish() {
        let snap = snapshot()
        for c in continuations.values { c.yield(snap) }
        let anyLive = entries.values.contains { $0.state == .active || $0.state == .reconnecting }
        if anyLive, tickTask == nil {
            tickTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(500))
                    await self?.tick()
                }
            }
        } else if !anyLive {
            tickTask?.cancel(); tickTask = nil
        }
    }

    private func tick() { publish() }

    // MARK: Lifecycle

    /// Starts a forward. `localPort == 0` picks a free port. Throws if the port can't be bound.
    /// `readOnly` is the cluster's read-only flag (port-forwarding is refused unless `allowExecInReadOnly`).
    @discardableResult
    public func start(clusterID: ClusterID, clusterName: String, client: any KubeClientProtocol,
                      target: PortForwardTarget, localPort: Int = 0,
                      readOnly: Bool = false, allowExecInReadOnly: Bool = false) async throws -> PortForwardInfo {
        if readOnly && !allowExecInReadOnly { throw KubeError.readOnly }
        if localPort != 0, entries.values.contains(where: { $0.localPort == localPort && $0.state.isLive }) {
            throw PortForwardError.portInUse(localPort)
        }
        let epoch = clusterEpoch[clusterID, default: 0]
        let entry = Entry(id: UUID(), clusterID: clusterID, clusterName: clusterName, client: client, target: target, localPort: localPort)
        // Validate the target before binding so permission/readiness problems surface in the setup sheet.
        let resolver = PortForwardResolver(client: client)
        let endpoint = try await resolver.resolve(target)
        entry.resolved = (endpoint, Date())
        let (listener, port) = try await bind(entry)
        // The cluster may have been removed or edited while we were resolving / binding.
        guard clusterEpoch[clusterID, default: 0] == epoch else { listener.cancel(); throw CancellationError() }
        entry.listener = listener
        entry.localPort = port
        entries[entry.id] = entry
        order.append(entry.id)
        entry.state = .active
        publish()
        return info(for: entry)
    }

    public func stop(_ id: UUID) {
        guard let e = entries[id] else { return }
        tearDown(e)
        e.state = .stopped
        e.endedAt = Date()
        publish()
    }

    /// Removes a stopped forward from the list.
    public func remove(_ id: UUID) {
        if let e = entries[id], e.state.isLive { tearDown(e) }
        entries[id] = nil
        order.removeAll { $0 == id }
        publish()
    }

    public func stopAll() { for id in order { stop(id) } }

    /// Stops every forward bound to a cluster whose credentials, access mode or existence changed. Forwards started
    /// concurrently are refused too. They would otherwise keep using the old client (deleted credentials, a cleared read-only flag).
    public func stopAll(clusterID: ClusterID) {
        clusterEpoch[clusterID, default: 0] += 1
        for id in order where entries[id]?.clusterID == clusterID { stop(id) }
    }

    /// Releases sockets while the app is in the background; entries are kept as `.suspended`.
    public func pauseAll() {
        for e in entries.values where e.state.isLive {
            tearDown(e)
            e.state = .suspended
        }
        publish()
    }

    /// Re-binds the same local ports after returning to the foreground.
    public func resumeAll() async {
        let pending = entries.values.filter { $0.state == .suspended || $0.state == .reconnecting }
        for e in pending {
            e.state = .reconnecting
            publish()
            do {
                let (listener, port) = try await bind(e)
                // `stop()`, removal or a new `pauseAll()` may have run while we awaited: don't resurrect the forward.
                guard entries[e.id] === e, e.state == .reconnecting else { listener.cancel(); continue }
                e.listener?.cancel()
                e.listener = listener
                e.localPort = port
                e.state = .active
                e.lastError = nil
            } catch {
                guard entries[e.id] === e, e.state == .reconnecting else { continue }
                e.state = .failed(error.localizedDescription)
                e.lastError = error.localizedDescription
            }
        }
        publish()
    }

    public func info(id: UUID) -> PortForwardInfo? { entries[id].map(info(for:)) }

    private func tearDown(_ e: Entry) {
        e.retryTask?.cancel(); e.retryTask = nil
        e.listener?.stateUpdateHandler = nil
        e.listener?.newConnectionHandler = nil
        e.listener?.cancel()
        e.listener = nil
        for t in e.connectionTasks.values { t.cancel() }
        e.connectionTasks.removeAll()
    }

    // MARK: Listening

    /// Binds a loopback listener for the entry. The caller installs it (after re-checking the entry's state).
    private func bind(_ e: Entry) async throws -> (NWListener, Int) {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let port: NWEndpoint.Port = e.localPort == 0 ? .any : (NWEndpoint.Port(rawValue: UInt16(clamping: e.localPort)) ?? .any)
        params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        let listener: NWListener
        do { listener = try NWListener(using: params) } catch { throw PortForwardError.listenerFailed(error.localizedDescription) }

        let id = e.id
        let requestedPort = e.localPort
        listener.newConnectionHandler = { [weak self] conn in
            Task { await self?.accept(conn, entryID: id) }
        }
        let assigned: Int = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int, Error>) in
            let once = Mutex(false)
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                case .waiting(let err):
                    // Never becomes ready (e.g. the port is blocked): fail like `.failed` instead of hanging `start`.
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        listener.cancel()
                        cont.resume(throwing: PortForwardError.listenerFailed(err.localizedDescription))
                    }
                case .failed(let err):
                    if once.withLock({ let was = $0; $0 = true; return !was }) {
                        if case .posix(let code) = err, code == .EADDRINUSE { cont.resume(throwing: PortForwardError.portInUse(requestedPort)) }
                        else { cont.resume(throwing: PortForwardError.listenerFailed(err.localizedDescription)) }
                    } else {
                        Task { await self?.listenerDied(entryID: id, message: err.localizedDescription) }
                    }
                case .cancelled:
                    if once.withLock({ let was = $0; $0 = true; return !was }) { cont.resume(throwing: CancellationError()) }
                default: break
                }
            }
            listener.start(queue: queue)
        }
        return (listener, assigned)
    }

    private func listenerDied(entryID: UUID, message: String) {
        guard let e = entries[entryID], e.state == .active else { return }
        e.state = .reconnecting
        e.lastError = message
        e.listener?.cancel(); e.listener = nil
        publish()
        e.retryTask = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                if Task.isCancelled { return }
                if await self?.retryListen(entryID) == true { return }
                delay = min(delay * 2, 15)
            }
        }
    }

    private func retryListen(_ id: UUID) async -> Bool {
        guard let e = entries[id], e.state == .reconnecting else { return true }
        do {
            let (listener, port) = try await bind(e)
            guard entries[id] === e, e.state == .reconnecting else { listener.cancel(); return true }
            e.listener?.cancel()
            e.listener = listener
            e.localPort = port
            e.state = .active
            e.lastError = nil
            publish()
            return true
        } catch { return false }
    }

    // MARK: Connections

    private func accept(_ conn: NWConnection, entryID: UUID) {
        guard let e = entries[entryID], e.state == .active || e.state == .reconnecting else { conn.cancel(); return }
        let connID = UUID()
        let counters = e.counters
        let target = e.target
        let client = e.client
        counters.opened()
        let task = Task { [weak self] in
            let outcome = await ForwardPump.run(connection: conn, client: client, target: target, counters: counters,
                                                resolve: { [weak self] force in
                                                    guard let self else { throw CancellationError() }
                                                    return try await self.endpoint(for: entryID, forceRefresh: force)
                                                },
                                                queue: self?.queue ?? .global())
            counters.closed()
            await self?.connectionEnded(entryID: entryID, connID: connID, error: outcome)
        }
        e.connectionTasks[connID] = task
    }

    private func connectionEnded(entryID: UUID, connID: UUID, error: String?) {
        guard let e = entries[entryID] else { return }
        e.connectionTasks[connID] = nil
        if let error { e.lastError = error } else if e.state == .active { e.lastError = nil }
        publish()
    }

    private func endpoint(for id: UUID, forceRefresh: Bool) async throws -> ResolvedEndpoint {
        guard let e = entries[id] else { throw CancellationError() }
        if !forceRefresh, let r = e.resolved, Date().timeIntervalSince(r.at) < resolutionTTL { return r.endpoint }
        let resolver = PortForwardResolver(client: e.client)
        let ep = try await resolver.resolve(e.target, preferring: e.resolved?.endpoint.pod)
        e.resolved = (ep, Date())
        return ep
    }
}

// MARK: - Per-connection pump

enum ForwardPump {
    /// Tunnels one local TCP connection. Returns an error description when the tunnel failed, nil on a clean close.
    static func run(connection conn: NWConnection, client: any KubeClientProtocol, target: PortForwardTarget, counters: ForwardCounters,
                    resolve: @escaping @Sendable (Bool) async throws -> ResolvedEndpoint, queue: DispatchQueue) async -> String? {
        conn.start(queue: queue)
        defer { conn.cancel() }
        var lastFailure: String?
        // One retry with a fresh resolution if the pod disappeared between resolve and connect.
        for attempt in 0..<2 {
            do {
                let endpoint = try await resolve(attempt > 0)
                let ws = try client.portForwardWebSocket(namespace: target.namespace, pod: endpoint.pod, ports: [endpoint.port])
                ws.resume()
                let result = await tunnel(conn: conn, ws: ws, port: endpoint.port, counters: counters)
                switch result {
                case .finished: return nil
                case .failedBeforeData(let msg):
                    lastFailure = msg
                    if attempt == 0, target.kind == .service { continue }
                    return msg
                case .failed(let msg): return msg
                }
            } catch is CancellationError {
                return nil
            } catch {
                return (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
        }
        return lastFailure
    }

    enum Result { case finished, failedBeforeData(String), failed(String) }

    static func tunnel(conn: NWConnection, ws: KubeWebSocket, port: Int, counters: ForwardCounters) async -> Result {
        let sentOutgoing = Mutex(false)
        let gotIncoming = Mutex(false)
        let errorText = Mutex<String?>(nil)
        let outgoing = PortForwardDemux(port: port)

        await withTaskCancellationHandler {
            await withTaskGroup(of: Bool.self) { group in
                // cluster -> local client. Returns true when the whole tunnel should end.
                group.addTask {
                    var demux = PortForwardDemux(port: port)
                    while !Task.isCancelled {
                        do {
                            let message = try await ws.receive()
                            let data: Data
                            switch message {
                            case .data(let d): data = d
                            case .string(let s): data = Data(s.utf8)
                            @unknown default: continue
                            }
                            switch demux.process(data) {
                            case .data(let bytes):
                                gotIncoming.withLock { $0 = true }
                                counters.addDown(bytes.count)
                                try await conn.sendAsync(bytes)
                            case .error(let text):
                                errorText.withLock { $0 = text.trimmingCharacters(in: .whitespacesAndNewlines) }
                                return true
                            case .none: break
                            }
                        } catch { return true }
                    }
                    return true
                }
                // local client -> cluster. Returns false at local EOF so the other direction can drain.
                group.addTask {
                    while !Task.isCancelled {
                        do {
                            let (data, complete) = try await conn.receiveAsync()
                            if let data, !data.isEmpty {
                                sentOutgoing.withLock { $0 = true }
                                counters.addUp(data.count)
                                try await ws.send(outgoing.outgoing(data))
                            }
                            if complete { return false }
                        } catch { return true }
                    }
                    return true
                }
                var results = 0
                for await shouldEnd in group {
                    results += 1
                    if shouldEnd {
                        // URLSession/NWConnection awaits don't observe task cancellation; close both ends to unblock them.
                        ws.close(); conn.cancel()
                        group.cancelAll()
                        break
                    }
                    // Local side finished sending; give the cluster side a grace period to deliver the response.
                    group.addTask {
                        try? await Task.sleep(for: .seconds(8))
                        return true
                    }
                }
            }
        } onCancel: {
            conn.cancel()
            ws.close()
        }
        ws.close()
        if !gotIncoming.withLock({ $0 }), let tls = ws.tlsFailure() {
            return .failed("The cluster’s certificate is not trusted (\(tls.summary)).")
        }
        if let text = errorText.withLock({ $0 }), !text.isEmpty {
            // Only safe to retry on a fresh tunnel while none of the client's bytes were consumed by this one.
            return (gotIncoming.withLock { $0 } || sentOutgoing.withLock { $0 }) ? .failed(text) : .failedBeforeData(text)
        }
        if !gotIncoming.withLock({ $0 }), !sentOutgoing.withLock({ $0 }) {
            if ws.task.closeCode != .invalid, ws.task.closeCode != .normalClosure {
                return .failedBeforeData("The cluster closed the tunnel (\(ws.task.closeCode.rawValue)).")
            }
            if let http = ws.task.response as? HTTPURLResponse, http.statusCode >= 400 {
                return .failedBeforeData("The API server refused the port-forward (HTTP \(http.statusCode)).")
            }
        }
        return .finished
    }
}

extension NWConnection {
    func sendAsync(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) } else { cont.resume() }
            })
        }
    }

    /// Returns the next chunk and whether the peer finished sending.
    func receiveAsync() async throws -> (Data?, Bool) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data?, Bool), Error>) in
            receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let error { cont.resume(throwing: error) } else { cont.resume(returning: (data, isComplete)) }
            }
        }
    }
}
