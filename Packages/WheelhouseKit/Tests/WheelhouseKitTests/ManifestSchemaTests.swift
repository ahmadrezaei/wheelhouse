import Foundation
import Testing
@testable import WheelhouseKit

/// A store that answers from the schema bundled with the package (Kubernetes 1.32): the fallback path with real schemas.
private let sharedBundledStore = OpenAPIStore(cluster: "test", serverVersion: "v1.32.0", cacheRoot: nil, fetch: { _ in throw KubeError.unsupported("no openapi") })

/// The default store is shared by every test (parsing the bundled schema once keeps the suite from starving the timing-based tests
/// that run beside it); a store with another version is built fresh.
func bundledStore(version: String? = "v1.32.0") -> OpenAPIStore {
    if version == "v1.32.0" { return sharedBundledStore }
    return OpenAPIStore(cluster: "test", serverVersion: version, cacheRoot: nil, fetch: { _ in throw KubeError.unsupported("no openapi") })
}

let validDeployment = """
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: shop
  labels:
    app: web
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web
  template:
    metadata:
      labels:
        app: web
    spec:
      containers:
        - name: web
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 500m
              memory: 128Mi
            limits:
              cpu: "1"
              memory: 1Gi
          readinessProbe:
            httpGet:
              path: /
              port: http
          env:
            - name: MODE
              value: prod
"""

@Suite("YAML node map")
struct YAMLNodeMapTests {
    @Test func positionsOfKeysAndValues() throws {
        let docs = YAMLNodeMap.documents(in: "a: 1\nb:\n  c: hello\n")
        let root = try #require(docs.first?.root)
        let b = try #require(root.entry("b"))
        #expect(b.keySpan.line == 2 && b.keySpan.column == 0 && b.keySpan.endColumn == 1)
        let c = try #require(b.value.entry("c"))
        #expect(c.keySpan.line == 3 && c.keySpan.column == 2)
        #expect(c.value.span.line == 3 && c.value.span.column == 5 && c.value.span.endColumn == 10)
        #expect(root.child("a")?.scalar == .int(1))
    }

    @Test func quotedScalarsStayStrings() throws {
        let root = try #require(YAMLNodeMap.documents(in: "a: \"true\"\nb: true\nc: '5'\nd: 5\ne: ~\n").first?.root)
        #expect(root.child("a")?.scalar == .string("true") && root.child("a")?.isQuoted == true)
        #expect(root.child("b")?.scalar == .bool(true))
        #expect(root.child("c")?.scalar == .string("5"))
        #expect(root.child("d")?.scalar == .int(5))
        #expect(root.child("e")?.scalar.isNull == true)
    }

    @Test func columnsAreUTF16AfterEmoji() throws {
        // The emoji is one Unicode scalar but two UTF-16 units: the key after it must start two units later than a scalar count says.
        let root = try #require(YAMLNodeMap.documents(in: "s: \"😀\"\nk: 1\n").first?.root)
        #expect(root.child("s")?.span.column == 3)
        #expect(root.child("s")?.span.endColumn == 3 + 2 + 2)
        let flow = try #require(YAMLNodeMap.documents(in: "{ a: \"😀\", b: 2 }\n").first?.root)
        #expect(flow.entry("b")?.keySpan.column == 11)
    }

    @Test func crlfAndFlowAndAliases() throws {
        let docs = YAMLNodeMap.documents(in: "base: &b\r\n  x: 1\r\ncopy: *b\r\nlist: [1, 2]\r\n")
        let root = try #require(docs.first?.root)
        #expect(root.child("list")?.items.count == 2)
        #expect(root.child("copy") != nil)
        #expect(root.entry("list")?.keySpan.line == 4)
    }

