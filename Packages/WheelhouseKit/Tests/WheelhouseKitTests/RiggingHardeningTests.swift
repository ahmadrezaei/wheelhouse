import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Rigging: validator and template hardening")
struct RiggingHardeningTests {
    static let base = """
    apiVersion: rigging.wheelhouse.app/v1
    kind: Pack
    metadata: { name: sample, version: 1.0.0 }
    views:
      - match: { group: example.io, kind: Widget }
    commands:
      - title: "Describe"
        for: { group: example.io, kind: Widget }
        terminal: "kubectl describe widget {{name}}"
    """

    @Test func packsCannotReadSecrets() {
        #expect((try? RiggingPackParser.parse(Self.base)) != nil)
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(Self.base.replacingOccurrences(of: "{ group: example.io, kind: Widget }", with: "{ group: \"\", kind: Secret }", options: [], range: Self.base.range(of: "match: { group: example.io, kind: Widget }"))) }
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(Self.base.replacingOccurrences(of: "for: { group: example.io, kind: Widget }", with: "for: { group: \"\", kind: Secret }")) }
        let rule = Self.base + "\nhealthRules:\n  - for: { group: \"\", kind: Secret }\n    when: { path: \".data.x\", exists: true }\n    tone: warning\n    message: \"x\""
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(rule) }
    }

    @Test func secretObjectsNeverFeedATemplate() {
        let values = RiggingValues.make(subject: .init(name: "tok", namespace: "ns", kind: "Secret", raw: .object(["data": .object(["a": .string("b")])])), cluster: "c",
                                        fields: [.init(name: "a", path: ".data.a")])
        #expect(values["name"] == nil && values["a"] == nil)
    }

    @Test func duplicateCommandsAndRulesAreRejected() {
        let twice = Self.base + "\n  - title: \"Describe\"\n    for: { group: example.io, kind: Widget }\n    terminal: \"kubectl get widget {{name}}\""
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(twice) }
    }

    @Test func hiddenCharactersInLabelsAreRejected() {
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(Self.base.replacingOccurrences(of: "\"Describe\"", with: "\"Desc\u{202E}ribe\"")) }
    }

    @Test(arguments: ["FOO=x {{name}}", "env {{name}}", "sh -c {{name}}", "eval {{name}}", "xargs {{name}}", "sudo {{name}}", "a=b c=d {{name}}", "/usr/bin/env {{name}}", "echo a | sh {{name}}"])
    func aVariableCannotBeTheCommandOrReachAWrapper(_ text: String) {
        #expect(throws: RiggingTemplate.TemplateError.self, "\(text)") { try RiggingTemplate(text, mode: .shell, allowed: ["name"]) }
    }

    @Test func ordinaryArgumentsStillWork() throws {
        for text in ["kubectl get x {{name}}", "FOO=1 kubectl get {{name}}", "kubectl get a | grep {{name}}", "cmctl renew {{name}} -n {{name}}"] {
            _ = try RiggingTemplate(text, mode: .shell, allowed: ["name"])
        }
    }

    @Test func theDeclarationListsFieldsAndWhatHealthRulesRead() throws {
        let pack = try RiggingPackParser.parse(Self.base.replacingOccurrences(of: "match: { group: example.io, kind: Widget }", with: "match: { group: example.io, kind: Widget }\n    fields: [ { name: owner, path: \".spec.owner\" } ]"))
        let text = RiggingDeclaration.sections(for: pack).flatMap(\.lines).joined(separator: "\n")
        #expect(text.contains("owner = .spec.owner"))
    }
}
