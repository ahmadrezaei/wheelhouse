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

    // MARK: Pane layout

    @Test func dividersAndRectanglesFollowTheTreeAndTheFractions() {
        let a = PaneState(), b = PaneState(), c = PaneState()
        let tree = PaneNode.split(axis: .horizontal, fraction: 0.4, first: .leaf(a), second: .split(axis: .vertical, fraction: 0.5, first: .leaf(b), second: .leaf(c)))
        let rects = Dictionary(uniqueKeysWithValues: tree.layout().map { ($0.id, $0.rect) })
        #expect(rects[a.id] == CGRect(x: 0, y: 0, width: 0.4, height: 1))
        #expect(rects[b.id] == CGRect(x: 0.4, y: 0, width: 0.6, height: 0.5))
        let dividers = tree.dividers()
        #expect(dividers.map(\.path) == [[], [1]])
        #expect(dividers[1].parent == CGRect(x: 0.4, y: 0, width: 0.6, height: 1))
        let moved = tree.applying(fractions: [[]: 0.7])
        #expect(Dictionary(uniqueKeysWithValues: moved.layout().map { ($0.id, $0.rect) })[a.id]?.width == 0.7)
        #expect(PaneTreeLayout.minimumFraction(side: 1_000, points: 320) == 0.32)
    }

    @Test func splittingDoesNotDuplicateThePaneItWasSplitFrom() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        model.mutate { $0.setRoot(.route(.resourceList(f.cluster, .pod, namespace: nil)), in: pane) }
        model.split(.horizontal)
        let new = model.focusedPaneID
        #expect(model.pane(new)?.stack == [.route(.cluster(f.cluster))])
        #expect(model.pane(pane)?.stack == [.route(.resourceList(f.cluster, .pod, namespace: nil))])
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

    @Test func mergeAllWindowsKeepsPlaceholderTabsAndDetachedPanesWithoutDuplicates() throws {
        let f = fixture()
        let c = f.controller
        let a = c.model(for: c.store.createWindow())
        let bID = c.store.createWindow(WorkspaceWindowState(tabs: [TabState.placeholder(raw: ["id": "bad", "root": ["x": 1]])]))
        let b = c.model(for: bID)
        a.split(.horizontal)
        let moved = a.focusedPaneID
        a.detach(moved)
        _ = c.detachedModel(for: moved)
        c.becameActive({ if case .window(let w) = a.scope { w } else { WorkspaceWindowID.new() } }())
        c.mergeAllWindows()
        let tabs = a.state.tabs
        #expect(tabs.contains { $0.raw != nil })                             // the unreadable tab and its JSON travelled
        let ids = tabs.flatMap(\.panes).map(\.id)
        #expect(ids.count == Set(ids).count)                                 // no pane ID twice
        #expect(ids.contains(moved))                                         // the detached pane joined
        #expect(b.state.tabs.count == 1 && b.state.tabs[0].raw == nil)       // the source is reset
        #expect(c.store.detachedPane(moved) == nil)
    }

    @Test func closingTheOnlyPaneOfAPlaceholderWindowResetsItInsteadOfClosing() {
        let f = fixture()
        let id = f.controller.store.createWindow(.placeholder(raw: ["id": "w", "state": "nope"]))
        let model = f.controller.model(for: id)
        model.closePane(model.focusedPaneID)
        #expect(f.controller.store.windows[id]?.raw == nil)
        #expect(f.controller.store.windows[id]?.tabs.first?.raw == nil)
    }

    @Test func detachedWindowsHaveNoSidebarAndMenusSkipThem() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let detachedPane = PaneState(showing: .route(.sessions))
        f.controller.store.detach(detachedPane)
        let detached = f.controller.detachedModel(for: detachedPane.id)
        detached.focusedPaneChanged()
        #expect(detached.sidebarIfCreated == nil)                            // no discovery or rules review from a detached window
        f.controller.becameActiveDetached(detachedPane.id)
        #expect(f.controller.activeModel === detached)
        _ = model
    }

    @Test func aHiddenWindowsContentIsReleasedAtOnceOnCriticalPressure() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.releaseGrace = 60
        model.visibilityChanged(false, thermalGrace: false)
        #expect(model.buildsContent)
        model.releaseContentNow()
        #expect(!model.buildsContent)
    }
}
