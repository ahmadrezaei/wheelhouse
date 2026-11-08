#if os(macOS)
import Foundation
import AppKit

/// Identity and change marker of one table row. A row is "updated" when its `version` changes (the object's resourceVersion plus
/// anything shown that does not come from the object, such as metrics).
struct KubeRowKey: Hashable, Sendable {
    var id: String
    var version: String
}

/// What changed between two row arrays, as table-view operations (ARCHITECTURE-MAC section 12.3.4 item 2).
struct KubeTableDelta: Equatable, Sendable {
    /// Row indexes in the OLD array that disappeared.
    var removed = IndexSet()
    /// Row indexes in the NEW array that appeared.
    var inserted = IndexSet()
    /// Row indexes in the NEW array whose content changed.
    var updated = IndexSet()
    /// The order changed (sort or filter change) or too much changed: reload everything.
    var needsReload = false

    var isEmpty: Bool { removed.isEmpty && inserted.isEmpty && updated.isEmpty && !needsReload }
}

enum KubeTableDiffer {
    /// Computes the delta. When the rows that survive keep their relative order, the change is expressed as removals, insertions and
    /// updates; when the order changed, or more than half the rows are touched, `needsReload` is set instead.
    static func diff(old: [KubeRowKey], new: [KubeRowKey]) -> KubeTableDelta {
        if old.isEmpty || new.isEmpty { return KubeTableDelta(needsReload: !(old.isEmpty && new.isEmpty)) }
        var oldIndex: [String: Int] = [:]
        oldIndex.reserveCapacity(old.count)
        for (i, k) in old.enumerated() { oldIndex[k.id] = i }
        var newIDs = Set<String>()
        newIDs.reserveCapacity(new.count)
        for k in new { newIDs.insert(k.id) }
        if newIDs.count != new.count || oldIndex.count != old.count { return KubeTableDelta(needsReload: true) }   // duplicate ids

        var delta = KubeTableDelta()
        var lastOld = -1
        for (i, k) in new.enumerated() {
            guard let o = oldIndex[k.id] else { delta.inserted.insert(i); continue }
            if o < lastOld { return KubeTableDelta(needsReload: true) }           // survivors changed relative order
            lastOld = o
            if old[o].version != k.version { delta.updated.insert(i) }
        }
        for (i, k) in old.enumerated() where !newIDs.contains(k.id) { delta.removed.insert(i) }
        let touched = delta.removed.count + delta.inserted.count + delta.updated.count
        if touched > max(old.count, new.count) / 2 && touched > 8 { return KubeTableDelta(needsReload: true) }
        return delta
    }
}

extension NSTableView {
    /// Applies a delta: `removeRows`, `insertRows` and `reloadData(forRowIndexes:)` keep selection and scroll position. This file is the
    /// only place in the table code allowed to call `reloadData()` (lint rule): on the first load, a reorder, or a change that touches
    /// more than half the rows.
    func applyKubeDelta(_ delta: KubeTableDelta) {
        if delta.needsReload { reloadData(); return }
        if delta.isEmpty { return }
        beginUpdates()
        if !delta.removed.isEmpty { removeRows(at: delta.removed, withAnimation: []) }
        if !delta.inserted.isEmpty { insertRows(at: delta.inserted, withAnimation: []) }
        endUpdates()
        if !delta.updated.isEmpty {
            reloadData(forRowIndexes: delta.updated, columnIndexes: IndexSet(integersIn: 0..<numberOfColumns))
        }
    }

    /// Reloads while keeping the selection (by row id) and the top visible row.
    func reloadKeepingState(ids: [String], selectedIDs: Set<String>, anchorID: String?, anchorOffset: CGFloat) {
        reloadData()
        guard let clip = enclosingScrollView?.contentView else { return }
        if !selectedIDs.isEmpty {
            let rows = IndexSet(ids.enumerated().filter { selectedIDs.contains($0.element) }.map(\.offset))
            selectRowIndexes(rows, byExtendingSelection: false)
        }
        if let anchorID, let i = ids.firstIndex(of: anchorID) {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: max(0, rect(ofRow: i).minY + anchorOffset)))
            enclosingScrollView?.reflectScrolledClipView(clip)
        }
    }
}
#endif
