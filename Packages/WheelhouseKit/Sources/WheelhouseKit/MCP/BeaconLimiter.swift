import Foundation
import Synchronization

/// 10 calls per second and 4 concurrent calls per client (ARCHITECTURE-MAC section 10.2). One limiter is shared by every session of a client.
public final class BeaconLimiter: Sendable {
    public static let defaultPerSecond = 10
    public static let defaultConcurrent = 4

    public enum Refusal: String, Sendable { case rateLimited = "rate_limited", tooManyConcurrent = "too_many_concurrent_calls" }

    private struct State { var starts: [TimeInterval] = []; var running = 0 }
    private let state = Mutex(State())
    private let perSecond: Int
    private let concurrent: Int
    private let clock: @Sendable () -> TimeInterval

    public init(perSecond: Int = defaultPerSecond, concurrent: Int = defaultConcurrent,
                clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.perSecond = perSecond
        self.concurrent = concurrent
        self.clock = clock
    }

    /// Reserves a slot. When it returns nil the caller must call ``finish()`` exactly once.
    public func begin() -> Refusal? {
        let now = clock()
        return state.withLock { s in
            s.starts.removeAll { now - $0 >= 1 }
            if s.running >= concurrent { return .tooManyConcurrent }
            if s.starts.count >= perSecond { return .rateLimited }
            s.starts.append(now)
            s.running += 1
            return nil
        }
    }

    public func finish() { state.withLock { $0.running = max(0, $0.running - 1) } }
    public var running: Int { state.withLock { $0.running } }
}
