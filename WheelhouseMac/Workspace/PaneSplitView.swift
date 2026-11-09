import AppKit
import SwiftUI
import WheelhouseKit

/// The pane tree of one tab: nested `NSSplitView`s with one `NSHostingView` per leaf (ARCHITECTURE-MAC section 12.2).
///
/// - Each leaf hosts `PaneHost` once; the host reads its own state from the store, so the root view is never reassigned and a store
///   change does not re-diff every pane.
/// - Leaf hosting views use `sizingOptions = []`: AppKit never asks SwiftUI for a minimum size (P1: that question walked the whole
///   screen on every update). The split view enforces 320 x 180 minimums with its delegate.
/// - A structural change (split, close, move) rebuilds the split hierarchy but reuses the leaf views by pane ID, so panes keep their
///   SwiftUI state. Divider fractions are committed when the mouse is released.
struct PaneSplitView: NSViewRepresentable {
    let env: MacAppEnvironment
    let model: WorkspaceWindowModel
    let tab: TabState
    let isSelected: Bool

    func makeNSView(context: Context) -> PaneTreeView { PaneTreeView(env: env, model: model, tabID: tab.id) }

    func updateNSView(_ view: PaneTreeView, context: Context) {
        let shown: PaneNode
        if let zoomed = tab.zoomedPane, let pane = tab.root.pane(zoomed) { shown = .leaf(pane) } else { shown = tab.root }
        view.isHidden = !isSelected          // a hidden tab (kept for its stateful panes) draws nothing
        view.apply(root: shown, all: tab.root, focused: tab.focusedPane)
    }
}

final class PaneTreeView: NSView, NSSplitViewDelegate {
    private let env: MacAppEnvironment
    private let model: WorkspaceWindowModel
    let tabID: TabID
    private var leaves: [PaneID: PaneLeafView] = [:]
    private var content: NSView?
    private var signature = ""
    private var root: PaneNode?
    private var needsFractions = true
    private var applyingFractions = false

    init(env: MacAppEnvironment, model: WorkspaceWindowModel, tabID: TabID) {
        self.env = env
        self.model = model
        self.tabID = tabID
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Leaf views currently in the tree (tests).
    var leafIDs: Set<PaneID> { Set(leaves.keys) }
    var splitViews: [PaneSplitNSView] { allSplits(in: content) }

    private func allSplits(in view: NSView?) -> [PaneSplitNSView] {
        guard let view else { return [] }
        return ((view as? PaneSplitNSView).map { [$0] } ?? []) + view.subviews.flatMap { allSplits(in: $0) }
    }

    // MARK: Applying state

    /// `root` is what is shown (one leaf while a pane is zoomed); `all` is the whole tab, so zooming parks the other panes' views
    /// (their SwiftUI state, such as unsaved YAML, survives) instead of freeing them.
    func apply(root newRoot: PaneNode, all: PaneNode? = nil, focused: PaneID) {
        let newSignature = Self.signature(newRoot)
        root = newRoot
        if newSignature != signature {
            signature = newSignature
            rebuild(newRoot, all: all ?? newRoot)
        } else {
            needsFractions = needsFractions || fractionsDiffer(newRoot)
        }
        for (id, leaf) in leaves { leaf.isFocused = id == focused }
        if needsFractions { needsLayout = true }
    }

    /// The shape of the tree: split axes and pane IDs, not fractions.
    static func signature(_ node: PaneNode) -> String {
        switch node {
        case .leaf(let p): p.id.rawValue
        case .split(let axis, _, let a, let b): "\(axis == .horizontal ? "H" : "V")(\(signature(a)),\(signature(b)))"
        }
    }

    private func rebuild(_ node: PaneNode, all: PaneNode) {
        let ids = Set(all.paneIDs)
        for (id, leaf) in leaves where !ids.contains(id) {
            leaf.removeFromSuperview()
            leaves[id] = nil
        }
        content?.removeFromSuperview()
        let built = build(node, path: [])
        built.frame = bounds
        built.autoresizingMask = [.width, .height]
        addSubview(built)
        content = built
        needsFractions = true
        needsLayout = true
    }

    private func build(_ node: PaneNode, path: [Int]) -> NSView {
        switch node {
        case .leaf(let pane):
            if let existing = leaves[pane.id] { existing.removeFromSuperview(); return existing }
            let leaf = PaneLeafView(env: env, model: model, paneID: pane.id)
            leaves[pane.id] = leaf
            return leaf
        case .split(let axis, _, let a, let b):
            let split = PaneSplitNSView()
            split.isVertical = axis == .horizontal
            split.dividerStyle = .thin
            split.path = path
            split.delegate = self
            split.onCommit = { [weak self] in self?.commitFractions() }
            split.addArrangedSubview(build(a, path: path + [0]))
            split.addArrangedSubview(build(b, path: path + [1]))
            return split
        }
    }

    // MARK: Fractions

    private func fraction(of split: NSSplitView) -> Double {
        guard split.subviews.count == 2 else { return 0.5 }
        let total = split.isVertical ? split.bounds.width : split.bounds.height
        let first = split.isVertical ? split.subviews[0].frame.width : split.subviews[0].frame.height
        let usable = total - split.dividerThickness
        return usable > 0 ? Double(first / usable) : 0.5
    }

    private func stateFraction(at path: [Int]) -> Double? {
        var node = root
        for step in path {
            guard case .split(_, _, let a, let b)? = node else { return nil }
            node = step == 0 ? a : b
        }
        if case .split(_, let f, _, _)? = node { return f }
        return nil
    }

    private func fractionsDiffer(_ node: PaneNode) -> Bool {
        splitViews.contains { split in
            guard let want = stateFraction(at: split.path), split.bounds.width > 1 else { return false }
            return abs(fraction(of: split) - want) > 0.02
        }
    }

    override func layout() {
        super.layout()
        guard needsFractions, bounds.width > 1 else { return }
        needsFractions = false
        applyingFractions = true
        defer { applyingFractions = false }
        // Outer splits first: an outer divider changes the size the inner ones divide.
        for split in splitViews.sorted(by: { $0.path.count < $1.path.count }) {
            guard let want = stateFraction(at: split.path), split.subviews.count == 2 else { continue }
            split.layoutSubtreeIfNeeded()
            let total = split.isVertical ? split.bounds.width : split.bounds.height
            let position = (total - split.dividerThickness) * CGFloat(want)
            if abs(fraction(of: split) - want) > 0.005 { split.setPosition(position, ofDividerAt: 0) }
            split.layoutSubtreeIfNeeded()
        }
    }

    /// Called when a divider drag ends: the new fractions go to the store.
    private func commitFractions() {
        for split in splitViews {
            let f = fraction(of: split)
            guard let current = stateFraction(at: split.path), abs(current - f) > 0.005 else { continue }
            model.setFraction(f, tab: tabID, path: split.path)
        }
    }

    // MARK: NSSplitViewDelegate

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMinimumPosition + (splitView.isVertical ? PaneMinimums.width : PaneMinimums.height)
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        proposedMaximumPosition - (splitView.isVertical ? PaneMinimums.width : PaneMinimums.height)
    }

