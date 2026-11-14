import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

@MainActor @Suite struct NamespacePickerTests {
    private func model(_ selection: NamespaceSelection = .all, query: String = "") -> NamespacePickerModel {
        var m = NamespacePickerModel(selection: selection, clusterNamespaces: ["web", "payments", "kube-system", "shop"], pinned: ["shop", "gone"])
        m.query = query
        return m
    }

    @Test func nameClickSelectsOnlyThatNamespace() {
        var m = model(NamespaceSelection(names: ["web", "shop"]))
        m.selectOnly("payments")
        #expect(m.selection == NamespaceSelection("payments"))
    }

    @Test func checkboxTogglesAndEmptyingFallsBackToAll() {
        var m = model()
        m.toggle("web")
        m.toggle("shop")
        #expect(m.selection.names == ["shop", "web"])
        m.toggle("web")
        #expect(m.selection == NamespaceSelection("shop"))
        m.toggle("shop")
        #expect(m.selection == .all)
    }

    @Test func allRowClearsTheSelection() {
        var m = model(NamespaceSelection(names: ["web", "shop"]))
        m.clear()
        #expect(m.selection == .all)
    }

    @Test func rowsListPinnedFirstAndSearchFilters() {
        let m = model()
        #expect(m.showsAllRow)
        #expect(m.pinnedRows == ["shop"])                                        // a pinned name the cluster no longer lists is dropped
        #expect(m.otherRows == ["kube-system", "payments", "web"])
        let q = model(query: " PAY ")
        #expect(!q.showsAllRow && q.pinnedRows.isEmpty && q.otherRows == ["payments"])
        #expect(model(query: "zzz").isEmpty)
    }

    @Test func aSelectedNamespaceTheClusterNoLongerListsStaysVisible() {
        let m = NamespacePickerModel(selection: NamespaceSelection("old"), clusterNamespaces: ["web"], pinned: [])
        #expect(m.otherRows == ["old", "web"])
    }

    @Test func pinnedNamesSurviveAnEmptyNamespaceList() {
        let m = NamespacePickerModel(selection: .all, clusterNamespaces: ["shop"], pinned: ["shop"])
        #expect(m.pinnedRows == ["shop"] && m.otherRows.isEmpty)
    }

    @Test func limitStopsFurtherAdditions() {
        var m = model(NamespaceSelection(names: (0 ..< NamespaceSelection.limit).map { "n\($0)" }))
        #expect(m.atLimit)
        m.toggle("web")
        #expect(!m.selection.contains("web"))
    }
}

@MainActor @Suite struct MultiNamespaceListAndSidebarTests {
    private func demo() throws -> (ClusterRegistry, ClusterSession, ClusterID) {
        let registry = ClusterRegistry.preview()
        let config = try #require(registry.clusters.first)
        return (registry, try #require(registry.session(for: config.id)), config.id)
    }

    private func settle(_ store: ResourceStore<Unstructured>) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while store.phase != .loaded, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func listScreenReadsTheSelectionForItsStoresKeyAndColumn() throws {
        let (_, session, _) = try demo()
        let screen = ListScreen(session: session, baseKind: .pod, initialSelection: NamespaceSelection(names: ["b", "a"]))
        #expect(screen.effectiveNamespace == nil)                                // several namespaces: the namespace column shows
        #expect(screen.contextNamespace == "a, b")
        #expect(screen.store.stores.map(\.namespace) == ["a", "b"])
        #expect(screen.storeKey == "\(ResourceKind.pod.id)|a,b|")
        let one = ListScreen(session: session, baseKind: .pod, initialSelection: NamespaceSelection("a"))
        #expect(one.effectiveNamespace == "a" && one.store.stores.count == 1)
        let all = ListScreen(session: session, baseKind: .pod, initialSelection: .all)
        #expect(all.effectiveNamespace == nil && all.contextNamespace == nil && all.storeKey == "\(ResourceKind.pod.id)|*|")
        let nodes = ListScreen(session: session, baseKind: .node, initialSelection: NamespaceSelection(names: ["a", "b"]))
        #expect(nodes.store.stores.count == 1 && nodes.contextNamespace == nil)  // a cluster-scoped kind ignores the selection
    }

    @Test func sidebarCountsUseRunningStoresOfTheSelectionOnly() async throws {
        let (registry, session, id) = try demo()
        let provider = RegistrySidebarProvider(registry: registry)
        let everything = session.unstructuredStore(kind: .pod)
        everything.start()
        defer { everything.stop() }
        await settle(everything)
        let byNamespace = Dictionary(grouping: everything.items, by: { $0.metadata.namespace ?? "" }).filter { !$0.key.isEmpty }
        try #require(byNamespace.count >= 3)
        let names = Array(byNamespace.keys.sorted().prefix(2))
        let selection = NamespaceSelection(names: names)
        let expected = names.reduce(0) { $0 + (byNamespace[$1]?.count ?? 0) }

        // No per-namespace store runs: the all-namespaces store is filtered to the set.
        let filtered = try #require(provider.runningItems(for: id, kind: .pod, selection: selection))
        #expect(filtered.items.count == expected)
        #expect(Set(filtered.items.compactMap(\.metadata.namespace)) == Set(names))

        // Every per-namespace store running: they are concatenated.
        let each = names.map { session.unstructuredStore(kind: .pod, namespace: $0) }
        each.forEach { $0.start() }
        defer { each.forEach { $0.stop() } }
        for store in each { await settle(store) }
        #expect(try #require(provider.runningItems(for: id, kind: .pod, selection: selection)).items.count == expected)

        // A single namespace keeps the old path.
        #expect(provider.runningItems(for: id, kind: .pod, selection: NamespaceSelection(names[0]))?.items.count == byNamespace[names[0]]?.count)
    }

    @Test func sidebarHasNothingWhenNoStoreCoversTheSelection() throws {
        let (registry, _, id) = try demo()
        let provider = RegistrySidebarProvider(registry: registry)
        #expect(provider.runningItems(for: id, kind: .pod, selection: NamespaceSelection(names: ["a", "b"])) == nil)
    }
}
