import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Values schema hints")
struct ValuesSchemaHintsTests {
    let schema: JSONValue = [
        "$schema": "http://json-schema.org/draft-07/schema#",
        "type": "object",
        "required": ["image"],
        "properties": [
            "replicaCount": ["type": "integer", "minimum": 1, "description": "How many pods."],
            "image": ["type": "object", "properties": [
                "repository": ["type": "string"],
                "pullPolicy": ["type": "string", "enum": ["Always", "IfNotPresent", "Never"]],
            ]],
            "service": ["$ref": "#/definitions/service"],
        ],
        "definitions": ["service": ["type": "object", "properties": ["type": ["type": "string", "enum": ["ClusterIP", "LoadBalancer"]], "port": ["type": "integer"]]]],
    ]

    @Test func aRealSchemaGivesTypeErrorsAndEnumChecks() {
        let hints = ValuesSchemaHints(schema: schema, defaults: nil)
        #expect(hints.origin == .schema)
        let d = hints.diagnostics(for: "replicaCount: lots\nimage:\n  pullPolicy: Sometimes\nservice:\n  port: 80\n  extra: 1\n")
        #expect(d.count == 2)
        #expect(d.allSatisfy { $0.severity == .error })
        #expect(d[0].span.line == 1 && d[1].span.line == 3)
    }

    @Test func missingRequiredAndMinimum() {
        let d = ValuesSchemaHints(schema: schema, defaults: nil).diagnostics(for: "replicaCount: 0\n")
        #expect(d.map(\.message).contains("Missing required field “image”"))
        #expect(d.map(\.message).contains { $0.hasPrefix("Must be at least 1") })
    }

    @Test func completesKeysThroughRefsAndEnumValues() {
        let hints = ValuesSchemaHints(schema: schema, defaults: nil)
        let text = "image:\n  pull\n"
        let keys = hints.completions(text: text, offset: (text as NSString).length - 1)
        #expect(keys.items.map(\.label) == ["pullPolicy"])
        let value = "image:\n  pullPolicy: I\n"
        #expect(hints.completions(text: value, offset: (value as NSString).length - 1).items.map(\.label) == ["IfNotPresent"])
        let viaRef = "service:\n  type: \n"
        #expect(Set(hints.completions(text: viaRef, offset: (viaRef as NSString).length - 1).items.map(\.label)) == ["ClusterIP", "LoadBalancer"])
        let top = "\n"
        #expect(Set(hints.completions(text: top, offset: 0).items.map(\.label)) == ["image", "replicaCount", "service"])
    }

    @Test func hoverShowsTheDescription() throws {
        let hints = ValuesSchemaHints(schema: schema, defaults: nil)
        let h = try #require(hints.hover(text: "replicaCount: 2\n", offset: 3))
        #expect(h.documentation == "How many pods." && h.type == "integer")
    }

    @Test func withoutASchemaTypesComeFromTheDefaults() {
        let defaults = """
        # -- Number of replicas
        replicaCount: 1
        image:
          # The image to run.
          # Second line.
          repository: nginx
          tag: ""
          pullPolicy: IfNotPresent
        ingress:
          enabled: false
          hosts: [a.example.com]
        resources: {}
        nodeSelector:
        """
        let hints = ValuesSchemaHints(schema: nil, defaults: defaults)
        #expect(hints.origin == .inferred)
        let d = hints.diagnostics(for: "replicaCount: three\nimage:\n  repository: [x]\ningress:\n  enabled: yes please\nnewKey: 1\nnodeSelector:\n  a: b\n")
        #expect(d.count == 3, "\(d.map(\.message))")
        #expect(d.allSatisfy { $0.severity == .warning })
        let keys = hints.completions(text: "image:\n  \n", offset: 9).items.map(\.label)
        #expect(keys == ["pullPolicy", "repository", "tag"])
        let h = hints.hover(text: "image:\n  repository: x\n", offset: 11)
        #expect(h?.documentation == "The image to run. Second line.")
        #expect(hints.hover(text: "replicaCount: 2\n", offset: 3)?.documentation == "Number of replicas")
    }

    @Test func noSchemaAndNoDefaultsMeansNoHints() {
        let hints = ValuesSchemaHints(schema: nil, defaults: nil)
        #expect(hints.origin == .none)
        #expect(hints.diagnostics(for: "a: 1\n").isEmpty)
        #expect(hints.diagnostics(for: "a: [\n").count == 1)       // syntax errors are still reported
        #expect(hints.completions(text: "a", offset: 1).items.isEmpty)
    }

    @Test func schemaBytesAndBrokenSchemas() {
        let bytes = try? schema.data()
        #expect(ValuesSchemaHints(schemaData: bytes, defaults: nil).origin == .schema)
        #expect(ValuesSchemaHints(schemaData: Data("{nope".utf8), defaults: "a: 1\n").origin == .inferred)
    }
}

@Suite("Schema toolbox provider")
struct SchemaToolboxProviderTests {
    func toolbox() -> ClusterToolbox {
        let store = bundledStore()
        let provider = SchemaToolboxProvider { _ in store }
        return ClusterToolbox(source: FakeToolboxSource([testCluster("dev")]), policy: ToolboxPolicy(caller: .firstMate(conversation: "c")), extensions: [provider])
    }

    @Test func explainsAFieldWithItsTypeAndChildren() async {
        let out = await toolbox().call(.explainField, input: ["cluster": "dev", "kind": "deployment", "path": "spec.template.spec.containers"])
        #expect(out.isError == false, "\(out.text)")
        #expect(out.json["type"]?.stringValue == "[]Container")
        let fields = out.json["fields"]?.arrayValue?.compactMap { $0["name"]?.stringValue } ?? []
        #expect(fields.contains("image") && fields.contains("name"))
        #expect(out.json["note"]?.stringValue == "Schema from Kubernetes 1.32, cluster schema unavailable")
    }

    @Test func listsAreEnteredAutomaticallyAndEnumsAreShown() async {
        let out = await toolbox().call(.explainField, input: ["cluster": "dev", "kind": "service", "path": "spec.type"])
        #expect(out.json["enum"]?.arrayValue?.compactMap(\.stringValue).contains("NodePort") == true)
        let nested = await toolbox().call(.explainField, input: ["cluster": "dev", "kind": "deployment", "path": "spec.template.spec.containers.image"])
        #expect(nested.json["path"]?.stringValue == "spec.template.spec.containers.image")
        #expect(nested.json["type"]?.stringValue == "string")
    }

    @Test func unknownFieldsAndKindsAnswerWithAMessage() async {
        let field = await toolbox().call(.explainField, input: ["cluster": "dev", "kind": "deployment", "path": "spec.nope"])
        #expect(field.json["error"]?.stringValue == "unknown_field")
        let kind = await toolbox().call(.explainField, input: ["cluster": "dev", "kind": "gizmo", "path": "spec"])
        #expect(kind.json["error"]?.stringValue == "unknown_kind")
    }

    @Test func theToolIsStillUnavailableWithoutAProvider() async {
        let bare = ClusterToolbox(source: FakeToolboxSource([testCluster("dev")]), policy: ToolboxPolicy(caller: .firstMate(conversation: "c")))
        let out = await bare.call(.explainField, input: ["cluster": "dev", "kind": "pod", "path": "spec"])
        #expect(out.json["error"]?.stringValue == "unavailable")
    }
}
