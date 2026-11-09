#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

/// An open upgraded stream (exec, attach, port-forward), so it can be closed when the situation changes.
struct StreamRecord: Sendable {
    var clusterID: ClusterID
    var sessionID: UUID
    var openedOnProduction: Bool
    var kind: GangwayStreamKind
    var close: @Sendable (String) -> Void
}

/// What every connection shares. One per `GangwayServer`.
public final class GangwayContext: Sendable {
    public let registry: SessionRegistry
    public let grants: GrantStore
    public let clusters: any GangwayClusterProviding
    public let connector: UpstreamConnector
    public let activity: any ActivityLogging
    public let metrics: GangwayMetrics
    public let resolver: any PeerResolving
    let holds: HoldCoordinator
    let streams = Mutex<[UUID: StreamRecord]>([:])
    private let lockedFlag = Mutex(false)
    private let port = Mutex<UInt16>(0)
    /// Idle keep-alive timeout (ARCHITECTURE-MAC 3.6 step 10).
    let idleTimeout: Duration

    public init(registry: SessionRegistry, grants: GrantStore, clusters: any GangwayClusterProviding, connector: UpstreamConnector,
                confirmer: any GangwayConfirming, activity: any ActivityLogging, metrics: GangwayMetrics = GangwayMetrics(),
                resolver: any PeerResolving = PeerResolver(), batchingWindow: Duration = .seconds(2), holdTimeout: Duration = .seconds(120),
                idleTimeout: Duration = .seconds(120)) {
        self.registry = registry
        self.grants = grants
        self.clusters = clusters
        self.connector = connector
        self.activity = activity
        self.metrics = metrics
        self.resolver = resolver
        self.holds = HoldCoordinator(confirmer: confirmer, grants: grants, registry: registry, window: batchingWindow, timeout: holdTimeout)
        self.idleTimeout = idleTimeout
    }

    var listenerPort: UInt16 {
        get { port.withLock { $0 } }
        set { port.withLock { $0 = newValue } }
    }
    public var isLocked: Bool { lockedFlag.withLock { $0 } }
    public func setLocked(_ locked: Bool) { lockedFlag.withLock { $0 = locked } }

    func register(stream record: StreamRecord) -> UUID {
        let id = UUID()
        streams.withLock { $0[id] = record }
        return id
    }
    func unregister(stream id: UUID) { streams.withLock { $0[id] = nil } }
    public var openStreamCount: Int { streams.withLock { $0.count } }

    /// Closes every open stream that matches. Returns how many were closed.
    @discardableResult
    func closeStreams(reason: String, where predicate: (StreamRecord) -> Bool) -> Int {
        let matching = streams.withLock { s -> [StreamRecord] in
            let hits = s.filter { predicate($0.value) }
            hits.keys.forEach { s[$0] = nil }
            return Array(hits.values)
        }
        matching.forEach { $0.close(reason) }
        return matching.count
    }

    func audit(_ entry: ActivityEntry) { activity.record(entry) }
}

