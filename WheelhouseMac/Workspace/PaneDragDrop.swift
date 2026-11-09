import AppKit
import SwiftUI
import WheelhouseKit

// Drag-to-dock and tear-off (ARCHITECTURE-MAC risk R19). The menu equivalents (pane ⋯ ▸ Move ▸ Left/Right/Up/Down/New Window and
// Window ▸ Move Tab to New Window) are the primary, tested path; this is the AppKit fallback the spec names for drag:
//
// - the source is an `NSDraggingSource` on the pane header, because a SwiftUI `draggable` cannot say that a drag ended outside every
//   window, which is what tear-off needs;
// - each pane leaf is an `NSDraggingDestination` that registers ONLY the pane pasteboard type, so file drops (kubeconfig import) and
//   every other drag keep going to their own targets, and its overlay returns nil from `hitTest`, so clicks pass through.
//
// The pasteboard carries identifiers only, never state.

extension NSPasteboard.PasteboardType {
    static let wheelhousePane = NSPasteboard.PasteboardType("com.ahmadrezaei.wheelhouse.pane")
}

/// What a dragged pane is: the window it comes from (or nil for a detached pane window) and its pane ID.
struct PaneDragPayload: Codable, Hashable {
    var window: WorkspaceWindowID?
    var pane: PaneID

    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }
    init(window: WorkspaceWindowID?, pane: PaneID) { self.window = window; self.pane = pane }
    init?(data: Data) {
        guard let p = try? JSONDecoder().decode(PaneDragPayload.self, from: data) else { return nil }
        self = p
    }
}

/// The five drop zones of a pane (DESIGN-MAC section 6.5): the outer quarter of each edge docks there, the middle replaces.
enum PaneDropZones {
    static func zone(at point: CGPoint, in size: CGSize) -> DropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let fx = point.x / size.width, fy = point.y / size.height     // fy: 0 at the top
        let edge = 0.25
        let dx = min(fx, 1 - fx), dy = min(fy, 1 - fy)
        if dx >= edge && dy >= edge { return .center }
        if dx < dy { return fx < 0.5 ? .left : .right }
        return fy < 0.5 ? .top : .bottom
    }

    /// The part of the pane a zone covers, in unit coordinates (y from the top).
    static func highlight(_ zone: DropZone) -> CGRect {
        switch zone {
        case .left: CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .right: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        case .center: CGRect(x: 0.05, y: 0.05, width: 0.9, height: 0.9)
        }
    }
}

// MARK: Source

/// A grip on the pane header: dragging it starts a pane drag. It sits behind the header's buttons, so they keep their clicks.
struct PaneDragHandle: NSViewRepresentable {
    let model: WorkspaceWindowModel
    let paneID: PaneID

    func makeNSView(context: Context) -> PaneDragSourceView { PaneDragSourceView(model: model, paneID: paneID) }
    func updateNSView(_ view: PaneDragSourceView, context: Context) { view.model = model; view.paneID = paneID }
}

final class PaneDragSourceView: NSView, NSDraggingSource {
    var model: WorkspaceWindowModel
    var paneID: PaneID
    private var mouseDownEvent: NSEvent?

