import Testing
import Foundation
@testable import WheelhouseKit

/// A structural validator transcribed from the SARIF 2.1.0 JSON schema for the parts the exporter emits: required properties, enums,
/// types and `additionalProperties: false` objects. (The full schema file is not vendored: it is large and changes nothing here.)
enum SARIFSchemaCheck {
    static let resultKeys: Set<String> = ["analysisTarget", "attachments", "baselineState", "codeFlows", "correlationGuid", "fingerprints", "fixes", "graphTraversals", "graphs",
                                          "guid", "hostedViewerUri", "kind", "level", "locations", "message", "occurrenceCount", "partialFingerprints", "properties",
                                          "provenance", "rank", "relatedLocations", "rule", "ruleId", "ruleIndex", "stacks", "suppressions", "taxa", "webRequest",
                                          "webResponse", "workItemUris"]
    static let runKeys: Set<String> = ["addresses", "artifacts", "automationDetails", "baselineGuid", "columnKind", "conversion", "defaultEncoding", "defaultSourceLanguage",
                                       "externalPropertyFileReferences", "graphs", "invocations", "language", "logicalLocations", "newlineSequences", "originalUriBaseIds",
                                       "policies", "properties", "redactionTokens", "results", "runAggregates", "specialLocations", "taxonomies", "threadFlowLocations",
                                       "tool", "translations", "versionControlProvenance", "webRequests", "webResponses"]
    static let driverKeys: Set<String> = ["associatedComponent", "contents", "dottedQuadFileVersion", "downloadUri", "fullDescription", "fullName", "globalMessageStrings",
                                          "guid", "informationUri", "isComprehensive", "language", "locations", "localizedDataSemanticVersion",
                                          "minimumRequiredLocalizedDataSemanticVersion", "name", "notifications", "organization", "product", "productSuite", "properties",
                                          "releaseDateUtc", "rules", "semanticVersion", "shortDescription", "supportedTaxonomies", "taxa", "translationMetadata", "version"]
    static let descriptorKeys: Set<String> = ["defaultConfiguration", "deprecatedGuids", "deprecatedIds", "deprecatedNames", "fullDescription", "guid", "help", "helpUri", "id",
                                              "messageStrings", "name", "properties", "relationships", "shortDescription"]
    static let locationKeys: Set<String> = ["annotations", "id", "logicalLocations", "message", "physicalLocation", "properties", "relationships"]
    static let logicalLocationKeys: Set<String> = ["decoratedName", "fullyQualifiedName", "index", "kind", "name", "parentIndex", "properties"]
    static let suppressionKeys: Set<String> = ["guid", "justification", "kind", "location", "properties", "status"]
    static let levels: Set<String> = ["none", "note", "warning", "error"]