    @Test func mergeKeysJoinTheMapping() throws {
        let text = "base: &labels\n  app: web\n  tier: be\nlabels:\n  <<: *labels\n  tier: fe\n"
        let root = try #require(YAMLNodeMap.documents(in: text).first?.root)
        let labels = try #require(root.child("labels"))
        #expect(labels.entries.map(\.key).sorted() == ["app", "tier"])
        #expect(labels.child("tier")?.scalar == .string("fe"))                  // explicit keys win
        #expect(labels.child("app")?.scalar == .string("web"))
        #expect(labels.entry("app")?.keySpan.line == 5)                          // the `<<` key, where the alias is used
        #expect(labels.child("app")?.span.line == 5)
        let several = try #require(YAMLNodeMap.documents(in: "a: &a {x: 1}\nb: &b {x: 2, y: 3}\nc:\n  <<: [*a, *b]\n").first?.root)
        #expect(several.child("c")?.child("x")?.scalar == .int(1) && several.child("c")?.child("y")?.scalar == .int(3))
    }

    @Test func mergeKeysDoNotProduceTypeErrors() async {
        let text = "apiVersion: v1\nkind: ConfigMap\nx-labels: &l\n  app: web\nmetadata:\n  name: c\n  labels:\n    <<: *l\n    tier: fe\n"
        let a = await ManifestAnalyzer(schemas: bundledStore()).analyze(text)
        #expect(a.diagnostics.map(\.message) == ["Unknown field “x-labels”"])
    }

    @Test func crlfKeepsLineNumbersSpansAndFolds() async throws {
        let text = "apiVersion: v1\r\nkind: ConfigMap\r\nmetadata:\r\n  name: a\r\n---\r\napiVersion: v1\r\nkind: ConfigMap\r\nmetadata:\r\n  name: b\r\ndata: 5\r\n"
        let docs = YAMLNodeMap.documents(in: text)
        #expect(docs.map(\.startLine) == [1, 6])
        #expect(docs[1].root?.child("data")?.span.line == 10)
        #expect(docs[1].root?.child("data")?.span.column == 6 && docs[1].root?.child("data")?.span.endColumn == 7)
        let a = await ManifestAnalyzer(schemas: bundledStore()).analyze(text)
        #expect(a.diagnostics.first?.span.line == 10)
        #expect(a.outline.map(\.startLine) == [1, 6] && a.outline[1].endLine == 11)     // the empty line after the final newline belongs to it, as with LF
        #expect(ManifestFolding.ranges(in: text) == [ManifestFoldRange(startLine: 3, endLine: 4), ManifestFoldRange(startLine: 8, endLine: 9)])
        let table = TextLineTable(text)
        #expect(table.lineCount == 11)
        // Completion with CRLF line ends.
        let typed = "apiVersion: apps/v1\r\nkind: Deployment\r\nspec:\r\n  repl"
        let r = await ManifestAssist.completions(text: typed, offset: (typed as NSString).length, schemas: bundledStore())
        #expect(r.items.map(\.label) == ["replicas"])
    }

    @Test func documentsMatchTheCodec() {
        let text = "# only a comment\n---\na: 1\n---\n\n---\nb: [\n---\nc: 3\n"
        let mine = YAMLNodeMap.documents(in: text)
        let theirs = YAMLCodec.parseDocuments(text)
        #expect(mine.map(\.index) == theirs.map(\.index))
        #expect(mine.map(\.startLine) == theirs.map(\.startLine))
        #expect(mine.map { $0.diagnostic?.line } == theirs.map { $0.diagnostic?.line })
        #expect(mine[1].diagnostic != nil && mine[0].diagnostic == nil)
    }

    @Test func aSyntaxErrorInOneDocumentDoesNotHideTheOthers() throws {
        let docs = YAMLNodeMap.documents(in: "a: 1\n---\nb: [unclosed\n---\nc: 3\n")
        #expect(docs.count == 3)
        #expect(docs[1].diagnostic != nil)
        #expect(docs[2].root?.child("c")?.scalar == .int(3))
        #expect(docs[2].startLine == 5)
    }
}

@Suite("Schema engine")
struct SchemaEngineTests {
    func analyze(_ text: String) async -> ManifestAnalysis {
        await ManifestAnalyzer(schemas: bundledStore()).analyze(text)
    }

