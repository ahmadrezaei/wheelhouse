#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@Suite("Compass matcher, query and index")
struct CompassIndexTests {
    private func score(_ q: String, _ name: String) -> Int? { CompassMatcher.score(CompassMatcher.fold(q), in: CompassMatcher.fold(name)) }

    @Test func matcherOrdersExactPrefixWordSubstringAcronymSubsequence() {
        #expect(score("web", "web") == CompassMatcher.exact)
        #expect(score("web", "web-api")! > score("api", "web-api")!)          // prefix beats word prefix
        #expect(score("api", "web-api")! > score("eb-a", "web-api")!)         // word prefix beats substring
        #expect(score("pa-api", "payments-api") == CompassMatcher.chain)      // acronym chain
        #expect(score("pgw", "payments-gateway-worker") == CompassMatcher.acronym)
        #expect(score("pmts", "payments-api") == CompassMatcher.subsequence - 3)
        #expect(score("zzz", "payments-api") == nil)
        #expect(score("longer-than-the-name", "web") == nil)
    }

    @Test func matchedOffsetsMarkTheCharacters() {
        #expect(CompassMatcher.matchedOffsets(query: "api", in: "web-api") == [4, 5, 6])
        #expect(CompassMatcher.matchedOffsets(query: "wa", in: "web-api") == [0, 4])
        #expect(CompassMatcher.matchedOffsets(query: "xyz", in: "web-api").isEmpty)
    }

    @Test func queryParsing() {
        #expect(CompassQuery.parse("> split down").mode == .actions)
        #expect(CompassQuery.parse("> split down").tokens == ["split", "down"])
        let q = CompassQuery.parse("@prod-eu po #payments crash is:Failing l:app=web,tier in (api, worker) img:web:1.9")
        #expect(q.cluster == "prod-eu" && q.namespace == "payments" && q.tokens == ["po", "crash"])
        #expect(q.states == ["failing"] && q.labelSelector == "app=web,tier in (api, worker)" && q.image == "web:1.9")
        #expect(CompassQuery.parse("go deploy").mode == .goToKind)
        #expect(CompassQuery.parse("go deploy").argument == "deploy")
        #expect(CompassQuery.parse("settings:beacon").mode == .settings)
        #expect(CompassQuery.parse("station:triage").argument == "triage")
        #expect(CompassQuery.parse("cve:2026-31337").mode == .cve)
        #expect(CompassQuery.parse("? why is checkout pending").argument == "why is checkout pending")
        // The bang keeps exactly what was typed after it.
        let run = CompassQuery.parse("!kubectl top pods  -n payments ")
        #expect(run.mode == .run && run.argument == "kubectl top pods  -n payments ")
        #expect(CompassQuery.parse("   ").isEmpty)
    }

    @Test func labelSelectors() {
        let labels = ["app": "web", "tier": "api"]
        #expect(CompassLabelSelector("app=web").matches(labels))
        #expect(CompassLabelSelector("app==web,tier in (api,worker)").matches(labels))
        #expect(!CompassLabelSelector("app!=web").matches(labels))
        #expect(CompassLabelSelector("tier notin (db)").matches(labels))
        #expect(CompassLabelSelector("app").matches(labels))
        #expect(CompassLabelSelector("!canary").matches(labels))
        #expect(!CompassLabelSelector("app=web,,").isValid)
        #expect(!CompassLabelSelector("app=web,@@").matches(labels))
    }

    private func items(_ names: [String], ns: String = "payments", labels: [String: String] = [:]) -> [CompassMetadataItem] {
        names.map { CompassMetadataItem(name: $0, namespace: ns, labels: labels) }
    }

