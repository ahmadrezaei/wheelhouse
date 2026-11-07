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

    @Test func sameSecretFingerprintsEqualAndDifferentOnesDiffer() {
        let a = HelmValuesMask.maskedForComparison(["password": "one", "name": "x"])
        let b = HelmValuesMask.maskedForComparison(["password": "one", "name": "x"])
        let c = HelmValuesMask.maskedForComparison(["password": "two", "name": "x"])
        #expect(a == b && a != c)
    }
}