    /// Returns the list of violations (empty = valid).
    static func validate(_ data: Data) -> [String] {
        var errors: [String] = []
        guard let root = try? JSONValue.parse(data), let top = root.objectValue else { return ["not a JSON object"] }
        func object(_ v: JSONValue?, _ path: String, allowed: Set<String>? = nil, required: [String] = []) -> [String: JSONValue]? {
            guard let o = v?.objectValue else { errors.append("\(path): expected object"); return nil }
            for r in required where o[r] == nil { errors.append("\(path): missing required \(r)") }
            if let allowed { for k in o.keys where !allowed.contains(k) { errors.append("\(path): unexpected property \(k)") } }
            return o
        }
        func string(_ v: JSONValue?, _ path: String) { if v?.stringValue == nil { errors.append("\(path): expected string") } }
        func multiformat(_ v: JSONValue?, _ path: String) {
            if let o = object(v, path, allowed: ["text", "markdown", "properties"], required: ["text"]) { string(o["text"], path + ".text") }
        }

        if top["version"]?.stringValue != "2.1.0" { errors.append("version must be 2.1.0") }
        if let s = top["$schema"] { string(s, "$schema") }
        for k in top.keys where !["$schema", "version", "runs", "inlineExternalProperties", "properties"].contains(k) { errors.append("unexpected root property \(k)") }
        guard let runs = top["runs"]?.arrayValue else { return errors + ["runs must be an array"] }
        for (ri, run) in runs.enumerated() {
            let rp = "runs[\(ri)]"
            guard let r = object(run, rp, allowed: runKeys, required: ["tool"]) else { continue }
            guard let tool = object(r["tool"], rp + ".tool", allowed: ["driver", "extensions", "properties"], required: ["driver"]),
                  let driver = object(tool["driver"], rp + ".tool.driver", allowed: driverKeys, required: ["name"]) else { continue }
            string(driver["name"], rp + ".tool.driver.name")
            var ruleCount = 0
            if let rules = driver["rules"] {
                guard let list = rules.arrayValue else { errors.append("rules must be an array"); continue }
                ruleCount = list.count
                var ids = Set<String>()
                for (i, rule) in list.enumerated() {
                    let p = "\(rp).rules[\(i)]"
                    guard let o = object(rule, p, allowed: descriptorKeys, required: ["id"]) else { continue }
                    string(o["id"], p + ".id")
                    if let id = o["id"]?.stringValue, !ids.insert(id).inserted { errors.append("\(p): duplicate id") }
                    if let s = o["shortDescription"] { multiformat(s, p + ".shortDescription") }
                    if let s = o["fullDescription"] { multiformat(s, p + ".fullDescription") }
                    if let s = o["help"] { multiformat(s, p + ".help") }
                    if let h = o["helpUri"] { string(h, p + ".helpUri"); if URL(string: h.stringValue ?? "")?.scheme == nil { errors.append("\(p).helpUri is not a URI") } }
                    if let dc = o["defaultConfiguration"] {
                        if let c = object(dc, p + ".defaultConfiguration", allowed: ["enabled", "level", "parameters", "properties", "rank"]),
                           let l = c["level"]?.stringValue, !levels.contains(l) { errors.append("\(p) level \(l)") }
                    }
                    if let props = o["properties"]?.objectValue, let tags = props["tags"] {
                        let t = tags.arrayValue?.compactMap(\.stringValue) ?? []
                        if t.count != tags.arrayValue?.count || Set(t).count != t.count { errors.append("\(p).properties.tags must be unique strings") }
                    }
                }
            }
            guard let results = r["results"] else { continue }
            guard let list = results.arrayValue else { errors.append("results must be an array"); continue }
            for (i, result) in list.enumerated() {
                let p = "\(rp).results[\(i)]"
                guard let o = object(result, p, allowed: resultKeys, required: ["message"]) else { continue }
                if let m = object(o["message"], p + ".message", allowed: ["arguments", "id", "markdown", "properties", "text"]), m["text"] == nil, m["id"] == nil {
                    errors.append("\(p).message needs text or id")
                }
                if let l = o["level"]?.stringValue, !levels.contains(l) { errors.append("\(p).level \(l)") }
                if let idx = o["ruleIndex"] {
                    if let n = idx.intValue, n >= -1 { if n >= ruleCount { errors.append("\(p).ruleIndex out of range") } } else { errors.append("\(p).ruleIndex") }
                }
                if let id = o["ruleId"] { string(id, p + ".ruleId") }
                if let pf = o["partialFingerprints"]?.objectValue, pf.values.contains(where: { $0.stringValue == nil }) { errors.append("\(p).partialFingerprints must be strings") }
                if let locs = o["locations"] {
                    for (li, loc) in (locs.arrayValue ?? []).enumerated() {
                        guard let lo = object(loc, "\(p).locations[\(li)]", allowed: locationKeys) else { continue }
                        for (ci, ll) in (lo["logicalLocations"]?.arrayValue ?? []).enumerated() {
                            if let l = object(ll, "\(p).locations[\(li)].logicalLocations[\(ci)]", allowed: logicalLocationKeys) {
                                if let k = l["kind"] { string(k, "logicalLocation.kind") }
                                if let f = l["fullyQualifiedName"] { string(f, "logicalLocation.fullyQualifiedName") }
                            }
                        }
                    }
                }
                for (si, sup) in (o["suppressions"]?.arrayValue ?? []).enumerated() {
                    if let s = object(sup, "\(p).suppressions[\(si)]", allowed: suppressionKeys, required: ["kind"]) {
                        if !["inSource", "external"].contains(s["kind"]?.stringValue ?? "") { errors.append("\(p).suppression kind") }
                        if let st = s["status"]?.stringValue, !["accepted", "underReview", "rejected"].contains(st) { errors.append("\(p).suppression status") }
                    }
                }
            }
        }
        return errors
    }
}

