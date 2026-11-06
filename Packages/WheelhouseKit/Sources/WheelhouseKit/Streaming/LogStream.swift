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

/// A live (or finished) log tail backed by `client.logs`, with a bounded ring buffer, 10 Hz batching,
/// automatic reconnect on transient errors and optional merge of several containers.
@MainActor @Observable
public final class LogStream {
    public enum State: Equatable, Sendable {
        case idle, connecting, streaming
        /// The server ended the stream (container exited or a non-follow request completed).
        case finished
        /// Stopped because the app went to the background.
        case paused
        case failed(KubeError)
    }

    public private(set) var state: State = .idle
    /// Bumped whenever `buffer` changed; observe this to refresh views.
    public private(set) var revision = 0
    @ObservationIgnored public private(set) var buffer: LogRingBuffer
    public private(set) var totalReceived = 0
    public private(set) var droppedCount = 0
    /// Number of lines dropped by the last flush (views use it to adjust their scroll position).
    @ObservationIgnored public private(set) var lastFlushDropped = 0

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var pending: [LogLine] = []
    @ObservationIgnored private var flushTask: Task<Void, Never>?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var lastStamp: [String: Double] = [:]
    @ObservationIgnored private var lastWallClock: Date?
    @ObservationIgnored private var config: Config?
    @ObservationIgnored private var openStreams = 0

    private struct Config {
        var client: any KubeClientProtocol
        var namespace: String
        var pod: String
        var containers: [String?]
        var options: LogOptions
    }

    public init(capacity: Int = 20_000) { buffer = LogRingBuffer(capacity: capacity) }

    public var capacity: Int { buffer.capacity }
    public var count: Int { buffer.count }
    public var isLive: Bool { state == .streaming || state == .connecting }

    // MARK: Control

    /// Starts reading. Pass several `containers` to merge their output (each line gets a `source`).
    public func start(client: any KubeClientProtocol, namespace: String, pod: String, containers: [String?], options: LogOptions) {
        stop(to: .idle)
        var opts = options
        opts.timestamps = true // always request; the UI hides them on demand
        config = Config(client: client, namespace: namespace, pod: pod, containers: containers.isEmpty ? [nil] : containers, options: opts)
        lastStamp = [:]
        clear()
        connect(reconnecting: false)
    }

    /// Cancels the connections. The buffer is kept.
    public func stop(to newState: State = .paused) {
        generation += 1
        for t in tasks { t.cancel() }
        tasks.removeAll()
        flushTask?.cancel(); flushTask = nil
        flush()
        openStreams = 0
        if state != .finished { state = newState }
    }

    /// Re-opens a paused or ended stream, deduplicating against what was already received.
    public func resume() {
        guard config != nil else { return }
        stop(to: .idle)
        connect(reconnecting: true)
    }

    public func clear() {
        buffer.removeAll()
        pending.removeAll()
        droppedCount = 0
        lastFlushDropped = 0
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
            appendMarker("Stream reconnected")
            cfg.options.tailLines = nil
            if let last = lastWallClock { cfg.options.sinceSeconds = max(2, Int(Date().timeIntervalSince(last).rounded(.up)) + 2) }
        }
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
                        self.ingest(line, key: key)
                    }
                    self?.streamEnded(gen: gen, error: nil)
                } catch {
                    self?.streamEnded(gen: gen, error: (error as? KubeError) ?? .unreachable(cause: error.localizedDescription))
                }
            })
        }
    }

    private func ingest(_ line: LogLine, key: String) {
        var l = line
        l.id = takeID()
        if let ts = l.timestamp.flatMap(LogTimestamp.parse) { lastStamp[key] = max(lastStamp[key] ?? 0, ts) }
        lastWallClock = Date()
        reconnectAttempts = 0
        pending.append(l)
        totalReceived += 1
        scheduleFlush()
    }

    private func streamEnded(gen: Int, error: KubeError?) {
        guard gen == generation else { return }
        openStreams = max(0, openStreams - 1)
        if let error, error != .cancelled {
            if error.isTransient, let cfg = config, cfg.options.follow, reconnectAttempts < 5 {
                reconnectAttempts += 1
                let attempt = reconnectAttempts
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(min(Double(attempt) * 1.5, 10)))
                    guard let self, self.generation == gen else { return }
                    self.stop(to: .idle)
                    self.connect(reconnecting: true)
                }
                return
            }
            for t in tasks { t.cancel() }
            tasks.removeAll()
            flush()
            state = .failed(error)
            return
        }
        reconnectAttempts = 0
        if openStreams == 0 {
            flush()
            state = .finished
        }
    }
    @ObservationIgnored private var reconnectAttempts = 0

    private func scheduleFlush() {
        guard flushTask == nil else { return }
        flushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(100))
            guard !Task.isCancelled else { return }
            self?.flushTask = nil
            self?.flush()
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
        lastFlushDropped = buffer.append(contentsOf: batch)
        droppedCount = buffer.droppedCount
        revision += 1
    }
}
