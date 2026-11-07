import Foundation
import Observation

/// Parses RFC3339 timestamps (with optional fraction) to seconds since 1970 without `DateFormatter` overhead.
public enum LogTimestamp {
    public static func parse(_ s: String) -> Double? {
        let b = Array(s.utf8)
        guard b.count >= 19 else { return nil }
        func num(_ range: Range<Int>) -> Int? {
            var v = 0
            for i in range { let c = b[i]; guard c >= 0x30, c <= 0x39 else { return nil }; v = v * 10 + Int(c - 0x30) }
            return v
        }
        guard let y = num(0..<4), let mo = num(5..<7), let d = num(8..<10), let h = num(11..<13), let mi = num(14..<16), let sec = num(17..<19) else { return nil }
        var idx = 19
        var frac = 0.0
        if idx < b.count, b[idx] == 0x2E {
            idx += 1
            var scale = 0.1
            while idx < b.count, b[idx] >= 0x30, b[idx] <= 0x39 { frac += Double(b[idx] - 0x30) * scale; scale /= 10; idx += 1 }
        }
        var offset = 0
        if idx < b.count, b[idx] == 0x2B || b[idx] == 0x2D {
            let sign = b[idx] == 0x2B ? 1 : -1
            let digits = b[(idx + 1)...].filter { $0 != 0x3A }
            if digits.count >= 4 {
                let hh = Int(digits[0] - 0x30) * 10 + Int(digits[1] - 0x30)
                let mm = Int(digits[2] - 0x30) * 10 + Int(digits[3] - 0x30)
                offset = sign * (hh * 3600 + mm * 60)
            }
        }
        // Days from civil (Howard Hinnant).
        let yy = mo <= 2 ? y - 1 : y
        let era = (yy >= 0 ? yy : yy - 399) / 400
        let yoe = yy - era * 400
        let doy = (153 * (mo + (mo > 2 ? -3 : 9)) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        let days = era * 146097 + doe - 719468
        return Double(days * 86400 + h * 3600 + mi * 60 + sec - offset) + frac
    }
}

/// Why a stream is paused (no connection open) rather than finished.
public enum LogPauseReason: Sendable, Equatable {
    /// The app moved to the background; resumes when it returns.
    case background
    /// The user left the screen without pinning the stream; resumes when the screen is shown again.
    case screenLeft
    /// Another stream took over this pod/container, or the global follow cap was hit. Only the user resumes it.
    case preempted
}

/// Global bookkeeping of open `follow=true` log requests. Every follow makes the kubelet create an inotify watcher on
/// the node, a scarce resource, so the app keeps (a) at most ONE follow per pod/container and (b) at most
/// `maxConcurrentFollows` in total, closing the older stream first.
@MainActor
public final class LogFollowRegistry {
    public static let shared = LogFollowRegistry()
    public var maxConcurrentFollows = 6

    private struct Entry { weak var stream: LogStream?; var keys: Set<String>; var since: Date }
    private var entries: [ObjectIdentifier: Entry] = [:]

    /// Number of follow requests currently held.
    public var activeFollowCount: Int { entries.values.reduce(0) { $0 + ($1.stream == nil ? 0 : $1.keys.count) } }

    /// Registers `keys` for `stream`, first closing every other stream that follows the same pod/container and then the
    /// oldest ones while the global cap is exceeded. Old connections are cancelled before the new one is opened.
    func claim(_ stream: LogStream, keys: Set<String>) {
        let id = ObjectIdentifier(stream)
        entries[id] = nil
        for (otherID, e) in entries where !e.keys.isDisjoint(with: keys) {
            entries[otherID] = nil
            e.stream?.suspend(reason: .preempted, note: "Stopped: another view started following this container")
        }
        entries = entries.filter { $0.value.stream != nil }
        while activeFollowCount + keys.count > maxConcurrentFollows, let oldest = entries.min(by: { $0.value.since < $1.value.since }) {
            entries[oldest.key] = nil
            oldest.value.stream?.suspend(reason: .preempted, note: "Stopped: too many live log streams (limit \(maxConcurrentFollows))")
        }
        entries[id] = Entry(stream: stream, keys: keys, since: Date())
    }