@Suite("Survey: exports and accepted risks")
struct SurveyExportTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func sampleFindings() -> [SecurityFinding] {
        var priv = SF.hardenedSecurity; priv["privileged"] = true; priv["allowPrivilegeEscalation"] = nil
        let bad = SF.deployment("bad", ns: "payments", spec: SF.podSpec(containers: [SF.container(image: "registry.example.com:5000/team/app:1.0", security: priv)]))
        let s = SF.snapshot(
            clusterRoles: [SF.clusterRole("wild", rules: [SF.rule(resources: ["*"], verbs: ["get"])])],
            clusterRoleBindings: [SF.clusterBinding("a", role: "cluster-admin", subjects: [SF.subject("User", "=cmd|' /C calc'!A0, \"quoted\"")])],
            namespaces: [SF.namespace("payments")], workloads: [bad])
        return SF.run(s).findings
    }

    @Test func sarifValidatesAgainstTheSchemaConstraints() {
        let data = SurveyExporter.export(sampleFindings(), format: .sarif, now: now)
        let errors = SARIFSchemaCheck.validate(data)
        #expect(errors.isEmpty, "\(errors)")
        let doc = try! JSONValue.parse(data)
        #expect(doc["version"]?.stringValue == "2.1.0")
        let run = doc.value(at: "runs")?[0]
        #expect(run?.value(at: "tool.driver.rules")?.arrayValue?.count == 21)
        let first = run?["results"]?.arrayValue?.first { $0["ruleId"]?.stringValue == "WH-W01" }
        #expect(first?.value(at: "locations")?[0]?.value(at: "logicalLocations")?[0]?["fullyQualifiedName"]?.stringValue?.split(separator: "/").count == 4)
        // every result points at its rule in the catalogue
        for r in run?["results"]?.arrayValue ?? [] {
            let i = r["ruleIndex"]?.intValue ?? -1
            #expect(run?.value(at: "tool.driver.rules")?[i]?["id"]?.stringValue == r["ruleId"]?.stringValue)
        }
    }

    @Test func sarifOfNothingIsStillValid() {
        let errors = SARIFSchemaCheck.validate(SurveyExporter.export([], format: .sarif, now: now))
        #expect(errors.isEmpty, "\(errors)")
    }

    @Test func theSchemaCheckRejectsBrokenDocuments() {
        #expect(!SARIFSchemaCheck.validate(Data(#"{"version":"2.0.0","runs":[]}"#.utf8)).isEmpty)
        #expect(!SARIFSchemaCheck.validate(Data(#"{"version":"2.1.0","runs":[{"tool":{"driver":{}}}]}"#.utf8)).isEmpty)
        #expect(!SARIFSchemaCheck.validate(Data(#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"x"}},"results":[{"level":"fatal","message":{"text":"t"}}]}]}"#.utf8)).isEmpty)
        #expect(!SARIFSchemaCheck.validate(Data(#"{"version":"2.1.0","runs":[{"tool":{"driver":{"name":"x"}},"results":[{"bogus":1,"message":{"text":"t"}}]}]}"#.utf8)).isEmpty)
    }

    @Test func acceptedRisksBecomeSarifSuppressions() {
        let findings = sampleFindings()
        var book = AcceptedRiskBook()
        book.accept(findings.first { $0.ruleID == "WH-W01" }!, scope: .finding, reason: "node agent", days: 30, now: now)
        let data = SurveyExporter.export(findings, format: .sarif, book: book, now: now)
        #expect(SARIFSchemaCheck.validate(data).isEmpty)
        let doc = try! JSONValue.parse(data)
        let suppressed = doc.value(at: "runs")?[0]?["results"]?.arrayValue?.filter { $0["suppressions"] != nil }
        #expect(suppressed?.count == 1)
        #expect(suppressed?.first?["ruleId"]?.stringValue == "WH-W01")
        // leaving accepted risks out removes them
        let without = SurveyExporter.export(findings, format: .sarif, book: book, options: SurveyExportOptions(includeAcceptedRisks: false), now: now)
        #expect((try! JSONValue.parse(without)).value(at: "runs")?[0]?["results"]?.arrayValue?.contains { $0["ruleId"]?.stringValue == "WH-W01" } == false)
    }

    @Test func csvQuotesAndNeutralisesFormulas() {
        let csv = String(decoding: SurveyExporter.export(sampleFindings(), format: .csv, now: now), as: UTF8.self)
        let lines = csv.components(separatedBy: "\r\n")
        #expect(lines[0] == "rule,severity,cluster,namespace,kind,name,title,status,accepted_until,reason,evidence")
        #expect(csv.contains("'=cmd|' /C calc'!A0, \"\"quoted\"\"\""))        // leading apostrophe, doubled quotes, wrapped in quotes
        #expect(lines.last == "")
        #expect(SurveyExporter.csvCell("plain") == "plain")
        #expect(SurveyExporter.csvCell("a,b") == "\"a,b\"")
        #expect(SurveyExporter.csvCell("@SUM(1)") == "'@SUM(1)")
    }

    @Test func jsonIsParseableAndComplete() throws {
        let findings = sampleFindings()
        let doc = try JSONValue.parse(SurveyExporter.export(findings, format: .json, now: now))
        #expect(doc["findingCount"]?.intValue == findings.count)
        #expect(doc["findings"]?.arrayValue?.count == findings.count)
        #expect(doc["findings"]?[0]?["status"]?.stringValue == "open")
    }

    @Test func htmlEscapesEverything() {
        let f = SecurityFinding(ruleID: "WH-A02", severity: .critical, clusterID: "c", namespace: nil, object: FindingObject(kind: "User", name: "<script>alert(1)</script>"),
                                title: "x <b>bold</b> & \"q\"", evidence: ["<img src=x onerror=alert(1)>"])
        let html = String(decoding: SurveyExporter.export([f], format: .html, now: now), as: UTF8.self)
        #expect(!html.contains("<script>"))
        #expect(!html.contains("<img"))
        #expect(html.contains("&lt;script&gt;"))
        #expect(html.contains("&amp;"))
    }

    @Test func registriesAreRedactedOnRequest() {
        let findings = sampleFindings()
        let plain = String(decoding: SurveyExporter.export(findings, format: .csv, now: now), as: UTF8.self)
        let redacted = String(decoding: SurveyExporter.export(findings, format: .csv, options: SurveyExportOptions(redactImageRegistries: true), now: now), as: UTF8.self)
        #expect(plain.contains("registry.example.com:5000"))
        #expect(!redacted.contains("registry.example.com"))
        #expect(redacted.contains("<registry>/team/app:1.0"))
        #expect(SurveyExporter.redactRegistry("image nginx:latest") == "image nginx:latest")
        #expect(SurveyExporter.redactRegistry("image library/nginx:1") == "image library/nginx:1")
        #expect(SurveyExporter.redactRegistry("image ghcr.io/org/app@sha256:ab") == "image <registry>/org/app@sha256:ab")
        #expect(SurveyExporter.redactRegistry("image localhost:5000/app:1") == "image <registry>/app:1")
    }

    @Test func exportsNeverContainSecretValues() {
        // Findings are built from specs and rules only: an env var value or a Secret's data never enters a finding.
        let container: JSONValue = ["name": "app", "image": "x:1", "env": [["name": "TOKEN", "value": "super-secret-token-value"]],
                                    "securityContext": ["privileged": true]]
        let w = SF.deployment(spec: SF.podSpec(containers: [container]))
        let f = SF.run(SF.snapshot(workloads: [w])).findings
        for format in SurveyExportFormat.allCases {
            #expect(!String(decoding: SurveyExporter.export(f, format: format, now: now), as: UTF8.self).contains("super-secret-token-value"))
        }
    }

    // MARK: accepted risks

    @Test func acceptedRiskScopesAndExpiry() {
        let findings = sampleFindings()
        let w01 = findings.first { $0.ruleID == "WH-W01" }!
        let w05 = findings.first { $0.ruleID == "WH-W05" }!
        var book = AcceptedRiskBook()
        book.accept(w01, scope: .finding, reason: "agent", days: 30, now: now)
        #expect(book.status(of: w01, now: now).isAccepted)
        #expect(!book.status(of: w05, now: now).isAccepted)
        // expiry
        #expect(book.status(of: w01, now: now.addingTimeInterval(29 * 86_400)).isAccepted)
        #expect(!book.status(of: w01, now: now.addingTimeInterval(31 * 86_400)).isAccepted)
        // namespace and cluster scopes
        var ns = AcceptedRiskBook(); ns.accept(w05, scope: .ruleInNamespace, reason: "r", days: 90, now: now)
        let otherNS = SecurityFinding(ruleID: "WH-W05", severity: .medium, clusterID: SF.cluster, namespace: "other", object: FindingObject(kind: "Deployment", namespace: "other", name: "x"), title: "t", evidence: [])
        #expect(ns.status(of: w05, now: now).isAccepted)
        #expect(!ns.status(of: otherNS, now: now).isAccepted)
        var cl = AcceptedRiskBook(); cl.accept(w05, scope: .ruleInCluster, reason: "r", days: 180, now: now)
        #expect(cl.status(of: otherNS, now: now).isAccepted)
        let otherCluster = SecurityFinding(ruleID: "WH-W05", severity: .medium, clusterID: "elsewhere", namespace: "other", object: otherNS.object, title: "t", evidence: [])
        #expect(!cl.status(of: otherCluster, now: now).isAccepted)
        book.removeExpired(now: now.addingTimeInterval(40 * 86_400))
        #expect(book.risks.isEmpty)
    }

    @Test func acceptedRisksPersistToDisk() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wh-survey-\(UUID().uuidString)/risks.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let f = sampleFindings()[0]
        var book = AcceptedRiskBook()
        book.accept(f, scope: .ruleInCluster, reason: "because", days: 90, now: now)
        try AcceptedRiskStorage.save(book, to: url)
        let loaded = AcceptedRiskStorage.load(from: url)
        #expect(loaded.risks.count == 1)
        #expect(loaded.risks[0].reason == "because")
        #expect(loaded.status(of: f, now: now).isAccepted)
        #expect(AcceptedRiskStorage.load(from: url.appending(path: "missing")).risks.isEmpty)
    }

    // MARK: suggested patches

    @Test func suggestedPatchesExistForWorkloadFindingsAndAreValidYAML() throws {
        var priv = SF.hardenedSecurity; priv["privileged"] = true; priv["allowPrivilegeEscalation"] = nil
        let w = SF.deployment("bad", ns: "payments", spec: SF.podSpec(containers: [SF.container(image: "nginx", security: priv, limits: false)], extra: ["hostNetwork": true]))
        let findings = SF.run(SF.snapshot(workloads: [w])).findings
        var covered = Set<String>()
        for f in findings {
            guard let patch = SuggestedPatches.patch(for: f) else { continue }
            covered.insert(f.ruleID)
            #expect(!patch.yaml.isEmpty)
            #expect(SuggestedPatches.location(for: f) == "spec.template.spec")
            #expect(SuggestedPatches.editTarget(for: f)?.name == "bad")
        }
        #expect(covered.isSuperset(of: ["WH-W01", "WH-W03", "WH-W05", "WH-W08", "WH-W09"]))
        let w01 = SuggestedPatches.patch(for: findings.first { $0.ruleID == "WH-W01" }!)!
        #expect(w01.yaml == "containers:\n  - name: app\n    securityContext:\n      privileged: false")
        // a bare Pod gets a caveat about immutability
        let pod = SurveyWorkload(raw: ["metadata": ["name": "p", "namespace": "n"], "spec": SF.podSpec(containers: [SF.container(security: ["privileged": true])])], kind: "Pod")!
        let podFinding = WorkloadRules.findings(for: pod, clusterID: "c").first { $0.ruleID == "WH-W01" }!
        #expect(SuggestedPatches.patch(for: podFinding)?.caveat?.contains("cannot be changed in place") == true)
        #expect(SuggestedPatches.location(for: podFinding) == "spec")
    }

    @Test func everyCatalogueRuleHasGuidance() {
        #expect(RuleCatalogue.all.count == 21)
        #expect(RuleCatalogue.access.count == 10 && RuleCatalogue.workload.count == 11)
        for r in RuleCatalogue.all {
            #expect(!r.summary.isEmpty && !r.whyItMatters.isEmpty && !r.fix.isEmpty && r.docsURL.hasPrefix("https://"))
        }
        #expect(Set(RuleCatalogue.all.map(\.id)).count == 21)
        #expect(RuleCatalogue.rule("WH-A02")?.severity == .critical)
        #expect(RuleCatalogue.rule("WH-W07")?.severity == .low)
    }
}
