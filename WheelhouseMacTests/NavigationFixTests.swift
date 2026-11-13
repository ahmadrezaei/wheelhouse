import AppKit
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// Mac 1.0 feedback: dead YAML, Logs and Shell actions, the Nodes table, the green window button and single-click opening.
@MainActor
@Suite("NavigationFixTests")
struct NavigationFixTests {
    private struct Fixture {
        let registry: ClusterRegistry
        let controller: WorkspaceController
        let cluster: ClusterID
    }

    private func fixture() -> Fixture {
        let client = FixtureGitOpsClient(items: [:], groups: [])
        let cfg = ClusterConfig(name: "staging-1", server: URL(string: "https://example.invalid:6443")!, environment: .staging)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([cfg]),
                                       defaults: UserDefaults(suiteName: "wh.navfix.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        let controller = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        return Fixture(registry: registry, controller: controller, cluster: cfg.id)
    }

    // MARK: Item 1: YAML, Logs, Shell

    /// Every detail action pushes its screen onto the pane's own stack. Route destinations never go through the feature registry, so
    /// they cannot depend on the safety gate (a Distribution build has it off).
    @Test func yamlLogsAndShellPushOntoThePaneWithoutTheGate() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        let router = model.router(for: pane)
        let pod = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0")
        let cm = ResourceRef(clusterID: f.cluster, kind: .configMap, namespace: "shop", name: "settings")
        let actions: [(Route, ResourceRef)] = [(.yaml(cm), cm), (.yaml(pod), pod), (.logs(pod, container: nil, previous: false), pod),
                                               (.logs(pod, container: "app", previous: true), pod), (.shell(pod, container: nil), pod)]
        for (route, detail) in actions {
            router.push(.resourceDetail(detail))
            router.push(route)
            #expect(model.pane(pane)?.stack.last == .route(route))
            #expect(FeatureRegistry.all.allSatisfy { !$0.handles(.route(route)) })
            #expect(FeatureRegistry.feature(for: .route(route)) == nil)
            model.mutate { $0.pop(in: pane); $0.pop(in: pane) }
        }
        #expect(!FeatureRegistry.isEnabled(.rigging, gateActive: false))
        #expect(FeatureRegistry.isEnabled(.deckTerminal, gateActive: false))
    }

    // MARK: Item 4: single click