    init(model: WorkspaceWindowModel, paneID: PaneID) {
        self.model = model
        self.paneID = paneID
        super.init(frame: .zero)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) { mouseDownEvent = event }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownEvent, hypot(event.locationInWindow.x - start.locationInWindow.x, event.locationInWindow.y - start.locationInWindow.y) > 4 else { return }
        mouseDownEvent = nil
        let window: WorkspaceWindowID?
        if case .window(let id) = model.scope { window = id } else { window = nil }
        let item = NSPasteboardItem()
        item.setData(PaneDragPayload(window: window, pane: paneID).data, forType: .wheelhousePane)
        let dragging = NSDraggingItem(pasteboardWriter: item)
        let title = model.pane(paneID)?.title(registry: model.registry) ?? "Pane"
        let image = Self.chip(title)
        dragging.setDraggingFrame(NSRect(origin: NSPoint(x: bounds.minX, y: bounds.minY), size: image.size), contents: image)
        MainActor.assumeIsolated { PaneDragState.shared.isActive = true }
        beginDraggingSession(with: [dragging], event: start, source: self)
    }

    private static func chip(_ title: String) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 12, weight: .medium), .foregroundColor: NSColor.labelColor]
        let text = NSAttributedString(string: title, attributes: attributes)
        let size = NSSize(width: min(text.size().width + 20, 260), height: 24)
        return NSImage(size: size, flipped: false) { rect in
            NSColor.controlBackgroundColor.withAlphaComponent(0.95).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
            text.draw(in: rect.insetBy(dx: 10, dy: 4))
            return true
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .withinApplication ? .move : []
    }

    /// A drag that no pane accepted and that ended outside every workspace window tears the pane off into a window of its own.
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        MainActor.assumeIsolated { PaneDragState.shared.isActive = false }
        guard operation.isEmpty else { return }
        let overWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain && $0.frame.contains(screenPoint) }
        guard !overWindow else { return }
        let model = model, id = paneID
        DispatchQueue.main.async {
            MainActor.assumeIsolated { model.detach(id, near: screenPoint) }
        }
    }
}

// MARK: Destination

/// True while a pane is being dragged. Only then does each pane carry a drop target, so the target never exists during normal use and
/// cannot intercept a click or a file drop (the kubeconfig import target keeps its drags).
@MainActor @Observable
final class PaneDragState {
    static let shared = PaneDragState()
    var isActive = false
}

/// The drop target of a pane while a pane drag is active: it registers only the pane pasteboard type and shows the zone under the cursor.
struct PaneDropTarget: NSViewRepresentable {
    let model: WorkspaceWindowModel
    let paneID: PaneID

    func makeNSView(context: Context) -> PaneDropTargetView { PaneDropTargetView(model: model, paneID: paneID) }
    func updateNSView(_ view: PaneDropTargetView, context: Context) { view.model = model; view.paneID = paneID }
}

final class PaneDropTargetView: NSView {
    var model: WorkspaceWindowModel
    var paneID: PaneID
    var zone: DropZone? { didSet { needsDisplay = true } }

    init(model: WorkspaceWindowModel, paneID: PaneID) {
        self.model = model
        self.paneID = paneID
        super.init(frame: .zero)
        registerForDraggedTypes([.wheelhousePane])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    func payload(from info: NSDraggingInfo) -> PaneDragPayload? {
        info.draggingPasteboard.data(forType: .wheelhousePane).flatMap(PaneDragPayload.init(data:))
    }

    func zone(for info: NSDraggingInfo) -> DropZone {
        let p = convert(info.draggingLocation, from: nil)
        return PaneDropZones.zone(at: CGPoint(x: p.x, y: p.y), in: bounds.size)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { draggingUpdated(sender) }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let payload = payload(from: sender), payload.pane != paneID else { zone = nil; return [] }
        zone = zone(for: sender)
        return .move
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { zone = nil }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { zone = nil }
        guard let payload = payload(from: sender), payload.pane != paneID else { return false }
        let zone = zone(for: sender)
        let target = paneID
        return MainActor.assumeIsolated { model.controller.dockPane(payload, into: model, onto: target, zone: zone) }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let zone else { return }
        let unit = PaneDropZones.highlight(zone)
        let rect = NSRect(x: bounds.width * unit.minX, y: bounds.height * unit.minY, width: bounds.width * unit.width, height: bounds.height * unit.height).insetBy(dx: 3, dy: 3)
        NSColor.controlAccentColor.withAlphaComponent(0.22).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSColor.controlAccentColor.setStroke()
        let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
        path.lineWidth = 2
        path.stroke()
    }
}