    func release(_ stream: LogStream) { entries[ObjectIdentifier(stream)] = nil }
}

/// A live (or finished) log tail backed by `client.logs`, with a bounded ring buffer, batched UI updates,
/// exponential-backoff reconnects, and a polling fallback when the node cannot stream (inotify exhausted).
@MainActor @Observable
public final class LogStream {
    public enum State: Equatable, Sendable {
        case idle, connecting, streaming
        /// The server ended the stream (container exited or a non-follow request completed).
        case finished
        /// No connection is open; see ``pauseReason``.
        case paused
        case failed(KubeError)
    }

    /// How new lines arrive.
    public enum Mode: Equatable, Sendable {
        /// One `follow=true` request per container.
        case follow
        /// Repeated non-follow requests (`sinceTime=…`): used when the node cannot create log watchers.
        case polling
    }

    public private(set) var state: State = .idle
    public private(set) var mode: Mode = .follow
    public private(set) var pauseReason: LogPauseReason?
    /// Set when the node reported that it cannot stream logs; the stream then runs in ``Mode/polling``.
    public private(set) var problem: LogStreamProblem?
    /// Bumped whenever `buffer` changed; observe this to refresh views.
    public private(set) var revision = 0
    @ObservationIgnored public private(set) var buffer: LogRingBuffer
    public private(set) var totalReceived = 0
    public private(set) var droppedCount = 0
    /// Number of lines dropped by the last flush (views use it to adjust their scroll position).
    @ObservationIgnored public private(set) var lastFlushDropped = 0
    /// Lines ever appended to `buffer` and ever dropped from it; views use the deltas to update incrementally.
    @ObservationIgnored public private(set) var appendedTotal = 0
    /// Bumped by ``clear()``; deltas are only meaningful within one epoch.
    @ObservationIgnored public private(set) var epoch = 0
    /// Seconds between polls in polling mode (before the energy policy is applied).
    @ObservationIgnored public var pollInterval: TimeInterval = 4

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var lastBatchCount = 0
    @ObservationIgnored private var pending: [LogLine] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var reconnectTask: Task<Void, Never>?
    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastStamp: [String: Double] = [:]
    @ObservationIgnored private var dedupers: [String: LogPollDeduper] = [:]
    @ObservationIgnored private var recent: [String: [String]] = [:]
    @ObservationIgnored private var lastWallClock: Date?
    @ObservationIgnored private var connectedAt: Date?
    @ObservationIgnored private var backoff = LogReconnectBackoff()
    @ObservationIgnored private var config: Config?
    @ObservationIgnored private var openStreams = 0

    private struct Config {
        var client: any KubeClientProtocol
        var scope: String
        var namespace: String
        var pod: String
        var containers: [String?]
        var options: LogOptions
    }

    /// `limits` default to `.unlimited` (iOS, unchanged). The Mac passes `LogLimits.desktop` (section 12.3.2 caps).
    public init(capacity: Int = 20_000, limits: LogLimits = .unlimited) {
        buffer = LogRingBuffer(capacity: capacity, limits: limits)
        self.limits = limits
        if limits.maxTotalBytes > 0 { LogMemoryBudget.shared.register(self) }
    }

    @ObservationIgnored public let limits: LogLimits
    /// False while no view shows this stream; the global byte budget drops the oldest lines of non-visible streams first.
    @ObservationIgnored public var isVisible = true

    isolated deinit {
        for t in tasks { t.cancel() }
        reconnectTask?.cancel(); pollTask?.cancel(); flushTask?.cancel()
        LogFollowRegistry.shared.release(self)
    }

    /// Drops all but the last `n` lines (memory pressure). Views see an epoch-neutral change through `revision`.
    @discardableResult
    public func trim(keepingLast n: Int) -> Int {
        let dropped = buffer.trim(keepingLast: n)
        if dropped > 0 { droppedCount = buffer.droppedCount; lastFlushDropped = dropped; revision += 1 }
        return dropped
    }

    public var capacity: Int { buffer.capacity }
    public var count: Int { buffer.count }
    public var isLive: Bool { state == .streaming || state == .connecting }
    /// Open `follow=true` connections right now (0 while paused, finished or polling).
    public var openFollowCount: Int { mode == .follow && isLive ? max(openStreams, state == .connecting ? 1 : 0) : 0 }

    // MARK: Control

