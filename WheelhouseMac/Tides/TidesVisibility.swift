import AppKit
import SwiftUI

/// Reports whether the window that hosts the view is on screen (visible, not miniaturised, not fully covered). Tides stores run
/// only while their view is in a visible window, so a minimised or hidden window costs no watch (ARCHITECTURE-MAC §12.3).
struct WindowVisibilityReader: NSViewRepresentable {
    @Binding var isVisible: Bool

    func makeNSView(context: Context) -> ProbeView {
        let v = ProbeView()
        v.onChange = { visible in DispatchQueue.main.async { isVisible = visible } }
        return v
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {}

    final class ProbeView: NSView {
        var onChange: (Bool) -> Void = { _ in }
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { onChange(false); return }
            let center = NotificationCenter.default
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                tokens.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.report() }
                })
            }
            report()
        }

        @MainActor private func report() {
            guard let window else { onChange(false); return }
            onChange(window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }

        isolated deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
    }
}

extension View {
    /// Runs `body` only while this view is on screen in a visible window; cancels it (so watches stop) otherwise.
    /// `id` restarts the work when it changes.
    func whileVisible<ID: Equatable & Sendable>(id: ID, _ body: @escaping @MainActor @Sendable () async -> Void) -> some View {
        modifier(WhileVisible(id: id, work: body))
    }
}

private struct WhileVisible<ID: Equatable & Sendable>: ViewModifier {
    let id: ID
    let work: @MainActor @Sendable () async -> Void
    @State private var windowVisible = true

    private struct Key: Equatable { var id: ID; var visible: Bool }

    func body(content: Content) -> some View {
        content
            .background(WindowVisibilityReader(isVisible: $windowVisible).frame(width: 0, height: 0))
            .task(id: Key(id: id, visible: windowVisible)) {
                guard windowVisible else { return }
                await work()
            }
    }
}
