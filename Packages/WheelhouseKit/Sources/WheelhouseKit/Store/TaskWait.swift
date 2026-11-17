import Foundation

public extension Task where Success == Never, Failure == Never {
    /// Suspends until the calling task is cancelled, without arming a timer.
    ///
    /// The consumers of a store (`.task { await store.run() }`) used to wait with
    /// `while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }`. A cancelled sleep returns at once, but its one-hour
    /// dispatch timer stays armed until it fires, so every closed screen left its consumers' timers (and their sleep jobs) behind for an
    /// hour: the P2 tab-churn check counted about 50 more `dispatch_source_t` after each round of 20 tabs opened and closed.
    static func waitUntilCancelled() async {
        let gate = CancellationGate()
        await withTaskCancellationHandler {
            await withCheckedContinuation { gate.install($0) }
        } onCancel: {
            gate.open()
        }
    }
}

/// Resumes the waiting continuation once, whether cancellation comes before or after it is installed.
private final class CancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func install(_ c: CheckedContinuation<Void, Never>) {
        lock.lock()
        if isOpen { lock.unlock(); c.resume(); return }
        continuation = c
        lock.unlock()
    }

    func open() {
        lock.lock()
        isOpen = true
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume()
    }
}
