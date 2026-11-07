import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Helm revision compare")
struct HelmCompareTests {
    private func release(manifest: String) throws -> HelmRelease {
        let json: JSONValue = ["name": "a", "version": 1, "namespace": "ns", "chart": ["metadata": ["name": "c", "version": "1"]], "manifest": .string(manifest)]
        return try HelmReleaseCodec.decode(payload: json.data())
    }

    @Test func recordedRevisionsDifferInValuesAndManifest() throws {
        let v1 = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v1"))
        let v2 = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        let comparison = HelmComparison.compare(old: v1, new: v2)
        #expect(comparison.valuesStats.total > 0)
        let text = comparison.valuesDiff.map(\.text).joined(separator: "\n")
        #expect(!text.contains("fixture-password") && !text.contains("fixture-token"), "secret values never appear in a compare")
        // The passwords differ between the revisions, and the fingerprints show that.
        #expect(comparison.valuesDiff.contains { $0.kind != .context && $0.text.contains(HelmValuesMask.placeholder) })
        #expect(comparison.changed >= 1 && comparison.added == 0 && comparison.removed == 0)
        #expect(comparison.objects.contains { $0.id.hasSuffix("/wh-fixture-config") && $0.change == .changed })
    }

    @Test func addedRemovedAndUnchangedObjects() throws {
        let old = try release(manifest: "---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: keep\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: gone\n")
        let new = try release(manifest: "---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: keep\n---\napiVersion: v1\nkind: Service\nmetadata:\n  name: fresh\n")
        let c = HelmComparison.compare(old: old, new: new)
        #expect(c.objects.map(\.id) == ["ConfigMap/ns/keep", "ConfigMap/ns/gone", "Service/ns/fresh"])
        #expect(c.objects.map(\.change) == [.unchanged, .removed, .added])
        #expect(c.added == 1 && c.removed == 1 && c.changed == 0)
    }

    @Test func secretObjectsAreHiddenInDisplayYAML() {
        let objects = HelmManifest.objects(in: "apiVersion: v1\nkind: Secret\nmetadata:\n  name: s\ndata:\n  token: c2VjcmV0\nstringData:\n  pw: hunter2\n")
        let secret = objects[0]
        #expect(!secret.displayYAML(revealed: false).contains("hunter2") && !secret.displayYAML(revealed: false).contains("c2VjcmV0"))
        #expect(secret.displayYAML(revealed: true).contains("hunter2"))
        let map = HelmManifest.objects(in: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: m\ndata:\n  a: b\n")[0]
        #expect(map.displayYAML(revealed: false) == map.yaml)
    }

    private func hook(kind: String, manifest: String) -> HelmRelease.Hook {
        HelmRelease.Hook(name: "h", kind: kind, path: "t.yaml", manifest: manifest, events: [], weight: 0, deletePolicies: [], lastRun: nil)
    }

    @Test func aGenerateNameSecretHookIsMaskedUntilRevealed() {
        let manifest = "apiVersion: v1\nkind: Secret\nmetadata:\n  generateName: hook-\nstringData:\n  pw: hunter2\ndata:\n  t: c2VjcmV0\n"
        #expect(HelmManifest.objects(in: manifest).first?.name == "hook-")
        let h = hook(kind: "Secret", manifest: manifest)
        let hidden = h.displayManifest(revealed: false)
        #expect(!hidden.contains("hunter2") && !hidden.contains("c2VjcmV0") && hidden.contains(HelmValuesMask.placeholder))
        #expect(h.displayManifest(revealed: true) == manifest)
    }

    @Test func multiDocumentSecretHooksJoinMaskedDocuments() {
        let manifest = "apiVersion: v1\nkind: Secret\nmetadata:\n  name: a\ndata:\n  k: djE=\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: b\ndata:\n  k: djI=\n"
        let hidden = hook(kind: "Secret", manifest: manifest).displayManifest(revealed: false)
        #expect(hidden.contains("---\n") && !hidden.contains("djE=") && !hidden.contains("djI="))
    }

    @Test func anUnparseableSecretHookIsNeverShownRaw() {
        let broken = "kind: Secret\nmetadata: [unclosed\n  stringData: {pw: hunter2\n"
        #expect(hook(kind: "Secret", manifest: broken).displayManifest(revealed: false) == HelmRelease.Hook.hiddenSecretNote)
        #expect(hook(kind: "Secret", manifest: "").displayManifest(revealed: false) == HelmRelease.Hook.hiddenSecretNote)
        // A hook whose declared kind is wrong but whose text is a Secret is still hidden.
        #expect(!hook(kind: "Job", manifest: broken).displayManifest(revealed: false).contains("hunter2"))
        // Other kinds are shown as they are.
        let job = "apiVersion: batch/v1\nkind: Job\nmetadata:\n  name: j\n"
        #expect(hook(kind: "Job", manifest: job).displayManifest(revealed: false) == job)
    }

    @Test func envStyleValuesAreMaskedByTheirSiblingName() {
        let values: JSONValue = ["env": [["name": "DB_PASSWORD", "value": "hunter2"], ["name": "LOG_LEVEL", "value": "debug"]]]
        let masked = HelmValuesMask.masked(values)
        #expect(!masked.jsonString().contains("hunter2") && masked.jsonString().contains("debug"))
        #expect(!HelmValuesMask.maskedForComparison(values).jsonString().contains("hunter2"))
    }

    @Test func repositoryAndChartNamesCannotEscapeTheCacheDirectory() throws {
        let yaml = "repositories:\n- name: ../../etc\n  url: https://x\n- name: a/b\n  url: https://x\n- name: fine\n  url: https://x\n"
        #expect(try HelmRepositories.parse(yaml).map(\.name) == ["fine"])
        let cache = FileManager.default.temporaryDirectory
        #expect(HelmChartArchive.cachedArchive(chart: "../x", version: "1", cache: cache) == nil)
        #expect(HelmChartArchive.cachedArchive(chart: "x", version: "1/../../2", cache: cache) == nil)
    }

    @Test func lastAppliedAnnotationIsDroppedFromSummaries() {
        var meta = ObjectMeta(name: "sh.helm.release.v1.a.v1", namespace: "n",
                              labels: ["owner": "helm", "name": "a", "version": "1", "status": "deployed"],
                              annotations: ["kubectl.kubernetes.io/last-applied-configuration": "{\"data\":{\"release\":\"BIG\"}}", "keep": "me"])
        meta.name = "sh.helm.release.v1.a.v1"
        let summary = HelmRevisionSummary(meta: meta, storage: .secret)
        #expect(summary?.annotations == ["keep": "me"])
    }

    @Test func cacheCostCountsDecodedMemory() throws {
        #expect(DecodedReleaseCache.costMultiplier >= 4)
        let cache = DecodedReleaseCache(byteLimit: 10_000)
        var release = try HelmReleaseCodec.decodeSecret(HelmFixtures.object("helm3-secret-v2"))
        release.payloadBytes = 2_000                                // 4 x 2,000 = 8,000 of the 10,000
        cache.insert(release, forKey: "a")
        cache.insert(release, forKey: "b")
        #expect((["a", "b"].filter { cache.release(forKey: $0) != nil }).count <= 1)
    }

    @Test func sameSecretFingerprintsEqualAndDifferentOnesDiffer() {
        let a = HelmValuesMask.maskedForComparison(["password": "one", "name": "x"])
        let b = HelmValuesMask.maskedForComparison(["password": "one", "name": "x"])
        let c = HelmValuesMask.maskedForComparison(["password": "two", "name": "x"])
        #expect(a == b && a != c)
    }
}
