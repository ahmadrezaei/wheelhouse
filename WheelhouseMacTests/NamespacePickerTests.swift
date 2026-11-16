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

/// Lists the demo cluster but refuses one namespace, as RBAC does for a user with namespace-scoped permissions.
private final class ForbiddingClient: KubeClientProtocol, @unchecked Sendable {
    let inner: DemoKubeClient
    let forbidden: String
    /// A namespace whose lists answer late, so a load for it finishes after a newer one.
    let delayed: String?
    init(inner: DemoKubeClient, forbidden: String, delayed: String? = nil) { self.inner = inner; self.forbidden = forbidden; self.delayed = delayed }
    func version() async throws -> KubeVersion { try await inner.version() }
    func discovery() async throws -> DiscoveryInfo { try await inner.discovery() }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        if namespace == forbidden { throw KubeError.forbidden(verb: "list", resource: "pods", namespace: namespace, message: "forbidden") }
        return try await inner.list(type, kind: kind, namespace: namespace, options: options)
    }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { try await inner.get(type, kind: kind, name: name, namespace: namespace) }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue {
        if namespace == forbidden { throw KubeError.forbidden(verb: "list", resource: "pods", namespace: namespace, message: "forbidden") }
        if namespace != nil, namespace == delayed { try await Task.sleep(for: .milliseconds(600)) }
        return try await inner.listRaw(kind, namespace: namespace, options: options)
    }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { try await inner.getRaw(kind, name: name, namespace: namespace) }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        inner.watch(type, kind: kind, namespace: namespace, options: options)
    }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { try await inner.create(kind, namespace: namespace, name: name, subresource: subresource, body: body, options: options) }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { try await inner.replace(kind, name: name, namespace: namespace, body: body, options: options) }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { try await inner.patch(kind, name: name, namespace: namespace, subresource: subresource, patch: patch, options: options) }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { try await inner.delete(kind, name: name, namespace: namespace, options: options) }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { inner.logs(namespace: namespace, pod: pod, options: options) }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { try await inner.podMetrics(namespace: namespace) }
    func nodeMetrics() async throws -> [NodeMetrics] { try await inner.nodeMetrics() }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { try await inner.proxyGET(namespace: namespace, service: service, port: port, path: path, query: query) }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { try inner.execWebSocket(namespace: namespace, pod: pod, options: options) }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { try inner.portForwardWebSocket(namespace: namespace, pod: pod, ports: ports) }
}

