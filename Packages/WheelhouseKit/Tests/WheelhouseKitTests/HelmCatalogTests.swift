import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Helm catalog: metadata-only listing, forbidden state, decode cache")
struct HelmCatalogTests {
    // MARK: The live metadata request

    @Test func liveListMetadataAsksForPartialObjectMetadata() async throws {
        let (client, host) = FakeAPI.client { _ in .json(helmMetadataPage([("web", "shop", 2, "deployed")])) }
        let list = try await client.listMetadata(kind: .secret, namespace: "shop", labelSelector: "owner=helm", limit: nil)
        let request = try #require(FakeAPI.requests(host: host).first)
        #expect(request.path == "/api/v1/namespaces/shop/secrets")
        #expect(request.accept == "application/json;as=PartialObjectMetadataList;g=meta.k8s.io;v=v1")
        #expect(request.query["labelSelector"] == "owner=helm")
        #expect(list.items.count == 1 && list.items[0].name == "sh.helm.release.v1.web.v2")
        #expect(list.items[0].labels["status"] == "deployed" && list.resourceVersion == "42")
    }

    @Test func liveListMetadataFollowsContinueTokensOnlyWithoutALimit() async throws {
        let (client, host) = FakeAPI.client { req in
            switch req.query["continue"] {
            case nil: .json(helmMetadataPage([("a", "ns", 1, "deployed")], continueToken: "t1"))
            case "t1": .json(helmMetadataPage([("b", "ns", 1, "deployed")], continueToken: "t2"))
            default: .json(helmMetadataPage([("c", "ns", 1, "deployed")]))
            }
        }
        let all = try await client.listMetadata(kind: .secret, namespace: nil, labelSelector: nil, limit: nil)
        #expect(all.items.count == 3 && all.continueToken == nil)
        #expect(FakeAPI.requests(host: host).count == 3 && FakeAPI.requests(host: host).allSatisfy { $0.query["limit"] == "500" })

        let (client2, host2) = FakeAPI.client { _ in .json(helmMetadataPage([("a", "ns", 1, "deployed")], continueToken: "more")) }
        let page = try await client2.listMetadata(kind: .secret, namespace: nil, labelSelector: nil, limit: 1)
        #expect(page.items.count == 1 && page.continueToken == "more")
        #expect(FakeAPI.requests(host: host2).count == 1 && FakeAPI.requests(host: host2)[0].query["limit"] == "1")
    }

    // MARK: Listing

