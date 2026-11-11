import AppKit
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The M4a close-out: unapplied edits and moves between windows, the lock over split panes and sheets, the window toolbar with
/// several panes, and the keyboard of hidden tabs.
@MainActor
@Suite("WorkspaceCloseOutTests")
struct WorkspaceCloseOutTests {
    /// The selected tab of a window, laid out like the shell does (re-evaluated when the window's state changes).
    private struct SelectedTab: View {
        let env: MacAppEnvironment
        let model: WorkspaceWindowModel
        var body: some View { PaneTreeLayout(env: env, model: model, tab: model.selectedTab, isSelected: true) }
    }

    private func host<V: View>(_ view: V, size: NSSize = NSSize(width: 1_000, height: 640)) -> (NSWindow, NSHostingView<AnyView>) {
        let hosting = NSHostingView(rootView: AnyView(view.frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
        hosting.layoutSubtreeIfNeeded()
        return (window, hosting)
    }

    private func waitUntil(_ timeout: Duration = .seconds(10), _ condition: () -> Bool) async throws {
        let end = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < end { try await Task.sleep(for: .milliseconds(50)) }
    }

    private func settle(_ view: NSView) async throws {
        for _ in 0..<4 { view.layoutSubtreeIfNeeded(); try await Task.sleep(for: .milliseconds(80)) }
    }

    private static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let hit = view as? T { return hit }
        for sub in view.subviews { if let hit = find(type, in: sub) { return hit } }
        return nil
    }

    private func controller() -> (WorkspaceController, ClusterID) {
        let a = ClusterConfig(name: "dev-a", server: URL(string: "https://a.invalid:6443")!, environment: .development)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([a]),
                                       defaults: UserDefaults(suiteName: "wh.closeout.\(UUID().uuidString)")!)
        let c = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        return (c, a.id)
    }

    // MARK: F2: unapplied edits and other windows

