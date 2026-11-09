#if os(macOS)
import Foundation
import WheelhouseKit

/// Runs one queued image. The real implementation is ``TrivyScanRunner``; tests inject their own.
public protocol ScanRunner: Sendable {
    func scan(_ item: ScanQueueItem, trigger: ScanTrigger) async throws -> ImageScanResult
}

/// Tells the queue when the power source, Low Power Mode or the thermal state changed. Event driven; no timers.
public protocol ScanConditionsObserver: Sendable {
    func start(_ onChange: @escaping @Sendable () -> Void)
    func stop()
}

public struct ScanProgress: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        /// Nothing running. `restored` is the number of images a previous launch left in the queue (offered as "Resume").
        case idle
        case running
        case paused(ScanGate.PauseReason)
        case userPaused
    }
    public var state: State = .idle
    public var queued = 0
    public var scanned = 0
    public var failed = 0
    public var current: String?
    /// Estimated seconds left: average duration of the finished images times those left. Updated when an image finishes.
    public var eta: TimeInterval?
    public var lastError: String?
}

/// The scan queue (ARCHITECTURE-MAC §6.1 "CPU and energy"): persisted in `survey.sqlite`, one image at a time, pausable. Before
/// each image the energy gate is asked again; a change of conditions while an image is being scanned stops it and puts it back at the
/// head of the queue (not counted as a failure). A restored queue never starts by itself: the UI offers Resume. The queue holds no
/// timer; it observes the power source, Low Power Mode and the thermal state only while images are waiting and the user has not
/// paused it.
public actor ScanQueue {
    private let store: SurveyStore
    private let runner: any ScanRunner
    private let conditions: @Sendable () -> ScanConditions
    private let onlyOnPower: @Sendable () -> Bool
    private let observer: (any ScanConditionsObserver)?
    private let publish: @Sendable (ScanProgress) -> Void
    private let clock = ContinuousClock()

    public private(set) var progress = ScanProgress() { didSet { publish(progress) } }
    private var runTrigger: ScanTrigger = .scheduled
    private var loop: Task<Void, Never>?
    private var current: Task<ImageScanResult, Error>?
    private var observing = false
    private var durations: [Duration] = []
    private var generation = 0

    public init(store: SurveyStore, runner: any ScanRunner, conditions: @escaping @Sendable () -> ScanConditions,
                onlyOnPower: @escaping @Sendable () -> Bool = { true }, observer: (any ScanConditionsObserver)? = nil,
                publish: @escaping @Sendable (ScanProgress) -> Void = { _ in }) {
        self.store = store
        self.runner = runner
        self.conditions = conditions
        self.onlyOnPower = onlyOnPower
        self.observer = observer
        self.publish = publish
    }

    /// Reads the persisted queue (after a relaunch): shows how many images wait. Starts nothing.
    public func restore() async {
        progress.queued = (try? await store.queueCount()) ?? 0
    }

    public func enqueue(images: [(image: String, isMutable: Bool, clusters: [String])], trigger: ScanTrigger) async throws {
        for i in images { try await store.enqueue(image: i.image, isMutable: i.isMutable, clusters: i.clusters, trigger: trigger) }
        progress.queued = try await store.queueCount()
        updateObservation()
    }

    /// Starts (or resumes) the run. `.manual` overrides the energy rules for this run.
    public func start(trigger: ScanTrigger) {
        runTrigger = trigger
        guard loop == nil else { return }
        progress.scanned = 0
        progress.failed = 0
        progress.lastError = nil
        durations = []
        launch()
    }

    /// The user's Pause: the running image goes back to the head of the queue.
    public func pause() {
        guard loop != nil || progress.state == .running else { return }
        stopLoop()
        progress.state = .userPaused
        progress.current = nil
        updateObservation()
    }

    /// Resume after a pause (user or conditions), with `trigger` as the run's trigger.
    public func resume(trigger: ScanTrigger? = nil) {
        if let trigger { runTrigger = trigger }
        if case .running = progress.state { return }
        launch()
    }

    /// Empties the queue.
    public func cancelAll() async {
        stopLoop()
        try? await store.clearQueue()
        progress = ScanProgress(state: .idle, queued: 0, scanned: progress.scanned, failed: progress.failed)
        updateObservation()
    }

    /// Called by the observer, and by tests (the "battery" hook): the power source, Low Power Mode or the thermal state changed.
    public func conditionsChanged() {
        let decision = ScanGate.decide(trigger: runTrigger, conditions: conditions(), onlyOnPower: onlyOnPower())
        switch (progress.state, decision) {
        case (.running, .paused(let reason)):
            stopLoop()
            progress.state = .paused(reason)
        case (.paused, .allowed):
            launch()
        case (.paused, .paused(let reason)):
            progress.state = .paused(reason)
        default:
            break
        }
        updateObservation()
    }

    /// Whether the observer is currently registered (for tests and the energy audit).
    public var isObserving: Bool { observing }

    // MARK: Loop

    /// Ends the current run: the image being scanned is cancelled and stays queued, and the loop (which checks its generation after
    /// every suspension) exits without touching the state.
    private func stopLoop() {
        generation += 1
        current?.cancel()
        current = nil
        loop?.cancel()
        loop = nil
    }

    private func launch() {
        generation += 1
        let mine = generation
        loop?.cancel()
        progress.state = .running
        loop = Task { [weak self] in await self?.run(generation: mine) }
        updateObservation()
    }

    private func run(generation mine: Int) async {
        while !Task.isCancelled, mine == generation {
            let next = (try? await store.queue())?.first
            let count = (try? await store.queueCount()) ?? 0
            guard mine == generation, !Task.isCancelled else { return }
            progress.queued = count
            guard let item = next else { finish(generation: mine, state: .idle); return }
            if case .paused(let reason) = ScanGate.decide(trigger: runTrigger, conditions: conditions(), onlyOnPower: onlyOnPower()) {
                finish(generation: mine, state: .paused(reason))
                return
            }
            progress.state = .running
            progress.current = item.image
            let trigger = runTrigger
            let runner = self.runner
            let task = Task { try await runner.scan(item, trigger: trigger) }
            current = task
            let started = clock.now
            do {
                _ = try await task.value
                guard mine == generation else { return }
                try? await store.removeFromQueue(id: item.id)
                progress.scanned += 1
                durations.append(clock.now - started)
                progress.queued = max(0, progress.queued - 1)
                let average = durations.reduce(Duration.zero, +) / durations.count
                progress.eta = Double(progress.queued) * (Double(average.components.seconds) + Double(average.components.attoseconds) / 1e18)
            } catch {
                if mine != generation || task.isCancelled || error is CancellationError || Task.isCancelled {   // the item stays queued
                    if mine == generation { current = nil; loop = nil }
                    return
                }
                try? await store.removeFromQueue(id: item.id)
                progress.failed += 1
                progress.lastError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                progress.queued = max(0, progress.queued - 1)
            }
            if mine == generation { current = nil }
        }
    }

    private func finish(generation mine: Int, state: ScanProgress.State) {
        guard mine == generation else { return }
        loop = nil
        current = nil
        progress.state = state
        progress.current = nil
        if state == .idle { progress.eta = nil }
        updateObservation()
    }

    // MARK: Observation

    /// Observers exist only while images wait and the user has not paused the queue.
    private func updateObservation() {
        let want = progress.queued > 0 && progress.state != .userPaused && progress.state != .idle
        guard want != observing, let observer else { return }
        observing = want
        if want {
            observer.start { [weak self] in Task { await self?.conditionsChanged() } }
        } else {
            observer.stop()
        }
    }
}
#endif