@MainActor @Suite struct MultiNamespaceFollowUpTests {
    private func settle(_ until: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !until(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    /// Two namespaces of the demo fleet that hold pods.
    private func twoNamespaces(_ client: DemoKubeClient) async throws -> [String] {
        let all = try await client.list(Unstructured.self, kind: .pod, namespace: nil, options: ListOptions())
        let names = Set(all.items.compactMap(\.metadata.namespace)).sorted()
        try #require(names.count >= 2)
        return Array(names.prefix(2))
    }

    @Test func rowActionsHideForTheFailedMemberOnlyUnderAPartialError() async throws {
        let config = DemoFleet.configs[0]
        let demo = DemoKubeClient(config: config)
        let names = try await twoNamespaces(demo)
        let session = ClusterSession(config: config, client: ForbiddingClient(inner: demo, forbidden: names[1]))
        let screen = ListScreen(session: session, baseKind: .pod, initialSelection: NamespaceSelection(names: names))
        let group = screen.store
        group.stores.forEach { $0.start() }
        defer { group.stores.forEach { $0.stop() } }
        await settle { group.stores.allSatisfy { $0.phase != .loading && $0.phase != .idle } }
        #expect(group.stores[0].error == nil && group.stores[1].error != nil)

        let cache = SummaryCache()
        func row(in namespace: String) throws -> ListRowModel {
            let object = try #require(group.items.first { $0.metadata.namespace == namespace }
                ?? (try? JSONValue.object(["kind": "Pod", "metadata": .object(["name": "x", "namespace": .string(namespace)])]).decode(Unstructured.self)))
            return ListRowModel(object: object, summary: cache.summary(kind: .pod, object: object))
        }
        #expect(screen.canMutate)                                   // one member loaded: the list stays actionable
        #expect(screen.canMutate(try row(in: names[0])))
        #expect(!screen.canMutate(try row(in: names[1])))           // a row of the failed namespace gets no actions
    }

    @Test func switchingFromTwoNamespacesToOneReleasesTheDroppedWatch() async throws {
        let config = DemoFleet.configs[0]
        let session = ClusterSession(config: config, client: DemoKubeClient(config: config))
        let both = session.unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        let one = session.unstructuredStores(kind: .pod, selection: NamespaceSelection("a"))
        let (a, b) = (both.stores[0], both.stores[1])
        #expect(one.stores[0] === a)                                // the shared per-namespace store survives the switch

        let first = Task { await both.run() }
        await settle { a.consumerCount == 1 && b.consumerCount == 1 }
        #expect(a.consumerCount == 1 && b.consumerCount == 1)
        let second = Task { await one.run() }                       // the list's .task(id:) restarts with the new selection
        first.cancel()
        await first.value
        await settle { a.consumerCount == 1 && b.consumerCount == 0 }
        #expect(a.consumerCount == 1)                                // still watched, now by the new run only
        #expect(b.consumerCount == 0)                                // b's watch is released
        second.cancel()
        await second.value
        #expect(a.consumerCount == 0)
    }

    @Test func secretGroupsBuildOneStrippedStorePerNamespace() async throws {
        let config = DemoFleet.configs[0]
        let session = ClusterSession(config: config, client: DemoKubeClient(config: config))
        let cache = SecretStoreCache()
        let group = cache.group(session: session, selection: NamespaceSelection(names: ["b", "a"]), labelSelector: nil)
        #expect(group.stores.map(\.namespace) == ["a", "b"])
        #expect(cache.group(session: session, selection: NamespaceSelection(names: ["a", "b"]), labelSelector: nil).stores.first === group.stores[0])
        #expect(cache.group(session: session, selection: .all, labelSelector: nil).stores.map(\.namespace) == [nil])

        let wide = cache.group(session: session, selection: .all, labelSelector: nil).stores[0]
        wide.start()
        defer { wide.stop() }
        await settle { wide.phase == .loaded }
        #expect(!wide.items.isEmpty)
        for item in wide.items { for (_, v) in item.raw["data"]?.objectValue ?? [:] { #expect(v.stringValue == "") } }
    }

    @Test func workloadsSummaryCountsPerNamespaceAndSums() async throws {
        let config = DemoFleet.configs[0]
        let demo = DemoKubeClient(config: config)
        let names = try await twoNamespaces(demo)
        var expected: [Int] = []
        for name in names { expected.append(try await demo.list(Unstructured.self, kind: .pod, namespace: name, options: ListOptions()).items.count) }
        let session = ClusterSession(config: config, client: ForbiddingClient(inner: demo, forbidden: "nowhere"))
        let model = CountsModel()
        await model.load(session: session, selection: NamespaceSelection(names: names))
        #expect(model.counts[ResourceKind.pod.id] == .exact(expected.reduce(0, +)))
        #expect(model.loadedFor == "\(session.id)|\(NamespaceSelection(names: names).encoded)")

        // One namespace refused: its count is left out, the others still add up; every namespace refused locks the kind.
        let partial = ClusterSession(config: config, client: ForbiddingClient(inner: demo, forbidden: names[1]))
        let partialModel = CountsModel()
        await partialModel.load(session: partial, selection: NamespaceSelection(names: names))
        #expect(partialModel.counts[ResourceKind.pod.id] == .exact(expected[0]))
        let single = CountsModel()
        await single.load(session: partial, selection: NamespaceSelection(names[1]))
        #expect(single.counts[ResourceKind.pod.id] == .locked)
        #expect(single.counts[ResourceKind.node.id] != .locked)      // a cluster-scoped kind is listed once, whatever the selection
    }

    @Test func aSupersededLoadCannotOverwriteNewerCounts() async throws {
        let config = DemoFleet.configs[0]
        let demo = DemoKubeClient(config: config)
        let names = try await twoNamespaces(demo)
        let expected = try await demo.list(Unstructured.self, kind: .pod, namespace: names[0], options: ListOptions()).items.count
        let session = ClusterSession(config: config, client: ForbiddingClient(inner: demo, forbidden: "nowhere", delayed: "zz-none"))
        let model = CountsModel()
        let stale = Task { await model.load(session: session, selection: NamespaceSelection("zz-none")) }
        await Task.yield()
        await model.load(session: session, selection: NamespaceSelection(names[0]))     // the newer selection finishes first
        await stale.value
        #expect(model.counts[ResourceKind.pod.id] == .exact(expected))                  // the late, older answer (0 pods) was dropped
        #expect(model.loadedFor == "\(session.id)|\(names[0])")
    }

    @Test func kindCountsSum() {
        #expect(KindCount.sum([.exact(2), .exact(3)]) == .exact(5))
        #expect(KindCount.sum([.exact(2), .atLeast(3)]) == .atLeast(5))
        #expect(KindCount.sum([.exact(2), .locked]) == .exact(2))
        #expect(KindCount.sum([.locked, .locked]) == .locked)
        #expect(KindCount.sum([.exact(2), .unavailable]) == .atLeast(2))
        #expect(KindCount.sum([.unavailable, .unavailable]) == .unavailable)
        #expect(KindCount.sum([.unavailable]) == .unavailable)
        #expect(KindCount.sum([.locked, .unavailable]) == .unavailable)
        #expect(KindCount.sum([.atLeast(1), .unavailable]) == .atLeast(1))
    }
}
