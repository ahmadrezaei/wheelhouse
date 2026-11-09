import AppKit
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// Registers the window that hosts a workspace (or a detached pane) with the energy rules, connects it to its model and reports its
/// lifecycle: becoming key, occlusion and minimise (drawing stops at once, content is released after the grace period), moving
/// and resizing (the frame is saved), closing.
///
/// EVERY window that shows workspace content registers with ``WorkspaceWindows``, workspace windows and detached pane windows
/// alike: a window that is not registered would not count as visible, and the app would release its watches under a window that
/// is showing them.
struct WorkspaceWindowMarker: NSViewRepresentable {
    let model: WorkspaceWindowModel

    final class MarkerView: NSView {
        var model: WorkspaceWindowModel?
        private var observer: WindowObserver?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window, let model else { return }
            WorkspaceWindows.register(window)
            if observer?.window !== window { observer = WindowObserver(window: window, model: model) }
        }
    }

    func makeNSView(context: Context) -> MarkerView {
        let v = MarkerView()
        v.model = model
        return v
    }

    func updateNSView(_ view: MarkerView, context: Context) { view.model = model }
}

@MainActor
final class WindowObserver {
    private(set) weak var window: NSWindow?
    private unowned let model: WorkspaceWindowModel
    private var tokens: [NSObjectProtocol] = []

    init(window: NSWindow, model: WorkspaceWindowModel) {
        self.window = window
        self.model = model
        model.window = window
        window.isRestorable = false          // the workspace restores its own windows (WorkspaceStore), not AppKit
        restoreFrame(window)
        let center = NotificationCenter.default
        func observe(_ name: Notification.Name, _ body: @escaping @MainActor (WindowObserver) -> Void) {
            tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if let self { body(self) } }
            })
        }
        observe(NSWindow.didBecomeKeyNotification) { $0.becameKey() }
        observe(NSWindow.didResignKeyNotification) { $0.model.controller.syncSidebarState() }
        observe(NSWindow.didChangeOcclusionStateNotification) { $0.updateVisibility() }
        observe(NSWindow.didMiniaturizeNotification) { $0.updateVisibility() }
        observe(NSWindow.didDeminiaturizeNotification) { $0.updateVisibility() }
        observe(NSWindow.didMoveNotification) { $0.saveFrame() }
        observe(NSWindow.didEndLiveResizeNotification) { $0.saveFrame() }
        observe(NSWindow.willCloseNotification) { $0.closed() }
        updateVisibility()
        if window.isKeyWindow { becameKey() }
    }

    isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }

    private func updateVisibility() {
        guard let window else { return }
        model.visibilityChanged(OcclusionMonitor.isVisible(visible: window.isVisible, miniaturized: window.isMiniaturized,
                                                           occlusionVisible: window.occlusionState.contains(.visible)))
    }

    private func becameKey() {
        if case .window(let id) = model.scope { model.controller.becameActive(id) }
    }

    private func restoreFrame(_ window: NSWindow) {
        let saved: [Double]?
        switch model.scope {
        case .window(let id): saved = model.store.state(for: id).frame
        case .detached(let id): saved = model.store.detached[id]?.frame
        }
        guard let f = saved, f.count == 4, f[2] >= 400, f[3] >= 300 else { return }
        let frame = NSRect(x: f[0], y: f[1], width: f[2], height: f[3])
        // Only a frame that is still on a screen (a disconnected display would leave the window out of reach).
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else { return }
        window.setFrame(frame, display: false)
    }

    private func saveFrame() {
        guard let window, !window.isMiniaturized else { return }
        let f = window.frame
        let frame = [Double(f.minX), Double(f.minY), Double(f.width), Double(f.height)]
        switch model.scope {
        case .window(let id): model.store.setFrame(frame, for: id)
        case .detached(let id): model.store.mutateDetachedFrame(id, frame)
        }
    }

    private func closed() {
        saveFrame()
        model.controller.syncSidebarState()
        switch model.scope {
        case .window(let id): model.controller.windowClosed(id)
        case .detached(let id): model.controller.detachedClosed(id)
        }
    }
}
