import AppKit
import Foundation

/// Switches between a Dock app and a menu-bar-only app (ARCHITECTURE-MAC section 12.1): `.accessory` when no content window is left
/// and Crow's Nest is meant to keep running, `.regular` otherwise, and `.regular` BEFORE a window is opened (an accessory app's window
/// does not come forward). Content windows are workspace, detached pane, Settings and Activity windows: anything that can become main
/// and is visible or miniaturised, so a miniaturised window keeps the Dock icon it is minimised into.
///
/// It never touches windows, workspace state or the energy rules: those follow `WorkspaceWindows`, as before. It is inert while the
/// app quits (closing windows during termination), and in a performance run that keeps its window visible (that run starts as an
/// accessory app on purpose).
@MainActor
final class ActivationPolicyController {
    private let keepsRunning: () -> Bool
    private let windows: () -> [NSWindow]
    private let currentPolicy: () -> NSApplication.ActivationPolicy
    private let apply: (NSApplication.ActivationPolicy) -> Void
    /// Set while the app is quitting.
    var isTerminating = false
    /// A performance run that keeps its window visible.
    var isInert = false
    private var tokens: [NSObjectProtocol] = []
    private(set) var switches = 0

    init(keepsRunning: @escaping () -> Bool, windows: @escaping () -> [NSWindow] = { NSApp.windows },
         currentPolicy: @escaping () -> NSApplication.ActivationPolicy = { NSApp.activationPolicy() },
         apply: @escaping (NSApplication.ActivationPolicy) -> Void = { NSApp.setActivationPolicy($0) }) {
        self.keepsRunning = keepsRunning
        self.windows = windows
        self.currentPolicy = currentPolicy
        self.apply = apply
    }

    /// True when `windows` holds a window the person can see or find in the Dock.
    static func hasContentWindow(_ windows: [NSWindow], excluding closing: NSWindow? = nil) -> Bool {
        windows.contains { $0 !== closing && $0.canBecomeMain && ($0.isVisible || $0.isMiniaturized) }
    }

    /// The policy for a state.
    static func policy(keepsRunning: Bool, hasContentWindow: Bool) -> NSApplication.ActivationPolicy {
        keepsRunning && !hasContentWindow ? .accessory : .regular
    }

    func start() {
        guard tokens.isEmpty else { return }
        let center = NotificationCenter.default
        tokens.append(center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { [weak self] note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated { self?.evaluate(excluding: closing) }
        })
        for name in [NSWindow.didBecomeMainNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.evaluate() }
            })
        }
        evaluate()
    }

    func stop() {
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    /// Re-evaluates (also after the menu bar preferences change).
    func evaluate(excluding closing: NSWindow? = nil) {
        guard !isTerminating, !isInert else { return }
        let wanted = Self.policy(keepsRunning: keepsRunning(), hasContentWindow: Self.hasContentWindow(windows(), excluding: closing))
        guard currentPolicy() != wanted else { return }
        apply(wanted)
        switches += 1
    }

    /// Before a window is opened from menu-bar mode (Open Wheelhouse, a notification tap, Settings from the panel).
    func prepareForWindow() {
        guard !isTerminating, !isInert, currentPolicy() != .regular else { return }
        apply(.regular)
        switches += 1
    }
}
