#if os(macOS)
import Testing
import Foundation
@testable import WheelhouseDesktop

private final class FakeSource: MemoryPressureSource, @unchecked Sendable {
    let lock = NSLock()
    var handler: (@Sendable (MemoryPressureLevel) -> Void)?
    var stopped = false
    func start(_ handler: @escaping @Sendable (MemoryPressureLevel) -> Void) -> @Sendable () -> Void {
        lock.withLock { self.handler = handler; stopped = false }
        return { [weak self] in self?.lock.withLock { self?.stopped = true } }
    }
    func fire(_ level: MemoryPressureLevel) { lock.withLock { handler }?(level) }
}

@Suite("Energy seams")
struct EnergySeamTests {
    @Test func memoryPressureMonitorForwardsEventsAndStops() {
        let source = FakeSource()
        let monitor = MemoryPressureMonitor(source: source)
        let seen = Seen()
        monitor.start { seen.add($0) }
        source.fire(.warning)
        source.fire(.critical)
        #expect(seen.levels == [.warning, .critical])
        monitor.stop()
        #expect(source.lock.withLock { source.stopped })
    }

    @Test func occlusionVisibilityRule() {
        #expect(OcclusionMonitor.isVisible(visible: true, miniaturized: false, occlusionVisible: true))
        #expect(!OcclusionMonitor.isVisible(visible: true, miniaturized: true, occlusionVisible: true))
        #expect(!OcclusionMonitor.isVisible(visible: true, miniaturized: false, occlusionVisible: false))
        #expect(!OcclusionMonitor.isVisible(visible: false, miniaturized: false, occlusionVisible: true))
    }

    @Test func powerSourceReadIsAPlainBool() {
        _ = PowerSourceMonitor.onBattery   // a single IOKit read; the value depends on the machine
    }
}

private final class Seen: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [MemoryPressureLevel] = []
    func add(_ l: MemoryPressureLevel) { lock.withLock { stored.append(l) } }
    var levels: [MemoryPressureLevel] { lock.withLock { stored } }
}
#endif
