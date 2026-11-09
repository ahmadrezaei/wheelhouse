import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

@MainActor
@Suite("WorkspaceStoreTests")
struct WorkspaceStoreTests {
    static let c1 = "kc-aaaa", c2 = "kc-bbbb"

    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appending(path: "wh-ws-\(UUID().uuidString)/workspace.json")
    }

    private func pods(_ c: ClusterID = c1) -> WorkspaceDestination { .route(.resourceList(c, .pod, namespace: nil)) }

    private func window() -> WorkspaceWindowState {
        WorkspaceWindowState(tabs: [TabState(showing: pods()), TabState(showing: .route(.fleet))])
    }

    private func encode<T: Encodable>(_ v: T) throws -> Data {
        let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return try e.encode(v)
    }

    private func json(_ data: Data) throws -> JSONValue { try JSONDecoder().decode(JSONValue.self, from: data) }

    // MARK: Lossy decoding

    @Test func aPaneWithAnUnknownDestinationRestoresAsAPlaceholderAndKeepsItsJSON() throws {
        let paneJSON = #"{"id":"p-bad","context":{"clusterID":"kc-aaaa"},"stack":[{"case":"holodeck","payload":{"x":1,"y":[true,null,"z"]}}],"futureField":2.5}"#
        let file = #"{"version":1,"windows":[{"id":"w1","state":{"tabs":[{"id":"t1","focusedPane":"p-bad","root":{"split":{"axis":"horizontal","fraction":0.4,"first":{"leaf":\#(paneJSON)},"second":{"leaf":{"id":"p-ok","stack":[{"case":"moorings"}]}}}}}],"selectedTab":"t1","sidebarWidth":248,"inspector":{"isOpen":false,"segment":"details"},"sidebar":{"expandedClusters":[],"keepExpanded":[],"expandedGroups":[],"showsForbiddenKinds":false}}}]}"#
        let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: Data(file.utf8))
        let tab = try #require(decoded.windows.first?.state.tabs.first)
        let bad = try #require(tab.root.pane(PaneID(rawValue: "p-bad")))
        #expect(bad.isPlaceholder)
        let ok = try #require(tab.root.pane(PaneID(rawValue: "p-ok")))
        #expect(!ok.isPlaceholder)
        #expect(ok.stack == [.moorings])
        // The raw JSON is written back unchanged (semantically: key order and number formatting may differ).
        let back = try json(try encode(decoded))
        let expected = try json(Data(paneJSON.utf8))
        guard case .object(let root) = back, case .array(let windows)? = root["windows"], case .object(let w)? = windows.first, case .object(let st)? = w["state"],
              case .array(let tabs)? = st["tabs"], case .object(let t)? = tabs.first, case .object(let r)? = t["root"], case .object(let split)? = r["split"],
              case .object(let first)? = split["first"] else { Issue.record("shape"); return }
        #expect(first["leaf"] == expected)
    }

    @Test func aBrokenTabKeepsItsWindowAndItsJSON() throws {
        let file = #"{"version":1,"windows":[{"id":"w1","state":{"tabs":[{"id":"good","root":{"leaf":{"id":"p1","stack":[{"case":"landfall"}]}},"focusedPane":"p1"},{"id":"bad","root":{"nonsense":1}}],"selectedTab":"good"}}]}"#
        let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: Data(file.utf8))
        let state = try #require(decoded.windows.first?.state)
        #expect(state.tabs.count == 2)
        #expect(state.tabs[0].raw == nil)
        #expect(state.tabs[1].raw != nil)
        #expect(state.tabs[1].panes.first?.isPlaceholder == true)
        let again = try JSONDecoder().decode(WorkspaceFile.self, from: try encode(decoded))
        #expect(again.windows.first?.state.tabs[1].raw == state.tabs[1].raw)
    }

    @Test func aBrokenWindowAndAStationDoNotLoseTheRest() throws {
        let file = #"{"version":1,"windows":[{"id":"w-bad","state":"nope"},{"id":"w2","state":{"tabs":[{"id":"t","root":{"leaf":{"id":"p","stack":[]}},"focusedPane":"p"}],"selectedTab":"t"}}],"stations":[{"id":"s-bad"},{"id":"s-ok","name":"Mine","isTemplate":false,"tabs":[{"id":"t","root":{"leaf":{"id":"p","stack":[{"case":"activity"}]}},"focusedPane":"p"}],"selectedTab":"t"}],"rail":[{"anything":1}]}"#
        let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: Data(file.utf8))
        #expect(decoded.windows.count == 2)
        #expect(decoded.windows[0].state.raw != nil)
        #expect(decoded.windows[1].state.raw == nil)
        #expect(decoded.stations.count == 2)
        #expect(decoded.stations[0].raw != nil)
        #expect(decoded.stations[1].name == "Mine")
        #expect(decoded.rail.count == 1)
    }

    @Test func focusOnAMissingPaneFallsBackAndLinksToAMissingPaneAreHarmless() throws {
        let file = #"{"version":1,"windows":[{"id":"w","state":{"tabs":[{"id":"t","root":{"leaf":{"id":"p","stack":[],"link":"gone"}},"focusedPane":"missing"}],"selectedTab":"zzz"}}]}"#
        let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: Data(file.utf8))
        let state = try #require(decoded.windows.first?.state)
        #expect(state.tabs[0].focusedPane == PaneID(rawValue: "p"))
        #expect(state.selectedTab == state.tabs[0].id)
        var copy = state
        copy.closePane(PaneID(rawValue: "gone"))   // no crash, nothing to do
        #expect(copy.tabs.count == 1)
    }

    // MARK: Persistence

    @Test func restorationAfterARelaunchIsExact() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(file: url)
        let id = store.createWindow(window())
        var linked: PaneID?
        store.mutate(id) { s in
            let first = s.tabs[0].focusedPane
            linked = s.split(first, axis: .horizontal, showing: .route(.sessions))
            s.setLink(linked!, to: first, view: .logs)
            s.push(.route(.resourceDetail(ResourceRef(clusterID: Self.c1, kind: .pod, namespace: "x", name: "p-0"))), in: first)
            s.select(tab: s.tabs[1].id)
            s.sidebarWidth = 300
            s.inspector.isOpen = true
            s.frame = [10, 20, 1_000, 700]
        }
        let saved = store.windows[id]
        store.flush()
        let reopened = WorkspaceStore(file: url)
        #expect(reopened.windows[id] == saved)
        #expect(reopened.windowOrder == [id])
        #expect(reopened.launchWindowID() == id)
    }

    @Test func savingIsDebouncedAndSkippedWhenNothingChanged() async throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let store = WorkspaceStore(file: url)
        let id = store.createWindow(window())
        store.flush()
        let writes = store.writeCount
        store.flush()
        store.mutate(id) { $0.sidebarWidth = $0.sidebarWidth }   // no change
        store.flush()
        #expect(store.writeCount == writes)
        store.mutate(id) { $0.sidebarWidth = 280 }
        store.flush()
        #expect(store.writeCount == writes + 1)
    }

    @Test func aCorruptFileIsMovedAsideAndAFreshWindowOpens() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("{ not json".utf8).write(to: url)
        let store = WorkspaceStore(file: url)
        #expect(store.movedAsideCorruptFile != nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(FileManager.default.fileExists(atPath: try #require(store.movedAsideCorruptFile).path))
        #expect(store.windows.isEmpty)
        let id = store.launchWindowID()
        #expect(store.state(for: id).tabs.count == 1)
    }

    @Test func aStoreWithoutAFileNeverTouchesTheDisk() {
        let store = WorkspaceStore(file: nil)
        let id = store.createWindow()
        store.flush()
        #expect(store.windows[id] != nil)
        #expect(store.writeCount == 0)
    }

    @Test func closingAWindowRemovesItsStateExceptTheLastOneOrWhileQuitting() {
        let store = WorkspaceStore(file: nil)
        let a = store.createWindow(), b = store.createWindow()
        store.windowAppeared(a); store.windowAppeared(b)
        store.windowClosed(a)
        #expect(store.windows[a] == nil)
        store.windowClosed(b)                  // the last window: the workspace survives the quit it causes
        #expect(store.windows[b] != nil)
        let c = store.createWindow(), d = store.createWindow()
        store.windowAppeared(c); store.windowAppeared(d)
        store.isTerminating = true
        store.windowClosed(c)
        #expect(store.windows[c] != nil)
    }

    @Test func readingStateNeverCreatesAWindowAndAClosedWindowStaysClosed() {
        let store = WorkspaceStore(file: nil)
        let a = store.createWindow(), b = store.createWindow()
        store.windowAppeared(a); store.windowAppeared(b)
        store.windowClosed(a)
        _ = store.state(for: a)                         // a view body running once more
        store.ensureWindow(a)
        #expect(store.windows[a] == nil && store.windowOrder == [b])
        store.windowAppeared(a)                          // a stale appearance never makes it live again
        #expect(!store.liveWindows.contains(a))
        let ghost = WorkspaceWindowID.new()
        _ = store.state(for: ghost)
        #expect(store.windows[ghost] == nil)
        store.ensureWindow(ghost)                        // a restored identifier the file did not know gets a state
        #expect(store.windows[ghost] != nil)
    }

    @Test func editingAPlaceholderTabLetsItsJSONGoAndKeepsTheRestOfTheWindow() throws {
        let file = #"{"version":1,"windows":[{"id":"w","state":{"tabs":[{"id":"bad","root":{"nonsense":1}}],"selectedTab":"bad"}}]}"#
        var state = try #require(JSONDecoder().decode(WorkspaceFile.self, from: Data(file.utf8)).windows.first?.state)
        #expect(state.raw == nil && state.tabs[0].raw != nil)
        state.addTab(TabState(showing: .route(.fleet)))
        let encoded = try encode(state)
        let back = try JSONDecoder().decode(WorkspaceWindowState.self, from: encoded)
        #expect(back.tabs.count == 2)                    // the new tab is saved
        #expect(back.tabs[0].raw != nil)                 // the unreadable one is still kept until its pane is closed
        let pane = state.tabs[0].focusedPane
        state.setRoot(.route(.fleet), in: pane)
        #expect(state.tabs[0].raw == nil && state.pane(pane)?.isPlaceholder == false || state.pane(pane)?.raw == nil)
    }

    @Test func aFileFromANewerBuildIsReadButNeverOverwritten() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let text = #"{"version":2,"futureKey":true,"windows":[{"id":"w","state":{"tabs":[{"id":"t","root":{"leaf":{"id":"p","stack":[{"case":"moorings"}],"newField":1}},"focusedPane":"p"}],"selectedTab":"t"}}]}"#
        try text.write(to: url, atomically: true, encoding: .utf8)
        let store = WorkspaceStore(file: url)
        #expect(store.windows.count == 1)
        store.mutate(store.windowOrder[0]) { $0.sidebarWidth = 300 }
        store.flush()
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
        #expect(store.writeCount == 0)
    }

    @Test func linksWaitWhileLockedAndBeforeAnyWindowExists() {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.links.\(UUID().uuidString)")!)
        let c = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        let url = URL(string: "wheelhouse://cluster/x")!
        c.handle(url: url)
        #expect(c.pendingURL == url)                     // no window yet
        c.pendingURL = nil
        let id = c.store.createWindow()
        _ = c.model(for: id)
        c.becameActive(id)
        c.isLocked = { true }
        c.handle(url: url)
        #expect(c.pendingURL == url)                     // locked
    }

    // MARK: Layout rules

    @Test func splitInheritsTheContextAndFocusesTheNewPane() throws {
        var s = window()
        let first = s.tabs[0].focusedPane
        s.updatePane(first) { $0.context.namespace = "shop" }
        let r1 = s.split(first, axis: .vertical)
        let new = try #require(r1)
        #expect(s.tabs[0].panes.count == 2)
        #expect(s.pane(new)?.context == PaneContext(clusterID: Self.c1, namespace: "shop"))
        #expect(s.tabs[0].focusedPane == new)
        #expect(s.tabs[0].root.neighbour(of: first, .down) == new)
        #expect(s.tabs[0].root.neighbour(of: new, .up) == first)
        #expect(s.tabs[0].root.neighbour(of: new, .left) == nil)
    }

    @Test func closingPanesAndTabsKeepsTheWindowValid() throws {
        var s = window()
        let first = s.tabs[0].focusedPane
        let r2 = s.split(first, axis: .horizontal)
        let second = try #require(r2)
        s.setLink(second, to: first)
        let r3 = s.closePane(first)
        #expect(r3)
        #expect(s.tabs[0].panes.map(\.id) == [second])
        #expect(s.pane(second)?.link == nil)
        let closedSecond = s.closePane(second)                    // the last pane closes its tab
        #expect(closedSecond)
        #expect(s.tabs.count == 1)
        let only = s.tabs[0].focusedPane
        let closedOnly = s.closePane(only)                      // the last pane of the last tab: the caller closes the window
        #expect(!closedOnly)
    }

    @Test func movePaneGoesToTheOuterEdge() throws {
        var s = window()
        let a = s.tabs[0].focusedPane
        let r4 = s.split(a, axis: .horizontal)
        let b = try #require(r4)
        let r5 = s.split(b, axis: .horizontal)
        let c = try #require(r5)
        s.movePane(c, .left)
        #expect(s.tabs[0].root.neighbour(of: c, .right) != nil)
        #expect(s.tabs[0].root.neighbour(of: c, .left) == nil)
        s.movePane(c, .down)
        #expect(s.tabs[0].root.neighbour(of: c, .up) != nil)
        #expect(s.tabs[0].panes.count == 3)
    }

    @Test func dockAndDetachAndReattachMoveThePaneState() throws {
        let store = WorkspaceStore(file: nil)
        let id = store.createWindow(window())
        let a = store.windows[id]!.tabs[0].focusedPane
        let splitID: PaneID? = store.mutate(id) { (s: inout WorkspaceWindowState) in s.split(a, axis: .horizontal, showing: .route(.sessions)) }
        let b = try #require(splitID)
        let extracted: PaneState? = store.mutate(id) { (s: inout WorkspaceWindowState) in s.extractPane(b) }
        let moved = try #require(extracted)
        #expect(moved.stack == [.route(.sessions)])
        store.detach(moved)
        #expect(store.detachedPane(b)?.id == b)
        #expect(store.windows[id]!.tabs[0].panes.count == 1)
        let back = try #require(store.takeDetached(b))
        store.mutate(id) { $0.attach(back) }
        #expect(store.windows[id]!.tabs[0].panes.map(\.id) == [a, b])
        #expect(store.detachedPane(b) == nil)
        // Dock onto the top of the first pane.
        store.mutate(id) { $0.dock(b, onto: a, zone: .top) }
        #expect(store.windows[id]!.tabs[0].root.neighbour(of: b, .down) == a)
    }

    @Test func theOnlyPaneCannotBeExtracted() {
        var s = WorkspaceWindowState(tabs: [TabState(showing: .route(.fleet))])
        let r6 = s.extractPane(s.tabs[0].focusedPane)
        #expect(r6 == nil)
    }

    @Test func moveTabToANewWindowKeepsTheTabAndNeverEmptiesTheWindow() throws {
        let store = WorkspaceStore(file: nil)
        let id = store.createWindow(window())
        let tab = store.windows[id]!.tabs[1]
        let takenTab: TabState? = store.mutate(id) { (s: inout WorkspaceWindowState) in s.takeTab(tab.id) }
        let taken = try #require(takenTab)
        #expect(taken == tab)
        let other = store.createWindow(WorkspaceWindowState(tabs: [taken]))
        #expect(store.windows[other]?.tabs == [tab])
        let none: TabState? = store.mutate(id) { (s: inout WorkspaceWindowState) in s.takeTab(s.tabs[0].id) }
        #expect(none == nil)
    }

    @Test func tabSelectionWrapsAndClosingSelectsANeighbour() {
        var s = window()
        s.selectTab(offset: 1)
        #expect(s.selectedIndex == 1)
        s.selectTab(offset: 1)
        #expect(s.selectedIndex == 0)
        s.selectTab(offset: -1)
        #expect(s.selectedIndex == 1)
        let closing = s.tabs[1].id
        let r7 = s.closeTab(closing)
        #expect(r7)
        #expect(s.selectedIndex == 0)
        let r8 = s.closeTab(s.tabs[0].id)
        #expect(!r8)
    }

    @Test func fractionsAreClamped() {
        let split = PaneNode.split(axis: .horizontal, fraction: 0.5, first: .leaf(PaneState()), second: .leaf(PaneState()))
        guard case .split(_, let f, _, _) = split.settingFraction(0.01, at: []) else { Issue.record("split"); return }
        #expect(f == PaneNode.minimumFraction)
    }

    // MARK: Linked panes

    @Test func aSelectionReplacesTheLinkedPanesStack() throws {
        var s = window()
        let table = s.tabs[0].focusedPane
        let r9 = s.split(table, axis: .vertical)
        let logs = try #require(r9)
        s.setLink(logs, to: table, view: .logs)
        let pod = ResourceRef(clusterID: Self.c1, kind: .pod, namespace: "shop", name: "api-0")
        let other = ResourceRef(clusterID: Self.c1, kind: .pod, namespace: "shop", name: "api-1")
        let r10 = s.deliver(selection: .resourceDetail(pod), from: table)
        #expect(r10 == [logs])
        s.deliver(selection: .resourceDetail(other), from: table)
        #expect(s.pane(logs)?.stack == [.route(.logs(other, container: nil, previous: false))])   // replaced, not stacked
        #expect(s.hasLinkedPanes(following: table))
        #expect(!s.hasLinkedPanes(following: logs))
        let r11 = s.deliver(selection: .sessions, from: logs)
        #expect(r11.isEmpty)
    }

    // MARK: Contexts and Stations

    @Test func changingTheClusterKeepsTheView() {
        var s = window()
        let p = s.tabs[0].focusedPane
        s.setCluster(Self.c2, namespace: nil, in: p)
        #expect(s.pane(p)?.stack == [pods(Self.c2)])
        #expect(s.pane(p)?.context.clusterID == Self.c2)
    }

    @Test func everyDestinationCaseMapsItsClusters() {
        for (name, sample) in WorkspaceSamples.samples {
            let moved = sample.replacingClusters { _ in "kc-new" }
            if sample.clusterID != nil { #expect(moved.clusterID == "kc-new", Comment(rawValue: name)) } else { #expect(moved == sample, Comment(rawValue: name)) }
        }
        for (name, route) in WorkspaceSamples.routeSamples {
            let moved = route.replacingClusters { _ in "kc-new" }
            if route.clusterID != nil { #expect(moved.clusterID == "kc-new", Comment(rawValue: name)) } else { #expect(moved == route, Comment(rawValue: name)) }
        }
    }

    @Test func sidebarDestinationsRoundTrip() {
        let kinds: [SidebarDestination] = [.fleet, .alerts, .sessions, .clusterOverview(Self.c1), .workloadSummary(Self.c1), .kind(Self.c1, .pod), .feature(.moorings)]
        for d in kinds { #expect(WorkspaceDestination(d).sidebarDestination == d) }
        #expect(WorkspaceDestination(.search).sidebarDestination == .search)
    }

    @Test func aTemplateStationReplacesClustersWithPlaceholdersAndAsksForThemOnOpen() throws {
        let store = WorkspaceStore(file: nil)
        var state = window()
        let p = state.tabs[0].focusedPane
        _ = state.split(p, axis: .horizontal, showing: .chartRoom(Self.c2, .releases))
        let station = store.saveStation(named: "Incident", from: state, bindToClusters: false)
        #expect(station.isTemplate)
        #expect(station.placeholders == ["$cluster", "$cluster2"])
        #expect(!station.tabs.flatMap(\.clusterIDs).contains(Self.c1))
        let opened = store.instantiate(station, clusters: ["$cluster": "kc-x", "$cluster2": "kc-y"])
        #expect(opened.tabs[0].clusterIDs == ["kc-x", "kc-y"])
        #expect(opened.tabs[0].id != state.tabs[0].id)
        #expect(Set(opened.tabs[0].panes.map(\.id)).isDisjoint(with: state.tabs[0].panes.map(\.id)))
    }

    @Test func aBoundStationReopensTheSameClustersAndLinksFollow() throws {
        let store = WorkspaceStore(file: nil)
        var state = window()
        let table = state.tabs[0].focusedPane
        let splitLogs = state.split(table, axis: .vertical)
        let logs = try #require(splitLogs)
        state.setLink(logs, to: table, view: .logs)
        let station = store.saveStation(named: "Pair", from: state, bindToClusters: true)
        #expect(!station.isTemplate)
        let opened = store.instantiate(station)
        let panes = opened.tabs[0].panes
        let source = try #require(panes.first { $0.link == nil && !$0.stack.isEmpty })
        #expect(panes.first { $0.link != nil }?.link == source.id)
        #expect(opened.tabs[0].clusterIDs == [Self.c1])
    }

    @Test func stationsCanBeRenamedDuplicatedAndDeletedButNotBuiltIns() throws {
        let store = WorkspaceStore(file: nil)
        let builtIn = try #require(store.stations.first)
        #expect(store.stations.filter(\.isBuiltIn).map(\.name) == ["Triage", "Release", "Node work"])
        store.renameStation(builtIn.id, to: "x")
        store.deleteStation(builtIn.id)
        #expect(store.stations.first?.name == builtIn.name)
        let mine = store.saveStation(named: "A", from: window(), bindToClusters: true)
        store.renameStation(mine.id, to: "B")
        let copy = try #require(store.duplicateStation(mine.id))
        #expect(copy.name == "B Copy")
        store.deleteStation(mine.id)
        #expect(!store.stations.contains { $0.id == mine.id })
        #expect(store.stations.contains { $0.id == copy.id })
    }

    @Test func builtInTemplatesAreLinkedAndNeedOneCluster() {
        for station in BuiltInStations.all {
            #expect(station.placeholders == ["$cluster"])
            let tab = station.tabs[0]
            for pane in tab.panes { #expect(pane.link == nil || tab.root.pane(pane.link!) != nil) }
        }
        #expect(BuiltInStations.triage.tabs[0].panes.contains { $0.linkedView == .logs })
        #expect(BuiltInStations.nodeWork.tabs[0].panes.contains { $0.linkedView == .detail })
    }

    @Test func builtInStationsAreNotWrittenToTheFile() {
        let store = WorkspaceStore(file: nil)
        #expect(store.snapshot.stations.isEmpty)
    }
}