    @Test func aValidDeploymentHasNoFindings() async {
        let a = await analyze(validDeployment)
        #expect(a.diagnostics.isEmpty, "\(a.diagnostics.map(\.message))")
        #expect(a.schemaNote == "Schema from Kubernetes 1.32, cluster schema unavailable")
    }

    @Test func unknownFieldsAreWarningsWithASuggestion() async throws {
        let a = await analyze(validDeployment.replacingOccurrences(of: "replicas: 3", with: "replica: 3"))
        let d = try #require(a.diagnostics.first)
        #expect(d.severity == .warning && d.message.contains("Unknown field “replica”") && d.message.contains("replicas"))
        #expect(d.span.line == 9, "\(d)")
    }

    @Test func wrongTypesAndEnumsAndQuantitiesAreErrors() async {
        let text = validDeployment
            .replacingOccurrences(of: "replicas: 3", with: "replicas: many")
            .replacingOccurrences(of: "memory: 128Mi", with: "memory: lots")
            .replacingOccurrences(of: "cpu: 500m", with: "cpu: 500mm")
        let a = await analyze(text)
        let messages = a.diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("Expected an integer") })
        #expect(messages.filter { $0.contains("valid quantity") }.count == 2, "\(messages)")
        #expect(a.diagnostics.allSatisfy { $0.severity == .error })
    }

    @Test func requiredFieldsAndIntOrString() async {
        let missing = validDeployment.replacingOccurrences(of: "  selector:\n    matchLabels:\n      app: web\n", with: "")
        let a = await analyze(missing)
        #expect(a.diagnostics.contains { $0.message == "Missing required field “selector”" })
        // `port: http` and `port: 80` are both valid for an int-or-string; a list is not.
        let bad = await analyze(validDeployment.replacingOccurrences(of: "port: http", with: "port: [1]"))
        #expect(bad.diagnostics.contains { $0.severity == .error })
        let numeric = await analyze(validDeployment.replacingOccurrences(of: "port: http", with: "port: 8080"))
        #expect(numeric.diagnostics.isEmpty)
    }

    @Test func enumValuesAreChecked() async {
        let a = await analyze("apiVersion: v1\nkind: Service\nmetadata:\n  name: s\nspec:\n  type: Sideways\n  ports:\n    - port: 80\n")
        #expect(a.diagnostics.contains { $0.message.hasPrefix("Must be one of:") && $0.message.contains("ClusterIP") })
    }

    @Test func nameAndLabelSyntax() async {
        let a = await analyze("apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: Not_Valid\n  labels:\n    app: \"-bad\"\n    \"bad key!\": x\n")
        let messages = a.diagnostics.map(\.message)
        #expect(messages.contains { $0.contains("“Not_Valid” is not a valid name") })
        #expect(messages.contains { $0.contains("not a valid label value") })
        #expect(messages.contains { $0.contains("not a valid label key") })
    }

    @Test func missingApiVersionAndKind() async {
        let a = await analyze("metadata:\n  name: x\n")
        #expect(a.diagnostics.map(\.message).contains("apiVersion is required"))
        #expect(a.diagnostics.map(\.message).contains("kind is required"))
    }

    @Test func aKindWithoutASchemaIsNotAnErrorButSaysSo() async {
        let a = await analyze("apiVersion: example.com/v1\nkind: Gizmo\nmetadata:\n  name: g\nspec:\n  anything: [1, 2]\n")
        #expect(a.diagnostics.isEmpty)
        #expect(a.schemaNote == "No schema for Gizmo (example.com/v1): only the YAML is checked")
    }

    // MARK: structural patterns

    @Test(arguments: [SchemaOptions.kubernetes, SchemaOptions.jsonSchema])
    func oneOfWithRequiredOnlyMembers(options: SchemaOptions) throws {
        let root: JSONValue = ["type": "object", "properties": ["a": ["type": "string"], "b": ["type": "string"]],
                               "oneOf": [["required": ["a"]], ["required": ["b"]]]]
        let engine = JSONSchemaEngine(document: SchemaDocument(root: root), options: options)
        func issues(_ text: String) throws -> [SchemaIssue] { engine.validate(try #require(YAMLNodeMap.documents(in: text).first?.root), schema: root) }
        #expect(try issues("a: x\n").isEmpty)
        #expect(try issues("b: x\n").isEmpty)
        #expect(try issues("a: x\nb: y\n").map(\.message) == ["Matches more than one of the allowed shapes"])
        #expect(try issues("c: z\n").contains { $0.message == "Doesn’t match any of the allowed shapes" })
    }

    @Test(arguments: [SchemaOptions.kubernetes, SchemaOptions.jsonSchema])
    func anyOfWithRequiredOnlyMembersCanFail(options: SchemaOptions) throws {
        let root: JSONValue = ["type": "object", "anyOf": [["required": ["a"]], ["required": ["b"]]]]
        let engine = JSONSchemaEngine(document: SchemaDocument(root: root), options: options)
        let bad = try #require(YAMLNodeMap.documents(in: "c: 1\n").first?.root)
        #expect(engine.validate(bad, schema: root).count == 1)
        let good = try #require(YAMLNodeMap.documents(in: "b: 1\nc: 2\n").first?.root)
        #expect(engine.validate(good, schema: root).isEmpty)
    }

    @Test func patternPropertiesKeepAnObjectOpen() throws {
        let root: JSONValue = ["type": "object", "properties": ["a": ["type": "integer"]], "additionalProperties": false, "patternProperties": ["^x-": ["type": "string"]]]
        let node = try #require(YAMLNodeMap.documents(in: "a: 1\nx-extra: y\n").first?.root)
        #expect(JSONSchemaEngine(document: SchemaDocument(root: root), options: .jsonSchema).validate(node, schema: root).isEmpty)
        #expect(JSONSchemaEngine(document: SchemaDocument(root: root), options: .kubernetes).validate(node, schema: root).isEmpty)
    }

    @Test func mappingsWhereAScalarWrapperIsExpectedAreErrors() async {
        let a = await analyze(validDeployment.replacingOccurrences(of: "port: http", with: "port: {}"))
        #expect(a.diagnostics.contains { $0.severity == .error })
        let d = await analyze("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: d\nspec:\n  strategy:\n    rollingUpdate:\n      maxSurge: {a: 1}\n")
        #expect(d.diagnostics.contains { $0.span.line == 8 && $0.severity == .error })
        // And a valid mapping is still read once: no finding is reported twice.
        let e = await analyze(validDeployment.replacingOccurrences(of: "replicas: 3", with: "replica: 3"))
        #expect(e.diagnostics.count == 1)
    }

    @Test func nullMeansUnset() async {
        let a = await analyze(validDeployment.replacingOccurrences(of: "replicas: 3", with: "replicas:"))
        #expect(a.diagnostics.isEmpty)
    }

    @Test func nullQuantitiesAndIntOrStringsAreNotErrors() async {
        let text = validDeployment.replacingOccurrences(of: "cpu: 500m", with: "cpu: null").replacingOccurrences(of: "port: http", with: "port: ~")
        let a = await analyze(text)
        #expect(a.diagnostics.isEmpty, "\(a.diagnostics.map(\.message))")
    }

    @Test func syntaxErrorsAreFlaggedAsSyntax() async throws {
        let a = await analyze("a: [\n")
        let d = try #require(a.diagnostics.first)
        #expect(d.source == .syntax && d.severity == .error)
        #expect(a.syntaxErrors.count == 1 && a.schemaIssues.isEmpty)
    }

    @Test func schemaDiagnosticsLandOnTheRightLineInASecondDocument() async throws {
        let text = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: a\n---\napiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: b\ndata: 5\n"
        let a = await analyze(text)
        let d = try #require(a.diagnostics.first)
        #expect(d.span.line == 10 && d.span.column == 6)
        #expect(a.outline.map(\.title) == ["ConfigMap/a", "ConfigMap/b"])
        #expect(a.outline.map(\.errors) == [0, 1])
        #expect(a.outline[1].startLine == 6)
    }

    // MARK: closed versus open objects (Kubernetes versus values.schema.json)

    @Test func kubernetesObjectsAreClosedButPlainJSONSchemaIsOpen() throws {
        let schema: JSONValue = ["type": "object", "properties": ["a": ["type": "integer"]]]
        let doc = SchemaDocument(root: schema)
        let node = try #require(YAMLNodeMap.documents(in: "a: 1\nb: 2\n").first?.root)
        #expect(JSONSchemaEngine(document: doc, options: .kubernetes).validate(node, schema: schema).count == 1)
        #expect(JSONSchemaEngine(document: doc, options: .jsonSchema).validate(node, schema: schema).isEmpty)
        let closed: JSONValue = ["type": "object", "properties": ["a": ["type": "integer"]], "additionalProperties": false]
        #expect(JSONSchemaEngine(document: doc, options: .jsonSchema).validate(node, schema: closed).first?.severity == .error)
    }

    @Test func preserveUnknownFieldsOpensAnObject() throws {
        let schema: JSONValue = ["type": "object", "x-kubernetes-preserve-unknown-fields": true, "properties": ["a": ["type": "integer"]]]
        let node = try #require(YAMLNodeMap.documents(in: "a: 1\nb: 2\n").first?.root)
        #expect(JSONSchemaEngine(document: SchemaDocument(root: schema), options: .kubernetes).validate(node, schema: schema).isEmpty)
    }

    @Test func typeArraysAndAllOfWrappers() throws {
        let root: JSONValue = [
            "definitions": ["name": ["type": "string", "minLength": 2]],
            "type": "object",
            "properties": [
                "n": ["type": ["string", "null"]],
                "w": ["allOf": [["$ref": "#/definitions/name"]], "default": "xx", "description": "wrapped"],
            ],
        ]
        let engine = JSONSchemaEngine(document: SchemaDocument(root: root), options: .jsonSchema)
        let good = try #require(YAMLNodeMap.documents(in: "n: ~\nw: abc\n").first?.root)
        #expect(engine.validate(good, schema: root).isEmpty)
        let bad = try #require(YAMLNodeMap.documents(in: "n: 5\nw: a\n").first?.root)
        #expect(engine.validate(bad, schema: root).count == 2)
        #expect(engine.description(of: try #require(root.value(at: "properties.w"))) == "wrapped")
    }

    @Test func oneOfAndAnyOf() throws {
        let root: JSONValue = ["type": "object", "properties": [
            "o": ["oneOf": [["type": "string"], ["type": "integer"]]],
            "x": ["anyOf": [["type": "boolean"], ["type": "integer"]]],
        ]]
        let engine = JSONSchemaEngine(document: SchemaDocument(root: root), options: .jsonSchema)
        let ok = try #require(YAMLNodeMap.documents(in: "o: a\nx: true\n").first?.root)
        #expect(engine.validate(ok, schema: root).isEmpty)
        let bad = try #require(YAMLNodeMap.documents(in: "o: [1]\nx: nope\n").first?.root)
        #expect(engine.validate(bad, schema: root).count == 2)
    }

    @Test func patternAndRanges() throws {
        let root: JSONValue = ["type": "object", "properties": [
            "p": ["type": "string", "pattern": "^[a-z]+$", "maxLength": 3],
            "n": ["type": "integer", "minimum": 1, "maximum": 5],
            "l": ["type": "array", "minItems": 1, "items": ["type": "string"]],
        ]]
        let engine = JSONSchemaEngine(document: SchemaDocument(root: root), options: .jsonSchema)
        let node = try #require(YAMLNodeMap.documents(in: "p: ABCD\nn: 9\nl: []\n").first?.root)
        let messages = engine.validate(node, schema: root).map(\.message)
        #expect(messages.count == 4, "\(messages)")
    }

    @Test func recursiveSchemasTerminate() throws {
        let root: JSONValue = ["definitions": ["tree": ["type": "object", "properties": ["child": ["$ref": "#/definitions/tree"]]]], "$ref": "#/definitions/tree"]
        let node = try #require(YAMLNodeMap.documents(in: "child:\n  child:\n    child: {}\n").first?.root)
        #expect(JSONSchemaEngine(document: SchemaDocument(root: root), options: .jsonSchema).validate(node, schema: root).isEmpty)
    }
}

@Suite("Completion and hover")
struct CompletionTests {
    let store = bundledStore()

    func complete(_ text: String, at marker: String = "|", references: ClusterReferences? = nil, known: [GroupVersionKind] = []) async -> ManifestCompletionResult {
        let offset = (text as NSString).range(of: marker).location
        let clean = text.replacingOccurrences(of: marker, with: "")
        return await ManifestAssist.completions(text: clean, offset: offset, schemas: store, known: known, references: references)
    }

    @Test func fieldNamesOfTheContainer() async {
        let r = await complete("apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: web\n          im|\n")
        #expect(r.items.map(\.label) == ["image", "imagePullPolicy"])
        #expect(r.items[0].insertText == "image: ")
        #expect(r.items[0].documentation?.isEmpty == false)
        #expect(r.range.length == 2)
    }

    @Test func fieldsAlreadyWrittenAreNotSuggested() async {
        let r = await complete("apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n        - name: web\n          image: x\n          |\n")
        #expect(!r.items.map(\.label).contains("name") && !r.items.map(\.label).contains("image"))
        #expect(r.items.map(\.label).contains("ports"))
    }

    @Test func topLevelKeysComeFromTheKind() async {
        let r = await complete("apiVersion: apps/v1\nkind: Deployment\n|\n")
        #expect(Set(r.items.map(\.label)) == ["metadata", "spec", "status"])
    }

    @Test func requiredFieldsAreMarkedAndSortedFirst() async {
        let r = await complete("apiVersion: apps/v1\nkind: Deployment\nspec:\n  |\n")
        #expect(r.items.first?.detail?.contains("required") == true)
    }

    @Test func enumValues() async {
        let r = await complete("apiVersion: v1\nkind: Service\nspec:\n  type: |\n")
        #expect(Set(r.items.map(\.label)) == ["ClusterIP", "NodePort", "LoadBalancer", "ExternalName"])
        let filtered = await complete("apiVersion: v1\nkind: Service\nspec:\n  type: Node|\n")
        #expect(filtered.items.map(\.label) == ["NodePort"])
        #expect(filtered.range.length == 4)
    }

    @Test func booleans() async {
        let r = await complete("apiVersion: apps/v1\nkind: Deployment\nspec:\n  paused: |\n")
        #expect(r.items.map(\.label) == ["true", "false"])
    }

    @Test func apiVersionAndKindPairs() async {
        let known = [GroupVersionKind(group: "apps", version: "v1", kind: "Deployment"), GroupVersionKind(group: "", version: "v1", kind: "Pod"),
                     GroupVersionKind(group: "apps", version: "v1", kind: "StatefulSet")]
        let v = await complete("apiVersion: |\n", known: known)
        #expect(v.items.map(\.label) == ["apps/v1", "v1"])
        let k = await complete("apiVersion: apps/v1\nkind: |\n", known: known)
        #expect(k.items.map(\.label) == ["Deployment", "StatefulSet"])
        let kFirst = await complete("kind: Pod\napiVersion: |\n", known: known)
        #expect(kFirst.items.map(\.label) == ["v1"])
    }

    @Test func referencesComeFromTheClusterByName() async {
        let asked = Box<[String]>([])
        let refs = ClusterReferences { kind, namespace in
            asked.append("\(kind.rawValue)@\(namespace ?? "-")")
            return kind == .secret ? ["db-creds", "tls"] : ["m7-sa"]
        }
        let text = "apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: x\n  namespace: shop\nspec:\n  template:\n    spec:\n      serviceAccountName: |\n"
        let r = await complete(text, references: refs)
        #expect(r.items.map(\.label) == ["m7-sa"] && r.items[0].kind == .reference)
        #expect(asked.value == ["serviceAccount@shop"])
        let secret = await complete("apiVersion: v1\nkind: Pod\nspec:\n  containers:\n    - name: a\n      envFrom:\n        - secretRef:\n            name: |\n", references: refs)
        #expect(secret.items.map(\.label) == ["db-creds", "tls"])
    }

    @Test func secretReferencesListMetadataOnly() async {
        let client = ReadSpyClient()
        let names = await ClusterReferences(client: client).names(.secret, "shop")
        #expect(names == ["a-secret", "b-secret"])
        #expect(client.reads.value == ["listMetadata Secret shop"])
    }

    @Test func nothingInsideABlockScalar() async {
        let r = await complete("apiVersion: v1\nkind: ConfigMap\ndata:\n  script: |\n    echo |\n")
        #expect(r.items.isEmpty)
    }

    @Test func hoverOnAKey() async throws {
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  replicas: 3\n"
        let offset = (text as NSString).range(of: "replicas").location + 2
        let h = try #require(await ManifestAssist.hover(text: text, offset: offset, schemas: store))
        #expect(h.title == "replicas" && h.type == "integer" && h.documentation?.contains("desired pods") == true, "\(h)")
        #expect(h.range == NSRange(location: offset - 2, length: 8))
        #expect(await ManifestAssist.hover(text: text, offset: (text as NSString).range(of: "3").location, schemas: store) == nil)
    }

    @Test func hoverShowsRequiredAndEnums() async throws {
        let text = "apiVersion: v1\nkind: Service\nspec:\n  type: ClusterIP\n"
        let h = try #require(await ManifestAssist.hover(text: text, offset: (text as NSString).range(of: "type: C").location + 1, schemas: store))
        #expect(h.choices.contains("NodePort"))
    }
}

@Suite("Cursor context")
struct CursorContextTests {
    @Test func aListThatSitsAtTheSameIndentAsItsKey() async {
        let store = bundledStore()
        let text = "apiVersion: apps/v1\nkind: Deployment\nspec:\n  template:\n    spec:\n      containers:\n      - name: web\n        im\n"
        let r = await ManifestAssist.completions(text: text, offset: (text as NSString).length - 1, schemas: store)
        #expect(r.items.map(\.label) == ["image", "imagePullPolicy"])
    }

    @Test func theSecondDocumentUsesItsOwnKind() async {
        let store = bundledStore()
        let text = "apiVersion: v1\nkind: Service\n---\napiVersion: apps/v1\nkind: Deployment\nspec:\n  repl\n"
        let r = await ManifestAssist.completions(text: text, offset: (text as NSString).length - 1, schemas: store)
        #expect(r.items.map(\.label) == ["replicas"])
    }

    @Test func nonBMPTextBeforeTheCursor() async {
        let store = bundledStore()
        let text = "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  labels:\n    emoji: \"😀\"\n  na\n"
        let r = await ManifestAssist.completions(text: text, offset: (text as NSString).length - 1, schemas: store)
        #expect(r.items.map(\.label).contains("name") && r.range.length == 2)
    }

    @Test func shapeOfALine() {
        let s = YAMLLineShape("    - name: web # note")
        #expect(s.indent == 4 && s.dashes == 1 && s.effectiveIndent == 6 && s.key == "name" && s.value.hasPrefix("web"))
        let q = YAMLLineShape("  \"quoted key\": 1")
        #expect(q.key == "quoted key" && q.keyLength == 12)
        #expect(YAMLLineShape("  # comment").isBlankOrComment)
        #expect(YAMLLineShape("url: http://x:80").key == "url")
        #expect(YAMLLineShape("  script: |").opensBlockScalar)
    }
}

/// A small mutable box for `@Sendable` closures in tests.
final class Box<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: T
    init(_ value: T) { stored = value }
    var value: T { lock.lock(); defer { lock.unlock() }; return stored }
    func append<E>(_ e: E) where T == [E] { lock.lock(); stored.append(e); lock.unlock() }
}

