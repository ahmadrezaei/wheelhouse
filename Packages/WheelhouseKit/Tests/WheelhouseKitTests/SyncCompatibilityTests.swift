import Foundation
import Security
import Testing
@testable import WheelhouseKit

private func stamp(_ daysAgo: Double) -> String { ISO8601DateFormatter().string(from: Date().addingTimeInterval(-daysAgo * 86_400)) }

/// A cluster element as JSON text. `extra` is spliced in before the closing brace (unknown fields).
private func elementJSON(_ id: String, env: String = "development", color: String = "teal", modified: String = "2026-06-01T00:00:00Z", extra: String = "") -> String {
    """
    {"allowExecInReadOnly":false,"authKind":"token","color":"\(color)","createdAt":"2026-01-01T00:00:00Z","environment":"\(env)","iCloudSync":true,"id":"\(id)","isDemo":false,"modifiedAt":"\(modified)","name":"\(id)","pinnedNamespaces":[],"readOnly":false,"server":"https:\\/\\/\(id).example.com","skipTLSVerify":false\(extra)}
    """
}

private func makeDevice(_ mirror: InMemoryMetadataMirror) throws -> ClusterMetadataStore {
    let dir = FileManager.default.temporaryDirectory.appending(path: "wh-compat-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return ClusterMetadataStore(directory: dir, mirror: mirror)
}

private func cluster(_ id: String, env: ClusterEnvironment = .development, modified: Date = Date()) -> ClusterConfig {
    ClusterConfig(id: id, name: id, server: URL(string: "https://\(id).example.com")!, environment: env, iCloudSync: true, createdAt: modified, modifiedAt: modified)
}

private func contains(_ haystack: Data, _ needle: String) -> Bool { haystack.range(of: Data(needle.utf8)) != nil }

// MARK: - (a) elements from the future

@Suite("Sync compatibility: future elements")
struct FutureElementTests {
    // Byte patterns with unusual spacing: they must come back verbatim.
    static let futureEnv = "{\"id\":\"beta\",  \"environment\":\"sandbox\",\"name\":\"beta\",\"modifiedAt\":\"2026-06-01T00:00:00Z\"}"
    static let newType = "{\"kind\":\"mac-profile\", \"payload\":[1,2,3.5e0]}"
    static let weirdTombstone = "{\"at\":\"2026-01-01T00:00:00Z\",\"by\":\"mac\"}"

    private func futureMirror() -> Data {
        let json = """
        {"clusters":[\(elementJSON("alpha")),\(Self.futureEnv),\(elementJSON("gamma", extra: ",\"newThing\":{\"x\":1}")),\(Self.newType),\(elementJSON("ghost", modified: "2026-01-01T00:00:00Z"))],
         "deleted":{"ghost":"\(stamp(1))","odd":\(Self.weirdTombstone)},"schema":2}
        """
        return Data(json.utf8)
    }

    @Test func oneFutureElementDoesNotCostTheOthers() throws {
        let mirror = InMemoryMetadataMirror()
        try mirror.write(futureMirror())
        let loaded = try makeDevice(mirror).load()
        #expect(Set(loaded.map(\.id)) == ["alpha", "gamma"])          // beta (unknown env) hidden, ghost tombstoned
    }

    @Test func resavingKeepsEveryFutureElementTombstoneAndKey() throws {
        let mirror = InMemoryMetadataMirror()
        try mirror.write(futureMirror())
        let device = try makeDevice(mirror)
        try device.save(device.load() + [cluster("delta")])
        let data = try #require(mirror.read())

        #expect(contains(data, Self.futureEnv))                       // byte for byte
        #expect(contains(data, Self.newType))
        #expect(contains(data, Self.weirdTombstone))

        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schema"] as? Int == 2)
        let deleted = try #require(root["deleted"] as? [String: Any])
        #expect(deleted["ghost"] != nil && deleted["odd"] != nil)
        let elements = try #require(root["clusters"] as? [[String: Any]])
        let ids = Set(elements.compactMap { $0["id"] as? String })
        #expect(ids == ["alpha", "beta", "gamma", "delta"])           // ghost dropped by its tombstone, new type has no id
        #expect(elements.contains { $0["kind"] as? String == "mac-profile" })
        let gamma = try #require(elements.first { $0["id"] as? String == "gamma" })
        #expect((gamma["newThing"] as? [String: Int])?["x"] == 1)     // unknown field of a decoded element survives
    }

    @Test func aFutureMirrorStillReadsThroughTheNextSaveCycle() throws {
        let mirror = InMemoryMetadataMirror()
        try mirror.write(futureMirror())
        let a = try makeDevice(mirror)
        try a.save(a.load())
        try a.save(a.load())                                          // idempotent
        let data = try #require(mirror.read())
        #expect(contains(data, Self.futureEnv))
        #expect(Set(try makeDevice(mirror).load().map(\.id)) == ["alpha", "gamma"])
    }

    @Test func rawCopyWinsOverAnOlderLocalCopyAndIsNeverTombstoned() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try makeDevice(mirror)
        try a.save([cluster("beta", modified: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!)])
        // Another device (newer app) now owns beta with a value this build cannot read.
        try mirror.write(Data("{\"clusters\":[\(Self.futureEnv)],\"deleted\":{}}".utf8))
        #expect(a.load().isEmpty)                                     // older local copy is hidden, not shown as a stale safe one
        try a.save(a.load())
        let data = try #require(mirror.read())
        #expect(contains(data, Self.futureEnv))
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect((root["deleted"] as? [String: Any])?["beta"] == nil)  // hiding is not deleting
    }

    @Test func aStrictlyNewerLocalEditReplacesTheRawCopy() throws {
        let mirror = InMemoryMetadataMirror()
        try mirror.write(Data("{\"clusters\":[\(Self.futureEnv)],\"deleted\":{}}".utf8))
        let a = try makeDevice(mirror)
        try a.save([cluster("beta", modified: Date())])
        let data = try #require(mirror.read())
        #expect(!contains(data, Self.futureEnv))
        #expect(try a.load().map(\.id) == ["beta"])
    }

    @Test func aMirrorThatIsNotJSONIsNeverOverwritten() throws {
        let mirror = InMemoryMetadataMirror()
        let garbage = Data("\u{1}binary-from-the-future".utf8)
        try mirror.write(garbage)
        let a = try makeDevice(mirror)
        try a.save([cluster("alpha")])
        #expect(mirror.read() == garbage)
        #expect(a.load().map(\.id) == ["alpha"])                      // the local file was still saved
    }

    @Test func localFileKeepsElementsItCannotDecode() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-compat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appending(path: "clusters.json")
        try Data("[\(elementJSON("alpha")),\(Self.futureEnv)]".utf8).write(to: file)
        let store = ClusterMetadataStore(directory: dir, mirror: nil)
        #expect(store.load().map(\.id) == ["alpha"])
        try store.save(store.load())
        #expect(contains(try Data(contentsOf: file), Self.futureEnv))
    }
}

