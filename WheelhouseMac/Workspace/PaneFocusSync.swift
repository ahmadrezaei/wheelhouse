import AppKit
import Observation
import SwiftUI
import SwiftTerm

/// Keeps the model's focused pane and the keyboard focus together, so Tab, Full Keyboard Access and VoiceOver agree with what the
/// window shows as focused.
///
/// - Keyboard focus to pane: when the first responder moves (by a click or a key press) into another pane of the selected tab,
///   that pane becomes the focused one. Only a user event counts: a shell that connects in a background pane calls `focus()` too.
/// - Pane to keyboard focus: when the focused pane or the selected tab changes by another route (⌥⌘ arrows, a menu, a new tab),
///   the first responder moves to the best key view of the focused pane, unless it is already inside that pane.
///
/// It never acts under the lock, while a sheet is attached, or on responders outside the window's content view (the toolbar's
/// search field keeps the keyboard). The loop guard is idempotence: each direction does nothing when the other already agrees.
@MainActor
final class PaneFocusSync {
    private weak var window: NSWindow?
    private let model: WorkspaceWindowModel
    private var observation: NSKeyValueObservation?
    private var stopped = false
    /// The event being handled; tests replace it (there is no current event outside a run loop turn that received one).
    var isUserGesture: (_ responder: NSView, _ window: NSWindow) -> Bool = { responder, window in
        PaneFocusSync.isUserGesture(NSApp.currentEvent, responder: responder, in: window)
    }
    /// The tab and pane the keyboard focus was last placed for: the model also changes for reasons that have nothing to do with focus
    /// (a sidebar click, an inspector toggle), and those must not pull the keyboard out of the sidebar or the toolbar.
    private var placedFor: (tab: TabID, pane: PaneID)?
    /// How many model changes were looked at (tests wait on it instead of sleeping).
    private(set) var modelChangeCount = 0

