#if os(macOS)
import AppKit

/// Takes an AppKit view of a screen that cannot be seen (a hidden tab, a screen covered by a pushed one, a pane parked behind a
/// zoomed one) out of the window's key-view loop. SwiftUI only fades such a screen (`opacity(0)`, `allowsHitTesting(false)`); its
/// AppKit tables are still reachable with Tab, Full Keyboard Access and VoiceOver unless they are hidden. A view that held the
/// keyboard when it was hidden gets it back when it is shown again.
@MainActor
final class KeyViewGate {
    private weak var heldResponder: NSView?

    func apply(visible: Bool, to view: NSView) {
        guard view.isHidden == visible else { return }
        if visible {
            view.isHidden = false
            if let responder = heldResponder, let window = view.window, window.firstResponder == nil || window.firstResponder === window {
                window.makeFirstResponder(responder)
            }
            heldResponder = nil
        } else {
            if let window = view.window, let responder = window.firstResponder as? NSView, responder === view || responder.isDescendant(of: view) {
                heldResponder = responder
                // Hiding the first responder lets AppKit pick the next key view, which can lie in another pane: give the keyboard up
                // first, so nothing is chosen for the user.
                window.makeFirstResponder(nil)
            }
            view.isHidden = true
        }
    }
}
#endif
