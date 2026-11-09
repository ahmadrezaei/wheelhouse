import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

private actor CountingReader: SecretReading {
    private(set) var reads: [String] = []
    private let secrets: [String: JSONValue]
    init(_ secrets: [String: JSONValue]) { self.secrets = secrets }
    func secret(name: String, namespace: String) async -> JSONValue? {
        reads.append("\(namespace)/\(name)")
        return secrets["\(namespace)/\(name)"]
    }
}

@MainActor @Suite("Review fixes: pull secrets and accepted risks", .serialized)
struct ScanReviewTests {
    private func dockerSecret(registry: String) -> JSONValue {
        let config = #"{"auths":{"\#(registry)":{"username":"u","password":"p"}},"credsStore":"osxkeychain"}"#
        return ["type": "kubernetes.io/dockerconfigjson", "data": [".dockerconfigjson": .string(Data(config.utf8).base64EncodedString())]]
    }

    private func tempStore() throws -> (SurveyStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-review-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (try SurveyStore(url: dir.appending(path: "survey.sqlite")), dir)
    }

    @Test func withTheOptInOffNoSecretIsEverRead() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let ref = try #require(ImageReference("registry.example.com/team/web:1"))
        let reader = CountingReader(["shop/regcred": dockerSecret(registry: "registry.example.com")])
        let context = ScanClusterContext(store: store)
        await context.set(readers: ["a": reader], secrets: ["a": [ref.scanTarget: [PullSecretRef(namespace: "shop", name: "regcred")]]])
        #expect(await context.pullSecretConfig(cluster: "a", ref: ref) == nil)
        #expect(await reader.reads.isEmpty)
    }

    @Test func withTheOptInOnOnlyThatClustersDockerConfigSecretsAreUsed() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try await store.setUsesPullSecrets(true, clusterID: "a")
        let ref = try #require(ImageReference("registry.example.com/team/web:1"))
        let readerA = CountingReader(["shop/opaque": ["type": "Opaque", "data": ["x": "eQ=="]], "shop/regcred": dockerSecret(registry: "registry.example.com")])
        let readerB = CountingReader(["shop/regcred": dockerSecret(registry: "registry.example.com")])
        let context = ScanClusterContext(store: store)
        let refs = [PullSecretRef(namespace: "shop", name: "opaque"), PullSecretRef(namespace: "shop", name: "regcred")]
        await context.set(readers: ["a": readerA, "b": readerB], secrets: ["a": [ref.scanTarget: refs], "b": [ref.scanTarget: refs]])
        let config = try #require(await context.pullSecretConfig(cluster: "a", ref: ref))
        let json = try JSONValue.parse(config)
        #expect(json["auths"]?.objectValue?.keys.sorted() == ["registry.example.com"])
        #expect(json["credsStore"] == nil)                                      // the Opaque secret contributed nothing
        #expect(await readerB.reads.isEmpty)                                    // cluster b did not opt in
        #expect(await context.pullSecretConfig(cluster: "b", ref: ref) == nil)
        #expect(await readerB.reads.isEmpty)
        // A registry the secret does not cover yields nothing.
        let other = try #require(ImageReference("other.example.com/x:1"))
        await context.set(readers: [:], secrets: ["a": [other.scanTarget: refs]])
        #expect(await context.pullSecretConfig(cluster: "a", ref: other) == nil)
    }

    private func risk() -> SecurityFinding {
        SecurityFinding(ruleID: "WH-W07", severity: .low, clusterID: "c", namespace: "n", object: FindingObject(kind: "Deployment", namespace: "n", name: "d"),
                        title: "t", evidence: [])
    }

    @Test func onTheSecondLaunchTheDatabaseIsTheTruthAndRemovedRisksStayRemoved() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appending(path: "risks.json")
        SurveyHub(riskFile: json).accept(risk(), scope: .finding, reason: "legacy", days: 30)           // the M8a file
        let first = SurveyHub(riskFile: json)
        await first.attach(store: store)                                                                // launch 1: imports once
        #expect(first.risks.risks.count == 1)
        first.removeRisk(first.risks.risks[0].id)
        first.acceptCVE("CVE-2026-1", clusterID: "c", reason: "r", days: 30)
        try await Task.sleep(for: .milliseconds(300))
        let second = SurveyHub(riskFile: json)                                                          // launch 2: the stale JSON loads...
        #expect(second.risks.risks.count == 1)
        await second.attach(store: store)                                                               // ...but the flag is set: the database wins
        #expect(second.risks.risks.count == 1 && second.risks.status(ofCVE: "CVE-2026-1", cluster: "c").isAccepted)
        #expect(!second.risks.risks.contains { $0.cveID == nil })                                       // the removed legacy risk did not come back
    }

    @Test func aChangeMadeBeforeAttachIsReplayedAndNeverOverwritesTheDatabase() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appending(path: "risks.json")
        // The database already holds a risk (and the import flag), the JSON file holds nothing of it.
        var book = AcceptedRiskBook()
        book.acceptCVE("CVE-2026-OLD", clusterID: "c", reason: "kept", days: 30)
        try await store.importLegacyRisksOnce(from: json)
        try await store.saveAcceptedRisks(book)
        let hub = SurveyHub(riskFile: json)
        hub.acceptCVE("CVE-2026-NEW", clusterID: "c", reason: "before attach", days: 30)
        await hub.attach(store: store)
        #expect(hub.risks.risks.count == 2)
        try await Task.sleep(for: .milliseconds(300))
        let stored = try await store.acceptedRisks()
        #expect(stored.risks.count == 2)
        #expect(stored.status(ofCVE: "CVE-2026-OLD", cluster: "c").isAccepted && stored.status(ofCVE: "CVE-2026-NEW", cluster: "c").isAccepted)
    }

    @Test func aRemovalMadeBeforeAttachIsReplayedToo() async throws {
        let (store, dir) = try tempStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = dir.appending(path: "risks.json")
        var book = AcceptedRiskBook()
        book.acceptCVE("CVE-2026-OLD", clusterID: "c", reason: "r", days: 30)
        try await store.importLegacyRisksOnce(from: json)
        try await store.saveAcceptedRisks(book)
        let hub = SurveyHub(riskFile: json)
        hub.removeRisk(book.risks[0].id)                       // the in-memory book (the stale JSON) has no such risk: still replayed
        await hub.attach(store: store)
        #expect(hub.risks.risks.isEmpty)
        try await Task.sleep(for: .milliseconds(300))
        #expect(try await store.acceptedRisks().risks.isEmpty)
    }
}