/// Holds requests for a decision (ARCHITECTURE-MAC 3.6 step 5): one sheet per session at a time, a batching window, a timeout.
actor HoldCoordinator {
    enum Outcome: Sendable { case declined, approved }

    private struct Waiting {
        var hold: GangwayHold
        var peerBound: Bool
        var continuation: CheckedContinuation<Outcome, Never>
    }
    private var pending: [UUID: [Waiting]] = [:]
    private var presenting: Set<UUID> = []
    /// kubectl retries a refused WebSocket upgrade over SPDY at once. A declined stream is remembered for a moment (per session and path)
    /// so the person is asked once, not twice.
    private var declinedStreams: [String: ContinuousClock.Instant] = [:]
    static let declineMemory: Duration = .seconds(3)
    private let confirmer: any GangwayConfirming
    private let grants: GrantStore
    private let registry: SessionRegistry
    private let window: Duration
    private let timeout: Duration

    init(confirmer: any GangwayConfirming, grants: GrantStore, registry: SessionRegistry, window: Duration, timeout: Duration) {
        self.confirmer = confirmer
        self.grants = grants
        self.registry = registry
        self.window = window
        self.timeout = timeout
    }

    /// Waits for the answer to one held request. The approval itself is recorded in the grant store (a batch approval for exactly the
    /// listed requests, or a command grant); streams are approved without a grant.
    func request(_ hold: GangwayHold, peerBound: Bool) async -> Outcome {
        let streamKey = "\(hold.sessionID)|\(hold.path)"
        if hold.isStream, let at = declinedStreams[streamKey], ContinuousClock.now - at < Self.declineMemory { return .declined }
        let outcome = await enqueue(hold, peerBound: peerBound)
        if hold.isStream {
            declinedStreams = declinedStreams.filter { ContinuousClock.now - $0.value < Self.declineMemory }
            if outcome == .declined { declinedStreams[streamKey] = .now }
        }
        return outcome
    }

    private func enqueue(_ hold: GangwayHold, peerBound: Bool) async -> Outcome {
        await withCheckedContinuation { continuation in
            pending[hold.sessionID, default: []].append(Waiting(hold: hold, peerBound: peerBound, continuation: continuation))
            if !presenting.contains(hold.sessionID) {
                presenting.insert(hold.sessionID)
                Task { await self.drain(sessionID: hold.sessionID) }
            }
        }
    }

    private func drain(sessionID: UUID) async {
        var first = true
        while let queue = pending[sessionID], !queue.isEmpty {
            // The batching window applies once per round, and only to non-stream requests.
            if first, !queue[0].hold.isStream, window > .zero { try? await Task.sleep(for: window) }
            first = false
            var round = pending[sessionID] ?? []
            let batch: [Waiting]
            if round[0].hold.isStream { batch = [round.removeFirst()] } else {
                batch = round.filter { !$0.hold.isStream }
                round.removeAll { !$0.hold.isStream }
            }
            pending[sessionID] = round
            let outcome = await present(batch, sessionID: sessionID)
            for waiting in batch { waiting.continuation.resume(returning: outcome) }
            first = true
        }
        pending[sessionID] = nil
        presenting.remove(sessionID)
    }

    private func present(_ batch: [Waiting], sessionID: UUID) async -> Outcome {
        guard let session = registry.session(id: sessionID), !session.isRevoked else { return .declined }
        let holds = batch.map(\.hold)
        var kind: GangwaySheet.Kind = batch[0].hold.isStream ? .stream : .requests
        if kind == .requests, batch.allSatisfy(\.peerBound), let command = session.reportedCommand, CommandEligibility.isEligible(command.line) {
            kind = .command(line: command.line)
        }
        let sheet = GangwaySheet(kind: kind, holds: holds)
        // The timeout does not wait for the confirmer: a sheet that ignores cancellation still ends at the deadline.
        let confirmer = self.confirmer, timeout = self.timeout
        let approved = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let once = AnswerOnce(continuation)
            let timer = Task {
                try? await Task.sleep(for: timeout)
                once.answer(false)
            }
            Task {
                let answer = await confirmer.confirm(sheet)
                timer.cancel()
                once.answer(answer)
            }
        }
        guard approved, !session.isRevoked else { return .declined }
        switch kind {
        case .stream: break
        case .command:
            if let command = session.reportedCommand { grants.grantCommand(session: session, command: command) }
            // Requests of the sheet that the command grant does not cover (not the foreground job) still need their own approval.
            grants.approveBatch(session: session, holdIDs: holds.map(\.id))
        case .requests: grants.approveBatch(session: session, holdIDs: holds.map(\.id))
        }
        return .approved
    }
}

/// Resumes a continuation with the first answer only.
final class AnswerOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<Bool, Never>?>
    init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = Mutex(continuation) }
    func answer(_ value: Bool) {
        let c = continuation.withLock { c -> CheckedContinuation<Bool, Never>? in
            defer { c = nil }
            return c
        }
        c?.resume(returning: value)
    }
}
#endif
