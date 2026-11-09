import Foundation
import WheelhouseKit

/// Every change to a window's tabs and panes, as pure functions on the state (no UI, no persistence), so the layout rules are unit
/// tested. `WorkspaceStore` applies them to the window it names and saves.
extension WorkspaceWindowState {
    var selectedIndex: Int { tabs.firstIndex { $0.id == selectedTab } ?? 0 }
    var selected: TabState { tabs[selectedIndex] }
    var allPanes: [PaneState] { tabs.flatMap(\.panes) }

    func tabIndex(containing pane: PaneID) -> Int? { tabs.firstIndex { $0.root.pane(pane) != nil } }
    func pane(_ id: PaneID) -> PaneState? { tabs.lazy.compactMap { $0.root.pane(id) }.first }

    // MARK: Tabs

    mutating func select(tab id: TabID) {
        if tabs.contains(where: { $0.id == id }) { selectedTab = id }
    }

    /// Selects the tab `offset` places from the current one, wrapping.
    mutating func selectTab(offset: Int) {
        guard tabs.count > 1 else { return }
        selectedTab = tabs[((selectedIndex + offset) % tabs.count + tabs.count) % tabs.count].id
    }

    /// Opens a tab after the selected one and selects it.
    mutating func addTab(_ tab: TabState, select: Bool = true) {
        raw = nil
        tabs.insert(tab, at: min(selectedIndex + 1, tabs.count))
        if select { selectedTab = tab.id }
    }