    init(window: NSWindow, model: WorkspaceWindowModel) {
        self.window = window
        self.model = model
        observation = window.observe(\.firstResponder, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.responderChanged() }
        }
        placedFor = (model.selectedTab.id, model.focusedPaneID)
        trackModel()
    }

    isolated deinit { stopped = true; observation?.invalidate() }

    // MARK: Responder to pane

    /// What counts as the user moving the keyboard focus: Tab or Shift-Tab, or a mouse press in this window that lands inside the
    /// responder. Return, a menu shortcut, a command that places focus itself, a shell connecting in a background pane: none of those.
    static func isUserGesture(_ event: NSEvent?, responder: NSView, in window: NSWindow) -> Bool {
        guard let event, ProcessInfo.processInfo.systemUptime - event.timestamp < 0.25 else { return false }
        switch event.type {
        case .keyDown: return event.keyCode == 48
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            guard event.window === window else { return false }
            return responder.bounds.contains(responder.convert(event.locationInWindow, from: nil))
        default: return false
        }
    }

    private var isInert: Bool {
        guard let window else { return true }
        return model.controller.isLocked() || window.attachedSheet != nil || CompassMarkerView.isShowing(in: window)
    }

    func responderChanged() {
        guard !isInert, let window, let responder = window.firstResponder as? NSView, isUserGesture(responder, window),
              let id = pane(containing: responder),
              id != model.focusedPaneID else { return }
        model.focus(pane: id)
    }

    /// The pane of the selected tab whose visible area holds the responder. Every tab shares one area and hidden screens stay in the
    /// window, so geometry alone is not enough: the view hit at the responder's centre must belong to the responder.
    func pane(containing responder: NSView) -> PaneID? {
        guard let window, let content = window.contentView, responder.isDescendant(of: content) else { return nil }
        let visible = responder.visibleRect.intersection(responder.bounds)
        guard !visible.isEmpty else { return nil }
        let frame = responder.convert(visible, to: nil)
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        let selected = Set(model.selectedTab.panes.map(\.id))
        for id in selected {
            guard let anchor = model.paneAnchors[id]?.view, anchor.window === window else { continue }
            let rect = anchor.convert(anchor.bounds, to: nil)
            // A pane parked behind a zoomed one is a 1 x 1 view.
            guard rect.width > 2, rect.height > 2, rect.contains(centre) else { continue }
            if let hit = content.hitTest(content.superview?.convert(centre, from: nil) ?? centre),
               HiddenTabResponderGuard.GuardView.owns(hit, responder, area: rect) { return id }
        }
        return nil
    }

    // MARK: Pane to responder

    private func trackModel() {
        guard !stopped else { return }
        withObservationTracking {
            _ = model.selectedTab.id
            _ = model.focusedPaneID
        } onChange: { [weak self] in
            // After SwiftUI has laid the new pane out.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.modelChangeCount += 1
                    let now = (tab: self.model.selectedTab.id, pane: self.model.focusedPaneID)
                    if self.placedFor?.tab != now.tab || self.placedFor?.pane != now.pane {
                        self.placedFor = now
                        self.moveKeyboardFocusToFocusedPane()
                    }
                    self.trackModel()
                }
            }
        }
    }

    func moveKeyboardFocusToFocusedPane() {
        guard !isInert, let window, window.isKeyWindow else { return }
        let id = model.focusedPaneID
        if let responder = window.firstResponder as? NSView {
            // The toolbar (its search field) and the title bar are not pane content: they keep the keyboard.
            if let content = window.contentView, !responder.isDescendant(of: content) { return }
            if pane(containing: responder) == id { return }
        }
        guard let target = firstKeyView(in: id) else { return }
        window.makeFirstResponder(target)
    }

    /// The best key view of a pane: a table, then a text view or terminal, then any other control.
    func firstKeyView(in id: PaneID) -> NSView? {
        guard let window, let content = window.contentView, let anchor = model.paneAnchors[id]?.view, anchor.window === window else { return nil }
        let rect = anchor.convert(anchor.bounds, to: nil)
        guard rect.width > 2, rect.height > 2 else { return nil }
        var candidates: [NSView] = []
        func walk(_ view: NSView) {
            if view.isHidden { return }
            if view.acceptsFirstResponder, view.canBecomeKeyView, !(view is NSScrollView) { candidates.append(view) }
            for sub in view.subviews { walk(sub) }
        }
        walk(content)
        let inPane = candidates.filter { view in
            let visible = view.visibleRect.intersection(view.bounds)
            guard !visible.isEmpty else { return false }
            let frame = view.convert(visible, to: nil)
            let centre = CGPoint(x: frame.midX, y: frame.midY)
            guard rect.contains(centre) else { return false }
            guard let hit = content.hitTest(content.superview?.convert(centre, from: nil) ?? centre) else { return false }
            return HiddenTabResponderGuard.GuardView.owns(hit, view, area: rect)
        }
        func rank(_ view: NSView) -> Int {
            if view is NSTableView || view is NSOutlineView { return 0 }
            if view is NSTextView || view is TerminalView { return 1 }
            return 2
        }
        return inPane.min { rank($0) < rank($1) }
    }
}

/// Behind the Compass panel: while it shows in a window, the focus sync leaves that window's keyboard alone (the panel's field
/// is not a pane, and it sits over one).
struct CompassMarker: NSViewRepresentable {
    func makeNSView(context: Context) -> CompassMarkerView { CompassMarkerView() }
    func updateNSView(_ view: CompassMarkerView, context: Context) {}
}

final class CompassMarkerView: NSView {
    private static let windows = NSHashTable<NSWindow>.weakObjects()
    @MainActor static func isShowing(in window: NSWindow) -> Bool { windows.contains(window) }

    private weak var registered: NSWindow?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let registered { Self.windows.remove(registered) }
        registered = window
        if let window { Self.windows.add(window) }
    }
}

/// A weak reference to a pane's anchor view.
struct WeakPaneAnchor {
    weak var view: NSView?
}

/// A transparent view behind a pane that tells the model where the pane is in the window.
struct PaneAnchor: NSViewRepresentable {
    let model: WorkspaceWindowModel
    let paneID: PaneID

    final class AnchorView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override var isFlipped: Bool { true }
    }

    func makeNSView(context: Context) -> AnchorView {
        let view = AnchorView()
        model.paneAnchors[paneID] = WeakPaneAnchor(view: view)
        return view
    }

    func updateNSView(_ view: AnchorView, context: Context) {
        if model.paneAnchors[paneID]?.view !== view { model.paneAnchors[paneID] = WeakPaneAnchor(view: view) }
    }
}