    @Test func followingASelectionReachesOnlyLinkedPanes() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let source = model.focusedPaneID
        let pod = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0")
        #expect(!model.followSelection(.resourceDetail(pod), from: source))                       // nobody follows: nothing changes
        model.split(.horizontal, pane: source)
        let follower = model.selectedTab.panes.first { $0.id != source }!.id
        model.mutate { $0.setLink(follower, to: source) }
        model.focus(pane: source)
        #expect(model.followSelection(.resourceDetail(pod), from: source))
        #expect(model.pane(follower)?.stack == [.route(.resourceDetail(pod))])
        #expect(model.focusedPaneID == source)                                                      // focus is not stolen
        #expect(model.pane(source)?.stack.count == 1)                                               // the source pane's own stack is unchanged
        #expect(!model.followSelection(.sessions, from: source))                                    // only detail routes follow
        let next = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-1")
        model.router(for: source).follow(.resourceDetail(next))
        #expect(model.pane(follower)?.stack == [.route(.resourceDetail(next))])
    }

    /// A window with a source pane and one follower of it.
    private func linked() -> (f: Fixture, model: WorkspaceWindowModel, source: PaneID, follower: PaneID, pod: ResourceRef) {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let source = model.focusedPaneID
        model.split(.horizontal, pane: source)
        let follower = model.selectedTab.panes.first { $0.id != source }!.id
        model.mutate { $0.setLink(follower, to: source) }
        model.focus(pane: source)
        return (f, model, source, follower, ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0"))
    }

    @Test func aFollowerThatAlreadyShowsTheRouteIsNotRebuilt() {
        let (_, model, source, follower, pod) = linked()
        model.push(.resourceDetail(pod), from: source)
        let editor = NSObject()
        model.editorReported(editor, dirty: false, in: follower)
        var asked = 0
        model.controller.confirmsDiscardingEdits = { _, _ in asked += 1; return true }
        #expect(model.mutate { $0.deliver(selection: .resourceDetail(pod), from: source) }.isEmpty)          // nothing changed
        #expect(model.pane(follower)?.stack == [.route(.resourceDetail(pod))])
        #expect(asked == 0)
    }

    @Test func aClickAsksBeforeReplacingAFollowersUnsavedDraftAndKeyboardNeverDoes() {
        let (f, model, source, follower, pod) = linked()
        let other = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-1")
        model.push(.resourceDetail(pod), from: source)
        let editor = NSObject()
        model.editorReported(editor, dirty: true, in: follower)
        var asked = 0, answer = false
        model.controller.confirmsDiscardingEdits = { _, _ in asked += 1; return answer }
        model.push(.resourceDetail(other), from: source)                                               // click, declined
        #expect(asked == 1 && model.pane(follower)?.stack == [.route(.resourceDetail(pod))])
        #expect(model.pane(source)?.stack.count == 1)                                                  // and not pushed in place either
        #expect(model.followSelection(.resourceDetail(other), from: source))                           // arrow key: skipped, never asked
        #expect(asked == 1 && model.pane(follower)?.stack == [.route(.resourceDetail(pod))])
        answer = true
        model.push(.resourceDetail(other), from: source)                                               // click, accepted
        #expect(asked == 2 && model.pane(follower)?.stack == [.route(.resourceDetail(other))])
    }

    @Test func aFollowerParkedBehindAZoomedPaneIsNotUsedAndTheRoutePushesInPlace() {
        let (_, model, source, follower, pod) = linked()
        model.zoom(pane: source)
        #expect(model.state.visibleFollowers(of: source).isEmpty)
        #expect(!model.router(for: source).hasFollowers)
        #expect(!model.followSelection(.resourceDetail(pod), from: source))
        model.push(.resourceDetail(pod), from: source)
        #expect(model.pane(source)?.stack.last == .route(.resourceDetail(pod)))
        #expect(model.pane(follower)?.stack.contains(.route(.resourceDetail(pod))) != true)
        model.zoom(pane: source)                                                                       // restored: the follower is visible again
        #expect(model.router(for: source).hasFollowers)
    }

    @Test func aClickOpenIgnoresTheModifiersHeldWhenItRuns() {
        let f = fixture()
        let model = f.controller.model(for: f.controller.store.createWindow())
        let pane = model.focusedPaneID
        let pod = ResourceRef(clusterID: f.cluster, kind: .pod, namespace: "shop", name: "api-0")
        model.router(for: pane).pushFromClick(.resourceDetail(pod))
        #expect(model.pane(pane)?.stack.last == .route(.resourceDetail(pod)))
        #expect(model.state.tabs.count == 1)
    }

    private final class Box { var ids: [String] = [] }

    private func keys(_ n: Int) -> [KubeRowKey] { (0..<n).map { KubeRowKey(id: "p\($0)", version: "1") } }
    private func row(_ i: Int) -> KubeTableRow {
        KubeTableRow(id: "p\(i)", name: "pod-\(i)", namespace: "shop", status: "Running", tone: .healthy, ready: "1/1", upToDate: "", restarts: "0", node: "n1",
                     cpu: "1m", memory: "4Mi", details: "", age: "3d", extra: [], accessibility: "pod-\(i)")
    }

    private func table() -> (table: KubeTableScrollView, opened: Box, followed: Box) {
        let t = KubeTableScrollView()
        t.assumeVisible = true
        t.frame = NSRect(x: 0, y: 0, width: 900, height: 500)
        t.clickDelay = .milliseconds(40)
        t.followDelay = .milliseconds(40)
        let opened = Box(), followed = Box()
        t.onSelect = { opened.ids.append($0) }
        t.onFollow = { followed.ids.append($0) }
        t.update(kindID: ResourceKind.pod.id, columns: KubeColumn.columns(for: .pod, showNamespace: true, extra: []), sort: .status, reversed: false, keys: keys(5), rowAt: row)
        return (t, opened, followed)
    }

    @Test func aPlainClickOpensTheRowAfterTheDoubleClickWindow() async throws {
        let (t, opened, _) = table()
        t.selectRows([2])
        t.handleClick(row: 2, modifiers: [])
        #expect(opened.ids.isEmpty)                                    // waits for a possible second click
        try await Task.sleep(for: .milliseconds(250))
        #expect(opened.ids == ["p2"])
    }

    @Test func aClickFollowsAtOnceWhenALinkedPaneShowsTheSelection() {
        let (t, opened, _) = table()
        t.followsImmediately = { true }
        t.selectRows([2])
        t.handleClick(row: 2, modifiers: [])
        #expect(opened.ids == ["p2"])
    }

    @Test func theDefaultClickDelayIsTheSystemDoubleClickInterval() {
        #expect(KubeTableScrollView().clickDelay == .seconds(NSEvent.doubleClickInterval))
    }

    @Test func aProgrammaticSelectionChangeDoesNotFollow() async throws {
        let (t, opened, followed) = table()
        t.selectRows([3])                                  // what a reload or a live update does: no key event is being handled
        try await Task.sleep(for: .milliseconds(250))
        #expect(followed.ids.isEmpty && opened.ids.isEmpty)
    }

    @Test func commandShiftAndControlClicksSelectWithoutOpening() async throws {
        let (t, opened, _) = table()
        t.selectRows([1])
        t.handleClick(row: 1, modifiers: .command)
        t.handleClick(row: 1, modifiers: .shift)
        t.handleClick(row: 1, modifiers: .control)
        t.selectRows([1, 2])
        t.handleClick(row: 2, modifiers: [])                           // a multi-row selection is not a click on one row
        try await Task.sleep(for: .milliseconds(200))
        #expect(opened.ids.isEmpty)
    }

    @Test func aClickOnARowThatIsNotTheSelectionIsIgnored() async throws {
        let (t, opened, _) = table()
        t.selectRows([1])
        t.handleClick(row: 3, modifiers: [])
        t.handleClick(row: 99, modifiers: [])
        try await Task.sleep(for: .milliseconds(150))
        #expect(opened.ids.isEmpty)
    }

    @Test func keyboardSelectionFollowsOnlyAfterItSettlesAndNeverOpens() async throws {
        let (t, opened, followed) = table()
        t.selectRows([0]); t.selectionMovedByKeyboard()
        t.selectRows([1]); t.selectionMovedByKeyboard()
        t.selectRows([2]); t.selectionMovedByKeyboard()                 // holding an arrow: only the last row is followed
        try await Task.sleep(for: .milliseconds(250))
        #expect(followed.ids == ["p2"])
        #expect(opened.ids.isEmpty)
        t.selectRows([1, 2]); t.selectionMovedByKeyboard()              // two rows selected: nothing follows
        try await Task.sleep(for: .milliseconds(150))
        #expect(followed.ids == ["p2"])
    }

    @Test func selectionOnlyModifiers() {
        #expect(KubeTableScrollView.isSelectionOnly(.command) && KubeTableScrollView.isSelectionOnly(.shift) && KubeTableScrollView.isSelectionOnly(.control))
        #expect(!KubeTableScrollView.isSelectionOnly([]) && !KubeTableScrollView.isSelectionOnly(.option))
    }

    // MARK: Item 2: Nodes table

    @Test func theNodesTableHasTheLensColumns() {
        let cols = KubeColumn.columns(for: .node, showNamespace: true, extra: [])
        #expect(cols.map(\.id) == ["name", "status", "roles", "version", "cpu", "memory", "pods", "taints", "age"])
    }

    private func node(taints: Int, unschedulable: Bool = false) throws -> Unstructured {
        let taintList: [JSONValue] = (0..<taints).map { ["key": .string("k\($0)"), "effect": "NoSchedule"] }
        let json: JSONValue = ["apiVersion": "v1", "kind": "Node",
                               "metadata": ["name": "n1", "labels": ["node-role.kubernetes.io/control-plane": ""]],
                               "spec": ["unschedulable": .bool(unschedulable), "taints": .array(taintList)],
                               "status": ["nodeInfo": ["kubeletVersion": "v1.31.2"], "conditions": [["type": "Ready", "status": "True"]]]]
        return try json.decode(Unstructured.self)
    }

    private func pod(on node: String?, phase: String = "Running") throws -> Unstructured {
        var body: [String: JSONValue] = ["apiVersion": "v1", "kind": "Pod", "metadata": ["name": "p", "namespace": "x"], "status": ["phase": .string(phase)]]
        if let node { body["spec"] = ["nodeName": .string(node)] }
        return try JSONValue.object(body).decode(Unstructured.self)
    }

    @Test func nodeCellsShowRolesVersionPodsAndTaints() throws {
        let n = try node(taints: 2, unschedulable: true)
        let summary = ResourceSummarizer.summarize(kind: .node, object: n)
        let cells = ListScreen.nodeColumns(n, summary: summary, pods: 7)
        #expect(cells == ["roles": "control-plane", "version": "v1.31.2", "pods": "7", "taints": "2"])
        #expect(summary.statusText == "Ready,SchedulingDisabled")
        #expect(ListScreen.nodeColumns(n, summary: summary, pods: nil)["pods"] == "\u{2014}")         // no live pod store: a dash
        let row = KubeTableRow(id: "n1", name: "n1", namespace: "", status: "", tone: .healthy, ready: "", upToDate: "", restarts: "", node: "", cpu: "", memory: "",
                               details: "", age: "", extra: [], accessibility: "", kindColumns: cells)
        #expect(row.text(for: "version") == "v1.31.2" && row.text(for: "taints") == "2")
    }

    @Test func podsPerNodeIgnoreUnscheduledAndFinishedPods() throws {
        let counts = ListScreen.podCounts([try pod(on: "a"), try pod(on: "a"), try pod(on: "b"), try pod(on: nil),
                                           try pod(on: "a", phase: "Succeeded"), try pod(on: "b", phase: "Failed")])
        #expect(counts == ["a": 2, "b": 1])
    }
}
