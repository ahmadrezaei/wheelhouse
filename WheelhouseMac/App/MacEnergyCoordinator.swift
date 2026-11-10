import AppKit
import Foundation
import notify
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
    /// Set by the app: drops the sidebars' summary caches (memory warning) and the content of hidden windows (critical).
    @ObservationIgnored var trimSidebars: @MainActor () -> Void = {}
    @ObservationIgnored var releaseHiddenWindowContent: @MainActor () -> Void = {}
    /// Counts for diagnostics and tests.
    private(set) var memoryWarnings = 0
    private(set) var memoryCriticals = 0

    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let periodicTasks: PeriodicTaskRegistry
    @ObservationIgnored private let reportsVisibility: Bool
    @ObservationIgnored private let memory: MemoryPressureMonitor
    @ObservationIgnored private let releaseGrace: TimeInterval
    @ObservationIgnored private let visibility: @MainActor () -> Bool
    @ObservationIgnored private let power = PowerSourceMonitor()
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored private var tokens: [NSObjectProtocol] = []

    /// `memorySource`, `releaseGrace`, `visibility` and `periodicTasks` are test seams; the app uses the defaults. Only WORKSPACE
    /// windows count (``WorkspaceWindows``): an open Settings window, a sheet or a panel never keeps the app out of its hidden mode.
    /// This coordinator is the one source of "a window is visible": it also switches the `PeriodicTaskRegistry` cadence.
    /// `reportsVisibility` (development builds) publishes each evaluation for the performance sampler (``VisibilityReport``).
    init(registry: ClusterRegistry, memorySource: any MemoryPressureSource = SystemMemoryPressureSource(),
         releaseGrace: TimeInterval = MacEnergyCoordinator.defaultReleaseGrace,
         visibility: @escaping @MainActor () -> Bool = { MacEnergyCoordinator.anyWindowVisible(WorkspaceWindows.all) },
         periodicTasks: PeriodicTaskRegistry = .shared, reportsVisibility: Bool = false) {
        self.registry = registry
        self.periodicTasks = periodicTasks
        self.reportsVisibility = reportsVisibility
        self.memory = MemoryPressureMonitor(source: memorySource)
        self.releaseGrace = releaseGrace
        self.visibility = visibility
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification, NSWindow.didBecomeMainNotification]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                // `willClose` fires before the window leaves `NSApp.windows`; evaluate on the next turn.
                Task { @MainActor in self?.evaluateVisibility() }
            })
        }
        // A workspace window registers when its content moves into it, which can be after `start()`.
        tokens.append(center.addObserver(forName: WorkspaceWindows.didChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluateVisibility() }
        })
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
        memory.stop()
        power.stop()
        graceTask?.cancel(); graceTask = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    // MARK: Visibility

    /// True when at least one of `windows` (the workspace windows) can be seen.
    static func anyWindowVisible(_ windows: [NSWindow]) -> Bool {
        windows.contains { w in
            w.canBecomeMain && OcclusionMonitor.isVisible(visible: w.isVisible, miniaturized: w.isMiniaturized, occlusionVisible: w.occlusionState.contains(.visible))
        }
    }

    func evaluateVisibility() {
        let visible = visibility()
        periodicTasks.setWindowsVisible(visible)
        if reportsVisibility { VisibilityReport.publish(visible) }
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
        SchemaServices.trim()
    }

    // MARK: Memory pressure

    func handleMemoryPressure(_ level: MemoryPressureLevel) {
        switch level {
        case .warning:
            memoryWarnings += 1
            trimSidebars()
            trimLogBuffers()
            registry.trimCaches()
            ChartRoomMemory.trim()
            SchemaServices.trim()
        case .critical:
            memoryCriticals += 1
            trimSidebars()
            releaseHiddenWindowContent()
            trimLogBuffers()
            registry.trimCaches()
            ChartRoomMemory.trim()
            SchemaServices.trim()
            // Every non-visible consumer goes now; with a window visible only the idle caches are dropped above.
            if !windowsVisible { release() }
        }
    }

    private func trimLogBuffers() {
        for stream in LogMemoryBudget.shared.streams where !stream.isVisible { stream.trim(keepingLast: Self.trimmedLogLines) }
    }
}

/// Development builds publish whether a workspace window is visible as the state of a Darwin notification, so
/// `scripts/perf-sample.sh` can check (`notifyutil -g`) that a "visible" scenario really measured a visible window: a Space switch, a
/// covering window, display sleep or the lock screen all make it invisible, and then nothing is drawn. State 1 = visible, 2 = hidden
/// (0, the state of a name nobody set, means the app never published).
@MainActor
enum VisibilityReport {
    static let name = "com.ahmadrezaei.wheelhouse.perf.windows-visible"
    private static var token: Int32 = -1

    static func publish(_ visible: Bool) {
        if token < 0, notify_register_check(name, &token) != 0 { token = -1; return }
        notify_set_state(token, visible ? 1 : 2)          // 0 is "never published"
        notify_post(name)
    }
}

/// The workspace windows: the only windows whose visibility drives the energy rules (ARCHITECTURE-MAC section 12.3.3). A window
/// registers itself when the workspace content moves into it (`WorkspaceWindowMarker` in `MacShell`); Settings, sheets, panels and
/// alerts never register, so an open Settings window does not count as a visible workspace. Held weakly: a closed and released window
/// drops out by itself, and a closed window that AppKit keeps alive is not visible.
@MainActor
enum WorkspaceWindows {
    /// Posted (main thread) when a window registers.
    static let didChange = Notification.Name("WheelhouseWorkspaceWindowsDidChange")
    private static let table = NSHashTable<NSWindow>.weakObjects()
    private static var observers: [(NSWindow) -> Void] = []

    static var all: [NSWindow] { table.allObjects }

    static func contains(_ window: NSWindow) -> Bool { table.contains(window) }

    /// Idempotent: a window SwiftUI reuses keeps its registration (occlusion and main-window notifications re-evaluate it).
    static func register(_ window: NSWindow) {
        guard !table.contains(window) else { return }
        table.add(window)
        observers.forEach { $0(window) }
        NotificationCenter.default.post(name: didChange, object: window)
    }

    /// Calls `body` for every workspace window already registered and for each one that registers later.
    static func observe(_ body: @escaping (NSWindow) -> Void) {
        all.forEach(body)
        observers.append(body)
    }
}
