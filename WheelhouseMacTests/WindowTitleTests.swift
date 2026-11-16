import AppKit
import SwiftUI
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The window title follows the focused pane (it followed the first pane's screen) and is plain "Wheelhouse" while the app is locked, a
/// Tides app opens as a screen of the pane's own stack, and a shell's Close Session leaves through the pane. Each hosts a whole
/// workspace window, with the toolbar and title bridged from SwiftUI the way a `WindowGroup` window's are (the same fixture as
/// `PaneNavigationTests`).
@MainActor
@Suite("WindowTitleTests", .serialized)
struct WindowTitleTests {
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
        var focusedTitle: String { model.focusedPane?.title(registry: env.registry) ?? "" }
    }

    /// `client`: every cluster of the registry (the Demo fleet) answers with it, where the test needs data of its own.
    private func workspaceWindow(root: (ClusterID) -> WorkspaceDestination = { .route(.resourceList($0, .deployment, namespace: nil)) },
                                 client: (any KubeClientProtocol & Sendable)? = nil) throws -> Fixture {
        let env = MacAppEnvironment.live(registryClientFactory: client.map { client -> ClusterRegistry.ClientFactory in { _, _ in client } })
        env.registry.enterDemoMode(persist: false)
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: root(cluster))]))
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
        for sheet in f.window.sheets { f.window.endSheet(sheet) }
        f.window.orderOut(nil)
        f.env.registry.exitDemoMode()
    }

    /// The Overview's table: the one with several columns (the sidebar is a single-column outline).
    private func firstTable(in view: NSView?) -> NSTableView? {
        guard let view else { return nil }
        if let table = view as? NSTableView, table.tableColumns.count > 3 { return table }
        for sub in view.subviews { if let found = firstTable(in: sub) { return found } }
        return nil
    }

    /// A real double click on a table row, through the window's event dispatch.
    private func doubleClick(row: Int, in table: NSTableView, window: NSWindow) async throws {
        window.makeKeyAndOrderFront(nil)
        let rect = table.rect(ofRow: row)
        let point = table.convert(NSPoint(x: min(rect.minX + 40, rect.maxX - 1), y: rect.midY), to: nil)
        for (type, count) in [(NSEvent.EventType.leftMouseDown, 1), (.leftMouseUp, 1), (.leftMouseDown, 2), (.leftMouseUp, 2)] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: count, pressure: 1) else { continue }
            NSApp.postEvent(event, atStart: false)
            try await Task.sleep(for: .milliseconds(60))
        }
    }

    /// True when a segmented control with a segment called `label` is in the window (the detail's sections).
    private func hasSegment(_ label: String, in view: NSView?) -> Bool {
        guard let view else { return false }
        if let control = view as? NSSegmentedControl, (0..<control.segmentCount).contains(where: { control.label(forSegment: $0) == label }) { return true }
        return view.subviews.contains { hasSegment(label, in: $0) }
    }

    @Test func theWindowTitleFollowsTheFocusedPane() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        let first = f.model.focusedPaneID
        try await waitUntil { f.window.title == f.focusedTitle }
        #expect(f.window.title == "Deployments")

        // A second pane takes focus: the window is named for it, not for the first pane's screen.
        f.model.split(.vertical)
        let second = f.model.focusedPaneID
        #expect(second != first)
        f.model.mutate { $0.setRoot(.route(.resourceList(f.cluster, .configMap, namespace: nil)), in: second) }
        try await waitUntil { f.window.title == "ConfigMaps" }
        #expect(f.window.title == "ConfigMaps")

        // A pushed detail names the window, although the screens set their own navigation titles.
        f.model.push(.resourceDetail(f.ref), from: second)
        try await waitUntil { f.window.title == "payments-api" }
        #expect(f.window.title == "payments-api")

        // Focus moves back to the first pane; Back in the unfocused second pane leaves the title alone.
        f.model.focus(pane: first)
        try await waitUntil { f.window.title == "Deployments" }
        #expect(f.window.title == "Deployments")
        #expect(f.model.goBack(in: second))
        try await Task.sleep(for: .milliseconds(300))
        #expect(f.window.title == "Deployments")
        f.model.focus(pane: second)
        try await waitUntil { f.window.title == "ConfigMaps" }
        #expect(f.window.title == "ConfigMaps")
    }

    @Test func aTitleWrittenByAScreenDoesNotStick() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { f.window.title == "Deployments" }
        f.window.title = "Something a screen set"
        // The observer answers synchronously: no re-render is needed to put the title back.
        #expect(f.window.title == "Deployments")
    }

    /// A locked app shows no cluster or resource name in a window title (Mission Control, the Window menu and the Dock list it).
    @Test func aLockedAppNamesItsWindowPlainlyAndKeepsItSo() async throws {
        let f = try workspaceWindow()
        defer { close(f) }
        try await waitUntil { f.window.title == "Deployments" }
        f.env.lock.controller.lockNow()
        try await waitUntil { f.window.title == "Wheelhouse" }
        #expect(f.window.title == "Wheelhouse")
        f.window.title = "x"
        #expect(f.window.title == "Wheelhouse")
        // A push under the lock (a screen's own title arrives) does not bring a name back either.
        f.model.push(.resourceDetail(f.ref), from: f.model.focusedPaneID)
        try await Task.sleep(for: .milliseconds(400))
        #expect(f.window.title == "Wheelhouse")
    }

    @Test func aDetachedPaneWindowIsNamedForItsPaneAndPlainlyWhenLocked() async throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let pane = PaneState(showing: .route(.resourceList(cluster, .secret, namespace: nil)))
        env.workspace.store.detach(pane)
        let controller = NSHostingController(rootView: AnyView(DetachedPaneWindow(paneID: pane.id).environment(env).environment(env.registry).environment(env.preferences).environment(env.lock.controller)))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.setFrame(NSRect(x: 40, y: 40, width: 900, height: 600), display: true)
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await waitUntil { window.title == "Secrets" }
        #expect(window.title == "Secrets")
        // Whatever else writes the title, it reverts.
        window.title = "Something a screen set"
        #expect(window.title == "Secrets")
        let model = env.workspace.detachedModel(for: pane.id)
        model.push(.route(.resourceDetail(ResourceRef(clusterID: cluster, kind: .secret, namespace: "payments", name: "db-credentials"))), from: pane.id)
        try await waitUntil { window.title == "db-credentials" }
        #expect(window.title == "db-credentials")
        env.lock.controller.lockNow()
        try await waitUntil { window.title == "Wheelhouse" }
        #expect(window.title == "Wheelhouse")
        window.title = "x"
        #expect(window.title == "Wheelhouse")
    }

    /// The whole path: an Overview row opened from the table (its primary action) pushes the app onto the pane's stack, the detail
    /// renders the app from the cluster, the pane still takes sheets over it, and Back returns to the Overview.
    @Test func aTidesAppOpensFromTheOverviewOnThePaneStackAndBackReturns() async throws {
        let client = FixtureGitOpsClient(items: ["kustomizations": [Self.kustomization]],
                                         groups: [("kustomize.toolkit.fluxcd.io", "v1", "Kustomization", "kustomizations")])
        let f = try workspaceWindow(root: { .tides(TidesScope(clusterID: $0, tool: nil)) }, client: client)
        defer { close(f) }
        let pane = f.model.focusedPaneID
        try await waitUntil { f.window.title == "Tides" }
        #expect(f.window.title == "Tides")

        // The Overview lists the app; opening its row is the table's primary action (a double click).
        try await waitUntil { (firstTable(in: f.window.contentView)?.numberOfRows ?? 0) > 0 }
        let table = try #require(firstTable(in: f.window.contentView))
        try #require(table.numberOfRows > 0)
        table.selectRowIndexes([0], byExtendingSelection: false)
        try await doubleClick(row: 0, in: table, window: f.window)

        try await waitUntil { f.model.pane(pane)?.stack.count == 2 }
        let top = try #require(f.model.pane(pane)?.stack.last)
        guard case .gitopsApp(let ref) = top else { Issue.record("expected a gitopsApp screen, got \(top)"); return }
        #expect(ref.name == "apps" && ref.namespace == "flux-system" && ref.clusterID == f.cluster)
        try await waitUntil { f.window.title == "apps" }
        #expect(f.window.title == "apps")

        // The detail shows the app (its sections), not the "Not found" state of a model that has not loaded.
        try await waitUntil { hasSegment("Conditions & Events", in: f.window.contentView) }
        #expect(hasSegment("Conditions & Events", in: f.window.contentView))

        // The pane still takes its sheets over the pushed app (the nested stack's failure).
        f.model.router(for: pane).sheet = PresentedRoute(route: .portForward(f.ref))
        try await waitUntil { f.window.attachedSheet != nil }
        #expect(f.window.attachedSheet != nil)
        f.model.router(for: pane).sheet = nil
        try await waitUntil { f.window.attachedSheet == nil }

        #expect(f.model.goBack(in: pane))
        try await waitUntil { f.window.title == "Tides" }
        #expect(f.window.title == "Tides")
        #expect(f.model.pane(pane)?.stack.count == 1)
    }

    /// What opening a row shows, and what a pane gives its screens to push with: the pane's own stack, keyed by pane and window.
    @Test func aPanePusherPushesOntoItsPaneAndComparesByPaneAndModel() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let pane = model.focusedPaneID
        let pusher = PaneDestinationPusher(model: model, paneID: pane)
        #expect(pusher == PaneDestinationPusher(model: model, paneID: pane))
        #expect(pusher != PaneDestinationPusher(model: model, paneID: .new()))
        let kustomization = try #require(GitOpsApp(raw: Self.kustomization, kind: Self.kustomizationKind))
        let destination = TidesRootView.destination(for: TidesRow(cluster: cluster, clusterName: "demo", app: kustomization))
        #expect(destination == .gitopsApp(ResourceRef(clusterID: cluster, kind: kustomization.kind, namespace: "flux-system", name: "apps")))
        pusher.push(destination)
        #expect(model.pane(pane)?.stack.last == destination)
        #expect(model.pane(pane)?.stack.count == 2)
    }

    /// The shell's Close Session on the Mac leaves through the pane: Back from a pushed screen, closing the pane when it is the only one.
    @Test func aPaneDismissesItsShellByBackOrByClosingThePane() throws {
        let env = MacAppEnvironment.live()
        env.registry.enterDemoMode(persist: false)
        defer { env.registry.exitDemoMode() }
        let cluster = try #require(env.registry.clusters.first?.id)
        let id = env.workspace.store.createWindow(WorkspaceWindowState(tabs: [TabState(showing: .route(.resourceList(cluster, .pod, namespace: nil)))]))
        let model = env.workspace.model(for: id)
        let first = model.focusedPaneID
        let pod = ResourceRef(clusterID: cluster, kind: .pod, namespace: "payments", name: "api-0")
        let dismiss = try #require(model.router(for: first).paneDismiss)
        model.push(.shell(pod, container: nil), from: first)
        #expect(model.pane(first)?.stack.count == 2)
        dismiss()
        #expect(model.pane(first)?.stack.count == 1)

        // A shell that is a pane's root (a second pane opened on it) closes the pane: nothing is left spinning.
        model.split(.vertical)
        let second = model.focusedPaneID
        model.mutate { $0.setRoot(.route(.shell(pod, container: nil)), in: second) }
        let dismissSecond = try #require(model.router(for: second).paneDismiss)
        #expect(model.selectedTab.panes.count == 2)
        dismissSecond()
        #expect(model.selectedTab.panes.map(\.id) == [first])
    }

    private static let kustomizationKind: ResourceKind = .custom(group: "kustomize.toolkit.fluxcd.io", version: "v1", kind: "Kustomization",
                                                                 plural: "kustomizations", namespaced: true)
    private static let kustomization: JSONValue = try! JSONValue.parse(Data(#"{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"apps","namespace":"flux-system","uid":"k1"},"spec":{"interval":"10m","path":"./apps/prod","sourceRef":{"kind":"GitRepository","name":"fleet"}},"status":{"conditions":[{"type":"Ready","status":"True","message":"Applied revision: main@sha1:3f2a9c1d0e","lastTransitionTime":"2026-11-07T10:00:00Z"}],"lastAppliedRevision":"main@sha1:3f2a9c1d0e","lastAttemptedRevision":"main@sha1:3f2a9c1d0e"}}"#.utf8))
}
