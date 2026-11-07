import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// Wires the §12.3 energy rules into the shell (ARCHITECTURE-MAC section 12.3.3 and 12.3.4 items 4, 8 and 9):
///
/// - **Occlusion and minimise.** While no workspace window is visible (closed, miniaturised or fully covered) the
///   `PeriodicTaskRegistry` switches every periodic task to its hidden cadence (most stop), views stop drawing at once, and after a
///   30 s grace (0 s under thermal `serious` or worse) the shared stores release their watches. Becoming visible again resumes them.
///   The grace avoids a re-list when the user flips through Spaces or Mission Control.
/// - **Memory pressure.** `warning`: stores with no consumers drop their cached items and non-visible log buffers keep their last 2,000
///   lines. `critical`: every non-visible consumer is released at once. Terminal scrollback is never trimmed.
/// - **Power source.** `PowerSourceMonitor` publishes `onBattery` (event driven, never polled) for the consumers that care
///   (Survey scans and the Compass index, in later milestones).
/// - **Energy policy.** Low Power Mode and the thermal state re-apply the registry's energy policy.
@MainActor @Observable
final class MacEnergyCoordinator {
    /// Seconds hidden before the stores release their watches.
    static let defaultReleaseGrace: TimeInterval = 30
    /// Lines a non-visible log buffer keeps under memory pressure.
    static let trimmedLogLines = 2_000

    private(set) var windowsVisible = true
    private(set) var onBattery = PowerSourceMonitor.onBattery
    private(set) var released = false
    /// Counts for diagnostics and tests.
    private(set) var memoryWarnings = 0
    private(set) var memoryCriticals = 0

    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let occlusion: OcclusionMonitor
    @ObservationIgnored private let memory: MemoryPressureMonitor
    @ObservationIgnored private let releaseGrace: TimeInterval
    @ObservationIgnored private let visibility: @MainActor () -> Bool
    @ObservationIgnored private let power = PowerSourceMonitor()
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    /// `memorySource`, `releaseGrace` and `visibility` are test seams; the app uses the defaults.
    init(registry: ClusterRegistry, memorySource: any MemoryPressureSource = SystemMemoryPressureSource(),
         releaseGrace: TimeInterval = MacEnergyCoordinator.defaultReleaseGrace,
         visibility: @escaping @MainActor () -> Bool = { MacEnergyCoordinator.anyWindowVisible(NSApp.windows) }) {
        self.registry = registry
        self.occlusion = OcclusionMonitor()
        self.memory = MemoryPressureMonitor(source: memorySource)
        self.releaseGrace = releaseGrace
        self.visibility = visibility
    }

    func start() {
        guard tokens.isEmpty else { return }
        occlusion.start()
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `willClose` fires before the window leaves `NSApp.windows`; evaluate on the next turn.
                Task { @MainActor in self?.evaluateVisibility() }
            })
        }
        tokens.append(center.addObserver(forName: EnergyPolicy.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registry.applyEnergyPolicy() }
        })
        memory.start { [weak self] level in
            Task { @MainActor in self?.handleMemoryPressure(level) }
        }
        power.start { [weak self] battery in
            Task { @MainActor in self?.onBattery = battery }
        }
        evaluateVisibility()
    }

    func stop() {
        occlusion.stop()
        memory.stop()
        power.stop()
        graceTask?.cancel(); graceTask = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    // MARK: Visibility

    /// True when at least one real content window can be seen.
    static func anyWindowVisible(_ windows: [NSWindow]) -> Bool {
        windows.contains { w in
            w.canBecomeMain && OcclusionMonitor.isVisible(visible: w.isVisible, miniaturized: w.isMiniaturized, occlusionVisible: w.occlusionState.contains(.visible))
        }
    }

    func evaluateVisibility() {
        let visible = visibility()
        occlusion.refresh()
        guard visible != windowsVisible else { return }
        windowsVisible = visible
        graceTask?.cancel(); graceTask = nil
        if visible {
            guard released else { return }
            released = false
            registry.resumeAllSessions()
        } else {
            let grace = EnergyPolicy.current.suspendsHiddenWatches ? 0 : releaseGrace
            if grace == 0 { release(); return }
            graceTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(grace))
                guard !Task.isCancelled else { return }
                self?.release()
            }
        }
    }

    private func release() {
        guard !windowsVisible, !released else { return }
        released = true
        registry.stopAllSessions()
    }

    // MARK: Memory pressure

    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        switch level {
        case .warning:
            memoryWarnings += 1
            trimLogBuffers()
            registry.trimCaches()
        case .critical:
            memoryCriticals += 1
            trimLogBuffers()
            registry.trimCaches()
            // Every non-visible consumer goes now; with a window visible only the idle caches are dropped above.
            if !windowsVisible { release() }
        }
    }

    private func trimLogBuffers() {
        for stream in LogMemoryBudget.shared.streams where !stream.isVisible { stream.trim(keepingLast: Self.trimmedLogLines) }
    }
}