    @Test func searchesAcrossClustersWithKindScopeAndFilters() async {
        let index = CompassIndex()
        await index.replace(cluster: "a", kind: .pod, items: items(["payments-api-7d9f-x2k4q", "web-frontend-1"], labels: ["app": "payments-api"]))
        await index.replace(cluster: "a", kind: .deployment, items: items(["payments-api", "web-frontend"]))
        await index.replace(cluster: "b", kind: .deployment, items: items(["payments-api"], ns: "staging"))
        let names = ["a": "prod-eu", "b": "staging-eu"]

        let all = await index.search(.parse("pa-api"), clusters: names)
        #expect(all.map(\.name).contains("payments-api") && all.count == 3)
        // Kind first, then text.
        let pods = await index.search(.parse("po payments"), clusters: names)
        #expect(pods.first?.name == "payments-api-7d9f-x2k4q" && pods.allSatisfy { $0.kind == .pod })
        // Cluster and namespace scope.
        let scoped = await index.search(.parse("@staging payments"), clusters: names)
        #expect(scoped.map(\.cluster) == ["b"])
        let inNamespace = await index.search(.parse("#staging api"), clusters: names)
        #expect(inNamespace.map(\.cluster) == ["b"])
        // Label selector (case-insensitive) and an invalid selector.
        #expect(await index.search(.parse("l:app=payments-api"), clusters: names).count == 2)
        #expect(await index.search(.parse("l:(((")).isEmpty)
        // Labels are searched for plain tokens after names and namespaces.
        #expect(await index.search(.parse("app=payments")).map(\.name).contains("payments-api-7d9f-x2k4q"))
        // Metadata carries no image or status.
        #expect(await index.search(.parse("img:web")).isEmpty)
        #expect(await index.search(.parse("is:pending web")).isEmpty)
        #expect(await index.search(.parse("")).isEmpty)
    }

    @Test func problemsComeFirstAndFrecencyReorders() async {
        let index = CompassIndex()
        await index.replace(cluster: "a", kind: .pod, items: items(["api-1", "api-2", "api-3"]))
        let problem = CompassHit.key(cluster: "a", kindID: ResourceKind.pod.id, namespace: "payments", name: "api-3")
        let withProblem = await index.search(.parse("api"), problems: [problem])
        #expect(withProblem.first?.name == "api-3" && withProblem.first?.isProblem == true)
        #expect(await index.search(.parse("is:failing"), problems: [problem]).map(\.name) == ["api-3"])
        #expect(await index.search(.parse("is:pinned"), pinned: [problem]).map(\.name) == ["api-3"])
        let boosted = await index.search(.parse("api"), frecency: { $0.hasSuffix("api-2") ? 150 : 0 })
        #expect(boosted.first?.name == "api-2")
    }

    @Test func secretsKeepOnlyTheirNameAndNamespace() async {
        let index = CompassIndex()
        let sentinel = "SENTINEL-" + "base64" + "-DATA"
        let secret = CompassMetadataItem(name: "db-credentials", namespace: "payments", labels: ["leak": sentinel], ownerKind: "Thing", ownerName: sentinel)
        await index.replace(cluster: "a", kind: .secret, items: [secret])
        #expect(await index.search(.parse("db-cred")).map(\.name) == ["db-credentials"])
        #expect(await index.search(.parse(sentinel.lowercased())).isEmpty)
        #expect(await index.search(.parse("l:leak=\(sentinel)")).isEmpty)
    }

    @Test func theCapEvictsTheLeastRecentlyFocusedCluster() async {
        let index = CompassIndex(capBytes: 60_000)
        let many = (0..<80).map { CompassMetadataItem(name: "object-number-\($0)", namespace: "ns", labels: ["app": "x"]) }
        await index.replace(cluster: "old", kind: .pod, items: many)
        await index.replace(cluster: "mid", kind: .pod, items: many)
        await index.noteFocus("old")
        await index.replace(cluster: "new", kind: .pod, items: many)
        let kept = await index.indexedClusters
        #expect(kept.contains("new"))
        #expect(await index.stats.bytes <= 60_000)
        #expect(!kept.contains("mid"))
        #expect(await index.evictions >= 1)
    }

    @Test func aRefreshThatFailsKeepsTheOldEntries() async {
        let index = CompassIndex()
        await index.replace(cluster: "a", kind: .pod, items: items(["keep-me"]))
        await index.beginRefresh(cluster: "a", kind: .pod)
        await index.stage(cluster: "a", kind: .pod, items: items(["half-way"]))
        await index.abortRefresh(cluster: "a", kind: .pod)
        #expect(await index.search(.parse("keep")).map(\.name) == ["keep-me"])
        // Staging without a begin is ignored, and an empty commit removes the kind.
        await index.stage(cluster: "a", kind: .service, items: items(["stray"]))
        #expect(await index.search(.parse("stray")).isEmpty)
        await index.replace(cluster: "a", kind: .pod, items: [])
        let emptied = await index.stats
        #expect(emptied.objects == 0 && emptied.clusters == 0)
    }

