import SwiftUI
import WheelhouseKit

/// One divider of the pane tree: where it is and what it moves.
struct PaneDivider: Identifiable, Hashable {
    var path: [Int]
    var axis: SplitAxis
    /// The split's own rectangle in unit coordinates.
    var parent: CGRect
    var fraction: Double
    var id: [Int] { path }
}

extension PaneNode {
    /// Every split of the tree with its rectangle.
    func dividers(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1), path: [Int] = []) -> [PaneDivider] {
        guard case .split(let axis, let f, let a, let b) = self else { return [] }
        let (ra, rb) = Self.split(rect, axis: axis, fraction: f)
        return [PaneDivider(path: path, axis: axis, parent: rect, fraction: f)] + a.dividers(in: ra, path: path + [0]) + b.dividers(in: rb, path: path + [1])
    }

    static func split(_ rect: CGRect, axis: SplitAxis, fraction f: Double) -> (CGRect, CGRect) {
        if axis == .horizontal {
            let w = rect.width * f
            return (CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height), CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
        }
        let h = rect.height * f
        return (CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h), CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
    }

    /// The tree with some fractions replaced (a divider being dragged).
    func applying(fractions: [[Int]: Double], path: [Int] = []) -> PaneNode {
        guard case .split(let axis, let f, let a, let b) = self else { return self }
        return .split(axis: axis, fraction: fractions[path] ?? f, first: a.applying(fractions: fractions, path: path + [0]), second: b.applying(fractions: fractions, path: path + [1]))
    }
}

/// The pane tree of one tab, laid out in SwiftUI (ARCHITECTURE-MAC section 12.2).
///
/// Every pane is a direct child of one flat `ZStack`, keyed by its pane ID, and placed by its rectangle. The identity of a pane's view
/// therefore does not depend on the shape of the tree: splitting, unsplitting, moving a pane and zooming never rebuild a pane (a YAML
/// draft or a followed log survives), and the screens keep their toolbars because they are plain SwiftUI views of the window.
/// Dividers are thin handles above the panes; a drag moves the fraction live and commits it on release. Minimum pane size 320 x 180.
struct PaneTreeLayout: View {
    let env: MacAppEnvironment
    let model: WorkspaceWindowModel
    let tab: TabState
    let isSelected: Bool
    @State private var live: [[Int]: Double] = [:]
    @State private var dragStart: [[Int]: Double] = [:]

    static func minimumFraction(side: CGFloat, points: CGFloat) -> Double { side > 0 ? min(0.45, Double(points / side)) : PaneNode.minimumFraction }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let root = tab.root.applying(fractions: live)
            let zoomed = tab.zoomedPane
            let rects = Dictionary(root.layout().map { ($0.id, $0.rect) }, uniquingKeysWith: { first, _ in first })
            ZStack(alignment: .topLeading) {
                ForEach(tab.root.paneIDs, id: \.self) { id in
                    let unit = (zoomed == nil ? rects[id] : (zoomed == id ? CGRect(x: 0, y: 0, width: 1, height: 1) : nil))
                    PaneHost(env: env, model: model, paneID: id)
                        .frame(width: max(1, (unit?.width ?? 0) * size.width - 1), height: max(1, (unit?.height ?? 0) * size.height - 1))
                        .offset(x: (unit?.minX ?? 0) * size.width, y: (unit?.minY ?? 0) * size.height)
                        .opacity(unit == nil ? 0 : 1)
                        .allowsHitTesting(unit != nil)
                        .accessibilityHidden(unit == nil)
                }
                if zoomed == nil {
                    ForEach(root.dividers()) { divider in handle(divider, in: size) }
                }
            }
            .frame(width: size.width, height: size.height, alignment: .topLeading)
        }
        .clipped()
        .opacity(isSelected ? 1 : 0)
        .allowsHitTesting(isSelected)
        .disabled(!isSelected)
    }

    private func handle(_ d: PaneDivider, in size: CGSize) -> some View {
        let horizontal = d.axis == .horizontal
        let parentSide = (horizontal ? d.parent.width * size.width : d.parent.height * size.height)
        let position = (horizontal ? d.parent.minX * size.width + parentSide * d.fraction : d.parent.minY * size.height + parentSide * d.fraction)
        let length = horizontal ? d.parent.height * size.height : d.parent.width * size.width
        let start = horizontal ? d.parent.minY * size.height : d.parent.minX * size.width
        return Rectangle().fill(Color.clear).frame(width: horizontal ? 9 : length, height: horizontal ? length : 9)
            .contentShape(Rectangle())
            .offset(x: horizontal ? position - 4.5 : start, y: horizontal ? start : position - 4.5)
            .onHover { inside in if inside { (horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let base = dragStart[d.path] ?? d.fraction
                    dragStart[d.path] = base
                    let delta = Double((horizontal ? value.translation.width : value.translation.height) / max(1, parentSide))
                    let minFraction = Self.minimumFraction(side: parentSide, points: horizontal ? PaneMinimums.width : PaneMinimums.height)
                    live[d.path] = min(max(base + delta, minFraction), 1 - minFraction)
                }
                .onEnded { _ in
                    if let f = live[d.path] { model.setFraction(f, tab: tab.id, path: d.path) }
                    live[d.path] = nil
                    dragStart[d.path] = nil
                })
            .accessibilityLabel("Pane divider")
            .accessibilityIdentifier("pane.divider")
    }
}
