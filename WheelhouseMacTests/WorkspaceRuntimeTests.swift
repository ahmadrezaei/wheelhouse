import AppKit
import SwiftUI
import Testing
import WheelhouseKit
@testable import WheelhouseMac

/// The workspace at runtime: routers, visibility, shared stores and the split view. These host real views off screen.
@MainActor
@Suite("WorkspaceRuntimeTests")
struct WorkspaceRuntimeTests {
    static let podJSON: JSONValue = ["apiVersion": "v1", "kind": "Pod", "metadata": ["name": "api-0", "namespace": "shop", "uid": "u1"], "spec": ["containers": []]]

    private struct Fixture {
        /// Only for hosting views (`PaneHost` takes the app environment); everything else uses the fixture's own controller.
        let env: MacAppEnvironment
        let client: FixtureGitOpsClient
        let registry: ClusterRegistry
        let controller: WorkspaceController
        let cluster: ClusterID
    }

    /// A workspace controller over a registry whose one cluster is served by a counting fixture client.
    private func fixture() -> Fixture {
        let client = FixtureGitOpsClient(items: ["pods": [Self.podJSON]], groups: [("", "v1", "Pod", "pods")])
        let cfg = ClusterConfig(name: "staging-1", server: URL(string: "https://example.invalid:6443")!, environment: .staging)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([cfg]),
                                       defaults: UserDefaults(suiteName: "wh.runtime.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        let controller = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        return Fixture(env: MacAppEnvironment.live(), client: client, registry: registry, controller: controller, cluster: cfg.id)
    }

    // MARK: Shared watches

    @Test func threePanesInTwoWindowsShareOneListAndOneWatch() async throws {
        let client = FixtureGitOpsClient(items: ["pods": [Self.podJSON]], groups: [("", "v1", "Pod", "pods")])
        let cfg = ClusterConfig(name: "staging-1", server: URL(string: "https://example.invalid:6443")!, environment: .staging)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([cfg]),
                                       defaults: UserDefaults(suiteName: "wh.sharing.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        let session = try #require(registry.session(for: cfg.id))
        // Panes ask for their store exactly as ResourceListView does: the unstructured store of the kind, in the pane's namespace.
        func paneConsumer() -> ResourceStore<Unstructured> { session.unstructuredStore(kind: .pod, namespace: registry.namespace(for: cfg.id)) }
        let windowA1 = paneConsumer(), windowA2 = paneConsumer(), windowB = paneConsumer()
        #expect(windowA1 === windowA2 && windowA2 === windowB)
        let tasks = [Task { await windowA1.run() }, Task { await windowA2.run() }, Task { await windowB.run() }]
        try await Task.sleep(for: .milliseconds(600))
        #expect(client.listCount == 1)
        #expect(client.watchCount == 1)
        #expect(windowA1.consumerCount == 3)
        tasks[0].cancel(); tasks[1].cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(windowA1.consumerCount == 1)
        #expect(client.watchCount == 1)                 // still the same single watch
        tasks[2].cancel()
        try await Task.sleep(for: .milliseconds(200))
        #expect(windowA1.consumerCount == 0)
    }

    // MARK: Visibility

    @Test func aHiddenWindowStopsDrawingAtOnceAndReleasesContentAfterTheGrace() async throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.releaseGrace = 0.15
        #expect(model.isVisible && model.buildsContent)
        model.visibilityChanged(false, thermalGrace: false)
        #expect(!model.isVisible && model.buildsContent)        // drawing stops now, consumers stay for the grace
        try await Task.sleep(for: .milliseconds(400))
        #expect(!model.buildsContent)
        model.visibilityChanged(true)
        #expect(model.isVisible && model.buildsContent)          // coming back is immediate
    }

    @Test func comingBackWithinTheGraceKeepsTheContent() async throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.releaseGrace = 0.3
        model.visibilityChanged(false, thermalGrace: false)
        try await Task.sleep(for: .milliseconds(100))
        model.visibilityChanged(true)
        try await Task.sleep(for: .milliseconds(500))
        #expect(model.buildsContent)
    }

