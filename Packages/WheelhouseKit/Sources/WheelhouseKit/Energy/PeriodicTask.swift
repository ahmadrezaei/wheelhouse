import Foundation
import Synchronization

/// What the registry knows about one periodic task, for `PeriodicTaskAuditTests` and the perf harness.
public struct PeriodicTaskInfo: Hashable, Sendable {
    public var name: String
    /// Base interval while a window is visible, before `EnergyPolicy.refreshMultiplier`.
    public var interval: TimeInterval
    /// Interval while no window is visible; nil means the task stops (≥ 60 s otherwise).
    public var hiddenInterval: TimeInterval?
    public var tolerance: TimeInterval
}

/// Every `PeriodicTask` registers here while it is running, so the audit can list what runs in each state (ARCHITECTURE-MAC §12.3.4 item 7).
public final class PeriodicTaskRegistry: Sendable {
    public static let shared = PeriodicTaskRegistry()
    private let state = Mutex<[UUID: PeriodicTaskInfo]>([:])
    private let visibility = Mutex<Bool>(true)
    private let listeners = Mutex<[UUID: @Sendable (Bool) -> Void]>([:])

    public init() {}

    /// True while at least one workspace window is visible (not closed, miniaturised or occluded).
    public var windowsVisible: Bool { visibility.withLock { $0 } }

    /// Called by the Mac shell (`OcclusionMonitor`). Running tasks switch between their visible and hidden cadence.
    public func setWindowsVisible(_ visible: Bool) {
        let changed = visibility.withLock { v -> Bool in defer { v = visible }; return v != visible }
        guard changed else { return }
        let callbacks = listeners.withLock { Array($0.values) }
        for c in callbacks { c(visible) }
    }

    func register(_ id: UUID, _ info: PeriodicTaskInfo) { state.withLock { $0[id] = info } }
    func unregister(_ id: UUID) { state.withLock { $0[id] = nil } }
    func observe(_ id: UUID, _ f: @escaping @Sendable (Bool) -> Void) { listeners.withLock { $0[id] = f } }
    func stopObserving(_ id: UUID) { listeners.withLock { $0[id] = nil } }

    /// The tasks that are running, sorted by name.
    public func snapshot() -> [PeriodicTaskInfo] { state.withLock { Array($0.values) }.sorted { $0.name < $1.name } }

    /// What would fire in the given state: with no window visible only tasks with a `hiddenInterval`, at that cadence.
    public func effectiveIntervals(windowsVisible: Bool, policy: EnergyPolicy = EnergyPolicy()) -> [(name: String, interval: TimeInterval)] {
        snapshot().compactMap { info in
            if windowsVisible { return (info.name, policy.interval(info.interval)) }
            guard let hidden = info.hiddenInterval else { return nil }
            return (info.name, policy.interval(hidden))
        }
    }
}

/// The ONLY periodic-work primitive in the app. `Timer.scheduledTimer`, `Timer.publish` and `DispatchSource.makeTimerSource`
/// are lint errors outside this file (`scripts/lint-mac.sh`).
///
/// Runs on `Task.sleep(for:tolerance:clock: .continuous)`, scales by `EnergyPolicy.refreshMultiplier`, and registers in the
/// ``PeriodicTaskRegistry``. `interval >= 1 s`; `hiddenInterval` is nil (the task stops while no window is visible) or >= 60 s.
public final class PeriodicTask: Sendable {
    public let name: String
    public let interval: TimeInterval
    public let hiddenInterval: TimeInterval?
    public let tolerance: TimeInterval

    private let work: @Sendable () async -> Void
    private let registry: PeriodicTaskRegistry
    private let policy: @Sendable () -> EnergyPolicy
    private let id = UUID()
    private struct State { var started = false; var loop: Task<Void, Never>? }
    private let state = Mutex(State())

    /// `tolerance` defaults to 10 % of `interval`.
    public init(name: String, interval: TimeInterval, hiddenInterval: TimeInterval? = nil, tolerance: TimeInterval? = nil,
                registry: PeriodicTaskRegistry = .shared, policy: @escaping @Sendable () -> EnergyPolicy = { EnergyPolicy.current },
                work: @escaping @Sendable () async -> Void) {
        precondition(Self.isValid(interval: interval, hiddenInterval: hiddenInterval), "PeriodicTask \(name): interval must be >= 1 s and hiddenInterval nil or >= 60 s")
        self.name = name
        self.interval = interval
        self.hiddenInterval = hiddenInterval
        self.tolerance = tolerance ?? interval * 0.1
        self.work = work
        self.registry = registry
        self.policy = policy
    }

    /// The rule the initializer asserts.
    public static func isValid(interval: TimeInterval, hiddenInterval: TimeInterval?) -> Bool {
        interval >= 1 && (hiddenInterval.map { $0 >= 60 } ?? true)
    }

    /// The delay before the next run, or nil when the task must not run in this state.
    public static func delay(interval: TimeInterval, hiddenInterval: TimeInterval?, windowsVisible: Bool, policy: EnergyPolicy) -> TimeInterval? {
        if windowsVisible { return policy.interval(interval) }
        return hiddenInterval.map { policy.interval($0) }
    }

    /// True between `start()` and `stop()`, even while parked (hidden with no hidden cadence: no timer is armed then).
    public var isStarted: Bool { state.withLock { $0.started } }
    /// True while a sleep or run loop exists.
    public var isArmed: Bool { state.withLock { $0.loop != nil } }

    /// Starts the task (no-op when already started). The first run happens after one delay, never immediately.
    public func start() {
        let first = state.withLock { s -> Bool in
            guard !s.started else { return false }
            s.started = true
            return true
        }
        guard first else { return }
        registry.register(id, PeriodicTaskInfo(name: name, interval: interval, hiddenInterval: hiddenInterval, tolerance: tolerance))
        registry.observe(id) { [weak self] _ in self?.rearm() }
        rearm()
    }

    public func stop() {
        registry.stopObserving(id)
        registry.unregister(id)
        let loop = state.withLock { s -> Task<Void, Never>? in defer { s.started = false; s.loop = nil }; return s.loop }
        loop?.cancel()
    }

    deinit {
        registry.stopObserving(id)
        registry.unregister(id)
        state.withLock { $0.loop?.cancel() }
    }

    /// (Re)creates the loop for the current visibility; no loop at all when the task must not run.
    private func rearm() {
        let delay = Self.delay(interval: interval, hiddenInterval: hiddenInterval, windowsVisible: registry.windowsVisible, policy: policy())
        state.withLock { s in
            guard s.started else { return }
            s.loop?.cancel()
            s.loop = delay == nil ? nil : Task { [self] in await run() }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            guard let delay = Self.delay(interval: interval, hiddenInterval: hiddenInterval, windowsVisible: registry.windowsVisible, policy: policy()) else { return }
            do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(tolerance), clock: .continuous) } catch { return }
            if Task.isCancelled { return }
            await work()
        }
    }
}