// MARK: - Tolerant shared types

@Suite("Sync compatibility: shared types")
struct TolerantTypesTests {
    private func decode(_ json: String) throws -> ClusterConfig {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        return try d.decode(ClusterConfig.self, from: Data(json.utf8))
    }

    @Test func unknownEnvironmentAndAuthKindAreRejectedNotGuessed() {
        // Rejecting makes the store keep the element raw; no value is mapped to something less restrictive.
        #expect(throws: DecodingError.self) { try decode(elementJSON("a", env: "sandbox")) }
        #expect(throws: DecodingError.self) { try decode(elementJSON("a").replacingOccurrences(of: "\"token\"", with: "\"oidc\"")) }
    }

    @Test func unknownKeysAreIgnoredButRoundTrip() throws {
        let c = try decode(elementJSON("a", extra: ",\"newThing\":{\"x\":[1,2]},\"flag\":true"))
        #expect(c.id == "a")
        #expect(c.unknownFields["flag"] == .bool(true))
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        let back = try decode(String(decoding: try e.encode(c), as: UTF8.self))
        #expect(back.unknownFields == c.unknownFields)
        #expect(back == c)
    }

    @Test func unknownColorIsCosmeticAndSurvivesUntilChanged() throws {
        var c = try decode(elementJSON("a", color: "magenta"))
        #expect(c.color == .gray)
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        #expect(contains(try e.encode(c), "\"magenta\""))
        c.color = .blue
        #expect(contains(try e.encode(c), "\"blue\""))
    }

    @Test func secretsKeepUnknownKeys() throws {
        var s = try JSONDecoder().decode(ClusterSecrets.self, from: Data("{\"token\":\"t\",\"futureKey\":[1]}".utf8))
        #expect(s.token == "t")
        s.token = "t2"
        let out = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any])
        #expect(out["token"] as? String == "t2")
        #expect(out["futureKey"] as? [Int] == [1])
    }
}