@Suite("Folding and outline")
struct FoldingTests {
    @Test func foldsByIndentation() {
        let folds = ManifestFolding.ranges(in: "a:\n  b:\n    c: 1\n    d: 2\n  e: 3\nf: 4\n")
        #expect(folds == [ManifestFoldRange(startLine: 1, endLine: 5), ManifestFoldRange(startLine: 2, endLine: 4)])
    }

    @Test func documentsFoldSeparately() {
        let folds = ManifestFolding.ranges(in: "a:\n  b: 1\n---\nc:\n  d: 2\n\n")
        #expect(folds == [ManifestFoldRange(startLine: 1, endLine: 2), ManifestFoldRange(startLine: 4, endLine: 5)])
    }

    @Test func listItemsFold() {
        let folds = ManifestFolding.ranges(in: "items:\n  - name: a\n    v: 1\n  - name: b\n    v: 2\n")
        #expect(folds.contains(ManifestFoldRange(startLine: 2, endLine: 3)))
        #expect(folds.contains(ManifestFoldRange(startLine: 1, endLine: 5)))
    }
}

@Suite("Schema memory cache")
struct SchemaMemoryCacheTests {
    func doc(_ n: Int) -> LoadedSchemaDocument {
        LoadedSchemaDocument(components: ["components": ["schemas": ["s": .string(String(repeating: "x", count: n))]]])
    }