    @Test func releasesGroupByNameAndTakeTheHighestRevisionAsCurrent() async throws {
        let (client, host) = FakeAPI.client { _ in
            .json(helmMetadataPage([("web", "shop", 1, "superseded"), ("web", "shop", 3, "deployed"), ("web", "shop", 2, "superseded"),
                                    ("web", "other", 1, "deployed"), ("db", "shop", 4, "failed"), ("api", "shop", 1, "pending-upgrade")]))
        }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: nil)
        #expect(listing.failure == nil && listing.storage == .secret && listing.revisionCount == 6)
        // Problems first (failed, pending-*), then namespace and name.
        #expect(listing.releases.map(\.id) == ["shop/api", "shop/db", "other/web", "shop/web"])
        let web = try #require(listing.releases.first { $0.id == "shop/web" })
        #expect(web.current.revision == 3 && web.history.map(\.revision) == [3, 2, 1])
        // Metadata only: one list, never a GET of a record.
        #expect(FakeAPI.requests(host: host).count == 1)
    }

    @Test func twoHundredReleasesListFromMetadataInUnderASecond() async throws {
        let metas = (1...200).map { (String(format: "release-%03d", $0), "ns-\($0 % 7)", 1 + $0 % 3, $0 % 50 == 0 ? "failed" : "deployed") }
        let (client, host) = FakeAPI.client { _ in .json(helmMetadataPage(metas)) }
        let clock = ContinuousClock()
        let start = clock.now
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: nil)
        let elapsed = clock.now - start
        #expect(listing.releases.count == 200)
        #expect(elapsed < .seconds(1), "listing took \(elapsed)")
        #expect(FakeAPI.requests(host: host).count == 1)
        #expect(listing.releases.prefix(4).allSatisfy { $0.current.status == .failed })
    }

    @Test func forbiddenSecretsFallBackToConfigMaps() async throws {
        let (client, host) = FakeAPI.client { req in
            if req.path.hasSuffix("/secrets") { return .forbidden(resource: "secrets", namespace: "shop") }
            return .json(helmMetadataPage([("cm-release", "shop", 2, "deployed")]))
        }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: "shop")
        #expect(listing.failure == nil && listing.storage == .configMap)
        #expect(listing.releases.map(\.id) == ["shop/cm-release"])
        #expect(listing.releases[0].current.storage == .configMap)
        #expect(FakeAPI.requests(host: host).map(\.path).contains { $0.hasSuffix("/configmaps") })
    }

    @Test func forbiddenEverywhereIsTheNeedListSecretsState() async throws {
        let (client, _) = FakeAPI.client { req in
            .forbidden(resource: req.path.hasSuffix("/secrets") ? "secrets" : "configmaps", namespace: "payments")
        }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: "payments")
        #expect(listing.failure == .forbidden(namespace: "payments") && listing.releases.isEmpty)
        let rule = HelmReleaseCatalog.rbacRule(namespace: "payments")
        #expect(rule.contains("secrets") && rule.contains("list") && rule.contains("payments"))
        #expect(HelmReleaseCatalog.rbacRule(namespace: nil).contains("ClusterRole"))
    }

    @Test func forbiddenSecretsWithEmptyConfigMapsStaysForbidden() async throws {
        let (client, _) = FakeAPI.client { req in
            req.path.hasSuffix("/secrets") ? .forbidden(resource: "secrets", namespace: nil) : .json(helmMetadataPage([]))
        }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: nil)
        #expect(listing.failure == .forbidden(namespace: nil))
    }

    @Test func noReleasesIsNotAnError() async throws {
        let (client, _) = FakeAPI.client { _ in .json(helmMetadataPage([])) }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: "payments")
        #expect(listing.failure == nil && listing.releases.isEmpty)
    }

    @Test func nonHelmObjectsAreIgnored() async throws {
        let page: JSONValue = ["items": [["metadata": ["name": "other", "namespace": "x", "labels": ["owner": "someone"]]],
                                         ["metadata": ["name": "sh.helm.release.v1.a.v1", "namespace": "x",
                                                       "labels": ["owner": "helm", "name": "a", "version": "1", "status": "deployed"]]]]]
        let (client, _) = FakeAPI.client { _ in .json(page) }
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: nil)
        #expect(listing.releases.map(\.name) == ["a"])
    }

    // MARK: Decode on demand and the 32 MB cache

    @Test func decodeCacheHasA32MBCostLimitAndEmptiesOnPressure() throws {
        #expect(DecodedReleaseCache.defaultByteLimit == 32 * 1024 * 1024)
        let cache = DecodedReleaseCache()
        #expect(cache.byteLimit == 32 * 1024 * 1024)
        let release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        cache.insert(release, forKey: "k")
        #expect(cache.release(forKey: "k")?.name == "wh-fixture")
        cache.removeAll()
        #expect(cache.release(forKey: "k") == nil)
    }

    @Test func costLimitEvictsOldReleases() throws {
        let cache = DecodedReleaseCache(byteLimit: 4_000)             // a tiny limit makes the policy observable
        var release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        release.payloadBytes = 3_000
        for i in 0..<20 { cache.insert(release, forKey: "k\(i)") }
        let alive = (0..<20).filter { cache.release(forKey: "k\($0)") != nil }.count
        #expect(alive < 20)
    }

    @Test func readerDecodesOnceAndKeysOnResourceVersion() async throws {
        let secret = try HelmFixtures.object("helm3-secret-v2")
        let (client, host) = FakeAPI.client { req in
            req.path.hasSuffix("/sh.helm.release.v1.wh-fixture.v2") ? .json(secret) : .notFound()
        }
        let cache = DecodedReleaseCache()
        let reader = HelmReleaseReader(client: client, cluster: "c1", cache: cache)
        let revision = HelmRevisionSummary(name: "wh-fixture", namespace: "wh-m6a", revision: 2, status: .deployed, modifiedAt: nil, storage: .secret,
                                           objectName: "sh.helm.release.v1.wh-fixture.v2", resourceVersion: "100")
        let first = try await reader.read(revision)
        let second = try await reader.read(revision)
        #expect(first == second && first.name == "wh-fixture")
        #expect(FakeAPI.requests(host: host).count == 1, "the second read comes from the cache")
        // Helm rewrote the record (new resourceVersion): the cached copy is not reused.
        var rewritten = revision
        rewritten.resourceVersion = "101"
        _ = try await reader.read(rewritten)
        #expect(FakeAPI.requests(host: host).count == 2)
    }

    @Test func readerSurfacesDecodeErrors() async throws {
        let (client, _) = FakeAPI.client { _ in .json(["data": ["release": "###"]]) }
        let reader = HelmReleaseReader(client: client, cluster: "c1", cache: DecodedReleaseCache())
        let revision = HelmRevisionSummary(name: "x", namespace: "n", revision: 1, status: .deployed, modifiedAt: nil, storage: .secret, objectName: "sh.helm.release.v1.x.v1")
        await #expect(throws: HelmDecodeError.self) { _ = try await reader.read(revision) }
    }

    @Test func oneReleaseIsFoundByTheNameLabel() async throws {
        let (client, host) = FakeAPI.client { _ in .json(helmMetadataPage([("web", "shop", 2, "deployed"), ("web", "shop", 1, "superseded")])) }
        let release = try await HelmReleaseCatalog.release(named: "web", namespace: "shop", client: client)
        #expect(release?.history.map(\.revision) == [2, 1])
        #expect(FakeAPI.requests(host: host)[0].query["labelSelector"] == "owner=helm,name=web")
        let (empty, _) = FakeAPI.client { _ in .json(helmMetadataPage([])) }
        #expect(try await HelmReleaseCatalog.release(named: "web", namespace: "shop", client: empty) == nil)
        let (denied, _) = FakeAPI.client { _ in .forbidden(resource: "secrets", namespace: "shop") }
        await #expect(throws: KubeError.self) { _ = try await HelmReleaseCatalog.release(named: "web", namespace: "shop", client: denied) }
    }

    @Test func demoClientListMetadataStillWorksForOtherKinds() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[0])
        let listing = try await HelmReleaseCatalog.load(client: client, namespace: nil)
        #expect(listing.failure == nil)          // the Demo fleet has no Helm records: an empty list, not an error
    }
}