// MARK: - (b) current writer -> frozen 1.0.1 reader, (c) frozen writer -> current reader

@Suite("Sync compatibility: frozen 1.0.1")
struct FrozenCompatibilityTests {
    @Test func currentMirrorDecodesWithFrozenDecoder() throws {
        let mirror = InMemoryMetadataMirror()
        let a = try makeDevice(mirror)
        var prod = cluster("prod", env: .production)
        prod.readOnly = true; prod.color = .pink; prod.pinnedNamespaces = ["kube-system"]; prod.provider = "hetzner"
        try a.save([prod, cluster("dev")])
        try a.save([prod])                                            // leaves a tombstone for "dev"
        let frozen = Frozen_1_0_1.readMirror(try #require(mirror.read()))
        #expect(Set(frozen.clusters.map(\.id)) == ["prod"])
        #expect(frozen.deleted["dev"] != nil)
        let p = try #require(frozen.clusters.first)
        #expect(p.environment == .production && p.readOnly && p.color == .pink)
        #expect(p.pinnedNamespaces == ["kube-system"] && p.provider == "hetzner")
        #expect(p.iCloudSync)
    }

    @Test func currentClusterEncodingDecodesWithFrozenConfig() throws {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        var c = cluster("x", env: .staging)
        c.tlsServerName = "k8s.internal"; c.prometheusURL = URL(string: "https://prom.example.com")
        let f = try Frozen_1_0_1.decoder.decode(Frozen_1_0_1.ClusterConfig.self, from: e.encode(c))
        #expect(f.id == "x" && f.environment == .staging && f.tlsServerName == "k8s.internal")
        #expect(f.prometheusURL == c.prometheusURL)
    }

    @Test func frozenMirrorDecodesWithCurrentCode() throws {
        let created = Date(timeIntervalSince1970: 1_780_000_000)
        let old = Frozen_1_0_1.ClusterConfig(id: "legacy", name: "legacy", server: URL(string: "https://legacy.example.com")!, environment: .production,
                                             readOnly: true, tlsServerName: "x", createdAt: created, modifiedAt: created)
        let fresh = Frozen_1_0_1.ClusterConfig(id: "fresh", name: "fresh", server: URL(string: "https://fresh.example.com")!,
                                               createdAt: Date(), modifiedAt: Date())
        let frozenMirror = Frozen_1_0_1.Mirror(clusters: [old, fresh], deleted: ["gone": Date()])
        let mirror = InMemoryMetadataMirror()
        try mirror.write(try Frozen_1_0_1.encoder.encode(frozenMirror))
        let device = try makeDevice(mirror)
        let loaded = device.load()
        #expect(Set(loaded.map(\.id)) == ["legacy", "fresh"])
        let l = try #require(loaded.first { $0.id == "legacy" })
        #expect(l.environment == .production && l.readOnly && l.tlsServerName == "x" && l.unknownFields.isEmpty)
        try device.save(loaded)                                       // and the tombstone survives a save by the new code
        #expect(Frozen_1_0_1.readMirror(try #require(mirror.read())).deleted["gone"] != nil)
    }

    @Test func frozenLegacyArrayDecodesWithCurrentCode() throws {
        let f = Frozen_1_0_1.ClusterConfig(id: "arr", name: "arr", server: URL(string: "https://arr.example.com")!, createdAt: Date(), modifiedAt: Date())
        let mirror = InMemoryMetadataMirror()
        try mirror.write(try Frozen_1_0_1.encoder.encode([f]))
        #expect(try makeDevice(mirror).load().map(\.id) == ["arr"])
    }
}

// MARK: - (d) unreadable secrets, (e) keychain group

@Suite("Sync compatibility: keychain items")
struct UnreadableKeychainItemTests {
    private let service = "app.wheelhouse.credentials"

    @Test(arguments: ["not json at all", "{\"token\":{\"v\":2}}", "[1,2]"])
    func unreadableSecretsAreNeverOverwrittenOrDeleted(_ payload: String) throws {
        let kc = InMemoryKeychain()
        let bytes = Data(payload.utf8)
        try KeychainAccess.write(bytes, service: service, account: "c1", synchronizable: true, in: kc)
        let store = KeychainCredentialStore(backend: kc)

        #expect(throws: KeychainError.unreadable) { try store.load(clusterID: "c1") }
        #expect(throws: KeychainError.unreadable) { try store.save(ClusterSecrets(token: "new"), clusterID: "c1", synchronizable: true) }
        #expect(throws: KeychainError.unreadable) { try store.save(ClusterSecrets(token: "new"), clusterID: "c1", synchronizable: false) }
        try store.delete(clusterID: "c1")

        let v = kc.variants(service: service, account: "c1")
        #expect(v.synced == bytes)
        #expect(v.local == nil)
    }

