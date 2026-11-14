import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct NamespaceSelectionTests {
    @Test func encodingRoundTripsAndNormalises() {
        #expect(NamespaceSelection(encoded: "*") == .all)
        #expect(NamespaceSelection(encoded: "") == .all)
        #expect(NamespaceSelection(encoded: "shop") == .namespaces(["shop"]))
        #expect(NamespaceSelection(encoded: "a,b").names == ["a", "b"])
        #expect(NamespaceSelection(encoded: " b , a ,").names == ["a", "b"])
        #expect(NamespaceSelection(encoded: "a,a,b").names == ["a", "b"])
        #expect(NamespaceSelection.all.encoded == "*")
        #expect(NamespaceSelection("shop").encoded == "shop")                    // one name stays the bare legacy value
        #expect(NamespaceSelection(names: ["web", "api"]).encoded == "api,web")
        for s in [NamespaceSelection.all, .init("x"), .init(names: ["q", "p", "r"])] { #expect(NamespaceSelection(encoded: s.encoded) == s) }
    }

    @Test func singleIsTheNameOnlyForExactlyOne() {
        #expect(NamespaceSelection.all.single == nil)
        #expect(NamespaceSelection(nil).single == nil)
        #expect(NamespaceSelection("a").single == "a")
        #expect(NamespaceSelection(names: ["a", "b"]).single == nil)
        #expect(NamespaceSelection(names: [String]()).isAll)
    }

    @Test func labelAndDetail() {
        #expect(NamespaceSelection.all.label == "All namespaces")
        #expect(NamespaceSelection("payments").label == "payments")
        #expect(NamespaceSelection(names: ["web", "payments"]).label == "payments, web")
        #expect(NamespaceSelection(names: ["a", "b", "c"]).label == "3 namespaces")
        #expect(NamespaceSelection(names: ["a", "b", "c"]).detail == "a, b, c")
        #expect(NamespaceSelection.all.detail == "All namespaces")
    }

    @Test func togglingAddsRemovesAndCaps() {
        var s = NamespaceSelection.all.toggling("a")
        #expect(s == .namespaces(["a"]))
        s = s.toggling("b")
        #expect(s.names == ["a", "b"])
        s = s.toggling("a").toggling("b")
        #expect(s == .all)
        let full = NamespaceSelection(names: (0 ..< NamespaceSelection.limit).map { "n\($0)" })
        #expect(full.toggling("extra") == full)
        #expect(full.toggling("n0").names.count == NamespaceSelection.limit - 1)
        #expect(full.contains("n1") && !full.contains("zz"))
    }
}

@MainActor @Suite struct NamespaceStoreGroupTests {
    private func session(_ client: ScriptedClient) -> ClusterSession {
        ClusterSession(config: ClusterConfig(id: "g1", name: "g", server: URL(string: "https://g.example")!, authKind: .token), client: client)
    }

    private func settle(_ group: NamespaceStoreGroup) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while group.phase == .loading || group.phase == .idle, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func twoNamespacesMergeOnlyTheirOwnRows() async {
        let client = ScriptedClient()
        client.podNamesByNamespace = ["a": ["a1", "a2"], "b": ["b1"], "c": ["c1"]]
        let s = session(client)
        let group = s.unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["b", "a"]))
        #expect(group.stores.map(\.namespace) == ["a", "b"])
        let run = Task { await group.run() }
        await settle(group)
        #expect(group.items.map(\.metadata.name).sorted() == ["a1", "a2", "b1"])
        #expect(Set(group.items.compactMap(\.metadata.namespace)) == ["a", "b"])
        #expect(group.phase == .loaded)
        #expect(group.stores.allSatisfy { $0.consumerCount == 1 })
        run.cancel()
        await run.value
        #expect(group.stores.allSatisfy { $0.consumerCount == 0 })
    }

    @Test func sameStoresAreReusedAcrossSelections() {
        let s = session(ScriptedClient())
        let ab = s.unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        let a = s.unstructuredStores(kind: .pod, selection: NamespaceSelection("a"))
        #expect(a.stores[0] === ab.stores[0])
    }

    @Test func clusterScopedKindsNeverFanOut() {
        let s = session(ScriptedClient())
        let group = s.unstructuredStores(kind: .node, selection: NamespaceSelection(names: ["a", "b"]))
        #expect(group.stores.count == 1)
        #expect(group.stores[0].namespace == nil)
        #expect(s.unstructuredStores(kind: .pod, selection: .all).stores.count == 1)
    }

    @Test func oneForbiddenNamespaceKeepsTheOthersAndReportsItself() async {
        let client = ScriptedClient()
        client.podNamesByNamespace = ["a": ["a1"]]
        client.podsErrorByNamespace = ["b": .forbidden(verb: "list", resource: "pods", namespace: nil, message: "no")]
        let group = session(client).unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        let run = Task { await group.run() }
        await settle(group)
        #expect(group.items.map(\.metadata.name) == ["a1"])
        #expect(group.error != nil)
        #expect(group.error(forNamespace: "a") == nil)
        #expect(group.error(forNamespace: "b") != nil)
        #expect(group.failedNamespaces == ["b"])
        #expect(group.phase == .loaded)
        run.cancel()
        await run.value
    }

    @Test func allForbiddenIsFailed() async {
        let client = ScriptedClient()
        client.podsError = .forbidden(verb: "list", resource: "pods", namespace: nil, message: "no")
        let group = session(client).unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        let run = Task { await group.run() }
        await settle(group)
        #expect(group.items.isEmpty)
        #expect(group.phase == .failed)
        #expect(group.error != nil)
        run.cancel()
        await run.value
    }

    @Test func stampsChangeWhenAnyMemberUpdates() async {
        let client = ScriptedClient()
        client.podNamesByNamespace = ["a": ["a1"], "b": ["b1"]]
        let group = session(client).unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        #expect(group.updateStamps.count == 2 && group.lastUpdated == nil)
        let run = Task { await group.run() }
        await settle(group)
        let before = group.updateStamps
        try? await Task.sleep(for: .milliseconds(30))
        await group.stores[1].refresh()                                          // only the newer member updates
        #expect(group.updateStamps != before)
        #expect(group.lastUpdated != nil)
        run.cancel()
        await run.value
    }

    @Test func refreshReloadsEveryMember() async {
        let client = ScriptedClient()
        let group = session(client).unstructuredStores(kind: .pod, selection: NamespaceSelection(names: ["a", "b"]))
        let run = Task { await group.run() }
        await settle(group)
        let lists = client.lists
        await group.refresh()
        #expect(client.lists >= lists + 2)
        run.cancel()
        await run.value
    }

    @Test func podMetricsMergeAndSkipAFailingNamespace() async throws {
        func metric(_ name: String, _ ns: String) throws -> PodMetrics {
            try JSONValue.object(["metadata": ["name": .string(name), "namespace": .string(ns)], "containers": []]).decode(PodMetrics.self)
        }
        let client = ScriptedClient()
        client.metricsByNamespace = ["a": .success([try metric("p1", "a")]), "b": .failure(.forbidden(verb: "list", resource: "pods", namespace: nil, message: "no")), "c": .success([try metric("p2", "c")])]
        let merged = try await client.podMetrics(namespaces: ["a", "b", "c"])
        #expect(merged.map(\.metadata.name).sorted() == ["p1", "p2"])
        client.metricsByNamespace = ["a": .failure(.forbidden(verb: "list", resource: "pods", namespace: nil, message: "no")), "b": .failure(.forbidden(verb: "list", resource: "pods", namespace: nil, message: "no"))]
        await #expect(throws: KubeError.self) { try await client.podMetrics(namespaces: ["a", "b"]) }
        #expect(try await client.podMetrics(namespaces: []).isEmpty)
    }
}
