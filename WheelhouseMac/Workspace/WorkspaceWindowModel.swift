import AppKit
import Foundation
import Observation
import WheelhouseKit

/// App-level workspace runtime: the persisted store plus one `WorkspaceWindowModel` per open window (ARCHITECTURE-MAC section 12.1).
/// Menus act on the active window's model (the key window), which is driven by `NSWindow.didBecomeKeyNotification`, not by
/// `@FocusedValue`: a focused value inside a nested hosting view is not guaranteed to reach the menu bar.
@MainActor @Observable
final class WorkspaceController {
    let store: WorkspaceStore
    let registry: ClusterRegistry
    private(set) var activeWindowID: WorkspaceWindowID?
    /// The detached pane window that is key, if the last window to become key was one (menus must not act on a background window).
    private(set) var activeDetachedID: PaneID?
    @ObservationIgnored private(set) var models: [WorkspaceWindowID: WorkspaceWindowModel] = [:]
    @ObservationIgnored private(set) var detachedModels: [PaneID: WorkspaceWindowModel] = [:]
    /// Set by the scenes (SwiftUI's `openWindow`): opening a workspace window or a detached pane window.
    @ObservationIgnored var openWorkspaceWindow: ((WorkspaceWindowID) -> Void)?
    @ObservationIgnored var openDetachedWindow: ((PaneID) -> Void)?
    /// A link or notification tap that arrived while App Lock was engaged (replayed after unlock).
    @ObservationIgnored var pendingURL: URL?
    // M4b
    /// A link or notification tap arrived with no window to show it: the app opens one (it replays `pendingURL`).
    @ObservationIgnored var needsWindow: (() -> Void)?
    /// A pane took the focus on this cluster (the Compass index keeps the most recently focused cluster longest).
    @ObservationIgnored var clusterFocused: ((ClusterID) -> Void)?
    // end M4b
    /// Answers whether App Lock is engaged (set by the app environment); links wait while it is.
    @ObservationIgnored var isLocked: @MainActor () -> Bool = { false }
    /// One connectivity monitor for every window.
    @ObservationIgnored let network = NetworkMonitor()
    @ObservationIgnored let activity: any ActivityLogging
    /// Panes of other windows follow the registry's cluster when this changes (set by the app for tests).
    @ObservationIgnored let sidebarFactory: @MainActor () -> SidebarModel

    init(store: WorkspaceStore, registry: ClusterRegistry, activity: any ActivityLogging = NoopActivityLog(),
         sidebarFactory: @escaping @MainActor () -> SidebarModel) {
        self.store = store
        self.registry = registry
        self.activity = activity
        self.sidebarFactory = sidebarFactory
    }

    var activeModel: WorkspaceWindowModel? {
        if let id = activeDetachedID, let m = detachedModels[id] { return m }
        if let id = activeWindowID, let m = models[id] { return m }
        return models.values.first
    }

    var allModels: [WorkspaceWindowModel] { Array(models.values) + Array(detachedModels.values) }

    func model(for id: WorkspaceWindowID) -> WorkspaceWindowModel {
        if let m = models[id] { return m }
        store.ensureWindow(id)
        let factory = sidebarFactory
        let m = WorkspaceWindowModel(scope: .window(id), controller: self, sidebar: { factory() })
        models[id] = m
        store.windowAppeared(id)
        m.sidebar.restore(store.state(for: id).sidebar.persisted)
        return m
    }

    func detachedModel(for pane: PaneID) -> WorkspaceWindowModel {
        if let m = detachedModels[pane] { return m }
        let factory = sidebarFactory
        let m = WorkspaceWindowModel(scope: .detached(pane), controller: self, sidebar: { factory() })
        detachedModels[pane] = m
        store.detachedAppeared(pane)
        return m
    }

    /// Badges of the sidebars of windows that can be seen (a hidden window's sidebar costs nothing).
    func refreshSidebarBadges() {
        for model in allModels where model.isVisible { model.sidebarIfCreated?.refreshBadges() }
    }

    /// Copies each sidebar's disclosure state into its window's state (on resign key, close and quit).
    func syncSidebarState() {
        for (id, model) in models {
            guard let sidebar = model.sidebarIfCreated else { continue }
            let persisted = sidebar.persisted.state
            if store.existingState(for: id)?.sidebar != persisted { store.mutate(id) { $0.sidebar = persisted } }
        }
    }