    @Test func readableSecretsStillSaveAndDelete() throws {
        let kc = InMemoryKeychain()
        let store = KeychainCredentialStore(backend: kc)
        try store.save(ClusterSecrets(token: "a"), clusterID: "c1", synchronizable: true)
        try store.save(ClusterSecrets(token: "b"), clusterID: "c1", synchronizable: true)
        #expect(try store.load(clusterID: "c1").token == "b")
        try store.delete(clusterID: "c1")
        #expect(try store.load(clusterID: "c1").isEmpty)
    }

    @Test func prometheusTokenThatIsNotUTF8IsUnreadable() throws {
        let kc = InMemoryKeychain()
        try KeychainAccess.write(Data([0xFF, 0xFE, 0xFD]), service: "app.wheelhouse.prometheus", account: "c1", synchronizable: true, in: kc)
        #expect(PrometheusTokenStore.isUnreadable(clusterID: "c1", in: kc))
        try KeychainAccess.write(Data("tok".utf8), service: "app.wheelhouse.prometheus", account: "c2", synchronizable: true, in: kc)
        #expect(!PrometheusTokenStore.isUnreadable(clusterID: "c2", in: kc))
        #expect(!PrometheusTokenStore.isUnreadable(clusterID: "missing", in: kc))
    }

    @Test func defaultAccessGroupIsUnchanged() {
        #expect(KeychainAccess.defaultGroupSuffix == "com.ahmadrezaei.wheelhouse.shared")
        #expect(KeychainAccess.groupSuffix(in: .main) == "com.ahmadrezaei.wheelhouse.shared")   // test host sets no WHKeychainGroupSuffix
        #expect(KeychainAccess.accessGroup(prefix: "TEAM123", suffix: KeychainAccess.defaultGroupSuffix) == "TEAM123.com.ahmadrezaei.wheelhouse.shared")
        let implicit = KeychainAccess.baseQuery(service: "s", account: "a")
        #expect(implicit[kSecAttrAccessGroup] as? String == KeychainAccess.sharedGroup)
        #expect(KeychainAccess.baseQuery(service: "s", account: "a", accessGroup: "X.custom")[kSecAttrAccessGroup] as? String == "X.custom")
        #expect(KeychainAccess.baseQuery(service: "s", account: "a", accessGroup: nil)[kSecAttrAccessGroup] == nil)
        #expect(SystemKeychain().accessGroup == KeychainAccess.sharedGroup)
    }
}

// MARK: - Review fixes

private struct ThrowingMirror: MetadataMirroring {
    func read() throws -> Data? { throw KeychainError.status(errSecInteractionNotAllowed) }
    func write(_ data: Data) throws { Issue.record("write must not happen") }
    func clear() throws { Issue.record("clear must not happen") }
}

/// Reads fail on demand; everything else behaves like the in-memory mirror.
private final class FlakyMirror: MetadataMirroring, @unchecked Sendable {
    let inner = InMemoryMetadataMirror()
    private let lock = NSLock()
    private var failing = false
    func setFailing(_ f: Bool) { lock.withLock { failing = f } }
    func read() throws -> Data? { if lock.withLock({ failing }) { throw KeychainError.status(errSecInteractionNotAllowed) }; return try inner.read() }
    func write(_ data: Data) throws { try inner.write(data) }
    func clear() throws { try inner.clear() }
}

@Suite("Sync compatibility: review fixes")
struct ReviewFixTests {
    static let futureEnv = FutureElementTests.futureEnv