    /// Starts reading. Pass several `containers` to merge their output (each line gets a `source`).
    /// `scope` identifies the cluster, so two clusters with the same pod name never count as one.
    public func start(client: any KubeClientProtocol, namespace: String, pod: String, containers: [String?], options: LogOptions, scope: String = "") {
        stop(to: .idle)
        var opts = options
        opts.timestamps = true // always request; the UI hides them on demand
        var targets = containers.isEmpty ? [nil] : containers
        let cap = LogFollowRegistry.shared.maxConcurrentFollows
        let clamped = opts.follow && targets.count > cap
        if clamped { targets = Array(targets.prefix(cap)) }
        config = Config(client: client, scope: scope, namespace: namespace, pod: pod, containers: targets, options: opts)
        lastStamp = [:]
        dedupers = [:]
        recent = [:]
        problem = nil
        mode = .follow
        backoff.reset()
        pauseReason = nil
        clear()
        if clamped { appendMarker("Showing first \(cap) containers (live stream limit)") }
        connect(reconnecting: false)
    }

    /// Cancels the connections. The buffer is kept.
    public func stop(to newState: State = .paused) {
        generation += 1
        for t in tasks { t.cancel() }
        tasks.removeAll()
        reconnectTask?.cancel(); reconnectTask = nil
        pollTask?.cancel(); pollTask = nil
        flushTask?.cancel(); flushTask = nil
        flush()
        openStreams = 0
        LogFollowRegistry.shared.release(self)
        if newState != .paused { pauseReason = nil }
        if state != .finished { state = newState }
    }

    /// Closes the connection and remembers why, so the right trigger can bring it back.
    public func suspend(reason: LogPauseReason, note: String? = nil) {
        guard isLive else { return }
        stop(to: .paused)
        pauseReason = reason
        if let note { appendMarker(note) }
    }

    /// Re-opens a paused or ended stream, deduplicating against what was already received.
    public func resume() {
        guard config != nil else { return }
        stop(to: .idle)
        pauseReason = nil
        backoff.reset()
        connect(reconnecting: true)
    }

    public func clear() {
        buffer.removeAll()
        pending.removeAll()
        droppedCount = 0
        lastFlushDropped = 0
        appendedTotal = 0
        epoch += 1
        revision += 1
    }

    /// Inserts an app-generated divider line.
    public func appendMarker(_ text: String) {
        pending.append(LogLine(id: takeID(), message: text, kind: .marker))
        scheduleFlush()
    }

    // MARK: Internals

    private func takeID() -> Int { defer { nextID += 1 }; return nextID }

    private func connect(reconnecting: Bool) {
        guard var cfg = config else { return }
        generation += 1
        let gen = generation
        state = .connecting
        if reconnecting {
            appendMarker(mode == .polling ? "Polling resumed" : "Stream reconnected")
            cfg.options.tailLines = nil
            if let last = lastWallClock { cfg.options.sinceSeconds = max(2, Int(Date().timeIntervalSince(last).rounded(.up)) + 2) }
        }
        if mode == .polling { startPolling(); return }
        // One follow request per pod/container: whoever else follows the same one is closed before we connect.
        if cfg.options.follow {
            LogFollowRegistry.shared.claim(self, keys: Set(cfg.containers.map { "\(cfg.scope)/\(cfg.namespace)/\(cfg.pod)/\($0 ?? "")" }))
        }
        connectedAt = Date()
        let multi = cfg.containers.count > 1
        openStreams = cfg.containers.count
        for container in cfg.containers {
            var o = cfg.options
            o.container = container
            let stream = cfg.client.logs(namespace: cfg.namespace, pod: cfg.pod, options: o)
            let source = multi ? container : nil
            let key = container ?? ""
            let skipUntil = reconnecting ? lastStamp[key] : nil
            tasks.append(Task { [weak self] in
                var skip = skipUntil
                do {
                    for try await raw in stream {
                        guard let self, self.generation == gen else { return }
                        if self.state == .connecting { self.state = .streaming }
                        let line = LogParser.parse(id: 0, raw: raw, source: source)
                        if let limit = skip {
                            if let ts = line.timestamp.flatMap(LogTimestamp.parse), ts <= limit { continue }
                            skip = nil
                        }
                        self.ingest(line, raw: raw, key: key)
                    }
                    // A cancelled task (sibling failed, stop, suspend) must not report the stream as finished.
                    guard !Task.isCancelled else { return }
                    self?.streamEnded(gen: gen, key: key, error: nil)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.streamEnded(gen: gen, key: key, error: (error as? KubeError) ?? .unreachable(cause: error.localizedDescription))
                }
            })
        }
    }