    @Test func thermalPressureReleasesImmediately() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.visibilityChanged(false, thermalGrace: true)
        #expect(!model.buildsContent)
    }

    @Test func onlyDestinationsThatHoldNothingButStoreConsumersAreTornDown() {
        let pod = ResourceRef(clusterID: "c", kind: .pod, namespace: "ns", name: "p")
        let tornDown: [WorkspaceDestination?] = [nil, .route(.fleet), .route(.alerts), .route(.cluster("c")), .route(.resourceSections("c")),
                                                 .route(.resourceList("c", .pod, namespace: nil)), .route(.resourceDetail(pod)), .route(.search(query: nil)), .route(.sessions)]
        for d in tornDown { #expect(WorkspaceWindowModel.tearsDownWhenHidden(d)) }
        // Unsaved YAML, a pod shell, a followed log and every feature screen keep their state.
        let kept: [WorkspaceDestination] = [.route(.yaml(pod)), .route(.createYAML("c", namespace: nil)), .route(.logs(pod, container: nil, previous: false)),
                                            .route(.shell(pod, container: nil)), .route(.portForward(pod)), .chartRoom("c", .releases), .deckTerminal(TerminalSpec()), .activity]
        for d in kept { #expect(!WorkspaceWindowModel.tearsDownWhenHidden(d)) }
    }

    // MARK: Routers and navigation

    @Test func aPanesRouterPushesOntoItsOwnStack() throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        let router = model.router(for: pane)
        let pod = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0")
        router.push(.resourceDetail(pod))
        router.push(.logs(pod, container: nil, previous: false))
        #expect(model.pane(pane)?.stack.dropFirst().count == 2)
        #expect(router.detailPath.isEmpty && router.contentPath.isEmpty)        // the iOS stacks are untouched
        // Sheets stay on the router.
        router.push(.addCluster)
        #expect(router.sheet?.route == .addCluster)
        #expect(model.pane(pane)?.stack.count == 3)
    }

    @Test func absoluteOpenFocusesAnExistingPaneOrOpensATab() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let router = model.focusedRouter
        router.open(.sessions, registry: f.registry)
        #expect(model.state.tabs.count == 2)
        let tab = model.selectedTab.id
        router.open(.sessions, registry: f.registry)                      // already shown: no new tab
        #expect(model.state.tabs.count == 2 && model.selectedTab.id == tab)
        model.select(tab: model.state.tabs[0].id)
        router.open(.sessions, registry: f.registry)                      // focuses the pane that has it
        #expect(model.selectedTab.id == tab)
    }

    @Test func aDeepLinkOpensItsChainInANewTab() throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let url = try #require(URL(string: "wheelhouse://cluster/\(f.cluster)/ns/shop/Pod/api-0?view=logs"))
        model.openURL(url)
        let pane = try #require(model.focusedPane)
        #expect(model.state.tabs.count == 2)
        #expect(pane.stack.count >= 2)
        if case .route(.logs)? = pane.top {} else { Issue.record("the link should end on the log screen") }
    }

    @Test func commandClickOpensANewTabInsteadOfPushing() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        model.push(.sessions, from: pane, commandHeld: true)
        #expect(model.state.tabs.count == 2)
        #expect(model.pane(pane)?.stack.count == 1)
    }

    @Test func aSelectionInASourcePaneGoesToItsLinkedPane() throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let table = model.focusedPaneID
        model.split(.vertical)
        let logs = model.focusedPaneID
        model.mutate { $0.setLink(logs, to: table, view: .logs) }
        let pod = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0")
        model.router(for: table).push(.resourceDetail(pod))
        #expect(model.pane(table)?.stack.count == 1)                              // the source did not navigate away from its table
        #expect(model.pane(logs)?.stack == [.route(.logs(pod, container: nil, previous: false))])
    }

    @Test func closingPanesPrunesTheirRouters() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let first = model.focusedPaneID
        _ = model.router(for: first)
        for _ in 0..<5 {
            model.split(.horizontal)
            let extra = model.focusedPaneID
            _ = model.router(for: extra)
            model.closePane(extra)
        }
        #expect(model.liveRouterIDs == [first])
    }

    @Test func openingAndClosingTwentyTabsLeavesNothingBehind() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let baseline = model.liveRouterIDs.count
        var ids: [TabID] = []
        for _ in 0..<20 {
            model.newTab()
            ids.append(model.selectedTab.id)
            _ = model.focusedRouter
        }
        for id in ids { model.closeTab(id) }
        model.pruneRouters()
        #expect(model.state.tabs.count == 1)
        #expect(model.liveRouterIDs.count <= baseline + 1)
    }

    @Test func changingAPanesClusterKeepsItsViewAndMovesTheRegistry() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        model.mutate { $0.setRoot(.route(.resourceList(f.cluster, .pod, namespace: nil)), in: pane) }
        model.setCluster("other", namespace: nil, in: pane)
        #expect(model.pane(pane)?.stack == [.route(.resourceList("other", .pod, namespace: nil))])
    }

    // MARK: Split view

    @Test func theSplitViewBuildsOneLeafPerPaneAndReusesThemAcrossChanges() throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let first = model.focusedPaneID
        let tabID = model.selectedTab.id
        let view = PaneTreeView(env: f.env, model: model, tabID: tabID)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        view.apply(root: model.selectedTab.root, focused: first)
        #expect(view.leafIDs == [first] && view.splitViews.isEmpty)
        model.split(.horizontal)
        model.split(.vertical)
        view.apply(root: model.selectedTab.root, focused: model.focusedPaneID)
        view.layoutSubtreeIfNeeded()
        #expect(view.leafIDs.count == 3)
        #expect(view.splitViews.count == 2)
        let reused = view.leafIDs.contains(first)
        #expect(reused)
        // Moving a pane rebuilds the splits and keeps the leaf views.
        model.movePane(first, .down)
        view.apply(root: model.selectedTab.root, focused: first)
        #expect(view.leafIDs.count == 3)
        // Closing removes the leaf.
        let extra = model.selectedTab.panes.last!.id
        model.closePane(extra)
        view.apply(root: model.selectedTab.root, focused: model.focusedPaneID)
        #expect(view.leafIDs.count == 2 && view.splitViews.count == 1)
    }

    @Test func zoomingParksThePanesInsteadOfFreeingThem() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let first = model.focusedPaneID
        let tabID = model.selectedTab.id
        let view = PaneTreeView(env: f.env, model: model, tabID: tabID)
        view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 600)
        model.split(.horizontal)
        let second = model.focusedPaneID
        view.apply(root: model.selectedTab.root, all: model.selectedTab.root, focused: second)
        let before = view.leafIDs
        let tab = model.selectedTab
        view.apply(root: .leaf(tab.root.pane(second)!), all: tab.root, focused: second)       // zoomed
        #expect(view.leafIDs == before)
        view.apply(root: tab.root, all: tab.root, focused: second)
        #expect(view.leafIDs == before && before.contains(first))
    }

    @Test func dividerFractionsFollowTheState() throws {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let tabID = model.selectedTab.id
        let view = PaneTreeView(env: f.env, model: model, tabID: tabID)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1_000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderBack(nil)
        defer { window.close() }
        model.split(.horizontal)
        model.setFraction(0.4, tab: tabID, path: [])   // above the 320 pt minimum of a 1,000 pt split
        view.apply(root: model.selectedTab.root, focused: model.focusedPaneID)
        window.layoutIfNeeded()
        view.layoutSubtreeIfNeeded()
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        let split = try #require(view.splitViews.first)
        let first = split.subviews[0].frame.width
        let total = split.bounds.width - split.dividerThickness
        #expect(abs(first / total - 0.4) < 0.02)
    }

    // MARK: Scenarios

    @Test func busyTenPlansThreeWindowsOfTwoTabs() {
        let clusters = (1...10).map { (name: String(format: "wh-perf-%02d", $0), id: "id-\($0)") }
        let scenario = PerfScenario(name: "busy-10", description: nil, clusters: 10, windows: 3, tabs: 2,
                                    panes: ["pods", "deployments", "configmaps-2000", "overview", "overview", "logs:pause", "deck-terminal:120x40"], hideWindowsAfterSeconds: nil, windowAction: nil, cycleSeconds: nil)
        let plan = PerfLayout.plan(scenario, clusters: clusters)
        #expect(plan.count == 3)
        #expect(plan.allSatisfy { $0.count == 2 })
        let kinds = plan.flatMap { $0 }.compactMap { d -> String? in
            if case .route(.resourceList(_, let k, _)) = d { return k.plural }
            if case .route(.cluster) = d { return "overview" }
            if case .route(.logs) = d { return "logs" }
            return nil
        }
        #expect(kinds == ["pods", "deployments", "configmaps", "overview", "overview", "logs"])
    }

    @Test func theSingleTabScenarioKeepsTheLastPaneThatCanBeShown() {
        let clusters = [(name: "wh-perf-01", id: "a"), (name: "wh-perf-02", id: "b"), (name: "wh-perf-03", id: "c")]
        let scenario = PerfScenario(name: "idle-1", description: nil, clusters: 3, windows: 1, tabs: 1,
                                    panes: ["fleet", "cluster-overview:wh-perf-01", "pods:wh-perf-01/wh-perf"], hideWindowsAfterSeconds: nil, windowAction: nil, cycleSeconds: nil)
        #expect(PerfLayout.plan(scenario, clusters: clusters) == [[.route(.resourceList("a", .pod, namespace: nil))]])
    }

    @Test func shortPaneListsArePaddedWithClusterOverviews() {
        let clusters = [(name: "wh-perf-01", id: "a"), (name: "wh-perf-02", id: "b")]
        let scenario = PerfScenario(name: "soak-5", description: nil, clusters: 2, windows: 2, tabs: 2, panes: ["deck-terminal:x"], hideWindowsAfterSeconds: nil, windowAction: nil, cycleSeconds: 300)
        let plan = PerfLayout.plan(scenario, clusters: clusters)
        #expect(plan.count == 2 && plan.allSatisfy { $0.count == 2 })
    }
}
