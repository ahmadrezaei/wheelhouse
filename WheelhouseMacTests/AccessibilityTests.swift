import AppKit
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The accessibility pass: announcements, custom actions, labels, and the keyboard focus of a hosted workspace window.
@MainActor
@Suite("AccessibilityTests", .serialized)
struct AccessibilityTests {
    // MARK: Announcements

    @Test func aToastIsAnnouncedAndAFailureInterrupts() throws {
        let saved = AccessibilityAnnouncer.poster
        defer { AccessibilityAnnouncer.poster = saved }
        var heard: [(String, Bool)] = []
        AccessibilityAnnouncer.poster = { heard.append(($0, $1)) }
        let config = DemoFleet.configs[0]
        let host = ActionHost(session: ClusterSession(config: config, client: DemoKubeClient(config: config)))
        host.show(ActionToast(message: "Scaled web to 3"))
        host.show(ActionToast(message: "Scale failed", symbol: "xmark.octagon.fill", tone: .critical))
        #expect(heard.map(\.0) == ["Scaled web to 3", "Scale failed"])
        #expect(heard.map(\.1) == [false, true])
        AccessibilityAnnouncer.announce("")
        #expect(heard.count == 2)
    }

    @Test func compassSpeaksResultCountsAndTheSelectedRow() {
        #expect(CompassModel.resultsSummary(0) == "No results")
        #expect(CompassModel.resultsSummary(1) == "1 result")
        #expect(CompassModel.resultsSummary(7) == "7 results")
    }

    // MARK: Labels

    @Test func paneLabelsNameTheClusterAndProduction() {
        let prod = ClusterConfig(name: "prod-eu", server: URL(string: "https://p.example.com")!, environment: .production)
        let dev = ClusterConfig(name: "dev", server: URL(string: "https://d.example.com")!, environment: .development)
        #expect(PaneHost.accessibilityLabel(title: "Pods", cluster: prod) == "Pane, Pods, prod-eu, Production")
        #expect(PaneHost.accessibilityLabel(title: "Pods", cluster: dev) == "Pane, Pods, dev")
        #expect(PaneHost.accessibilityLabel(title: "Fleet", cluster: nil) == "Pane, Fleet")
    }

    @Test func driftDotsHaveWords() {
        #expect(DriftWords.label(nil) == "Not checked")
        #expect(DriftWords.label(.inSync) == "In sync")
        #expect(DriftWords.label(.missing) == "Missing from the cluster")
        #expect(DriftWords.label(.drifted(paths: ["a", "b"])) == "Differs: a, b")
        #expect(DriftWords.label(.unreadable("denied")) == "denied")
    }

    // MARK: Custom actions

    @Test func rowActionsAreCustomActionsWithoutSeparators() {
        var ran: [String] = []
        let actions = [KubeRowAction(title: "Logs", handler: { ran.append("logs") }), .separator, KubeRowAction(title: "Delete", isDestructive: true, handler: { ran.append("delete") })]
        let custom = KubeRowView.customActions(for: actions)
        #expect(custom.map(\.name) == ["Logs", "Delete"])
        #expect(custom[1].handler?() == true)
        #expect(ran == ["delete"])
        let sidebar = SidebarScrollView.customActions(for: [SidebarMenuItem(title: "Open in New Tab", handler: { ran.append("tab") }), .separator])
        #expect(sidebar.map(\.name) == ["Open in New Tab"])
        #expect(sidebar[0].handler?() == true)
        #expect(ran == ["delete", "tab"])
    }

