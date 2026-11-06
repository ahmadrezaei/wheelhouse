import Foundation
import Testing
@testable import WheelhouseKit

@Suite("LineDiff")
struct LineDiffTests {
    @Test func identicalTextHasNoChanges() {
        let d = LineDiff.diff(old: "a\nb\nc\n", new: "a\nb\nc\n")
        #expect(d.count == 3)
        #expect(LineDiff.stats(d).total == 0)
    }

    @Test func simpleReplacement() {
        let d = LineDiff.diff(old: "a\nb\nc\n", new: "a\nB\nc\n")
        #expect(d.map(\.kind) == [.context, .removed, .added, .context])
        #expect(d[1].text == "b" && d[1].oldNumber == 2 && d[1].newNumber == nil)
        #expect(d[2].text == "B" && d[2].newNumber == 2)
    }

    @Test func insertionsAndDeletions() {
        let d = LineDiff.diff(old: ["a", "b", "c", "d"], new: ["a", "x", "c", "d", "e"])
        let s = LineDiff.stats(d)
        #expect(s.added == 2 && s.removed == 1)
        // Reconstructing both sides from the diff yields the inputs.
        #expect(d.filter { $0.kind != .added }.map(\.text) == ["a", "b", "c", "d"])
        #expect(d.filter { $0.kind != .removed }.map(\.text) == ["a", "x", "c", "d", "e"])
    }

    @Test func emptySides() {
        #expect(LineDiff.diff(old: "", new: "a\nb\n").map(\.kind) == [.added, .added])
        #expect(LineDiff.diff(old: "a\nb\n", new: "").map(\.kind) == [.removed, .removed])
        #expect(LineDiff.diff(old: "", new: "").isEmpty)
    }

    @Test func reconstructsRandomInputs() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let a = (0..<Int.random(in: 0...25, using: &rng)).map { _ in String(Int.random(in: 0...5, using: &rng)) }
            let b = (0..<Int.random(in: 0...25, using: &rng)).map { _ in String(Int.random(in: 0...5, using: &rng)) }
            let d = LineDiff.diff(old: a, new: b)
            #expect(d.filter { $0.kind != .added }.map(\.text) == a)
            #expect(d.filter { $0.kind != .removed }.map(\.text) == b)
        }
    }

    @Test func minimalEditScript() {
        // LCS is "ace" (3) so the minimal script has 2 deletions + 2 insertions.
        let d = LineDiff.diff(old: ["a", "b", "c", "d", "e"], new: ["a", "c", "e", "f", "g"])
        let s = LineDiff.stats(d)
        #expect(s.removed == 2 && s.added == 2)
    }

    @Test func foldsLongUnchangedRuns() {
        let old = (1...40).map { "line \($0)" }
        var new = old
        new[19] = "changed"
        let d = LineDiff.diff(old: old, new: new)
        let rows = LineDiff.fold(d, context: 3)
        let folds = rows.compactMap { row -> Int? in if case .fold(_, let c) = row { c } else { nil } }
        #expect(folds.count == 2)
        #expect(folds[0] == 16 && folds[1] == 17)
        // 3 context + removed + added + 3 context
        #expect(rows.count == 2 + 8)
        // Expanding the first fold shows its lines.
        guard case .fold(let id, _) = rows[0] else { Issue.record("expected leading fold"); return }
        let expanded = LineDiff.fold(d, context: 3, expanded: [id])
        #expect(expanded.count == rows.count - 1 + 16)
    }

    @Test func unchangedTextCollapsesToOneFold() {
        let d = LineDiff.diff(old: "a\nb\n", new: "a\nb\n")
        #expect(LineDiff.fold(d) == [.fold(id: 0, count: 2)])
    }
}

@Suite("YAML normalisation")
struct YAMLNormalizerTests {
    let live: JSONValue = [
        "apiVersion": "v1", "kind": "ConfigMap",
        "metadata": [
            "name": "web-config", "namespace": "shop", "uid": "abc", "resourceVersion": "42",
            "creationTimestamp": "2025-01-01T00:00:00Z", "generation": 3,
            "labels": ["app": "web"], "annotations": [:],
            "managedFields": [["manager": "kubectl"]],
        ],
        "data": ["a": "1"],
        "status": ["phase": "x"],
    ]

    @Test func stripsServerFields() {
        let e = YAMLNormalizer.editable(live)
        #expect(e["status"] == nil)
        #expect(e.value(at: "metadata.managedFields") == nil)
        #expect(e.value(at: "metadata.resourceVersion") == nil)
        #expect(e.value(at: "metadata.uid") == nil)
        #expect(e.value(at: "metadata.creationTimestamp") == nil)
        #expect(e.value(at: "metadata.generation") == nil)
        #expect(e.value(at: "metadata.annotations") == nil)  // empty map dropped
        #expect(e.value(at: "metadata.labels.app") == "web")
        #expect(e.value(at: "metadata.name") == "web-config")
    }

