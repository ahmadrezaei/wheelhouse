import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Rigging: built-in packs on fixture objects")
struct RiggingBuiltInRenderTests {
    let now = ISO8601DateFormatter().date(from: "2026-03-01T12:00:00Z")!

    private func pack(_ name: String) throws -> RiggingPack { try #require(BuiltInRiggingPacks.all.first { $0.pack.metadata.name == name }).pack }

    private func cert(_ name: String, ready: String, since: String) -> JSONValue {
        .object(["metadata": .object(["name": .string(name), "namespace": .string("wh-m13")]),
                 "spec": .object(["secretName": .string(name), "issuerRef": .object(["name": .string("selfsigned")])]),
                 "status": .object(["notAfter": .string("2026-03-11T12:00:00Z"),
                                    "conditions": .array([.object(["type": .string("Ready"), "status": .string(ready), "lastTransitionTime": .string(since)])])])])
    }

    @Test func certManagerCertificatesRenderColumnsTonesRelatedAndHealth() throws {
        let p = try pack("cert-manager")
        let view = try #require(p.view(id: "certificates"))
        let good = cert("web-tls", ready: "True", since: "2026-03-01T08:00:00Z")
        let bad = cert("broken-tls", ready: "False", since: "2026-03-01T08:00:00Z")
        #expect(RiggingEngine.tone(for: view, object: good, now: now).tone == .healthy)
        let badTone = RiggingEngine.tone(for: view, object: bad, now: now)
        #expect(badTone.tone == .critical && badTone.label == "Not ready")
        let cells = (view.columns ?? []).map { RiggingEngine.cell($0, object: good, now: now) }
        #expect(cells == ["True", "web-tls", "selfsigned", "in 10d", ""])
        let related = RiggingEngine.related(of: good, view: view)
        #expect(related.map(\.name) == ["web-tls", "selfsigned"] && related.allSatisfy { $0.namespace == "wh-m13" })
        let rule = try #require(p.allHealthRules.first)
        let findings = RiggingEngine.findings(of: rule, pack: p, objects: [good, bad], cluster: "dev", now: now)
        #expect(findings.map(\.name) == ["broken-tls"] && findings.first?.message == "Certificate broken-tls has not been ready for over an hour")
    }

    @Test func kedaScaledObjectsShowFallbackAsAWarning() throws {
        let p = try pack("keda")
        let view = try #require(p.view(id: "scaledobjects"))
        func so(_ conds: [(String, String)]) -> JSONValue {
            .object(["metadata": .object(["name": .string("x"), "namespace": .string("ns")]),
                     "spec": .object(["scaleTargetRef": .object(["name": .string("x")]), "minReplicaCount": .int(1), "maxReplicaCount": .int(9)]),
                     "status": .object(["conditions": .array(conds.map { .object(["type": .string($0.0), "status": .string($0.1)]) })])])
        }
        #expect(RiggingEngine.tone(for: view, object: so([("Ready", "True")]), now: now).tone == .healthy)
        #expect(RiggingEngine.tone(for: view, object: so([("Ready", "True"), ("Fallback", "True")]), now: now).tone == .warning)
        #expect(RiggingEngine.tone(for: view, object: so([("Ready", "False")]), now: now).tone == .critical)
        #expect((view.columns ?? []).map { RiggingEngine.cell($0, object: so([("Ready", "True")]), now: now) }.prefix(3) == ["x", "1", "9"])
    }

    @Test func everyBuiltInViewEvaluatesOnAnEmptyObjectWithoutTrouble() {
        for loaded in BuiltInRiggingPacks.all {
            for view in loaded.pack.allViews {
                let empty: JSONValue = .object(["metadata": .object(["name": .string("x")])])
                _ = RiggingEngine.tone(for: view, object: empty, now: now)
                #expect((view.columns ?? []).allSatisfy { RiggingEngine.cell($0, object: empty, now: now) == "" })
                #expect(RiggingEngine.related(of: empty, view: view).isEmpty)
            }
            for rule in loaded.pack.allHealthRules {
                #expect(RiggingEngine.findings(of: rule, pack: loaded.pack, objects: [.object([:])], cluster: "c", now: now).isEmpty)
            }
        }
    }

    @Test func veleroBackupsFeedHealthRules() throws {
        let p = try pack("velero")
        let rule = try #require(p.allHealthRules.last)
        let objects: [JSONValue] = [.object(["metadata": .object(["name": .string("a")]), "status": .object(["phase": .string("Completed")])]),
                                    .object(["metadata": .object(["name": .string("b")]), "status": .object(["phase": .string("PartiallyFailed")])])]
        #expect(RiggingEngine.findings(of: rule, pack: p, objects: objects, cluster: "c", now: now).map(\.name) == ["b"])
    }
}
