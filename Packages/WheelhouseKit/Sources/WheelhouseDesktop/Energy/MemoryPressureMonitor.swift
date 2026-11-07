#if os(macOS)
import Foundation
import Dispatch

public enum MemoryPressureLevel: Sendable, Equatable { case warning, critical }

/// A source of memory-pressure events, so tests can inject a fake (`MemoryPressureTests`, M1b).
public protocol MemoryPressureSource: Sendable {
    /// Starts delivering events; the returned closure stops them.
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) -> @Sendable () -> Void
}

public struct SystemMemoryPressureSource: MemoryPressureSource {
    public init() {}
    public func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) -> @Sendable () -> Void {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        source.setEventHandler { [weak source] in
            guard let data = source?.data else { return }
            handler(data.contains(.critical) ? .critical : .warning)
        }
        source.resume()
        return { source.cancel() }
    }
}

/// Wraps `DispatchSource.makeMemoryPressureSource`. M1a ships the seam; M1b wires the trimming (§12.3.4 item 9).
public final class MemoryPressureMonitor: Sendable {
    private let source: any MemoryPressureSource
    private let stopper = StopHandle()

    public init(source: any MemoryPressureSource = SystemMemoryPressureSource()) { self.source = source }

    /// Starts observing. `handler` runs off the main actor.
    public func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) {
        stop()
        stopper.set(source.start(handler))
    }

    public func stop() { stopper.take()?() }

    deinit { stop() }
}

/// Tiny lock around the stop closure.
final class StopHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stop: (@Sendable () -> Void)?
    func set(_ f: @escaping @Sendable () -> Void) { lock.withLock { stop = f } }
    func take() -> (@Sendable () -> Void)? { lock.withLock { defer { stop = nil }; return stop } }
}
#endif