    @Test func showServerFieldsKeepsEverythingButManagedFields() {
        let v = YAMLNormalizer.withoutManagedFields(live)
        #expect(v.value(at: "metadata.managedFields") == nil)
        #expect(v.value(at: "metadata.uid") == "abc")
        #expect(v["status"] != nil)
    }

    @Test func replaceBodyReattachesConcurrencyAndStatus() {
        var edited = YAMLNormalizer.editable(live)
        edited.setValue("2", at: "data.a")
        let body = YAMLNormalizer.replaceBody(edited: edited, original: live, resourceVersion: "42")
        #expect(body.value(at: "metadata.resourceVersion") == "42")
        #expect(body.value(at: "metadata.uid") == "abc")
        #expect(body.value(at: "status.phase") == "x")
        #expect(body.value(at: "data.a") == "2")
    }

    @Test func semanticEqualityIgnoresNoise() {
        var other = live
        other.setValue("999", at: "metadata.resourceVersion")
        other.setValue("Running", at: "status.phase")
        #expect(YAMLNormalizer.semanticallyEqual(live, other))
        other.setValue("changed", at: "data.a")
        #expect(!YAMLNormalizer.semanticallyEqual(live, other))
    }

    @Test func secretMaskingHidesValuesButKeepsChangesVisible() {
        let secret: JSONValue = ["kind": "Secret", "data": ["password": "c2VjcmV0", "user": "YWRtaW4="]]
        let m = SecretMasking.masked(secret)
        let text = YAMLCodec.dump(m)
        #expect(!text.contains("c2VjcmV0") && !text.contains("YWRtaW4="))
        #expect(text.contains("password"))
        var changed = secret
        changed.setValue("bmV3", at: "data.password")
        #expect(YAMLCodec.dump(SecretMasking.masked(changed)) != text)
        #expect(YAMLCodec.dump(SecretMasking.masked(secret)) == text)
        // Non-secrets untouched.
        let cm: JSONValue = ["kind": "ConfigMap", "data": ["a": "b"]]
        #expect(SecretMasking.masked(cm) == cm)
    }
}

@Suite("YAML codec")
struct YAMLCodecTests {
    @Test func roundTripsKubernetesObject() throws {
        let obj: JSONValue = [
            "apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": ["name": "web", "labels": ["app": "web", "tier": "1"]],
            "spec": ["replicas": 3, "paused": false, "template": ["spec": ["containers": [["name": "c", "image": "nginx:1.27", "args": ["--a", "yes", "true", "123", ""], "env": []]]]]],
            "data": ["script": "line1\nline2\n", "ts": "2025-01-01T00:00:00Z", "empty": "", "nul": "null", "colon": "a: b # c"],
        ]
        let text = YAMLCodec.dump(obj)
        #expect(try YAMLCodec.parse(text) == obj)
    }

    @Test func putsApiVersionAndKindFirst() {
        let text = YAMLCodec.dump(["spec": ["a": 1], "metadata": ["name": "x"], "kind": "Foo", "apiVersion": "v1"])
        #expect(text.hasPrefix("apiVersion: v1\nkind: Foo\nmetadata:\n  name: x\nspec:"))
    }

    @Test func quotesAmbiguousStrings() {
        let text = YAMLCodec.dump(["a": "true", "b": "123", "c": "null", "d": "1.5"])
        #expect(text.contains("a: 'true'") && text.contains("b: '123'") && text.contains("c: 'null'") && text.contains("d: '1.5'"))
    }

    @Test func multilineStringsUseBlockScalars() {
        let text = YAMLCodec.dump(["a": "x\ny\n"])
        #expect(text.contains("a: |"))
    }

    @Test func lintReportsLineOfSyntaxError() {
        let bad = "apiVersion: v1\nkind: ConfigMap\ndata:\n  a: [1, 2\n  b: 3\n"
        let d = YAMLCodec.lint(bad)
        #expect(d.count == 1)
        #expect((3...6).contains(d[0].line))
        #expect(YAMLCodec.lint("a: 1\nb:\n  - x\n").isEmpty)
    }

    @Test func rejectsDuplicateKeys() {
        let d = YAMLCodec.lint("a: 1\na: 2\n")
        #expect(d.first?.message.contains("Duplicate") == true)
        #expect(d.first?.line == 2)
    }