    private func ingest(_ line: LogLine, raw: String, key: String) {
        var l = line
        l.id = takeID()
        if let ts = l.timestamp.flatMap(LogTimestamp.parse) { lastStamp[key] = max(lastStamp[key] ?? 0, ts) }
        dedupers[key, default: LogPollDeduper()].accept(raw)
        var tail = recent[key, default: []]
        tail.append(raw)
        if tail.count > 3 { tail.removeFirst(tail.count - 3) }
        recent[key] = tail
        lastWallClock = Date()
        pending.append(l)
        totalReceived += 1
        scheduleFlush()
    }

    private func streamEnded(gen: Int, key: String, error: KubeError?) {
        guard gen == generation else { return }
        openStreams = max(0, openStreams - 1)
        let follow = config?.options.follow == true
        // The kubelet's "failed to create fsnotify watcher" arrives as the last line (or as the error body): the node
        // cannot follow logs. Reconnecting would only create more pressure; switch to polling instead.
        if follow, mode == .follow, let problem = LogStreamProblem.detect(error: error) ?? LogStreamProblem.detect(lines: recent[key] ?? []) {
            enterPolling(problem)
            return
        }
        if let error, error != .cancelled {
            if error.isTransient, follow, let base = backoff.nextDelay(afterRunning: Date().timeIntervalSince(connectedAt ?? Date())) {
                let delay = base * Double.random(in: 0.8...1.2)
                generation += 1                      // sibling containers' cancelled loops must be ignored
                let waitGen = generation
                for t in tasks { t.cancel() }
                tasks.removeAll()
                openStreams = 0
                LogFollowRegistry.shared.release(self)   // no connection is open while we wait
                state = .connecting
                reconnectTask?.cancel()
                reconnectTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(delay))
                    guard !Task.isCancelled, let self, self.generation == waitGen else { return }
                    self.reconnectTask = nil
                    self.stop(to: .idle)
                    self.connect(reconnecting: true)
                }
                return
            }
            generation += 1
            for t in tasks { t.cancel() }
            tasks.removeAll()
            flush()
            LogFollowRegistry.shared.release(self)
            state = .failed(error)
            return
        }
        if openStreams == 0 {
            flush()
            LogFollowRegistry.shared.release(self)
            state = .finished
        }
    }

    // MARK: Polling fallback

    private func enterPolling(_ found: LogStreamProblem) {
        problem = found
        mode = .polling
        generation += 1
        for t in tasks { t.cancel() }
        tasks.removeAll()
        openStreams = 0
        LogFollowRegistry.shared.release(self)
        appendMarker("Live streaming unavailable on this node, polling for new lines")
        flush()
        startPolling()
    }

    private func startPolling() {
        guard let cfg = config else { return }
        generation += 1
        let gen = generation
        state = .streaming
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self, self.generation == gen else { return }
                let failure = await self.pollOnce(cfg, gen: gen)
                guard !Task.isCancelled, self.generation == gen else { return }
                if let failure, !failure.isTransient {
                    // 403 / 404 and the like will not fix themselves: stop instead of polling forever.
                    self.generation += 1
                    self.flush()
                    self.pollTask = nil
                    self.state = .failed(failure)
                    return
                }
                failures = failure == nil ? 0 : failures + 1
                let base = failure == nil ? self.pollInterval : Swift.min(30, self.pollInterval * pow(2, Double(failures)))
                try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(base)))
            }
        }
    }

    /// One non-follow request per container, de-duplicated against what was already shown. Returns the first error, if any.
    /// A container is polled with `sinceTime` once a timestamp is known; until then with the original tail/since options
    /// (never with an unbounded request, which would download the whole log every few seconds).
    private func pollOnce(_ cfg: Config, gen: Int) async -> KubeError? {
        let multi = cfg.containers.count > 1
        var failure: KubeError?
        for container in cfg.containers {
            let key = container ?? ""
            var o = cfg.options
            o.follow = false
            o.container = container
            if let since = dedupers[key]?.lastRawStamp { o.sinceTime = since; o.sinceSeconds = nil; o.tailLines = nil }
            var lines: [String] = []
            do {
                for try await raw in cfg.client.logs(namespace: cfg.namespace, pod: cfg.pod, options: o) { lines.append(raw) }
            } catch {
                let e = (error as? KubeError) ?? .unreachable(cause: error.localizedDescription)
                if e != .cancelled { failure = failure ?? e }
                continue
            }
            guard generation == gen, !Task.isCancelled else { return nil }
            let fresh = dedupers[key, default: LogPollDeduper()].accept(lines)
            for raw in fresh {
                var l = LogParser.parse(id: 0, raw: raw, source: multi ? container : nil)
                l.id = takeID()
                if let ts = l.timestamp.flatMap(LogTimestamp.parse) { lastStamp[key] = max(lastStamp[key] ?? 0, ts) }
                pending.append(l)
                totalReceived += 1
            }
            if !fresh.isEmpty { lastWallClock = Date(); scheduleFlush() }
        }
        return failure
    }

    // MARK: Flushing

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            // 100 ms normally; slower in Low Power Mode / when the device is hot, and slower again for a firehose:
            // nobody reads 200 lines a second, but every table update costs a fixed amount.
            let rate = Self.adaptiveInterval(lastBatch: self?.lastBatchCount ?? 0)
            let seconds = Swift.max(EnergyPolicy.current.publishInterval, rate)
            try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
        }
    }

    /// Publish interval for a given size of the previous batch (lines per flush).
    nonisolated static func adaptiveInterval(lastBatch: Int) -> TimeInterval {
        switch lastBatch {
        case 0..<30: 0.1
        case 30..<100: 0.25
        default: 0.5
        }
    }

    private func flush() {
        guard !pending.isEmpty else { return }
        var batch = pending
        pending.removeAll(keepingCapacity: true)
        if config.map({ $0.containers.count > 1 }) == true, batch.count > 1 {
            batch.sort { (a, b) in
                guard let x = a.timestamp.flatMap(LogTimestamp.parse), let y = b.timestamp.flatMap(LogTimestamp.parse) else { return a.id < b.id }
                return x == y ? a.id < b.id : x < y
            }
        }
        if limits.maxLineBytes != .max { batch = batch.map(limits.truncated) }
        lastBatchCount = batch.count
        lastFlushDropped = buffer.append(contentsOf: batch)
        appendedTotal += batch.count
        droppedCount = buffer.droppedCount
        revision += 1
        if limits.maxTotalBytes > 0 { LogMemoryBudget.shared.rebalance() }
    }
}

