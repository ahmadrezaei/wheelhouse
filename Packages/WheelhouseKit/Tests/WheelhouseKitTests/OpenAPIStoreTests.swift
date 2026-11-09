import Foundation
import Testing
@testable import WheelhouseKit

/// A fake API server for `/openapi/v3`.
final class FakeOpenAPI: @unchecked Sendable {
    private let lock = NSLock()
    private var gvs: [String: (hash: String, doc: JSONValue)] = [:]
    private(set) var requests: [String] = []
    var failIndex = false
    var failDocuments = false
    var delay: Duration = .zero

    func add(group: String, version: String, kind: String, hash: String = "AAAA", spec: JSONValue = ["type": "object", "properties": ["size": ["type": "string", "enum": ["small", "large"]]]]) {
        let gvk = GroupVersionKind(group: group, version: version, kind: kind)
        let schema: JSONValue = [
            "type": "object", "properties": ["spec": spec],
            "x-kubernetes-group-version-kind": [["group": .string(group), "version": .string(version), "kind": .string(kind)]],
        ]
        lock.withLock { gvs[gvk.groupVersionPath] = (hash, ["openapi": "3.0.0", "paths": ["/x": ["get": [:]]], "components": ["schemas": ["x.\(kind)": schema]]]) }
    }

    func fetch(_ path: String) async throws -> Data {
        lock.withLock { requests.append(path) }
        if delay != .zero { try await Task.sleep(for: delay) }
        if path == "/openapi/v3" {
            if failIndex { throw KubeError.forbidden(verb: "get", resource: nil, namespace: nil, message: "no") }
            var out: [String: JSONValue] = [:]
            for (gv, entry) in lock.withLock({ gvs }) { out[gv] = ["serverRelativeURL": .string("/openapi/v3/\(gv)?hash=\(entry.hash)")] }
            return try JSONValue.object(["paths": .object(out)]).data()
        }
        if failDocuments { throw KubeError.forbidden(verb: "get", resource: nil, namespace: nil, message: "no") }
        let gv = String(path.dropFirst("/openapi/v3/".count).split(separator: "?")[0])
        guard let entry = lock.withLock({ gvs[gv] }) else { throw KubeError.notFound(message: nil) }
        return try entry.doc.data()
    }

    var documentRequests: [String] { lock.withLock { requests.filter { $0 != "/openapi/v3" } } }
    var indexRequests: Int { lock.withLock { requests.filter { $0 == "/openapi/v3" }.count } }
}

func tempDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "wh-schema-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@Suite("OpenAPI store")
struct OpenAPIStoreTests {
    let widget = GroupVersionKind(group: "example.com", version: "v1", kind: "Widget")