    func windowClosed(_ id: WorkspaceWindowID) {
        store.windowClosed(id)
        models[id]?.teardown()
        models[id] = nil
        if activeWindowID == id { activeWindowID = nil }
    }

    func becameActiveDetached(_ id: PaneID) { activeDetachedID = id }

    func detachedClosed(_ id: PaneID) {
        store.detachedClosed(id)
        detachedModels[id]?.teardown()
        detachedModels[id] = nil
        if activeDetachedID == id { activeDetachedID = nil }
    }

    func becameActive(_ id: WorkspaceWindowID) {
        activeWindowID = id
        activeDetachedID = nil
        models[id]?.focusedPaneChanged()
    }

    /// ⌘N: a new window with the Fleet, or, when every window is closed, the window the last run left saved (no second, ghost window).
    func newWindowOrReopenLast() {
        if store.liveWindows.isEmpty, let saved = store.windowOrder.first(where: { !store.liveWindows.contains($0) }) {
            openWorkspaceWindow?(saved)
            return
        }
        newWindow()
    }

    /// A corrupt `workspace.json` was moved aside at launch: say so once, with where it went.
    func announceMovedAsideFileOnce() {
        guard !announcedMovedAside, let moved = store.movedAsideCorruptFile else { return }
        announcedMovedAside = true
        let alert = NSAlert()
        alert.messageText = "Your saved windows couldn't be read"
        alert.informativeText = "Wheelhouse started with a fresh window. The unreadable file was kept as \(moved.lastPathComponent) in its folder."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
    @ObservationIgnored private var announcedMovedAside = false

    /// Opens a new workspace window (⌘N) showing the Fleet.
    func newWindow(_ state: WorkspaceWindowState = .fresh()) {
        let id = store.createWindow(state)
        openWorkspaceWindow?(id)
    }

    /// Window ▸ Merge All Windows: every other window's tabs join the active window as tabs.
    func mergeAllWindows() {
        guard let target = activeModel else { return }
        let moving = models.values.filter { $0 !== target }.flatMap { model in model.state.allPanes.map { (model, $0.id) } }
            + detachedModels.compactMap { id, model in model === target ? nil : (model, id) }
        let dirty = moving.filter { $0.0.hasUnsavedEdits($0.1) }.count
        guard dirty == 0 || confirmsDiscardingEdits(dirty, .move) else { return }
        for (id, model) in models where model !== target {
            // Placeholder tabs travel with their JSON; the source is reset so no tab or pane ID exists in two windows, even when its
            // NSWindow is already gone and cannot be closed.
            let tabs = store.state(for: id).tabs
            target.mutate { state in for tab in tabs { state.addTab(tab, select: false) } }
            model.mutate { $0 = WorkspaceWindowState.fresh() }
            model.closeWindow(asked: true)
        }
        for (id, entry) in store.detached {
            guard let pane = store.takeDetached(id) else { continue }
            target.mutate { state in state.addTab(TabState(root: .leaf(pane), focusedPane: pane.id), select: false) }
            detachedModels[id]?.closeWindow(asked: true)
            _ = entry
        }
    }

    /// A pane dragged onto `targetPane` of `target` at `zone`: within a window it docks, from another window or from a detached
    /// window it moves. Returns false when it cannot (the source's only pane stays where it is).
    @discardableResult
    func dockPane(_ payload: PaneDragPayload, into target: WorkspaceWindowModel, onto targetPane: PaneID, zone: DropZone) -> Bool {
        if let source = payload.window, case .window(let own) = target.scope, source == own {
            target.dock(payload.pane, onto: targetPane, zone: zone)
            return true
        }
        // Check the target before anything is taken out of the source.
        guard target.pane(targetPane) != nil, let source = payload.window, let sourceModel = models[source],
              sourceModel.mayMoveToAnotherWindow([payload.pane]) else { return false }
        let pane: PaneState? = sourceModel.mutate { $0.extractPane(payload.pane) }
        sourceModel.pruneRouters()
        guard let pane else { return false }
        target.mutate { $0.insertForeign(pane, onto: targetPane, zone: zone) }
        target.focusedPaneChanged()
        return true
    }

    /// True when docking the dragged pane into `target` moves it to another window while it holds unapplied edits (the move asks).
    func dockingNeedsConfirmation(_ payload: PaneDragPayload, into target: WorkspaceWindowModel) -> Bool {
        guard let source = payload.window, let sourceModel = models[source] else { return false }
        if case .window(let own) = target.scope, own == source { return false }
        return sourceModel.hasUnsavedEdits(payload.pane)
    }

    /// Reopens what the last run left open, once the first window exists.
    func restoreRemainingWindows() {
        let restorable = store.takeRestorableWindows()
        for id in restorable.windows { openWorkspaceWindow?(id) }
        for id in restorable.panes { openDetachedWindow?(id) }
    }

    // MARK: Links and Stations

    /// A `wheelhouse://` link or a notification tap. `wheelhouse://station/<id>` opens a Station; everything else goes to the
    /// active window's focused pane. Links never open a terminal or start a mutation (DESIGN-MAC section 3.5).
    func handle(url: URL) {
        // The lock comes first, for every link (a Station link too): it waits and replays after unlock.
        guard !isLocked() else { pendingURL = url; if activeModel == nil { needsWindow?() }; return }
        if url.scheme == "wheelhouse", url.host == "station" {
            let id = url.pathComponents.dropFirst().first ?? ""
            if let station = store.stations.first(where: { $0.id.rawValue == id }), confirmsLinkedStation(station) { open(station: station, fromLink: true) }
            return
        }
        guard let model = activeModel else { pendingURL = url; needsWindow?(); return }
        model.openURL(url)
    }

    /// A bound Station opens in a new window; a template asks for its clusters first.
    /// A link must not open a layout by itself: the person confirms first (tests replace this).
    @ObservationIgnored var confirmsLinkedStation: (Station) -> Bool = { station in
        let alert = NSAlert()
        alert.messageText = "Open the Station “\(station.name)”?"
        alert.informativeText = "A link asked Wheelhouse to open this saved layout. Terminals in it will not start."
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// What would lose an unapplied edit.
    enum DiscardReason { case move, close, quit }

    /// Moving panes with unapplied edits to another window, closing them, or quitting discards those edits: the person confirms
    /// first (tests replace this).
    @ObservationIgnored var confirmsDiscardingEdits: @MainActor (_ panes: Int, _ reason: DiscardReason) -> Bool = { panes, reason in
        let alert = NSAlert()
        let one = panes == 1
        switch reason {
        case .move:
            alert.messageText = one ? "Move the pane and discard its unapplied changes?" : "Move the panes and discard their unapplied changes?"
            alert.informativeText = "A pane that moves to another window opens its screens again, so an edit that was not applied is lost. To keep it, apply or copy it first."
            alert.addButton(withTitle: "Move and Discard")
        case .close:
            alert.messageText = one ? "Close the pane and discard its unapplied changes?" : "Close and discard the unapplied changes of \(panes) panes?"
            alert.informativeText = "An edit that was not applied is lost when its pane closes. To keep it, apply or copy it first."
            alert.addButton(withTitle: "Close and Discard")
        case .quit:
            alert.messageText = one ? "Quit and discard an unapplied change?" : "Quit and discard the unapplied changes of \(panes) panes?"
            alert.informativeText = "Edits that were not applied are not saved. To keep them, apply or copy them first."
            alert.addButton(withTitle: "Quit and Discard")
        }
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Panes of every window that hold unapplied edits (quitting asks when there are any).
    var panesWithUnsavedEdits: Int {
        allModels.reduce(0) { count, model in count + model.state.allPanes.filter { model.hasUnsavedEdits($0.id) }.count }
    }

    func open(station: Station, clusters: [ClusterID: ClusterID]? = nil, fromLink: Bool = false) {
        if station.isTemplate, clusters == nil {
            let needed = station.placeholders
            if needed.count == 1, registry.clusters.count == 1, let only = registry.clusters.first {
                newWindow(store.instantiate(station, clusters: [needed[0]: only.id], dropTerminals: fromLink))
            } else {
                activeModel?.sheet = .pickClusters(station.id, fromLink: fromLink)
            }
            return
        }
        newWindow(store.instantiate(station, clusters: clusters ?? [:], dropTerminals: fromLink))
    }

    /// The template picker's Open: every placeholder left unchosen takes the first cluster. `fromLink` travels with the picker
    /// sheet, so a Station a link opened never starts its terminals, picker or not.
    func open(station: Station, picked chosen: [ClusterID: ClusterID], fromLink: Bool) {
        var map = chosen
        for p in station.placeholders where map[p] == nil { if let first = registry.clusters.first { map[p] = first.id } }
        open(station: station, clusters: map, fromLink: fromLink)
    }
}

/// One window's runtime: its pane routers, visibility, sidebar and every action the menus and the UI perform. State itself lives in
/// the store; a detached pane window is a window of one pane, handled by the same operations through a synthesized state.
@MainActor @Observable
final class WorkspaceWindowModel {
    enum Scope: Hashable { case window(WorkspaceWindowID), detached(PaneID) }

    let scope: Scope
    /// Strong: the controller drops the model when its window closes, which ends the cycle.
    let controller: WorkspaceController
    /// The window's resource tree state. Created on first use: a detached pane window has no sidebar and so triggers no discovery
    /// or rules review.
    private let makeSidebar: @MainActor () -> SidebarModel
    @ObservationIgnored private var createdSidebar: SidebarModel?
    var sidebar: SidebarModel {
        if let createdSidebar { return createdSidebar }
        let made = makeSidebar()
        createdSidebar = made
        return made
    }
    var sidebarIfCreated: SidebarModel? { createdSidebar }
    /// False while the window is miniaturised or covered: nothing draws.
    private(set) var isVisible = true
    /// False once the window has been hidden for the grace period: pane content that only holds store consumers is torn down.
    private(set) var buildsContent = true
    /// A sheet requested by a command (save Station, Stations, template clusters).
    var sheet: WorkspaceSheet?
    var isInspectorOpen: Bool {
        get { if case .window(let id) = scope { controller.store.state(for: id).inspector.isOpen } else { false } }
        set { setInspector { $0.isOpen = newValue } }
    }
    @ObservationIgnored weak var window: NSWindow?
    @ObservationIgnored private var routers: [PaneID: AppRouter] = [:]
    @ObservationIgnored private var graceTask: Task<Void, Never>?
    @ObservationIgnored var releaseGrace: TimeInterval = MacEnergyCoordinator.defaultReleaseGrace
    @ObservationIgnored var sleep: @Sendable (TimeInterval) async -> Void = { try? await Task.sleep(for: .seconds($0)) }
    /// A count of the panes built and torn down, for tests and the soak's leak checks.
    @ObservationIgnored private(set) var routerCount = 0

    init(scope: Scope, controller: WorkspaceController, sidebar: @escaping @MainActor () -> SidebarModel) {
        self.scope = scope
        self.controller = controller
        self.makeSidebar = sidebar
    }

    var store: WorkspaceStore { controller.store }
    /// True for a detached pane window (it has no Rail).
    var isDetachedScope: Bool { if case .detached = scope { true } else { false } }
    var registry: ClusterRegistry { controller.registry }

    // MARK: State

    /// The window's state (for a detached pane: a synthesized one-tab window around the pane).
    var state: WorkspaceWindowState {
        switch scope {
        case .window(let id): return store.state(for: id)
        case .detached(let id):
            let pane = store.detachedPane(id) ?? PaneState(id: id)
            var tab = TabState(id: TabID(rawValue: id.rawValue), root: .leaf(pane), focusedPane: id)
            tab.raw = nil
            return WorkspaceWindowState(tabs: [tab])
        }
    }

    @discardableResult
    func mutate<T>(_ change: (inout WorkspaceWindowState) -> T) -> T {
        switch scope {
        case .window(let id): return store.mutate(id, change)
        case .detached(let id):
            var temp = state
            let result = change(&temp)
            if let pane = temp.tabs.first?.root.pane(id) { store.mutateDetached(id) { $0 = pane } }
            return result
        }
    }

    func pane(_ id: PaneID) -> PaneState? { state.pane(id) }
    var selectedTab: TabState { state.selected }
    var focusedPaneID: PaneID { selectedTab.focusedPane }
    var focusedPane: PaneState? { selectedTab.focused }

    private func setInspector(_ change: (inout InspectorState) -> Void) {
        guard case .window = scope else { return }
        mutate { change(&$0.inspector) }
    }

    // MARK: Routers

    /// The pane's own router: `push` appends to the pane's stack and absolute `open` goes to the workspace (ARCHITECTURE-MAC 12.2).
    func router(for pane: PaneID) -> AppRouter {
        if let router = routers[pane] { return router }
        let router = AppRouter()
        router.isCompact = false
        router.paneNavigation = AppRouter.PaneNavigation(
            push: { [weak self] route, _ in self?.push(route, from: pane, commandHeld: NSEvent.modifierFlags.contains(.command)) },
            open: { [weak self] route in self?.open(route: route) },
            openChain: { [weak self] chain in self?.open(chain: chain) })
        // fix-P: one-click port-forward. The launcher lives with the router; the advanced form is a sheet on this pane's router.
        let launcher = PortForwardLauncher.live(registry: registry, isLocked: { [weak self] in self?.controller.isLocked() ?? false }) { [weak router] ref in router?.sheet = PresentedRoute(route: .portForward(ref)) }
        router.portForwardHost = launcher
        router.portForwardStarter = { [weak launcher] ref, port, configure in
            guard let launcher else { return }
            Task { await launcher.forward(ref, port: port, configure: configure) }
        }
        routers[pane] = router
        routerCount += 1
        return router
    }

    var focusedRouter: AppRouter { router(for: focusedPaneID) }

    /// The router of the window itself (the welcome screen). It is not a pane router: its navigation is the plain one.
    @ObservationIgnored lazy var windowRouter: AppRouter = { let r = AppRouter(); r.isCompact = false; return r }()

    /// Drops the routers of panes that no longer exist (a closed pane must not keep its router alive).
    func pruneRouters() {
        let alive = Set(state.allPanes.map(\.id))
        for id in routers.keys where !alive.contains(id) { routers[id] = nil }
        for id in editors.keys where !alive.contains(id) { editors[id] = nil }
        refreshUnsavedEdits()
    }

    /// App Lock engaged: every sheet above this window's content goes, the window's own (Stations, Save Station, the cluster
    /// picker), the welcome screen's and every pane's (sign-in, merge review, a feature's sheet), built or not.
    func dismissSheetsForLock() {
        sheet = nil
        windowRouter.sheet = nil
        for router in routers.values {
            router.sheet = nil
            (router.portForwardHost as? PortForwardLauncher)?.dismissForLock()   // fix-P
        }
    }

    /// fix-P: the pane's port-forward launcher (its confirmation and banner are presented by `PaneHost`).
    func launcher(for pane: PaneID) -> PortForwardLauncher? { router(for: pane).portForwardHost as? PortForwardLauncher }

    // MARK: Unsaved edits

    /// An editor of a pane, held weakly: an editor whose screen was torn down no longer counts.
    private final class EditorEntry {
        weak var editor: AnyObject?
        var dirty: Bool
        init(_ editor: AnyObject, dirty: Bool) { self.editor = editor; self.dirty = dirty }
    }
    @ObservationIgnored private var editors: [PaneID: [ObjectIdentifier: EditorEntry]] = [:]
    /// Every report, for tests.
    @ObservationIgnored var onEditorReport: ((PaneID, AnyObject, Bool) -> Void)?

    /// An editor in `pane` says whether it holds unsaved edits (``PaneEditsReporter``).
    func editorReported(_ editor: AnyObject, dirty: Bool, in pane: PaneID) {
        editors[pane, default: [:]][ObjectIdentifier(editor)] = EditorEntry(editor, dirty: dirty)
        refreshUnsavedEdits()
        onEditorReport?(pane, editor, dirty)
    }

    /// True while a pane of this window holds unapplied edits: the window's close button and ⌘W are disabled (closing would lose
    /// them without asking); the pane and window menus ask instead.
    private(set) var windowHasUnsavedEdits = false

    /// Re-reads the editors (an editor whose screen went away is released without a report: checked again after the update).
    func refreshUnsavedEdits() {
        let now = editors.keys.contains(where: hasUnsavedEdits)
        if now != windowHasUnsavedEdits { windowHasUnsavedEdits = now }
        guard now, !refreshScheduled else { return }
        refreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.refreshScheduled = false
                let later = self.editors.keys.contains(where: self.hasUnsavedEdits)
                if later != self.windowHasUnsavedEdits { self.windowHasUnsavedEdits = later }
            }
        }
    }
    @ObservationIgnored private var refreshScheduled = false

    /// Closing panes loses their unapplied edits: ask first when one of them has some.
    func mayClose(_ panes: [PaneID]) -> Bool {
        let dirty = panes.filter(hasUnsavedEdits)
        return dirty.isEmpty || controller.confirmsDiscardingEdits(dirty.count, .close)
    }

    /// True while an editor of the pane holds edits that were not applied (a YAML draft).
    func hasUnsavedEdits(_ pane: PaneID) -> Bool {
        editors[pane]?.values.contains { $0.editor != nil && $0.dirty } == true
    }

    /// Moving panes to another window rebuilds their screens, which loses an unapplied draft: ask first when one of them has one.
    /// Moves inside the window (split, unsplit, Move ▸ Left…, zoom, docking in the same tab) keep every pane's screen and never ask.
    func mayMoveToAnotherWindow(_ panes: [PaneID]) -> Bool {
        let dirty = panes.filter(hasUnsavedEdits)
        return dirty.isEmpty || controller.confirmsDiscardingEdits(dirty.count, .move)
    }

    /// Critical memory pressure: a hidden window's content goes now, without the grace period.
    func releaseContentNow() { if !isVisible { graceTask?.cancel(); buildsContent = false; MemoryRelief.schedule() } }

    func teardown() {
        graceTask?.cancel()
        routers.removeAll()
        MemoryRelief.schedule()
    }

    var liveRouterIDs: Set<PaneID> { Set(routers.keys) }

    // MARK: Navigation

    /// A route pushed from `pane`: ⌘-click opens a new tab, a selection in a source pane goes to its linked panes, anything else is
    /// pushed onto the pane's stack.
    func push(_ route: Route, from pane: PaneID, commandHeld: Bool = false) {
        if commandHeld { openInNewTab(.route(route)); return }
        if route.isDetail, state.hasLinkedPanes(following: pane) {
            mutate { $0.deliver(selection: route, from: pane) }
            return
        }
        mutate { $0.push(.route(route), in: pane) }
    }

    /// Pushes a feature destination (Chart Room release, Survey finding…) onto a pane.
    func push(_ destination: WorkspaceDestination, from pane: PaneID) {
        mutate { $0.push(destination, in: pane) }
    }

    func setPushed(_ pushed: [WorkspaceDestination], in pane: PaneID) {
        guard state.pane(pane)?.stack.dropFirst().elementsEqual(pushed) == false else { return }
        mutate { $0.setPushed(pushed, in: pane) }
    }

    func openInNewTab(_ destination: WorkspaceDestination, stack: [WorkspaceDestination] = []) {
        var tab = TabState(showing: destination)
        if !stack.isEmpty { tab.root = tab.root.mapPanes { var p = $0; p.stack.append(contentsOf: stack); return p } }
        mutate { $0.addTab(tab) }
        focusedPaneChanged()
    }

    /// Absolute navigation: focus a pane that already shows the route, else open a tab.
    func open(route: Route) { open(chain: [route]) }

    func open(chain: [Route]) {
        guard let first = chain.first else { return }
        let stack = chain.map { WorkspaceDestination.route($0) }
        if let existing = state.allPanes.first(where: { $0.stack == stack }) {
            mutate { $0.focus(pane: existing.id) }
        } else {
            openInNewTab(stack[0], stack: Array(stack.dropFirst()))
        }
        focusedPaneChanged()
    }

    func openURL(_ url: URL) {
        focusedRouter.open(url: url, registry: registry)
    }

    /// A click on a sidebar row: the focused pane shows it (⌘-click: a new tab).
    func selectSidebar(_ destination: SidebarDestination, newTab: Bool = false) {
        let target = WorkspaceDestination(destination)
        if let id = destination.clusterID { registry.select(id) }
        if newTab { openInNewTab(target); return }
        let pane = focusedPaneID
        mutate { $0.setRoot(target, in: pane) }
        focusedPaneChanged()
    }

    /// The row the sidebar highlights: the focused pane's root.
    var selectedSidebarDestination: SidebarDestination? { focusedPane?.root?.sidebarDestination }

    func focus(pane id: PaneID) {
        guard focusedPaneID != id else { return }
        mutate { $0.focus(pane: id) }
        focusedPaneChanged()
    }

    /// Keeps the registry's current cluster and the sidebar's focus on the focused pane's cluster.
    func focusedPaneChanged() {
        // A pane with no cluster of its own (the Fleet) leaves the registry's current cluster as the focus (the sidebar opens it).
        guard let cluster = focusedPane?.context.clusterID ?? focusedPane?.stack.lazy.compactMap(\.clusterID).first ?? registry.currentClusterID else { return }
        if registry.currentClusterID != cluster, registry.config(for: cluster) != nil { registry.select(cluster) }
        controller.clusterFocused?(cluster)
        if case .window = scope { sidebar.focus(cluster: cluster) }
    }

    // MARK: Tabs and panes

    func newTab() { mutate { $0.addTab(TabState(showing: .route(.fleet))) } }

    func closeTab(_ id: TabID) {
        guard mayClose(state.tabs.first { $0.id == id }?.panes.map(\.id) ?? []) else { return }
        let closed = mutate { $0.closeTab(id) }
        if !closed { closeWindow(asked: true); return }
        // The tab's panes are gone: their routers go with them, and the memory their screens used goes back to the system.
        pruneRouters()
        MemoryRelief.schedule()
    }

    func closePane(_ id: PaneID) {
        guard mayClose([id]) else { return }
        let wasPlaceholder = pane(id)?.isPlaceholder == true
        let kept = mutate { $0.closePane(id) }
        routers[id] = nil
        if !kept {
            // A window that holds only a pane that could not be restored is reset to a fresh window instead of closing (closing
            // the last window would keep the unreadable JSON saved for good).
            if wasPlaceholder, case .window = scope { mutate { $0 = WorkspaceWindowState.fresh() } } else { closeWindow(asked: true) }
        }
        pruneRouters()
        MemoryRelief.schedule()
    }

    /// Pane and window menus. A window with unapplied edits asks first (its close button and ⌘W are disabled meanwhile), then
    /// closes without the close button.
    func closeWindow(asked: Bool = false) {
        guard asked || mayClose(state.allPanes.map(\.id)) else { return }
        if windowHasUnsavedEdits { window?.close() } else { window?.performClose(nil) }
    }

    func split(_ axis: SplitAxis, pane: PaneID? = nil) {
        let target = pane ?? focusedPaneID
        mutate { $0.split(target, axis: axis) }
    }

    func focusPane(_ direction: MoveDirection) { mutate { $0.focus(direction) }; focusedPaneChanged() }
    func zoom(pane: PaneID? = nil) { let id = pane ?? focusedPaneID; mutate { $0.toggleZoom(pane: id) } }
    func selectTab(offset: Int) { mutate { $0.selectTab(offset: offset) }; focusedPaneChanged() }
    func select(tab id: TabID) { mutate { $0.select(tab: id) }; focusedPaneChanged() }
    func moveTab(_ id: TabID, to index: Int) { mutate { $0.moveTab(id, to: index) } }
    func movePane(_ id: PaneID, _ direction: MoveDirection) { mutate { $0.movePane(id, direction) } }
    func dock(_ pane: PaneID, onto target: PaneID, zone: DropZone) { mutate { $0.dock(pane, onto: target, zone: zone) } }
    func setFraction(_ fraction: Double, tab: TabID, path: [Int]) {
        mutate { $0.updateTab(tab) { $0.root = $0.root.settingFraction(fraction, at: path) } }
    }

    /// Window ▸ Move Tab to New Window.
    func moveTabToNewWindow(_ id: TabID? = nil) {
        let tabID = id ?? selectedTab.id
        guard mayMoveToAnotherWindow(state.tabs.first { $0.id == tabID }?.panes.map(\.id) ?? []) else { return }
        let taken: TabState? = mutate { $0.takeTab(tabID) }
        guard let taken else { return }
        controller.newWindow(WorkspaceWindowState(tabs: [taken]))
        pruneRouters()
    }

    /// Pane ⋯ ▸ Move ▸ New Window: the pane gets its own detached window.
    func detach(_ id: PaneID) {
        guard mayMoveToAnotherWindow([id]) else { return }
        let extracted: PaneState? = mutate { $0.extractPane(id) }
        guard let pane = extracted else { return }
        store.detach(pane, frame: nil)
        routers[id] = nil
        controller.openDetachedWindow?(pane.id)
        pruneRouters()
    }

    /// A drag that ended outside every window: the pane gets a window of its own where the drag ended.
    func detach(_ id: PaneID, near screenPoint: NSPoint) {
        guard mayMoveToAnotherWindow([id]) else { return }
        let extracted: PaneState? = mutate { $0.extractPane(id) }
        guard let pane = extracted else { return }
        store.detach(pane, frame: [Double(screenPoint.x - 120), Double(screenPoint.y - 40), 720, 520])
        routers[id] = nil
        controller.openDetachedWindow?(pane.id)
        pruneRouters()
    }

    /// Re-attach: a detached pane joins the tab of the active workspace window (or opens as a tab of a new one).
    func attachToWorkspace() {
        guard case .detached(let id) = scope, mayMoveToAnotherWindow([id]), let pane = store.takeDetached(id) else { return }
        if let target = controller.models.values.first(where: { $0.scope == controller.activeWindowID.map(Scope.window) }) ?? controller.models.values.first {
            target.mutate { $0.attach(pane) }
        } else {
            controller.newWindow(WorkspaceWindowState(tabs: [TabState(root: .leaf(pane), focusedPane: pane.id)]))
        }
        closeWindow(asked: true)
    }

    /// The link toggle of a pane header: follow the pane before it in the tab (or stop following).
    func toggleLink(_ id: PaneID) {
        let tab = selectedTab
        let current = pane(id)?.link
        if current != nil { mutate { $0.setLink(id, to: nil) }; return }
        let candidates = tab.root.leaves.filter { $0.id != id && !$0.isPlaceholder }
        guard let source = candidates.first(where: { $0.stack.first?.isListLike == true }) ?? candidates.first else { return }
        let view: LinkedView = pane(id)?.stack.first.map { if case .route(.logs) = $0 { true } else { false } } == true ? .logs : .detail
        mutate { $0.setLink(id, to: source.id, view: view) }
    }

    /// Changes a pane's cluster keeping its view.
    func setCluster(_ cluster: ClusterID, namespace: String?, in pane: PaneID, everyPaneInTab: Bool = false) {
        let ids = everyPaneInTab ? selectedTab.panes.map(\.id) : [pane]
        mutate { s in for id in ids { s.setCluster(cluster, namespace: namespace, in: id) } }
        registry.select(cluster)
        if let namespace { registry.setNamespace(namespace, for: cluster) }
        focusedPaneChanged()
    }

    // MARK: Stations

    func saveStation(named name: String, bindToClusters: Bool) {
        store.saveStation(named: name, from: state, bindToClusters: bindToClusters)
    }

    // MARK: Visibility

    /// The window became visible or hidden (occlusion, minimise). Drawing stops at once; after the grace period (0 under thermal
    /// serious or worse) the content that only holds store consumers is torn down, which releases the shared stores.
    func visibilityChanged(_ visible: Bool, thermalGrace: Bool = EnergyPolicy.current.suspendsHiddenWatches) {
        guard visible != isVisible else { return }
        isVisible = visible
        graceTask?.cancel(); graceTask = nil
        if visible { buildsContent = true; return }
        let grace = thermalGrace ? 0 : releaseGrace
        if grace == 0 { buildsContent = false; MemoryRelief.schedule(); return }
        graceTask = Task { [weak self] in
            guard let self else { return }
            await sleep(grace)
            guard !Task.isCancelled, !isVisible else { return }
            buildsContent = false
            MemoryRelief.schedule()
        }
    }

    /// Destinations that hold nothing but shared-store consumers can be torn down while hidden. The rest keep their state
    /// (unsaved YAML, a pod shell, a followed log) and only stop drawing (\.paneIsVisible = false).
    static func tearsDownWhenHidden(_ destination: WorkspaceDestination?) -> Bool {
        guard let destination else { return true }
        switch destination {
        case .route(let route):
            switch route {
            case .fleet, .alerts, .cluster, .resourceSections, .resourceList, .resourceDetail, .search, .sessions: return true
            case .yaml, .createYAML, .logs, .shell, .portForward, .settings, .addCluster, .importKubeconfig: return false
            }
        default: return false
        }
    }
}

private extension WorkspaceDestination {
    /// A table-like destination a linked pane can follow.
    var isListLike: Bool {
        if case .route(.resourceList) = self { return true }
        return false
    }
}

extension SidebarModel.Persisted {
    var state: SidebarState { SidebarState(expandedClusters: expandedClusters, keepExpanded: keepExpanded, expandedGroups: expandedGroups, showsForbiddenKinds: showsForbiddenKinds) }
}

extension SidebarState {
    var persisted: SidebarModel.Persisted {
        SidebarModel.Persisted(expandedClusters: expandedClusters, keepExpanded: keepExpanded, expandedGroups: expandedGroups, showsForbiddenKinds: showsForbiddenKinds)
    }
}