    @Test func splitsDocumentsWithCorrectLineOffsets() {
        let text = "# comment\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n---\n---\nkind: [oops\n"
        let docs = YAMLCodec.parseDocuments(text)
        #expect(docs.count == 2)
        #expect(docs[0].kind == "ConfigMap" && docs[0].name == "a")
        #expect(docs[0].startLine == 3)
        #expect(docs[1].diagnostic != nil)
        #expect((9...10).contains(docs[1].diagnostic?.line ?? 0))
    }

    @Test func mapsFieldPathsToLines() {
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: a\n          image: x\n        - name: b\n          image: y\n"
        #expect(YAMLCodec.line(forPath: "spec.template.spec.containers[1].image", in: text) == 10)
        #expect(YAMLCodec.line(forPath: "spec.template.spec.containers[0].name", in: text) == 7)
        #expect(YAMLCodec.line(forPath: "spec.template.spec.nothing.deeper", in: text) == 5)  // closest parent
        #expect(YAMLCodec.segments(of: "a.b[2].c") == [.key("a"), .key("b"), .index(2), .key("c")])
    }

    @Test func invalidCausesBecomeIssuesWithLines() {
        let text = "spec:\n  replicas: -1\n"
        let err = KubeError.invalid(message: "bad", causes: [Status.Cause(reason: "FieldValueInvalid", message: "spec.replicas: Invalid value: -1: must be >= 0", field: "spec.replicas")])
        let issues = YAMLIssues.issues(from: err, text: text)
        #expect(issues.count == 1)
        #expect(issues[0].line == 2)
        #expect(issues[0].message == "Invalid value: -1: must be >= 0")
    }
}

@Suite("YAML edit validation")
struct YAMLEditValidatorTests {
    let ref = ResourceRef(clusterID: "c", kind: .configMap, namespace: "shop", name: "web-config")

    @Test func acceptsUnchangedIdentity() {
        let r = YAMLEditValidator.validate(text: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: web-config\n  namespace: shop\ndata:\n  a: b\n", ref: ref)
        #expect(r.diagnostics.isEmpty && r.value != nil)
    }

    @Test func flagsRenamesAndKindChanges() {
        let r = YAMLEditValidator.validate(text: "apiVersion: v1\nkind: Secret\nmetadata:\n  name: other\n  namespace: shop\n", ref: ref)
        #expect(r.diagnostics.count == 2)
        #expect(r.diagnostics.map(\.line).sorted() == [2, 4])
    }

    @Test func flagsMultipleDocuments() {
        let r = YAMLEditValidator.validate(text: "kind: A\n---\nkind: B\n", ref: ref)
        #expect(r.diagnostics.first?.line == 3)
    }
}

@Suite("YAML rebase")
struct YAMLRebaseTests {
    @Test func appliesUserEditsOntoNewerServerCopy() {
        let base: JSONValue = ["data": ["a": "1", "b": "2"], "metadata": ["name": "x"]]
        let edited: JSONValue = ["data": ["a": "1", "b": "changed", "c": "new"], "metadata": ["name": "x"]]
        let latest: JSONValue = ["data": ["a": "server", "b": "2"], "metadata": ["name": "x", "labels": ["k": "v"]]]
        let r = YAMLRebase.rebase(base: base, edited: edited, onto: latest)
        #expect(r.merged.value(at: "data.a") == "server")   // server change kept
        #expect(r.merged.value(at: "data.b") == "changed")  // user change applied
        #expect(r.merged.value(at: "data.c") == "new")
        #expect(r.merged.value(at: "metadata.labels.k") == "v")
        #expect(r.conflicts.isEmpty)
    }

    @Test func reportsConflictsAndUserWins() {
        let base: JSONValue = ["data": ["a": "1"]]
        let r = YAMLRebase.rebase(base: base, edited: ["data": ["a": "mine"]], onto: ["data": ["a": "theirs"]])
        #expect(r.merged.value(at: "data.a") == "mine")
        #expect(r.conflicts == ["data.a"])
    }

    @Test func userDeletionsAreApplied() {
        let r = YAMLRebase.rebase(base: ["data": ["a": "1", "b": "2"]], edited: ["data": ["a": "1"]], onto: ["data": ["a": "1", "b": "2", "z": "9"]])
        #expect(r.merged.value(at: "data.b") == nil)
        #expect(r.merged.value(at: "data.z") == "9")
    }
}

@Suite("YAML tokenizer")
struct YAMLTokenizerTests {
    func kinds(_ text: String) -> [(String, YAMLToken.Kind)] {
        let ns = text as NSString
        return YAMLTokenizer.tokens(in: text).map { (ns.substring(with: $0.nsRange), $0.kind) }
    }

    @Test func keysAndScalars() {
        let k = kinds("name: web\nreplicas: 3\npaused: false\nimage: \"nginx:1\"  # pin\n")
        #expect(k.contains { $0 == ("name", .key) })
        #expect(k.contains { $0 == ("3", .number) })
        #expect(k.contains { $0 == ("false", .keyword) })
        #expect(k.contains { $0 == ("\"nginx:1\"", .string) })
        #expect(k.contains { $0 == ("# pin", .comment) })
    }

