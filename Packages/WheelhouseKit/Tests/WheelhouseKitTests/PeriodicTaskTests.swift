import Testing
import Foundation
@testable import WheelhouseKit

@Suite("PeriodicTask")
struct PeriodicTaskTests {
    @Test func validationRule() {
        #expect(PeriodicTask.isValid(interval: 1, hiddenInterval: nil))
        #expect(PeriodicTask.isValid(interval: 30, hiddenInterval: 60))
        #expect(PeriodicTask.isValid(interval: 30, hiddenInterval: 600))
        #expect(!PeriodicTask.isValid(interval: 0.5, hiddenInterval: nil))
        #expect(!PeriodicTask.isValid(interval: 30, hiddenInterval: 59))
        #expect(!PeriodicTask.isValid(interval: 30, hiddenInterval: 10))
    }

    @Test func delayScalesWithTheEnergyPolicyAndStopsWhenHiddenWithoutCadence() {
        let nominal = EnergyPolicy()
        let lowPower = EnergyPolicy(isLowPowerMode: true)
        let critical = EnergyPolicy(isLowPowerMode: true, thermalState: .critical)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: nil, windowsVisible: true, policy: nominal) == 30)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: nil, windowsVisible: true, policy: lowPower) == 60)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: nil, windowsVisible: true, policy: critical) == 240)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: nil, windowsVisible: false, policy: nominal) == nil)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: 60, windowsVisible: false, policy: nominal) == 60)
        #expect(PeriodicTask.delay(interval: 30, hiddenInterval: 60, windowsVisible: false, policy: lowPower) == 120)
    }

    @Test func registryListsRunningTasksAndTheirHiddenCadence() {
        let registry = PeriodicTaskRegistry()
        let a = PeriodicTask(name: "crowsnest.health", interval: 60, hiddenInterval: 60, tolerance: 30, registry: registry) {}
        let b = PeriodicTask(name: "compass.index", interval: 300, registry: registry) {}
        #expect(registry.snapshot().isEmpty)
        a.start(); b.start()
        #expect(registry.snapshot().map(\.name) == ["compass.index", "crowsnest.health"])
        let visible = registry.effectiveIntervals(windowsVisible: true)
        #expect(Dictionary(uniqueKeysWithValues: visible.map { ($0.name, $0.interval) }) == ["crowsnest.health": 60, "compass.index": 300])
        // While hidden only the task with a hidden cadence remains, and nothing fires more often than once per 60 s.
        let hidden = registry.effectiveIntervals(windowsVisible: false)
        #expect(hidden.map(\.name) == ["crowsnest.health"])
        #expect(hidden.allSatisfy { $0.interval >= 60 })
        a.stop(); b.stop()
        #expect(registry.snapshot().isEmpty)
    }

    @Test func toleranceDefaultsToTenPercent() {
        let t = PeriodicTask(name: "t", interval: 100, registry: PeriodicTaskRegistry()) {}
        #expect(t.tolerance == 10)
    }

    @Test func aTaskParksWhenHiddenWithoutCadenceAndResumesWhenVisible() async throws {
        let registry = PeriodicTaskRegistry()
        let t = PeriodicTask(name: "t", interval: 1, tolerance: 0, registry: registry) {}
        t.start()
        #expect(t.isStarted && t.isArmed)
        registry.setWindowsVisible(false)
        try await Task.sleep(for: .milliseconds(50))
        #expect(t.isStarted && !t.isArmed)            // no timer armed while hidden
        registry.setWindowsVisible(true)
        #expect(t.isArmed)
        t.stop()
        #expect(!t.isStarted && !t.isArmed)
    }

    @Test func workRunsAfterOneIntervalNeverImmediately() async throws {
        let registry = PeriodicTaskRegistry()
        let counter = TickCounter()
        let t = PeriodicTask(name: "t", interval: 1, tolerance: 0, registry: registry) { counter.bump() }
        t.start()
        #expect(counter.value == 0)
        try await Task.sleep(for: .milliseconds(1300))
        #expect(counter.value >= 1)
        t.stop()
        let after = counter.value
        try await Task.sleep(for: .milliseconds(1200))
        #expect(counter.value == after)               // stop() really stops it
    }
}

private final class TickCounter: @unchecked Sendable {
    private let lock = NSLock(); private var n = 0
    func bump() { lock.withLock { n += 1 } }
    var value: Int { lock.withLock { n } }
}