    /// Removes a tab. Returns false when it was the window's only tab (nothing is removed: the caller closes the window).
    @discardableResult
    mutating func closeTab(_ id: TabID) -> Bool {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return false }
        let wasSelected = selectedTab == id
        tabs.remove(at: index)
        raw = nil
        if wasSelected { selectedTab = tabs[min(index, tabs.count - 1)].id }
        return true
    }

    mutating func moveTab(_ id: TabID, to destination: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(max(destination, 0), tabs.count))
    }

    /// Takes a tab out of the window (Move Tab to New Window). Nil when it is the only tab.
    mutating func takeTab(_ id: TabID) -> TabState? {
        guard tabs.count > 1, let tab = tabs.first(where: { $0.id == id }) else { return nil }
        closeTab(id)
        return tab
    }

    // MARK: Panes

    mutating func updateTab(_ id: TabID, _ change: (inout TabState) -> Void) {
        guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
        change(&tabs[i])
    }

    mutating func updatePane(_ id: PaneID, _ change: (inout PaneState) -> Void) {
        guard let i = tabIndex(containing: id) else { return }
        // Editing a pane of a tab that could not be read starts a new tab from what the user does: the saved JSON is let go.
        tabs[i].raw = nil
        raw = nil
        tabs[i].root = tabs[i].root.updating(pane: id, change)
    }

    mutating func focus(pane id: PaneID) {
        guard let i = tabIndex(containing: id) else { return }
        tabs[i].focusedPane = id
        selectedTab = tabs[i].id
    }

    mutating func focus(_ direction: MoveDirection) {
        let tab = selected
        if let next = tab.root.neighbour(of: tab.focusedPane, direction) { updateTab(tab.id) { $0.focusedPane = next } }
    }

    mutating func toggleZoom(pane id: PaneID) {
        guard let i = tabIndex(containing: id) else { return }
        tabs[i].zoomedPane = tabs[i].zoomedPane == id ? nil : id
    }

    /// Splits `target`; the new pane inherits its context (DESIGN-MAC section 3.2) and opens `destination` (or is empty).
    @discardableResult
    mutating func split(_ target: PaneID, axis: SplitAxis, showing destination: WorkspaceDestination? = nil) -> PaneID? {
        guard let i = tabIndex(containing: target), let source = tabs[i].root.pane(target) else { return nil }
        var fresh = PaneState(context: source.context, stack: destination.map { [$0] } ?? source.stack.prefix(1).map { $0 })
        if destination == nil, source.isPlaceholder { fresh.stack = [] }
        tabs[i].raw = nil
        raw = nil
        tabs[i].root = tabs[i].root.splitting(target, axis: axis, inserting: fresh)
        tabs[i].focusedPane = fresh.id
        tabs[i].zoomedPane = nil
        return fresh.id
    }

    /// Removes a pane (closing its tab when it was the last one). Returns false when it was the last pane of the window's only
    /// tab: the caller closes the window.
    @discardableResult
    mutating func closePane(_ id: PaneID) -> Bool {
        guard let i = tabIndex(containing: id) else { return true }
        guard let rest = tabs[i].root.removing(pane: id) else {
            return closeTab(tabs[i].id)
        }
        tabs[i].root = rest.mapPanes { pane in
            guard pane.link == id else { return pane }
            var p = pane; p.link = nil; p.linkedView = nil; return p
        }
        tabs[i].raw = nil
        raw = nil
        if tabs[i].focusedPane == id { tabs[i].focusedPane = tabs[i].root.firstPane.id }
        if tabs[i].zoomedPane == id { tabs[i].zoomedPane = nil }
        return true
    }

    /// Takes a pane out of its tab for a move (Move to New Window, detach, drag). Nil when it is the only pane of the only tab.
    mutating func extractPane(_ id: PaneID) -> PaneState? {
        guard let i = tabIndex(containing: id), let pane = tabs[i].root.pane(id) else { return nil }
        if tabs[i].root.leaves.count == 1, tabs.count == 1 { return nil }
        var moved = pane
        moved.link = nil
        moved.linkedView = nil
        closePane(id)
        return moved
    }

    /// Move ▸ Left / Right / Up / Down: the pane goes to that outer edge of its tab.
    mutating func movePane(_ id: PaneID, _ direction: MoveDirection) {
        guard let i = tabIndex(containing: id), tabs[i].root.leaves.count > 1, let pane = tabs[i].root.pane(id), let rest = tabs[i].root.removing(pane: id) else { return }
        tabs[i].raw = nil
        raw = nil
        tabs[i].root = rest.wrapping(pane, direction: direction)
        tabs[i].focusedPane = id
        tabs[i].zoomedPane = nil
    }

    /// Drag-to-dock: `pane` (any pane of this window) lands on `target` at `zone`.
    mutating func dock(_ pane: PaneID, onto target: PaneID, zone: DropZone) {
        guard pane != target, let moved = self.pane(pane), self.pane(target) != nil else { return }
        guard let targetTabBefore = tabIndex(containing: target) else { return }
        var carried = moved
        carried.link = nil
        carried.linkedView = nil
        let targetTab = tabs[targetTabBefore].id
        // Remove from the source without dropping the target's tab.
        guard let sourceIndex = tabIndex(containing: pane) else { return }
        if tabs[sourceIndex].root.leaves.count == 1 {
            guard tabs.count > 1 else { return }
            tabs.remove(at: sourceIndex)
        } else if let rest = tabs[sourceIndex].root.removing(pane: pane) {
            tabs[sourceIndex].root = rest
            if tabs[sourceIndex].focusedPane == pane { tabs[sourceIndex].focusedPane = rest.firstPane.id }
        }
        guard let ti = tabs.firstIndex(where: { $0.id == targetTab }) else { return }
        tabs[ti].root = tabs[ti].root.inserting(carried, at: target, zone: zone)
        tabs[ti].focusedPane = pane
        tabs[ti].zoomedPane = nil
        selectedTab = targetTab
        raw = nil
    }

    /// A pane that comes from another window lands on `target` at `zone`.
    mutating func insertForeign(_ pane: PaneState, onto target: PaneID, zone: DropZone) {
        guard let i = tabIndex(containing: target) else { return }
        var carried = pane
        carried.link = nil
        carried.linkedView = nil
        tabs[i].raw = nil
        raw = nil
        tabs[i].root = tabs[i].root.inserting(carried, at: target, zone: zone)
        tabs[i].focusedPane = carried.id
        tabs[i].zoomedPane = nil
        selectedTab = tabs[i].id
    }

    /// Adds a pane to the selected tab (re-attach of a detached pane): split off the focused pane to the right.
    mutating func attach(_ pane: PaneState) {
        var tab = selected
        let fresh = pane
        tab.root = tab.root.inserting(fresh, at: tab.focusedPane, zone: .right)
        tab.focusedPane = fresh.id
        tab.zoomedPane = nil
        updateTab(tab.id) { $0 = tab }
    }

    // MARK: Navigation inside a pane

    mutating func setRoot(_ destination: WorkspaceDestination, in pane: PaneID) {
        updatePane(pane) {
            $0.stack = [destination]
            if let cluster = destination.clusterID { $0.context.clusterID = cluster }
        }
    }

    mutating func push(_ destination: WorkspaceDestination, in pane: PaneID) {
        updatePane(pane) {
            $0.stack.append(destination)
            if let cluster = destination.clusterID { $0.context.clusterID = cluster }
        }
    }

    mutating func pop(in pane: PaneID) {
        updatePane(pane) { if $0.stack.count > 1 { $0.stack.removeLast() } }
    }

    /// Replaces the pushed part of the stack (the path of a `NavigationStack`), keeping the root.
    mutating func setPushed(_ pushed: [WorkspaceDestination], in pane: PaneID) {
        updatePane(pane) { if let root = $0.stack.first { $0.stack = [root] + pushed } }
    }

    // MARK: Linked panes

    mutating func setLink(_ pane: PaneID, to source: PaneID?, view: LinkedView = .detail) {
        guard source != pane else { return }
        updatePane(pane) { $0.link = source; $0.linkedView = source == nil ? nil : view }
    }

    /// The pane `source` selected `selection` (a detail route): every pane linked to it shows it, REPLACING its stack (a stack
    /// of logs panes would hold one live follow per click). Returns the panes that changed.
    @discardableResult
    mutating func deliver(selection: Route, from source: PaneID) -> [PaneID] {
        guard let i = tabIndex(containing: source) else { return [] }
        let targets = tabs[i].root.leaves.filter { $0.link == source }
        for target in targets {
            let route: Route
            if target.linkedView == .logs, case .resourceDetail(let ref) = selection, ref.kind == .pod {
                route = .logs(ref, container: nil, previous: false)
            } else {
                route = selection
            }
            updatePane(target.id) {
                $0.stack = [.route(route)]
                if let cluster = route.clusterID { $0.context.clusterID = cluster }
            }
        }
        return targets.map(\.id)
    }

    /// True when some pane of the tab follows `source`.
    func hasLinkedPanes(following source: PaneID) -> Bool {
        guard let i = tabIndex(containing: source) else { return false }
        return tabs[i].root.leaves.contains { $0.link == source }
    }

    // MARK: Contexts

    /// Moves a pane to another cluster keeping its view: its destinations follow (DESIGN-MAC section 3.2).
    mutating func setCluster(_ cluster: ClusterID, namespace: String?, in pane: PaneID, replacingStack: Bool = true) {
        updatePane(pane) { p in
            let old = p.context.clusterID
            p.context = PaneContext(clusterID: cluster, namespace: namespace)
            if replacingStack, let old, old != cluster { p.stack = p.stack.map { $0.replacingClusters { $0 == old ? cluster : $0 } } }
        }
    }
}