    @Test func dropKeepOnlyAndRemoveAll() async {
        let index = CompassIndex()
        for c in ["a", "b", "c"] { await index.replace(cluster: c, kind: .pod, items: items(["x-\(c)"])) }
        await index.keepOnly(["a"])
        #expect(await index.indexedClusters == ["a"])
        await index.drop(cluster: "a")
        await index.replace(cluster: "b", kind: .pod, items: items(["x"]))
        await index.removeAll()
        let stats = await index.stats
        #expect(stats.objects == 0 && stats.bytes == 0 && stats.updated == nil)
        await index.noteFocus("nobody")
    }

    @Test func frecencyDecaysPersistsAndIsCapped() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "frecency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "compass-frecency.json")
        let clock = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let store = FrecencyStore(file: file, now: { clock.value })
        store.record("cmd|a"); store.record("cmd|a"); store.record("cmd|b")
        let fresh = store.boost("cmd|a")
        #expect(fresh > store.boost("cmd|b") && fresh <= FrecencyStore.maximumBoost)
        clock.value = clock.value.addingTimeInterval(86_400 * 28)
        #expect(store.boost("cmd|a") < fresh)
        #expect(store.boost("cmd|unknown") == 0)
        #expect(store.topKeys(prefix: "cmd|", limit: 1) == ["cmd|a"])
        store.flush()
        let reloaded = FrecencyStore(file: file, now: { clock.value })
        #expect(reloaded.records["cmd|a"]?.count == 2)
        for i in 0..<(FrecencyStore.capacity + 20) { store.record("obj|\(i)") }
        #expect(store.records.count == FrecencyStore.capacity)
        store.clear()
        #expect(FrecencyStore(file: file).records.isEmpty)
        FrecencyStore(file: nil).flush()
    }

    /// ARCHITECTURE-MAC 12.4: first results at most 50 ms warm over 100,000 objects, and the index within 64 MB. The tight bound
    /// applies to an optimised build (`swift test -c release`); a debug build keeps a loose one so the test still catches a
    /// quadratic scan.
    @Test func hundredThousandObjectsAnswerWithinTheBudget() async {
        let index = CompassIndex()
        let kinds: [ResourceKind] = [.pod, .deployment, .service, .configMap]
        let namespaces = (0..<40).map { "team-\($0)" }
        for (k, kind) in kinds.enumerated() {
            let batch = (0..<25_000).map { i in
                CompassMetadataItem(name: "\(["payments", "checkout", "search", "billing", "inventory"][i % 5])-\(["api", "worker", "cron", "web"][i % 4])-\(i)-\(k)x7f",
                                    namespace: namespaces[i % 40], labels: ["app": "svc-\(i % 500)", "tier": i % 2 == 0 ? "api" : "worker"],
                                    ownerKind: "ReplicaSet", ownerName: "owner-\(i % 900)")
            }
            await index.replace(cluster: "big", kind: kind, items: batch)
        }
        let stats = await index.stats
        #expect(stats.objects == 100_000 && stats.bytes < CompassIndex.defaultCapBytes)
        let queries = ["pay api", "pa-api", "checkout wrk", "deploy bill", "svc-42", "#team-9 inv", "l:tier=api"]
        _ = await index.search(.parse("warm"))
        #if DEBUG
        let budget = Duration.milliseconds(1_500)
        #else
        let budget = Duration.milliseconds(50)
        #endif
        var worst = Duration.zero
        for q in queries {
            let parsed = CompassQuery.parse(q)
            let start = ContinuousClock.now
            let hits = await index.search(parsed)
            let took = ContinuousClock.now - start
            print("COMPASS \(q) \(took)")
            worst = max(worst, took)
            #expect(!hits.isEmpty, "\(q)")
        }
        print("COMPASS worst \(worst)")
        #expect(worst <= budget, "worst query \(worst)")
    }
}

private final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}
#endif