    func splitView(_ splitView: NSSplitView, shouldAdjustSizeOfSubview view: NSView) -> Bool { true }
}

/// A split whose divider drags report when they end (`mouseDown` tracks the whole drag).
final class PaneSplitNSView: NSSplitView {
    var path: [Int] = []
    var onCommit: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onCommit?()
    }
}

/// One pane: a hosting view for `PaneHost`. A mouse press anywhere in it focuses the pane first (hit testing, so no gesture
/// competes with tables, text fields or the log view).
final class PaneLeafView: NSView {
    let paneID: PaneID
    private let hosting: NSHostingView<PaneHost>
    unowned let model: WorkspaceWindowModel
    let dropOverlay = PaneDropOverlay(frame: .zero)

    /// Only the focused pane bridges its toolbar items and title to the window (several panes would fight over the toolbar).
    var isFocused = false {
        didSet {
            guard isFocused != oldValue else { return }
            hosting.sceneBridgingOptions = isFocused ? [.toolbars] : []
        }
    }

    init(env: MacAppEnvironment, model: WorkspaceWindowModel, paneID: PaneID) {
        self.paneID = paneID
        self.model = model
        hosting = NSHostingView(rootView: PaneHost(env: env, model: model, paneID: paneID))
        super.init(frame: .zero)
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = []
        hosting.clipsToBounds = true
        hosting.frame = bounds
        hosting.autoresizingMask = [.width, .height]
        addSubview(hosting)
        dropOverlay.frame = bounds
        dropOverlay.autoresizingMask = [.width, .height]
        addSubview(dropOverlay)          // above the content, never hit-tested
        clipsToBounds = true
        registerForDraggedTypes([.wheelhousePane])     // only pane drags: file drops keep going to the window's import target
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = payload(from: sender), payload.pane != paneID else { dropOverlay.zone = nil; return [] }
        dropOverlay.zone = zone(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { dropOverlay.zone = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { dropOverlay.zone = nil }
        guard let payload = payload(from: sender), payload.pane != paneID else { return false }
        let zone = zone(for: sender)
        let target = paneID
        return model.controller.dockPane(payload, into: model, onto: target, zone: zone)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if let type = NSApp.currentEvent?.type, type == .leftMouseDown || type == .rightMouseDown, !isFocused {
            let id = paneID, model = model
            DispatchQueue.main.async { MainActor.assumeIsolated { model.focus(pane: id) } }
        }
        return super.hitTest(point)
    }
}