    @Test func evictsLeastRecentlyUsedFirst() {
        let each = doc(100).cost
        var cap = SchemaMemoryCache(limit: each * 2 + 10)
        cap.insert(doc(100), for: "a")
        cap.insert(doc(100), for: "b")
        _ = cap.value(for: "a")            // a is now more recent than b
        cap.insert(doc(100), for: "c")
        #expect(cap.keys == ["a", "c"])
        #expect(cap.totalCost <= cap.limit)
        cap.removeAll()
        #expect(cap.count == 0 && cap.totalCost == 0)
    }

    @Test func aDocumentLargerThanTheLimitIsNotStored() {
        var cache = SchemaMemoryCache(limit: doc(10).cost + 100)
        let small = cache.insert(doc(10), for: "small")
        let big = cache.insert(doc(5_000), for: "big")
        #expect(small && !big)
        #expect(cache.keys == ["small"])
    }

    @Test func totalNeverExceedsTheLimitAfterManyInserts() {
        var cache = SchemaMemoryCache(limit: 4_000)
        for i in 0..<200 {
            cache.insert(doc(50 + (i * 37) % 400), for: "k\(i)")
            #expect(cache.totalCost <= 4_000)
        }
        #expect(cache.count > 0)
    }

    @Test func reinsertingAKeyReplacesItsCost() {
        var cache = SchemaMemoryCache(limit: 10_000)
        cache.insert(doc(100), for: "a")
        let one = cache.totalCost
        cache.insert(doc(100), for: "a")
        #expect(cache.totalCost == one && cache.count == 1)
    }

