import Foundation
import Testing
@testable import WheelhouseKit

/// P2: `Task.waitUntilCancelled()` replaces the one-hour sleep loops of store consumers.
@Suite("Task.waitUntilCancelled")
struct TaskWaitTests {
    @Test func returnsWhenTheTaskIsCancelled() async {
        let waiter = Task { await Task.waitUntilCancelled(); return Task.isCancelled }
        try? await Task.sleep(for: .milliseconds(20))
        waiter.cancel()
        #expect(await waiter.value)
    }

    @Test func returnsAtOnceForAnAlreadyCancelledTask() async {
        let waiter = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await Task.waitUntilCancelled()
            return true
        }
        #expect(await waiter.value)
    }

    @MainActor @Test func aStoreConsumerStopsWhenItsTaskIsCancelled() async {
        let store = ResourceStore<Pod>(client: ScriptedClient())
        let consumer = Task { await store.run() }
        for _ in 0..<10_000 where store.consumerCount == 0 { await Task.yield() }
        #expect(store.consumerCount == 1)
        consumer.cancel()
        await consumer.value
        #expect(store.consumerCount == 0)
    }
}