/// Keeps all log streams together under `LogLimits.maxTotalBytes` (64 MB on the Mac): the oldest lines of non-visible streams go
/// first. Streams register themselves when their limits enforce a total; iOS streams never do.
@MainActor
public final class LogMemoryBudget {
    public static let shared = LogMemoryBudget()
    private struct Ref { weak var stream: LogStream? }
    private var refs: [Ref] = []
    public var maxTotalBytes = LogLimits.desktop.maxTotalBytes

    func register(_ stream: LogStream) {
        refs.removeAll { $0.stream == nil }
        refs.append(Ref(stream: stream))
    }

    public var streams: [LogStream] { refs.compactMap(\.stream) }
    public var totalBytes: Int { streams.reduce(0) { $0 + $1.buffer.byteCount } }

    /// Trims non-visible streams (largest first, a quarter at a time) while the total is over budget, then, if only visible streams
    /// remain over budget, the largest visible one.
    public func rebalance() {
        var total = totalBytes
        guard total > maxTotalBytes else { return }
        refs.removeAll { $0.stream == nil }
        var guardCount = 0
        while total > maxTotalBytes, guardCount < 64 {
            guardCount += 1
            let live = streams
            let hidden = live.filter { !$0.isVisible && $0.count > 1 }
            guard let victim = (hidden.isEmpty ? live.filter { $0.count > 1 } : hidden).max(by: { $0.buffer.byteCount < $1.buffer.byteCount }) else { return }
            victim.trim(keepingLast: max(1, victim.count * 3 / 4))
            total = totalBytes
        }
    }
}
