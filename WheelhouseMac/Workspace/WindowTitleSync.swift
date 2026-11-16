import AppKit
import SwiftUI

/// Keeps a window's title what the workspace says it is: the focused pane's title (a detached pane window: its pane's), and plain
/// "Wheelhouse" while the app is locked (a cluster or resource name must not show on a locked app).
///
/// SwiftUI bridges the title from `.navigationTitle`, and the screens inside a pane set their own (shared iOS code), which win over
/// the window's own: the first pane's screen named the window whichever pane had focus. The bridge writes `NSWindow.title` only when
/// its own value changes, so this observes the title and puts ours back whenever anything else writes it.
struct WindowTitleSync: NSViewRepresentable {
    let title: String

    final class SyncView: NSView {
        var title = "" { didSet { apply() } }
        private var observation: NSKeyValueObservation?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.title, options: [.new]) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.apply() }
            }
            apply()
        }

        private var isApplying = false

        private func apply() {
            guard !isApplying, let window, window.title != title else { return }
            isApplying = true
            defer { isApplying = false }
            window.title = title
        }
    }

    func makeNSView(context: Context) -> SyncView {
        let view = SyncView()
        view.title = title
        return view
    }

    func updateNSView(_ view: SyncView, context: Context) { view.title = title }
}