    @Test func listsAnchorsAndMarkers() {
        let k = kinds("---\nbase: &b\n  x: 1\nuse: *b\n- item\n")
        #expect(k.contains { $0 == ("---", .marker) })
        #expect(k.contains { $0 == ("&b", .anchor) })
        #expect(k.contains { $0 == ("*b", .anchor) })
        #expect(k.filter { $0.1 == .punctuation && $0.0 == "-" }.count == 1)
    }

    @Test func blockScalarBodyIsString() {
        let k = kinds("script: |\n  echo # not a comment\n  exit 0\nnext: 1\n")
        #expect(k.contains { $0 == ("echo # not a comment", .string) })
        #expect(!k.contains { $0.1 == .comment })
        #expect(k.contains { $0 == ("next", .key) })
    }

    @Test func offsetsAreUTF16() {
        let text = "é: 1\nb: 2\n"
        let t = YAMLTokenizer.tokens(in: text).first { $0.kind == .number && (text as NSString).substring(with: $0.nsRange) == "2" }
        #expect(t != nil)
    }

    @Test func urlValuesAreNotKeys() {
        let k = kinds("url: http://example.com:8080/x\n")
        #expect(k.filter { $0.1 == .key }.map(\.0) == ["url"])
    }
}

@Suite("Manifest preparation")
struct ManifestPreparerTests {
    @Test func defaultsNamespaceAndResolvesKinds() {
        let docs = YAMLCodec.parseDocuments("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n---\napiVersion: v1\nkind: Namespace\nmetadata:\n  name: n\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: b\n  namespace: other\n")
        let out = ManifestPreparer.prepare(docs, defaultNamespace: "shop", discovery: nil)
        guard case .ready(let a) = out[0], case .ready(let n) = out[1], case .ready(let b) = out[2] else { Issue.record("expected ready"); return }
        #expect(a.namespace == "shop" && a.namespaceDefaulted && a.body.value(at: "metadata.namespace") == "shop")
        #expect(n.namespace == nil)
        #expect(b.namespace == "other" && !b.namespaceDefaulted)
    }

    @Test func reportsMissingFieldsAndUnknownKinds() {
        let docs = YAMLCodec.parseDocuments("kind: ConfigMap\n---\napiVersion: example.io/v1\nkind: Widget\nmetadata:\n  name: w\n---\napiVersion: v1\nkind: ConfigMap\nmetadata: {}\n")
        let out = ManifestPreparer.prepare(docs, defaultNamespace: "shop", discovery: nil)
        for o in out { if case .ready = o { Issue.record("should not be ready") } }
        #expect(out.count == 3)
    }

    @Test func customResourcesResolveThroughDiscovery() {
        let discovery = DiscoveryInfo(resources: [APIResource(name: "widgets", singularName: "widget", namespaced: true, kind: "Widget", verbs: ["list"], shortNames: nil, group: "example.io", version: "v1")])
        let k = ManifestPreparer.resolveKind(apiVersion: "example.io/v1", kind: "Widget", discovery: discovery)
        #expect(k?.plural == "widgets" && k?.namespaced == true)
        #expect(ManifestPreparer.resolveKind(apiVersion: "apps/v1", kind: "Deployment", discovery: nil)?.plural == "deployments")
    }

    @Test func templatesAreValid() {
        for t in YAMLTemplate.all {
            let docs = YAMLCodec.parseDocuments(t.yaml)
            #expect(docs.count == 1 && docs[0].diagnostic == nil, "\(t.name)")
            let out = ManifestPreparer.prepare(docs, defaultNamespace: "default", discovery: nil)
            if case .ready = out[0] {} else { Issue.record("template \(t.name) not resolvable") }
        }
    }
}

@Suite("Manifest apply (demo client)")
struct ManifestApplierTests {
    @Test func createsThenUpdatesExisting() async throws {
        let client = DemoKubeClient(config: DemoFleet.configs[1])
        let docs = YAMLCodec.parseDocuments("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: throwaway\ndata:\n  a: b\n")
        guard case .ready(let m) = ManifestPreparer.prepare(docs, defaultNamespace: "default", discovery: nil)[0] else { Issue.record("not ready"); return }
        #expect(await ManifestApplier.dryRun(m, client: client) == .valid("Will create"))
        #expect(await ManifestApplier.commit(m, client: client) == .created)
        if case .willUpdate = await ManifestApplier.dryRun(m, client: client) {} else { Issue.record("expected willUpdate") }
        #expect(await ManifestApplier.commit(m, client: client) == .updated)
    }
}
