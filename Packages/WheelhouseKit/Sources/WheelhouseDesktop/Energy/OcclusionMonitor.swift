#if os(macOS)
import AppKit
import WheelhouseKit

/// Tracks whether any workspace window is visible (not closed, miniaturised or occluded) and publishes it to
/// ``PeriodicTaskRegistry`` so periodic work follows the §12.3.3 hidden cadence. M1a ships the seam; M1b wires it into the shell.
@MainActor
public final class OcclusionMonitor {
    private var tokens: [NSObjectProtocol] = []
    private let registry: PeriodicTaskRegistry
    private let windows: @MainActor () -> [NSWindow]

    public init(registry: PeriodicTaskRegistry = .shared, windows: @escaping @MainActor () -> [NSWindow] = { NSApp.windows }) {
        self.registry = registry
        self.windows = windows
    }

    /// A window counts when it is a visible, non-miniaturised, unoccluded content window.
    public nonisolated static func isVisible(visible: Bool, miniaturized: Bool, occlusionVisible: Bool) -> Bool {
        visible && !miniaturized && occlusionVisible
    }

    public func refresh() {
        let anyVisible = windows().contains { w in
            w.canBecomeMain && Self.isVisible(visible: w.isVisible, miniaturized: w.isMiniaturized, occlusionVisible: w.occlusionState.contains(.visible))
        }
        registry.setWindowsVisible(anyVisible)
    }

    public func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                                          NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification]
        for name in names {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    public func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }
}
#endif