    @Test func aRowViewAsksItsTableForActionsAtTheTimeOfTheQuestion() async throws {
        let table = KubeTableScrollView()
        table.assumeVisible = true
        table.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        var label = "first"
        var handled = 0
        table.actions = { _ in [KubeRowAction(title: "Open", handler: { handled += 1 })] }
        let cols = KubeColumn.columns(for: .pod, showNamespace: false, extra: [])
        func row(_ i: Int) -> KubeTableRow {
            KubeTableRow(id: "p\(i)", name: "pod-\(i)", namespace: "shop", status: "Running", tone: .healthy, ready: "1/1", upToDate: "", restarts: "0", node: "n1",
                         cpu: "1m", memory: "4Mi", details: "", age: "3d", extra: [], accessibility: "pod-\(i), \(label)")
        }
        table.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false, keys: [KubeRowKey(id: "p0", version: "1")], rowAt: row)
        let view = table.rowView(at: 0) as? KubeRowView
        #expect(view != nil)
        #expect(view?.accessibilityLabel() == "pod-0, first")
        #expect(view?.accessibilityCustomActions()?.map(\.name) == ["Open"])
        _ = view?.accessibilityCustomActions()?.first?.handler?()
        #expect(handled == 1)
        // A live update changes the row's data: the label read for the row follows it.
        label = "second"
        table.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false, keys: [KubeRowKey(id: "p0", version: "2")], rowAt: row)
        try await waitUntil { table.rowView(at: 0)?.accessibilityLabel() == "pod-0, second" }
        #expect(table.rowView(at: 0)?.accessibilityLabel() == "pod-0, second")
    }

    @Test func theRowMenuActsOnTheSelectedRowWhenNothingWasClicked() throws {
        let table = KubeTableScrollView()
        table.assumeVisible = true
        table.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
        table.actions = { id in [KubeRowAction(title: "Open \(id)")] }
        let cols = KubeColumn.columns(for: .pod, showNamespace: false, extra: [])
        func row(_ i: Int) -> KubeTableRow {
            KubeTableRow(id: "p\(i)", name: "pod-\(i)", namespace: "shop", status: "Running", tone: .healthy, ready: "1/1", upToDate: "", restarts: "0", node: "n1",
                         cpu: "1m", memory: "4Mi", details: "", age: "3d", extra: [], accessibility: "")
        }
        table.update(kindID: ResourceKind.pod.id, columns: cols, sort: .status, reversed: false,
                     keys: (0..<3).map { KubeRowKey(id: "p\($0)", version: "1") }, rowAt: row)
        table.selectRows(IndexSet(integer: 1))
        let menu = try #require(table.rowMenu)
        // A right-click on empty space has no clicked row and no menu.
        table.menuNeedsUpdate(menu)
        #expect(menu.items.isEmpty)
        // VoiceOver's Show Menu acts on the selected row.
        let nsTable = try #require(table.nsTable as? KubeNSTable)
        nsTable.menusSelectedRow = true
        table.menuNeedsUpdate(menu)
        #expect(menu.items.map(\.title) == ["Open p1"])
    }

    // MARK: Namespace picker keys

    @Test func theNamespaceHighlightMovesAndStopsAtTheEnds() {
        #expect(NamespacePickerModel.moved(nil, by: 1, count: 3) == 0)
        #expect(NamespacePickerModel.moved(nil, by: -1, count: 3) == 2)
        #expect(NamespacePickerModel.moved(2, by: 1, count: 3) == 2)
        #expect(NamespacePickerModel.moved(0, by: -1, count: 3) == 0)
        #expect(NamespacePickerModel.moved(1, by: 1, count: 3) == 2)
        #expect(NamespacePickerModel.moved(nil, by: 1, count: 0) == nil)
        var model = NamespacePickerModel(selection: .all, clusterNamespaces: ["a", "b", "c"], pinned: ["c"])
        #expect(model.rows == [.all, .namespace("c"), .namespace("a"), .namespace("b")])
        model.toggle(.namespace("a"))
        model.toggle(.namespace("b"))
        #expect(model.selection.names == ["a", "b"])
        model.selectOnly(.namespace("c"))
        #expect(model.selection.names == ["c"])
        model.selectOnly(.all)
        #expect(model.selection.isAll)
        model.toggle(.all)
        #expect(model.selection.isAll)
    }

    // MARK: Hosted window: key-view loop and focus sync

    private func shownViews(_ window: NSWindow, _ fragment: String) -> [NSView] {
        var found: [NSView] = []
        func walk(_ view: NSView) {
            if String(describing: type(of: view)).contains(fragment) { found.append(view) }
            view.subviews.forEach(walk)
        }
        if let content = window.contentView { walk(content) }
        return found
    }

    private func waitUntil(_ timeout: Duration = .seconds(5), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    @MainActor private struct Fixture {
        let env: MacAppEnvironment
        let model: WorkspaceWindowModel
        let cluster: ClusterID
        let window: NSWindow
        var ref: ResourceRef { ResourceRef(clusterID: cluster, kind: .deployment, namespace: "payments", name: "payments-api") }
    }

    private func workspaceWindow() throws -> Fixture {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .deployment, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let controller = NSHostingController(rootView: AnyView(WorkspaceWindowContent(model: model).environment(env)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 40, y: 40, width: 1_300, height: 820), display: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        return Fixture(env: env, model: model, cluster: cluster, window: window)
    }

    private func close(_ f: Fixture) {
        f.window.orderOut(nil)
        f.env.registry.exitDemoMode()
    }

    @Test func aCoveredScreenLeavesTheKeyViewLoop() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shownViews(f.window, "KubeNSTable").contains { !$0.isHiddenOrHasHiddenAncestor } }
        let tables = shownViews(f.window, "KubeNSTable")
        #expect(tables.count == 1)
        #expect(tables.allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
        f.model.push(.resourceDetail(f.ref), from: f.model.focusedPaneID)
        try await waitUntil { shownViews(f.window, "KubeNSTable").allSatisfy { $0.isHiddenOrHasHiddenAncestor } }
        // Hidden: no key view of the loop is a table of the covered screen, and Tab cannot land in it.
        #expect(shownViews(f.window, "KubeNSTable").allSatisfy { $0.isHiddenOrHasHiddenAncestor })
        #expect(shownViews(f.window, "KubeNSTable").allSatisfy { !$0.canBecomeKeyView || $0.isHiddenOrHasHiddenAncestor })
        _ = f.model.goBack(in: f.model.focusedPaneID)
        try await waitUntil { shownViews(f.window, "KubeNSTable").allSatisfy { !$0.isHiddenOrHasHiddenAncestor } }
        #expect(shownViews(f.window, "KubeNSTable").allSatisfy { !$0.isHiddenOrHasHiddenAncestor })
    }

    @Test func aSidebarClickKeepsTheKeyboardInTheSidebar() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shownViews(f.window, "SidebarOutline").first != nil && shownViews(f.window, "KubeNSTable").contains { !$0.isHiddenOrHasHiddenAncestor } }
        let outline = try #require(shownViews(f.window, "SidebarOutline").first)
        f.window.makeKeyAndOrderFront(nil)
        #expect(f.window.makeFirstResponder(outline))
        let sync = PaneFocusSync(window: f.window, model: f.model)
        f.model.selectSidebar(.kind(f.cluster, .configMap))
        try await waitUntil { sync.modelChangeCount > 0 }
        #expect(sync.modelChangeCount > 0)
        #expect(f.window.firstResponder === outline)
    }

    @Test func pushingADetailInASplitNeverMovesTheFocusedPane() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shownViews(f.window, "KubeNSTable").contains { !$0.isHiddenOrHasHiddenAncestor } }
        let first = f.model.focusedPaneID
        f.model.split(.horizontal)
        f.model.focus(pane: first)
        let sync = PaneFocusSync(window: f.window, model: f.model)
        f.model.push(.resourceDetail(f.ref), from: first)
        try await waitUntil { sync.modelChangeCount > 0 }
        #expect(f.model.focusedPaneID == first)
    }

    @Test func aCompassCommandThatMovesTheFocusIsNotUndone() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shownViews(f.window, "KubeNSTable").contains { !$0.isHiddenOrHasHiddenAncestor } }
        f.window.makeKeyAndOrderFront(nil)
        let table = try #require(shownViews(f.window, "KubeNSTable").first { !$0.isHiddenOrHasHiddenAncestor })
        #expect(f.window.makeFirstResponder(table))
        let compass = f.env.compass
        compass.open()
        #expect(compass.isOpen)
        // The command (open in a split) moves the focus to the new pane, then the panel closes.
        f.model.split(.horizontal)
        let created = f.model.focusedPaneID
        compass.close()
        try await waitUntil { compass.focusRestores + compass.focusRestoreSkips > 0 }
        #expect(compass.focusRestores == 0)
        #expect(f.model.focusedPaneID == created)
    }

    @Test func gestureRulesAcceptOnlyTabAndMouseInsideTheResponder() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(view)
        func key(_ code: UInt16, age: TimeInterval = 0) -> NSEvent? {
            NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime - age,
                             windowNumber: window.windowNumber, context: nil, characters: "\t", charactersIgnoringModifiers: "\t", isARepeat: false, keyCode: code)
        }
        func click(_ point: NSPoint) -> NSEvent? {
            NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)
        }
        #expect(PaneFocusSync.isUserGesture(key(48), responder: view, in: window))
        #expect(!PaneFocusSync.isUserGesture(key(36), responder: view, in: window))          // Return
        #expect(!PaneFocusSync.isUserGesture(key(48, age: 1), responder: view, in: window))  // stale
        #expect(!PaneFocusSync.isUserGesture(nil, responder: view, in: window))
        #expect(PaneFocusSync.isUserGesture(click(NSPoint(x: 10, y: 10)), responder: view, in: window))
        #expect(!PaneFocusSync.isUserGesture(click(NSPoint(x: 250, y: 150)), responder: view, in: window))
    }

    @Test func theKeyViewGateGivesTheKeyboardBackWhenShown() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        let field = NSTextView(frame: NSRect(x: 0, y: 0, width: 100, height: 50))
        container.addSubview(field)
        window.contentView?.addSubview(container)
        #expect(window.makeFirstResponder(field))
        let gate = KeyViewGate()
        gate.apply(visible: false, to: container)
        #expect(container.isHidden)
        #expect(window.firstResponder === window)
        gate.apply(visible: true, to: container)
        #expect(!container.isHidden)
        #expect(window.firstResponder === field)
    }

    @Test func keyboardFocusAndTheFocusedPaneFollowEachOther() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { shownViews(f.window, "KubeNSTable").contains { !$0.isHiddenOrHasHiddenAncestor } }
        let first = f.model.focusedPaneID
        f.model.split(.horizontal)
        let second = f.model.focusedPaneID
        #expect(first != second)
        f.model.show(.route(.resourceList(f.cluster, .configMap, namespace: nil)), placement: .here)
        try await waitUntil { shownViews(f.window, "KubeNSTable").filter { !$0.isHiddenOrHasHiddenAncestor }.count == 2 && f.model.paneAnchors.count == 2 }
        let sync = PaneFocusSync(window: f.window, model: f.model)
        let tables = shownViews(f.window, "KubeNSTable").filter { !$0.isHiddenOrHasHiddenAncestor }
        let byPane = Dictionary(uniqueKeysWithValues: tables.compactMap { t in sync.pane(containing: t).map { ($0, t) } })
        #expect(Set(byPane.keys) == [first, second])

        // A responder change by a click or a key press into the other pane focuses it.
        f.window.makeKeyAndOrderFront(nil)
        sync.isUserGesture = { _, _ in true }
        #expect(f.window.makeFirstResponder(byPane[first]))
        sync.responderChanged()
        #expect(f.model.focusedPaneID == first)
        // Without a user gesture (a shell connecting in a background pane, Return on a row) nothing is refocused.
        sync.isUserGesture = { _, _ in false }
        #expect(f.window.makeFirstResponder(byPane[second]))
        sync.responderChanged()
        #expect(f.model.focusedPaneID == first)

        // The other way: the pane focus moved by the keyboard command takes the keyboard with it.
        f.model.focus(pane: second)
        sync.moveKeyboardFocusToFocusedPane()
        let responder = try #require(f.window.firstResponder as? NSView)
        #expect(sync.pane(containing: responder) == second)
        // Already inside the pane: nothing moves.
        sync.moveKeyboardFocusToFocusedPane()
        #expect(f.window.firstResponder === responder)
    }
}
