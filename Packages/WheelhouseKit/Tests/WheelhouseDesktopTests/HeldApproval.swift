#if os(macOS)
import Foundation

/// A two-way handshake for a test that must act while a confirmation sheet is open. The confirmer calls ``hold()``, which tells the
/// test the request is parked and waits for ``release()``; the test calls ``waitUntilHeld()`` and ``release()``. Both signals are
/// buffered, so neither side can miss the other however the tasks are scheduled (no polling, no sleeps).
final class HeldApproval: Sendable {
    private let entered = AsyncStream<Void>.makeStream()
    private let released = AsyncStream<Void>.makeStream()

    /// Called from the confirmer: announce that the request is waiting, then wait to be released.
    func hold() async {
        entered.continuation.yield()
        for await _ in released.stream { return }
    }

    /// Returns once the confirmer is holding the request.
    func waitUntilHeld() async {
        for await _ in entered.stream { return }
    }

    /// Lets the held confirmer return.
    func release() { released.continuation.yield() }
}
#endif