    @Test func fetchesTheIndexThenOneGroupVersionWithItsHash() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H1")
        api.add(group: "other.io", version: "v1", kind: "Other")
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, fetch: api.fetch)
        let found = try #require(await store.kindSchema(for: widget))
        #expect(found.source == .cluster)
        #expect(found.engine.valueChoices(of: try #require(found.engine.schema(at: [.key("spec"), .key("size")], from: found.schema))) == ["small", "large"])
        #expect(api.documentRequests == ["/openapi/v3/apis/example.com/v1?hash=H1"])
        // The second ask comes from memory.
        _ = await store.kindSchema(for: widget)
        #expect(api.documentRequests.count == 1)
    }

    @Test func pathsAreDroppedFromTheDocument() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget")
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch)
        _ = await store.kindSchema(for: widget)
        let file = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        let saved = try JSONValue.parse(Data(contentsOf: file))
        #expect(saved["paths"] == nil && saved.value(at: "components.schemas") != nil)
    }

    @Test func theDiskCacheIsImmutablePerHashAndPerServerVersion() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H1")
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = OpenAPIStore(cluster: "c/1", serverVersion: "v1.32.0+k3s1", cacheRoot: dir, fetch: api.fetch)
        _ = await first.kindSchema(for: widget)
        #expect(await first.downloads == 1)
        // A new store (a new launch) reads the file: the index again, but no document.
        let second = OpenAPIStore(cluster: "c/1", serverVersion: "v1.32.0+k3s1", cacheRoot: dir, fetch: api.fetch)
        #expect(await second.kindSchema(for: widget) != nil)
        #expect(await second.downloads == 0 && api.documentRequests.count == 1)
        // The cluster serves a new hash: downloaded again.
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H2")
        let third = OpenAPIStore(cluster: "c/1", serverVersion: "v1.32.0+k3s1", cacheRoot: dir, fetch: api.fetch)
        _ = await third.kindSchema(for: widget)
        #expect(api.documentRequests.count == 2)
        // Another server version of the same cluster gets its own folder, and the old one is removed.
        let upgraded = OpenAPIStore(cluster: "c/1", serverVersion: "v1.33.0", cacheRoot: dir, fetch: api.fetch)
        _ = await upgraded.kindSchema(for: widget)
        #expect(api.documentRequests.count == 3)
        let clusterFolder = try #require(try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).first)
        #expect(try FileManager.default.contentsOfDirectory(atPath: clusterFolder.path) == [OpenAPIStore.digest("v1.33.0")])
    }

    @Test func aCorruptCacheFileIsFetchedAgain() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H1")
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch).kindSchema(for: widget)
        let file = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        try Data("{ not json".utf8).write(to: file)
        let again = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch)
        #expect(await again.kindSchema(for: widget) != nil)
        #expect(api.documentRequests.count == 2)
        #expect((try? JSONValue.parse(Data(contentsOf: file))) != nil)
    }

    @Test func aMissingKindRefreshesTheIndex() async throws {
        let api = FakeOpenAPI()
        api.add(group: "other.io", version: "v1", kind: "Other")
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, minRefresh: 0, fetch: api.fetch)
        #expect(await store.kindSchema(for: widget) == nil)
        api.add(group: "example.com", version: "v1", kind: "Widget")         // the CRD is installed meanwhile
        #expect(await store.kindSchema(for: widget) != nil)
        #expect(api.indexRequests >= 2)
    }

    @Test func anUnreadableIndexIsNotAskedForOnEveryCall() async throws {
        let api = FakeOpenAPI()
        api.failIndex = true
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, fetch: api.fetch)
        for _ in 0..<5 { _ = await store.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment")) }
        #expect(api.indexRequests == 1)
    }

    @Test func concurrentAsksShareOneDownload() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget")
        api.delay = .milliseconds(80)
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, fetch: api.fetch)
        let widget = self.widget
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<6 { group.addTask { await store.kindSchema(for: widget) != nil } }
            for await ok in group { #expect(ok) }
        }
        #expect(api.documentRequests.count == 1)
    }

    @Test func fallsBackToTheBundledSchemaWhenTheClusterRefuses() async throws {
        let api = FakeOpenAPI()
        api.failIndex = true
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.34.2", cacheRoot: nil, fetch: api.fetch)
        let found = try #require(await store.kindSchema(for: GroupVersionKind(group: "apps", version: "v1", kind: "Deployment")))
        #expect(found.source == .bundled(minor: "1.32"))
        #expect(found.source.note == "Schema from Kubernetes 1.32, cluster schema unavailable")
        #expect(await store.lastSource == .bundled(minor: "1.32"))
    }

    @Test func unsupportedClientsFallBackToo() async throws {
        let store = OpenAPIStore(cluster: "c", serverVersion: nil, cacheRoot: nil, client: ReadSpyClient())
        #expect(await store.kindSchema(for: GroupVersionKind(group: "", version: "v1", kind: "Pod")) != nil)
    }

    @Test func memoryStaysWithinTheLimit() async throws {
        let api = FakeOpenAPI()
        for i in 0..<20 { api.add(group: "g\(i).io", version: "v1", kind: "K\(i)", spec: ["type": "object", "description": .string(String(repeating: "d", count: 4_000))]) }
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, memoryLimit: 20_000, fetch: api.fetch)
        for i in 0..<20 {
            #expect(await store.kindSchema(for: GroupVersionKind(group: "g\(i).io", version: "v1", kind: "K\(i)")) != nil)
            #expect(await store.memoryCost <= 20_000)
        }
        await store.trimMemory()
        #expect(await store.memoryCost == 0)
    }

    @Test func aDocumentBiggerThanTheWholeCacheIsStillUsedOnce() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", spec: ["type": "object", "description": .string(String(repeating: "d", count: 10_000))])
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, memoryLimit: 2_000, fetch: api.fetch)
        #expect(await store.kindSchema(for: widget) != nil)
        #expect(await store.memoryCost == 0)
    }

    @Test func diskPruningRemovesTheOldestFiles() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (i, name) in ["old", "mid", "new"].enumerated() {
            let url = dir.appending(path: name)
            try Data(repeating: 1, count: 100).write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: Double(1_000 + i))], ofItemAtPath: url.path)
        }
        OpenAPIStore.pruneDisk(root: dir, maxBytes: 150)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["new"])
    }

    @Test func folderNamesAreDigests() {
        #expect(OpenAPIStore.digest("apis/apps/v1").count == 16)
        #expect(OpenAPIStore.digest("a") != OpenAPIStore.digest("b"))
        for hostile in ["..", ".", "../x", "a/b", "", "v1.32.0+k3s1"] {
            let name = OpenAPIStore.digest(hostile)
            #expect(name.count == 16 && name.allSatisfy { $0.isHexDigit }, "\(hostile)")
        }
    }

    @Test func hostileServerVersionsStayInsideTheirFolderAndDeleteNothingElse() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H1")
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Another cluster's cache.
        let other = OpenAPIStore(cluster: "other", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch)
        _ = await other.kindSchema(for: widget)
        let before = try FileManager.default.subpathsOfDirectory(atPath: dir.path).sorted()
        for version in ["..", ".", "../../x", "v1/../.."] {
            let store = OpenAPIStore(cluster: "c", serverVersion: version, cacheRoot: dir, fetch: api.fetch)
            #expect(await store.kindSchema(for: widget) != nil)
        }
        let after = try FileManager.default.subpathsOfDirectory(atPath: dir.path)
        #expect(Set(before).isSubset(of: Set(after)), "another cluster's cache was removed")
        #expect(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().path))
    }

    @Test func storesShareOneBudget() async throws {
        let api = FakeOpenAPI()
        for i in 0..<10 { api.add(group: "g\(i).io", version: "v1", kind: "K\(i)", spec: ["type": "object", "description": .string(String(repeating: "d", count: 4_000))]) }
        let shared = SharedSchemaCache(limit: 30_000)
        let stores = (0..<3).map { OpenAPIStore(cluster: "c\($0)", serverVersion: "v1.32.0", cacheRoot: nil, sharedCache: shared, fetch: api.fetch) }
        for i in 0..<10 {
            for store in stores {
                #expect(await store.kindSchema(for: GroupVersionKind(group: "g\(i).io", version: "v1", kind: "K\(i)")) != nil)
                #expect(shared.totalCost <= 30_000)
            }
        }
        #expect(shared.totalCost > 0)
        await stores[0].releaseMemory()
        #expect(!shared.keys.contains { $0.hasPrefix("cluster:c0|") } && shared.keys.contains { $0.hasPrefix("cluster:c1|") || $0.hasPrefix("cluster:c2|") })
        await stores[1].trimMemory()
        #expect(shared.totalCost == 0)
    }

    @Test func aFailedDocumentIsNotRefetchedForAWhile() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget")
        api.failDocuments = true
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, fetch: api.fetch)
        for _ in 0..<4 { _ = await store.kindSchema(for: widget) }
        #expect(api.documentRequests.count == 1)
    }

    @Test func theIndexFetchIsShared() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget")
        api.delay = .milliseconds(80)
        let store = OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: nil, fetch: api.fetch)
        let widget = self.widget
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<5 { group.addTask { _ = await store.kindSchema(for: widget) } }
        }
        #expect(api.indexRequests == 1)
    }

    @Test func aDiskHitCountsAsAUse() async throws {
        let api = FakeOpenAPI()
        api.add(group: "example.com", version: "v1", kind: "Widget", hash: "H1")
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = await OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch).kindSchema(for: widget)
        let file = try #require(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL }.first { $0.pathExtension == "json" })
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        _ = await OpenAPIStore(cluster: "c", serverVersion: "v1.32.0", cacheRoot: dir, fetch: api.fetch).kindSchema(for: widget)
        let touched = try #require(try FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate] as? Date)
        #expect(touched.timeIntervalSince1970 > 1_000_000)
    }
}