    @Test func theDefaultLimitIs32MB() {
        #expect(SchemaMemoryCache.defaultLimit == 32 * 1024 * 1024)
    }

    @Test func theEstimateGrowsWithTheContent() {
        #expect(doc(1_000).cost > doc(10).cost + 900)
    }
}

/// Records which reads are made; answers `listMetadata` only.
final class ReadSpyClient: KubeClientProtocol, @unchecked Sendable {
    let reads = Box<[String]>([])
    func listMetadata(kind: ResourceKind, namespace: String?, labelSelector: String?, limit: Int?) async throws -> ObjectMetadataList {
        reads.append("listMetadata \(kind.kind) \(namespace ?? "-")")
        return ObjectMetadataList(kind: kind, items: [ObjectMeta(name: "b-secret"), ObjectMeta(name: "a-secret")])
    }
    func version() async throws -> KubeVersion { throw KubeError.unsupported("stub") }
    func discovery() async throws -> DiscoveryInfo { reads.append("discovery"); return DiscoveryInfo(resources: []) }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { reads.append("list"); return KubeList(items: []) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { reads.append("get"); throw KubeError.unsupported("stub") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { reads.append("listRaw"); return [:] }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { reads.append("getRaw"); return [:] }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("stub") }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("stub") }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("stub") }
}