    @Test func movingAPaneWithUnappliedEditsToAnotherWindowAsksFirst() {
        let (c, cluster) = controller()
        let model = c.model(for: c.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil))),
                                                                                  TabState(showing: .route(.fleet))])))
        let pane = model.selectedTab.focusedPane
        model.split(.horizontal, pane: pane)
        let editor = NSObject()                  // stands for a Manifest Editor's model, held by its screen
        model.editorReported(editor, dirty: true, in: pane)
        #expect(model.hasUnsavedEdits(pane))
        var asked: [Int] = []
        var answer = false
        c.confirmsDiscardingEdits = { asked.append($0); return answer }

        // Moves inside the window never ask.
        model.movePane(pane, .right)
        model.zoom(pane: pane); model.zoom(pane: pane)
        #expect(asked.isEmpty)

        // Detaching asks; declining leaves the pane where it is.
        model.detach(pane)
        #expect(asked == [1])
        #expect(model.pane(pane) != nil && c.store.detached.isEmpty)
        model.moveTabToNewWindow()
        #expect(asked == [1, 1] && model.state.tabs.count == 2)

        // Accepting moves it.
        answer = true
        model.detach(pane)
        #expect(model.pane(pane) == nil && c.store.detached[pane] != nil)
        #expect(!model.hasUnsavedEdits(pane))   // the source window forgets the editor of a pane it no longer has

        // A clean editor, or one whose screen is gone, never asks.
        asked = []
        let other = model.selectedTab.focusedPane
        model.editorReported(editor, dirty: false, in: other)
        model.moveTabToNewWindow()
        #expect(asked.isEmpty)
        do {
            let gone = NSObject()
            model.editorReported(gone, dirty: true, in: model.selectedTab.focusedPane)
        }
        #expect(!model.hasUnsavedEdits(model.selectedTab.focusedPane))
    }

    @Test func mergingWindowsAndDockingIntoAnotherWindowAskForUnappliedEdits() {
        let (c, cluster) = controller()
        let target = c.model(for: c.store.createWindow())
        let source = c.model(for: c.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))])))
        c.becameActive(c.models.first { $0.value === target }!.key)
        let pane = source.selectedTab.focusedPane
        let editor = NSObject()
        source.editorReported(editor, dirty: true, in: pane)
        var asked = 0
        c.confirmsDiscardingEdits = { _ in asked += 1; return false }
        guard case .window(let sourceID) = source.scope else { Issue.record("scope"); return }
        let moved = c.dockPane(PaneDragPayload(window: sourceID, pane: pane), into: target, onto: target.selectedTab.focusedPane, zone: .right)
        #expect(!moved && asked == 1 && source.pane(pane) != nil)
        c.mergeAllWindows()
        #expect(asked == 2 && source.pane(pane) != nil && target.state.tabs.count == 1)
    }

    /// A dirty draft in the Manifest Editor is the same editor, with the same draft, after a split, an unsplit and a zoom: every
    /// pane of a tab is a child of one flat layout keyed by pane ID, so changing the tree never rebuilds a pane.
    @Test func aDirtyYAMLDraftSurvivesSplitUnsplitAndZoom() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        SchemaServices.shared.cacheRoot = FileManager.default.temporaryDirectory.appending(path: "wh-closeout-\(UUID().uuidString)")
        let cluster = try #require(env.registry.clusters.first { !$0.readOnly })
        let session = try #require(env.registry.session(for: cluster.id))
        let list = try await session.client.listRaw(.deployment, namespace: nil, options: ListOptions())
        let first = try #require(list["items"]?.arrayValue?.first)
        let ref = ResourceRef(clusterID: cluster.id, kind: .deployment, namespace: first.value(at: "metadata.namespace")?.stringValue,
                              name: try #require(first.value(at: "metadata.name")?.stringValue))
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.yaml(ref)))]))
        let model = env.workspace.model(for: id)
        let pane = model.focusedPaneID
        var editors: [ObjectIdentifier] = []
        var yaml: YAMLEditorModel?
        model.onEditorReport = { reported, editor, _ in
            if reported == pane { editors.append(ObjectIdentifier(editor)); yaml = editor as? YAMLEditorModel }
        }
        let (window, hosting) = host(SelectedTab(env: env, model: model))
        defer { window.close() }
        try await waitUntil { yaml?.canEdit == true }
        var editor: YAMLEditorModel? = try #require(yaml)
        await editor?.beginEdit()
        editor?.draft += "# an edit that was not applied\n"
        try await waitUntil { model.hasUnsavedEdits(pane) }
        #expect(model.hasUnsavedEdits(pane))

        model.split(.horizontal, pane: pane)
        try await settle(hosting)
        #expect(model.selectedTab.panes.count == 2)
        let added = try #require(model.selectedTab.panes.map(\.id).first { $0 != pane })
        model.zoom(pane: pane)
        try await settle(hosting)
        model.zoom(pane: pane)
        try await settle(hosting)
        model.closePane(added)
        try await settle(hosting)

        #expect(Set(editors).count == 1)                         // one editor, never rebuilt
        #expect(editor?.isDirty == true && editor?.draft.hasSuffix("# an edit that was not applied\n") == true)
        #expect(model.hasUnsavedEdits(pane))
        let shown = try #require(Self.find(CodeEditorScrollView.self, in: hosting))
        #expect(shown.textView.string.contains("# an edit that was not applied"))

        // The pane shows something else: the editor's screen goes, its model with it, and the pane has nothing to lose any more.
        yaml = nil
        editor = nil
        model.mutate { $0.setRoot(.route(.fleet), in: pane) }
        try await settle(hosting)
        try await waitUntil { !model.hasUnsavedEdits(pane) }
        #expect(!model.hasUnsavedEdits(pane))
    }

    // MARK: F3: the lock over sheets and split panes

    @Test func theLockDismissesWindowSheetsAndEveryPanesSheet() {
        let (c, cluster) = controller()
        let model = c.model(for: c.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))])))
        let first = model.focusedPaneID
        model.split(.horizontal, pane: first)
        let second = try? #require(model.selectedTab.panes.map(\.id).first { $0 != first })
        model.sheet = .stations
        model.windowRouter.sheet = PresentedRoute(route: .addCluster)
        model.router(for: first).sheet = PresentedRoute(route: .importKubeconfig)          // a feature's sheet in one leaf
        if let second { model.router(for: second).sheet = PresentedRoute(route: .addCluster) }
        model.dismissSheetsForLock()
        #expect(model.sheet == nil && model.windowRouter.sheet == nil)
        #expect(model.router(for: first).sheet == nil)
        if let second { #expect(model.router(for: second).sheet == nil) }
    }

    // Hidden from accessibility and disabled under the lock: `WheelhouseMacUITests.testLockedSplitLeavesAreHiddenFromAccessibility`
    // (SwiftUI builds no accessibility tree in process without an assistive client, and synthesized clicks do not reach an inactive
    // test window).

    // MARK: F14: hidden tabs and the keyboard

    /// A view of a tab that is not selected: SwiftUI's `allowsHitTesting(false)` makes it take no hits.
    private final class HiddenTextView: NSTextView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @Test func aTabThatIsHiddenGivesUpTheKeyboardButTheVisibleTabAndTheSidebarKeepIt() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        window.contentView = content
        let guardView = HiddenTabResponderGuard.GuardView(frame: NSRect(x: 250, y: 0, width: 550, height: 500))
        content.addSubview(guardView)
        let inHiddenTab = HiddenTextView(frame: NSRect(x: 300, y: 100, width: 300, height: 200))
        let inVisibleTab = NSTextView(frame: NSRect(x: 300, y: 350, width: 300, height: 100))
        let inSidebar = NSTextView(frame: NSRect(x: 10, y: 100, width: 200, height: 200))
        [inHiddenTab, inVisibleTab, inSidebar].forEach(content.addSubview)

        window.makeFirstResponder(inHiddenTab)
        guardView.tabWasHidden()
        #expect(window.firstResponder !== inHiddenTab)
        window.makeFirstResponder(inVisibleTab)          // the newly selected tab focused a field when it appeared
        guardView.tabWasHidden()
        #expect(window.firstResponder === inVisibleTab)
        window.makeFirstResponder(inSidebar)
        guardView.tabWasHidden()
        #expect(window.firstResponder === inSidebar)
    }

    @Test func switchingTabsTakesTheKeyboardFromTheTabThatWasHidden() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil))),
                                                                              TabState(showing: .route(.fleet))]))
        let model = env.workspace.model(for: id)
        let tabs = model.state.tabs.map(\.id)
        model.select(tab: tabs[0])
        struct Tabs: View {
            let env: MacAppEnvironment
            let model: WorkspaceWindowModel
            var body: some View {
                let state = model.state
                ZStack { ForEach(state.tabs, id: \.id) { PaneTreeLayout(env: env, model: model, tab: $0, isSelected: $0.id == state.selectedTab) } }
            }
        }
        let (window, hosting) = host(Tabs(env: env, model: model))
        defer { window.close() }
        try await settle(hosting)
        // A text view of the first tab's area takes the keyboard (a filter field or an editor would).
        let typing = HiddenTextView(frame: NSRect(x: 400, y: 300, width: 200, height: 40))   // the first tab takes no hits once hidden
        hosting.addSubview(typing)
        window.makeFirstResponder(typing)
        #expect(window.firstResponder === typing)
        model.select(tab: tabs[1])
        try await settle(hosting)
        #expect(window.firstResponder !== typing)
    }

    // MARK: F4: the window toolbar with several panes

    /// A window whose toolbar is bridged from SwiftUI the way a `WindowGroup` window's is.
    private func toolbarWindow(env: MacAppEnvironment, model: WorkspaceWindowModel) -> (NSWindow, NSHostingController<AnyView>) {
        let controller = NSHostingController(rootView: AnyView(WorkspaceWindowContent(model: model).environment(env)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 0, y: 0, width: 1_400, height: 860), display: false)
        window.isReleasedWhenClosed = false
        window.orderBack(nil)
        return (window, controller)
    }

    private func toolbarItems(_ window: NSWindow, _ controller: NSHostingController<AnyView>) async throws -> [String] {
        var last: [String] = []
        for _ in 0..<30 {
            controller.view.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(100))
            let now = (window.toolbar?.items ?? []).map { "\(type(of: $0))|\($0.itemIdentifier.rawValue)" }
            if now == last, !now.isEmpty { break }
            last = now
        }
        return last
    }

    /// Two lists and an overview side by side: only the focused pane puts its items and its filter field in the window toolbar. Before,
    /// both lists added a `.searchable` search item and AppKit raised (`NSToolbar already contains an item with the identifier
    /// com.apple.SwiftUI.search`), and every list's namespace and sort menus appeared once per pane.
    @Test func onlyTheFocusedPaneFillsTheWindowToolbarAndItsSearch() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let pods = WorkspaceDestination.route(.resourceList(cluster, .pod, namespace: nil))

        let single = env.workspace.model(for: env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: pods)])))
        let (oneWindow, oneController) = toolbarWindow(env: env, model: single)
        let onePane = try await toolbarItems(oneWindow, oneController)
        oneWindow.close()
        #expect(!onePane.isEmpty)

        let model = env.workspace.model(for: env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: pods)])))
        let first = model.focusedPaneID
        model.split(.horizontal, pane: first)
        let second = try #require(model.selectedTab.panes.map(\.id).first { $0 != first })
        model.mutate { $0.setRoot(.route(.resourceList(cluster, .deployment, namespace: nil)), in: second) }
        model.split(.vertical, pane: second)
        let third = try #require(model.selectedTab.panes.map(\.id).first { $0 != first && $0 != second })
        model.mutate { $0.setRoot(.route(.cluster(cluster)), in: third) }
        model.focus(pane: first)
        let (window, controller) = toolbarWindow(env: env, model: model)
        defer { window.close() }
        let focusedList = try await toolbarItems(window, controller)
        #expect(focusedList.count == onePane.count)               // one list's items, not two
        model.focus(pane: second)
        let otherList = try await toolbarItems(window, controller)
        #expect(otherList.count == onePane.count)
        model.focus(pane: third)
        _ = try await toolbarItems(window, controller)
        #expect(!(window.toolbar?.items ?? []).contains { $0.itemIdentifier.rawValue == "com.apple.SwiftUI.search" })
    }
}