    private func dirAndStore(_ mirror: (any MetadataMirroring)?) throws -> (URL, ClusterMetadataStore) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-compat-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir, ClusterMetadataStore(directory: dir, mirror: mirror))
    }

    // 1
    @Test func hiddenLocalCopySurvivesSaveAndReappearsWhenRawCopyVanishes() throws {
        let mirror = InMemoryMetadataMirror()
        let (dir, a) = try dirAndStore(mirror)
        try a.save([cluster("beta", modified: ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z")!), cluster("alpha")])
        try mirror.write(Data("{\"clusters\":[\(Self.futureEnv)],\"deleted\":{}}".utf8))
        #expect(a.load().map(\.id) == ["alpha"])
        try a.save(a.load())
        let file = try Data(contentsOf: dir.appending(path: "clusters.json"))
        #expect(contains(file, "\"beta\""))
        try mirror.clear()                                            // raw twin gone, no tombstone
        #expect(Set(a.load().map(\.id)) == ["alpha", "beta"])
    }

    // 2
    @Test func failedMirrorReadIsNotAnEmptyMirror() throws {
        let (_, a) = try dirAndStore(ThrowingMirror())
        try a.save([cluster("alpha")])                                // ThrowingMirror records an issue if written/cleared
        #expect(a.load().map(\.id) == ["alpha"])                      // falls back to the local file
    }

    @Test func mirrorIsUnchangedWhenReadFailsDuringSave() throws {
        let mirror = FlakyMirror()
        let (_, a) = try dirAndStore(mirror)
        try a.save([cluster("alpha")])
        let before = try #require(mirror.inner.read())
        mirror.setFailing(true)
        try a.save([cluster("alpha"), cluster("other")])
        #expect(try mirror.inner.read() == before)
        mirror.setFailing(false)
        #expect(contains(try #require(mirror.inner.read()), "\"alpha\""))
    }

    // 3
    @Test func unreadableVariantIsDetectedInEitherSlot() throws {
        let kc = InMemoryKeychain()
        let service = "app.wheelhouse.credentials"
        let good = try JSONEncoder().encode(ClusterSecrets(token: "ok"))
        let bad = Data("{\"token\":{\"v\":2}}".utf8)
        try kc.upsert(good, service: service, account: "c1", synchronizable: false)   // device-only variant readable
        try kc.upsert(bad, service: service, account: "c1", synchronizable: true)     // synced variant unreadable
        let store = KeychainCredentialStore(backend: kc)
        #expect(throws: KeychainError.unreadable) { try store.save(ClusterSecrets(token: "new"), clusterID: "c1", synchronizable: false) }
        try store.delete(clusterID: "c1")
        let v = kc.variants(service: service, account: "c1")
        #expect(v.synced == bad && v.local == good)
    }

    @Test func prometheusUnreadableVariantIsNeverOverwrittenOrDeleted() throws {
        let kc = InMemoryKeychain()
        let service = "app.wheelhouse.prometheus"
        let bad = Data([0xFF, 0xFE])
        try kc.upsert(Data("tok".utf8), service: service, account: "c1", synchronizable: false)
        try kc.upsert(bad, service: service, account: "c1", synchronizable: true)
        #expect(PrometheusTokenStore.isUnreadable(clusterID: "c1", in: kc))
        _ = PrometheusTokenStore.save("new", clusterID: "c1", synchronizable: false, in: kc)
        PrometheusTokenStore.delete(clusterID: "c1", in: kc)
        let v = kc.variants(service: service, account: "c1")
        #expect(v.synced == bad && v.local == Data("tok".utf8))
    }

    // 4
    @Test func unreadableErrorHasAClearMessage() {
        #expect(KeychainError.unreadable.localizedDescription == "These credentials were saved by a newer version of Wheelhouse. Update the app to change them.")
    }

    @MainActor @Test func metadataUpdateSucceedsWhileSecretsAreUnreadable() throws {
        let kc = InMemoryKeychain()
        let bad = Data("{\"token\":{\"v\":2}}".utf8)
        try kc.upsert(bad, service: "app.wheelhouse.credentials", account: "u1", synchronizable: false)
        let d = UserDefaults(suiteName: "wheelhouse.compat.\(UUID().uuidString)")!
        let (_, meta) = try dirAndStore(nil)
        var cfg = ClusterConfig(id: "u1", name: "old", server: URL(string: "https://u1.example.com")!)
        try meta.save([cfg])
        let registry = ClusterRegistry(credentials: KeychainCredentialStore(backend: kc), metadata: meta, defaults: d, clientFactory: { _, _ in ScriptedClient() })
        cfg.name = "renamed"; cfg.readOnly = true
        try registry.update(cfg, secrets: nil)
        #expect(registry.clusters.first?.name == "renamed")
        #expect(kc.variants(service: "app.wheelhouse.credentials", account: "u1").local == bad)
        let session = try #require(registry.session(for: "u1"))
        #expect(session.credentialsProblem == KeychainError.unreadable.errorDescription)
    }

    // 5
    @MainActor @Test func renameKeepsUnknownColourAndDoesNotRebuildClient() throws {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601
        let old = try d.decode(ClusterConfig.self, from: Data(elementJSON("a", color: "magenta").utf8))
        var renamed = old
        renamed.name = "renamed"
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601
        #expect(contains(try e.encode(renamed), "\"magenta\""))
        #expect(!ClusterRegistry.requiresNewClient(old, renamed))
        var recoloured = old
        recoloured.color = .blue
        #expect(!ClusterRegistry.requiresNewClient(old, recoloured))
        #expect(contains(try e.encode(recoloured), "\"blue\""))
    }

    // 6
    @Test func unreadableLocalFileIsBackedUpAndLaterBackupsGetATimestamp() throws {
        let (dir, store) = try dirAndStore(nil)
        let file = dir.appending(path: "clusters.json")
        try Data("garbage-1".utf8).write(to: file)
        try store.save([cluster("alpha")])
        #expect(try Data(contentsOf: dir.appending(path: "clusters.json.unreadable")) == Data("garbage-1".utf8))
        try Data("garbage-2".utf8).write(to: file)
        try store.save([cluster("alpha")])
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        let stamped = try #require(names.first { $0.hasPrefix("clusters.json.unreadable-") })
        #expect(try Data(contentsOf: dir.appending(path: stamped)) == Data("garbage-2".utf8))
        #expect(try Data(contentsOf: dir.appending(path: "clusters.json.unreadable")) == Data("garbage-1".utf8))
    }

    // 7a
    @Test func olderRawCopyIsDroppedWhenADecodedCopyIsNewerEvenWithoutALocalCopy() throws {
        let mirror = InMemoryMetadataMirror()
        let raw = "{\"id\":\"beta\",\"environment\":\"sandbox\",\"modifiedAt\":\"2026-01-01T00:00:00Z\"}"
        let newer = try JSONEncoder.iso.encode(cluster("beta", modified: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!))
        try mirror.write(Data("{\"clusters\":[\(raw),\(String(decoding: newer, as: UTF8.self))],\"deleted\":{}}".utf8))
        let (_, a) = try dirAndStore(mirror)
        try a.save([cluster("other")])
        #expect(!contains(try #require(mirror.read()), "sandbox"))
    }

    // 7b
    @Test func localFileNeverGetsDuplicateIDs() throws {
        let (dir, store) = try dirAndStore(nil)
        let file = dir.appending(path: "clusters.json")
        try Data("[\(Self.futureEnv)]".utf8).write(to: file)           // raw element with id "beta"
        try store.save([cluster("beta")])
        let arr = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [[String: Any]])
        #expect(arr.compactMap { $0["id"] as? String } == ["beta"])
    }

    // 7 tests: tombstones, tie, unreadable date
    @Test func tombstoneRemovesNewerThanRawElementsButNotNewerOnes() throws {
        let mirror = InMemoryMetadataMirror()
        let old = "{\"id\":\"old\",\"environment\":\"sandbox\",\"modifiedAt\":\"\(stamp(10))\"}"
        let fresh = "{\"id\":\"fresh\",\"environment\":\"sandbox\",\"modifiedAt\":\"\(stamp(0))\"}"
        try mirror.write(Data("{\"clusters\":[\(old),\(fresh)],\"deleted\":{\"old\":\"\(stamp(5))\",\"fresh\":\"\(stamp(5))\"}}".utf8))
        let (_, a) = try dirAndStore(mirror)
        try a.save([])
        let data = try #require(mirror.read())
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let ids = (root["clusters"] as? [[String: Any]])?.compactMap { $0["id"] as? String }
        #expect(ids == ["fresh"])
    }

    @Test func rawCopyWinsATieAndAnUnreadableDate() throws {
        let when = "2026-03-01T00:00:00Z"
        let date = ISO8601DateFormatter().date(from: when)!
        for rawDate in ["\"\(when)\"", "\"not-a-date\""] {
            let mirror = InMemoryMetadataMirror()
            let raw = "{\"id\":\"beta\",\"environment\":\"sandbox\",\"modifiedAt\":\(rawDate)}"
            try mirror.write(Data("{\"clusters\":[\(raw)],\"deleted\":{}}".utf8))
            let (_, a) = try dirAndStore(mirror)
            #expect(a.load().isEmpty)
            try a.save([cluster("beta", modified: date)])
            #expect(contains(try #require(mirror.read()), "sandbox"))
        }
    }
}

private extension JSONEncoder {
    static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}