@Suite("Bundled schemas")
struct BundledSchemaTests {
    @Test func theBundledFileIsSmallAndUsable() throws {
        let b = BundledSchemas.standard
        #expect(b.minors == ["1.32"])
        let docs = try #require(b.load(minor: "1.32"))
        #expect(Set(docs.keys).isSuperset(of: ["api/v1", "apis/apps/v1", "apis/batch/v1", "apis/networking.k8s.io/v1"]))
        let url = try #require(BundledSchemas.standardDirectory)
        let size = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]).reduce(0) {
            $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        }
        #expect(size < 200_000, "bundled schema is \(size) bytes")
    }

    @Test func nearestMinorPicksTheClosestAndTheNewerOnATie() throws {
        let dir = tempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for m in ["1.28", "1.30", "1.32"] { try Data().write(to: dir.appending(path: "k8s-\(m).json.lzfse")) }
        let b = BundledSchemas(directory: dir)
        #expect(b.minors == ["1.28", "1.30", "1.32"])
        #expect(b.nearestMinor(to: "v1.31.4") == "1.32")        // tie between 1.30 and 1.32: the newer
        #expect(b.nearestMinor(to: "v1.29.0") == "1.30")
        #expect(b.nearestMinor(to: "v1.20.0") == "1.28")
        #expect(b.nearestMinor(to: "v1.40.1+k3s2") == "1.32")
        #expect(b.nearestMinor(to: nil) == "1.32")
        #expect(b.nearestMinor(to: "garbage") == "1.32")
        #expect(BundledSchemas(directory: nil).nearestMinor(to: "v1.32.0") == nil)
    }

    @Test func everyBundledKindIsFound() async throws {
        let store = bundledStore()
        for (g, v, k) in [("", "v1", "Pod"), ("", "v1", "Service"), ("", "v1", "ConfigMap"), ("apps", "v1", "StatefulSet"), ("batch", "v1", "CronJob"),
                          ("networking.k8s.io", "v1", "Ingress"), ("rbac.authorization.k8s.io", "v1", "ClusterRole")] {
            #expect(await store.kindSchema(for: GroupVersionKind(group: g, version: v, kind: k)) != nil, "\(g)/\(v) \(k)")
        }
    }
}

@Suite("OpenAPI request paths")
struct OpenAPIRequestPathTests {
    @Test func theHashStaysAQueryItem() throws {
        let parts = try #require(LiveKubeClient.openAPIRequestParts("/openapi/v3/apis/apps/v1?hash=ABC123"))
        #expect(parts.path == "/openapi/v3/apis/apps/v1" && parts.query.count == 1 && parts.query[0].0 == "hash" && parts.query[0].1 == "ABC123")
        #expect(LiveKubeClient.openAPIRequestParts("/openapi/v3")?.path == "/openapi/v3")
    }

    @Test func nothingElseIsServed() {
        for bad in ["/api/v1/secrets", "/openapi/v2", "/openapi/v3/../../api", "/openapi/v3//x", "/openapi/v3/a%2Fb", "/openapi/v3?x=1", "/openapi/v3x", "openapi/v3"] {
            #expect(LiveKubeClient.openAPIRequestParts(bad) == nil, "\(bad)")
        }
    }

    @Test func defaultClientsRefuse() async {
        await #expect(throws: KubeError.self) { _ = try await ReadSpyClient().openAPIDocument(path: "/openapi/v3") }
    }
}
