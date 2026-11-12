import Foundation
import Testing
@testable import WheelhouseKit

@Suite("Rigging: JSONPath subset")
struct RiggingJSONPathTests {
    let object: JSONValue = .object([
        "metadata": .object(["name": .string("web"), "namespace": .string("shop")]),
        "spec": .object(["hosts": .array([.string("a.example"), .string("b.example")]), "replicas": .int(3)]),
        "status": .object(["conditions": .array([
            .object(["type": .string("Ready"), "status": .string("False"), "lastTransitionTime": .string("2026-01-01T00:00:00Z")]),
            .object(["type": .string("Active"), "status": .string("True")]),
        ])]),
    ])

    @Test func dotIndexWildcardAndFilter() throws {
        #expect(try JSONPathSubset(".metadata.name").text(in: object) == "web")
        #expect(try JSONPathSubset("$.spec.hosts[1]").text(in: object) == "b.example")
        #expect(try JSONPathSubset(".spec.hosts[*]").evaluate(object).count == 2)
        #expect(try JSONPathSubset(".status.conditions[?(@.type=='Ready')].status").text(in: object) == "False")
        #expect(try JSONPathSubset(".spec.replicas").text(in: object) == "3")
        #expect(try JSONPathSubset(".spec.missing.deeper").evaluate(object).isEmpty)
    }

    @Test(arguments: [
        "", ".", "..spec", ".spec[", ".spec[abc]", ".spec[-1]", ".a[?(@.b>'x')]", ".a[?(@.b=='x' && @.c=='y')]", ".a[?(@.b==x)]",
        ".a[(@.length-1)]", ".a[0:2]", ".a[1,2]", "..a", ".a..b", ".a.b|c", ".a['b']", ".a[\"b\"]", ".a[?(@.b=='x\\')]", ".a[?(@.b=='x')", "$", "$.",
        ".a b", ".{a}", ".a;b", ".a`b`", ".a$(b)", ".a[?(@.b=='x')]]", ".a[?(@=='x')]", ".a.*",
    ])
    func unsupportedPathsAreRejected(_ path: String) {
        #expect(throws: JSONPathSubset.ParseError.self) { try JSONPathSubset(path) }
    }

    @Test func overlongAndDeepPathsAreRejected() {
        #expect(throws: JSONPathSubset.ParseError.self) { try JSONPathSubset("." + String(repeating: "a", count: 300)) }
        #expect(throws: JSONPathSubset.ParseError.self) { try JSONPathSubset(String(repeating: ".a", count: 20)) }
    }

    @Test func wildcardResultsAreBounded() throws {
        let big: JSONValue = .object(["a": .array(Array(repeating: .array(Array(repeating: .int(1), count: 100)), count: 100))])
        #expect(try JSONPathSubset(".a[*][*]").evaluate(big).count == JSONPathSubset.maxResults)
    }
}

@Suite("Rigging: status rules and columns")
struct RiggingEngineTests {
    let now = ISO8601DateFormatter().date(from: "2026-01-01T02:00:00Z")!
    let object: JSONValue = .object([
        "spec": .object(["secretName": .string("tls")]),
        "status": .object([
            "notAfter": .string("2026-01-04T02:00:00Z"),
            "conditions": .array([.object(["type": .string("Ready"), "status": .string("False"), "lastTransitionTime": .string("2026-01-01T00:00:00Z")])]),
        ]),
    ])

    @Test func conditionAndDuration() {
        #expect(RiggingEngine.matches(.init(condition: "Ready", status: "False"), in: object, now: now))
        #expect(!RiggingEngine.matches(.init(condition: "Ready", status: "True"), in: object, now: now))
        #expect(RiggingEngine.matches(.init(condition: "Ready", status: "False", duration: "1h"), in: object, now: now))
        #expect(!RiggingEngine.matches(.init(condition: "Ready", status: "False", duration: "3h"), in: object, now: now))
        #expect(!RiggingEngine.matches(.init(condition: "Missing", status: "False"), in: object, now: now))
    }

    @Test func pathChecks() {
        #expect(RiggingEngine.matches(.init(path: ".status.notAfter", exists: true), in: object, now: now))
        #expect(RiggingEngine.matches(.init(path: ".status.nope", exists: false), in: object, now: now))
        #expect(RiggingEngine.matches(.init(path: ".spec.secretName", equals: "tls"), in: object, now: now))
        #expect(RiggingEngine.matches(.init(path: ".spec.secretName", oneOf: ["x", "tls"]), in: object, now: now))
        #expect(!RiggingEngine.matches(.init(path: ".spec.secretName", oneOf: ["x"]), in: object, now: now))
    }

    @Test func columnsAndAges() {
        #expect(RiggingEngine.cell(.init(name: "Expires", path: ".status.notAfter", format: .age), object: object, now: now) == "in 3d")
        #expect(RiggingEngine.cell(.init(name: "S", path: ".spec.secretName", format: nil), object: object, now: now) == "tls")
        #expect(RiggingEngine.cell(.init(name: "S", path: ".spec.nope", format: nil), object: object, now: now) == "")
        #expect(RiggingEngine.age(since: now.addingTimeInterval(-90), now: now) == "1m")
    }
}

@Suite("Rigging: pack parsing and the built-in packs")
struct RiggingPackTests {
    static let minimal = """
    apiVersion: rigging.wheelhouse.app/v1
    kind: Pack
    metadata: { name: sample, version: 1.0.0 }
    views:
      - match: { group: example.io, kind: Widget }
        columns: [ { name: Phase, path: ".status.phase" } ]
    commands:
      - title: "Describe"
        for: { group: example.io, kind: Widget }
        terminal: "kubectl describe widget {{name}} -n {{namespace}}"
    """

    @Test func minimalPackParses() throws {
        let pack = try RiggingPackParser.parse(Self.minimal)
        #expect(pack.metadata.name == "sample")
        #expect(pack.allViews.first?.viewID == "widget")
        #expect(pack.allCommands.count == 1)
    }

    @Test func allEightBuiltInPacksLoad() throws {
        let names = BuiltInRiggingPacks.all.map(\.pack.metadata.name)
        #expect(Set(names) == Set(BuiltInRiggingPacks.names))
        for loaded in BuiltInRiggingPacks.all {
            #expect(!loaded.pack.allViews.isEmpty)
            #expect(loaded.digest.count == 64)
        }
    }

    @Test(arguments: [
        ("unknown top-level key", Self.minimal + "\nextra: 1"),
        ("wrong apiVersion", Self.minimal.replacingOccurrences(of: "rigging.wheelhouse.app/v1", with: "rigging.wheelhouse.app/v9")),
        ("script path", Self.minimal.replacingOccurrences(of: ".status.phase", with: ".items[?(@.a>1)]")),
        ("variable outside the allowlist", Self.minimal.replacingOccurrences(of: "{{namespace}}", with: "{{secret}}")),
        ("variable in quotes", Self.minimal.replacingOccurrences(of: "describe widget {{name}}", with: "describe widget '{{name}}'")),
        ("command substitution", Self.minimal.replacingOccurrences(of: "describe widget {{name}}", with: "describe $(id) {{name}}")),
        ("backticks", Self.minimal.replacingOccurrences(of: "describe widget {{name}}", with: "describe `id` {{name}}")),
        ("both terminal and port forward", Self.minimal + "\n    portForward: { service: a, namespace: b, port: 80 }"),
        ("no terminal or port forward", Self.minimal.replacingOccurrences(of: "    terminal: \"kubectl describe widget {{name}} -n {{namespace}}\"", with: "")),
        ("alias", Self.minimal.replacingOccurrences(of: "columns: [", with: "columns: &a [") + "\nx: *a"),
        ("merge key", Self.minimal.replacingOccurrences(of: "match: { group", with: "match: { <<: { group: a }, group")),
        ("tagged anchor then alias on the next line", Self.minimal.replacingOccurrences(of: "columns: [", with: "columns: !!seq &a [") + "\ny:\n  *a"),
        ("bad name", Self.minimal.replacingOccurrences(of: "name: sample", with: "name: Sample_Pack")),
        ("not yaml", "{{{"),
    ])
    func badPacksAreRejected(_ label: String, _ text: String) {
        #expect(throws: RiggingPackError.self, "\(label)") { try RiggingPackParser.parse(text) }
    }

    @Test func fieldsAreAllowedInTemplatesOnlyWhenTheViewDeclaresThem() throws {
        let with = Self.minimal.replacingOccurrences(of: "columns: [", with: "fields: [ { name: owner, path: \".spec.owner\" } ]\n    columns: [")
            .replacingOccurrences(of: "-n {{namespace}}", with: "--as={{owner}}")
        let pack = try RiggingPackParser.parse(with)
        #expect(pack.fields(for: .init(group: "example.io", kind: "Widget")).map(\.name) == ["owner"])
        #expect(throws: RiggingPackError.self) {
            try RiggingPackParser.parse(Self.minimal.replacingOccurrences(of: "-n {{namespace}}", with: "--as={{owner}}"))
        }
    }

    @Test func portForwardOpenMustBeLoopback() {
        let base = Self.minimal.replacingOccurrences(of: "terminal: \"kubectl describe widget {{name}} -n {{namespace}}\"", with: "portForward: { service: grafana, namespace: monitoring, port: 3000, open: \"OPEN\" }")
        #expect((try? RiggingPackParser.parse(base.replacingOccurrences(of: "OPEN", with: "http://127.0.0.1:{{localPort}}/"))) != nil)
        #expect((try? RiggingPackParser.parse(base.replacingOccurrences(of: "OPEN", with: "https://evil.example/{{localPort}}"))) == nil)
        #expect((try? RiggingPackParser.parse(base.replacingOccurrences(of: "OPEN", with: "http://127.0.0.1.evil.example:{{localPort}}/"))) == nil)
        #expect((try? RiggingPackParser.parse(base.replacingOccurrences(of: "OPEN", with: "file:///etc/passwd"))) == nil)
    }

    @Test func aBillionLaughsFileIsRefusedQuickly() {
        var text = "a0: &a0 [x, x, x, x, x, x, x, x, x]\n"
        for i in 1..<9 { text += "a\(i): &a\(i) [" + Array(repeating: "*a\(i - 1)", count: 9).joined(separator: ", ") + "]\n" }
        let started = Date()
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(text) }
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func deepNestingIsRefused() {
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(String(repeating: "[", count: 500) + String(repeating: "]", count: 500)) }
    }

    @Test func oversizedPackIsRejected() {
        #expect(throws: RiggingPackError.self) { try RiggingPackParser.parse(String(repeating: "# x\n", count: 100_000)) }
    }

    @Test func builtInCommandsRenderForSampleObjects() throws {
        for loaded in BuiltInRiggingPacks.all {
            for command in loaded.pack.allCommands {
                guard let text = command.terminal else { continue }
                let template = try RiggingTemplate(text, mode: .shell, allowed: Set(["name", "namespace", "cluster", "kind"]).union(command.for.map { loaded.pack.fields(for: $0).map(\.name) } ?? []))
                var values = ["name": "my-obj", "namespace": "prod", "cluster": "staging", "kind": "Thing"]
                for f in command.for.map({ loaded.pack.fields(for: $0) }) ?? [] { values[f.name] = "x" }
                let line = try template.render(values)
                #expect(!line.contains("{{"))
            }
        }
    }
}

/// A POSIX-shell word splitter that refuses anything that would run or expand. The renderer's output must split into exactly the
/// words the template and the values give.
enum ShellWords {
    struct Injected: Error { var why: String }

    static func split(_ text: String) throws -> [String] {
        var words: [String] = []
        var current = ""
        var inWord = false
        var chars = Array(text)[...]
        while let ch = chars.popFirst() {
            switch ch {
            case " ": if inWord { words.append(current); current = ""; inWord = false }
            case "'":
                inWord = true
                while let c = chars.popFirst(), c != "'" { current.append(c) }
            case "\"":
                inWord = true
                while let c = chars.popFirst(), c != "\"" {
                    if c == "$" || c == "`" { throw Injected(why: "expansion in double quotes") }
                    if c == "\\" { current.append(chars.popFirst() ?? "\\") } else { current.append(c) }
                }
            case "\\": inWord = true; current.append(chars.popFirst() ?? "\\")
            case "$", "`", ";", "|", "&", "<", ">", "(", ")", "\n", "\r", "*", "?", "[", "~", "#", "{": throw Injected(why: "unquoted \(ch)")
            default: inWord = true; current.append(ch)
            }
        }
        if inWord { words.append(current) }
        return words
    }
}

@Suite("Rigging: template quoting")
struct RiggingTemplateTests {
    @Test func quotesEveryValue() throws {
        let t = try RiggingTemplate("cmctl renew {{name}} -n {{namespace}}", mode: .shell, allowed: ["name", "namespace"])
        #expect(try t.render(["name": "web", "namespace": "prod"]) == "cmctl renew 'web' -n 'prod'")
        #expect(RiggingTemplate.shellQuote("it's") == "'it'\\''s'")
        let q = try RiggingTemplate("echo {{name}}", mode: .shell, allowed: ["name"])
        #expect(throws: RiggingTemplate.TemplateError.self) { try q.render(["name": "it's"]) }
        #expect(throws: RiggingTemplate.TemplateError.self) { try q.render(["name": ""]) }
        #expect(throws: RiggingTemplate.TemplateError.self) { try q.render(["name": "a b"]) }
        #expect(throws: RiggingTemplate.TemplateError.self) { try q.render(["name": "~root"]) }
    }

    @Test func refusesTemplatesThatPutAVariableWhereQuotingCannotHelp() {
        for text in ["echo '{{name}}'", "echo \"{{name}}\"", "echo \\{{name}}", "echo $(x) {{name}}", "echo `x` {{name}}", "echo 'unclosed {{name}}", "echo {{name}} \\",
                    "echo {{ other }}", "echo {{name", "echo name}}", "echo {{}}", "echo {{na me}}", "echo \u{202E}{{name}}", "echo\n{{name}}", "echo {{name}}\u{E000}",
                    "echo ${{name}}", "echo ''{{name}}", "echo \"\"{{name}}", "echo {{name}}{{name}}", "echo {,{{name}}}", "echo > {{name}}", "{{name}} x", "FOO={{name}} cmd", "echo ={{name}}",
                    "echo ~{{name}}", "echo <(x) {{name}}", "echo !!", "echo a | {{name}}", "echo {{name}}'x'", "echo a; {{name}}", "echo é {{name}}", "echo x{{name}}y;", "echo \"$x\" {{name}}"] {
            #expect(throws: RiggingTemplate.TemplateError.self, "\(text)") { try RiggingTemplate(text, mode: .shell, allowed: ["name"]) }
        }
    }

    @Test func refusesUnsafeValuesInsteadOfCleaningThem() throws {
        let t = try RiggingTemplate("echo {{name}}", mode: .shell, allowed: ["name"])
        for value in ["a\nb", "a\rb", "a\tb", "a\u{202E}b", "a\u{200B}b", "a\u{0}b", "a\u{85}b", "a\u{2028}b", String(repeating: "x", count: 2000)] {
            #expect(throws: RiggingTemplate.TemplateError.self) { try t.render(["name": value]) }
        }
        #expect(throws: RiggingTemplate.TemplateError.self) { try t.render([:]) }
    }

    @Test func aValueThatStartsWithADashIsNotAnOption() throws {
        let t = try RiggingTemplate("kubectl get {{name}} --as={{name}}", mode: .shell, allowed: ["name"])
        #expect(throws: RiggingTemplate.TemplateError.self) { try t.render(["name": "--all"]) }
        let mid = try RiggingTemplate("kubectl get --as={{name}}", mode: .shell, allowed: ["name"])
        #expect(try mid.render(["name": "-x"]) == "kubectl get --as='-x'")
    }

    @Test func namesAreCheckedAgainstKubeNames() {
        let values = RiggingValues.make(subject: .init(name: "Bad Name;rm", namespace: "ns_bad", kind: "Kind;x"), cluster: "c")
        #expect(values["name"] == nil && values["namespace"] == nil && values["kind"] == nil)
        let good = RiggingValues.make(subject: .init(name: "web-1.v2", namespace: "prod", kind: "Certificate"), cluster: "c", localPort: 8080)
        #expect(good["name"] == "web-1.v2" && good["namespace"] == "prod" && good["kind"] == "Certificate" && good["localPort"] == "8080")
        #expect(RiggingValues.make(subject: nil, cluster: "c", localPort: 70000)["localPort"] == nil)
    }

    /// Random names and values: the rendered text splits back into exactly the expected words, or the render is refused. Never anything else.
    @Test func fuzzedValuesParseBackToTheSameWordsWithNoInjectedToken() throws {
        let alphabet: [String] = ["a", "b", "Z", "0", "-", ".", " ", "'", "\"", "$", "(", ")", "`", ";", "|", "&", "<", ">", "\\", "*", "?", "~", "#", "{", "}", "[", "]", "!",
                                  "é", "日本", "🙂", "$(id)", "`id`", "'; touch /tmp/x; '", "\"; id; \"", "${IFS}"]
        let unsafe: [String] = ["\n", "\r", "\t", "\u{202E}", "\u{2066}", "\u{200E}", "\u{061C}", "\u{FEFF}", "\u{0}", "\u{85}"]
        var rng = SystemRandomNumberGenerator()
        let template = try RiggingTemplate("tool run {{name}} --ns={{namespace}} --x {{field}} tail", mode: .shell, allowed: ["name", "namespace", "field"])
        var accepted = 0, refused = 0
        for _ in 0..<5000 {
            func plain() -> String { String((0..<Int.random(in: 1...12, using: &rng)).map { _ in "abXY09._:/@=+,%-".randomElement(using: &rng)! }) }
            func random() -> String { Int.random(in: 0..<100, using: &rng) < 60 ? plain() : fuzzy() }
            func fuzzy() -> String { (0..<Int.random(in: 0...14, using: &rng)).map { _ in Int.random(in: 0..<100, using: &rng) < 2 ? unsafe.randomElement(using: &rng)! : alphabet.randomElement(using: &rng)! }.joined() }
            let values = ["name": random(), "namespace": random(), "field": random()]
            do {
                let line = try template.render(values)
                let words = try ShellWords.split(line)
                #expect(words == ["tool", "run", values["name"]!, "--ns=" + values["namespace"]!, "--x", values["field"]!, "tail"], "\(line)")
                accepted += 1
            } catch is RiggingTemplate.TemplateError {
                refused += 1
            }
        }
        #expect(accepted > 300 && refused > 300, "accepted \(accepted), refused \(refused)")
    }

    @Test func plainModeNeverQuotesButStillRefusesUnsafeValues() throws {
        let t = try RiggingTemplate("Certificate {{name}} is not ready", mode: .plain, allowed: ["name"])
        #expect(try t.render(["name": "web"]) == "Certificate web is not ready")
        #expect(throws: RiggingTemplate.TemplateError.self) { try t.render(["name": "a\nb"]) }
    }
}

#if os(macOS)
@Suite("Rigging: real shells agree")
struct RiggingRealShellTests {
    /// The rendered words go through a real shell's `printf` (it prints, never runs, what it is given) and must come back unchanged.
    @Test(arguments: ["/bin/bash", "/bin/zsh"])
    func renderedTextSplitsIntoTheExpectedWords(shell: String) throws {
        let template = try RiggingTemplate("printf '%s\\n' run {{name}} --ns={{namespace}} x{{field}}y -- {{field}}", mode: .shell, allowed: ["name", "namespace", "field"])
        let samples = ["a", "web-1.v2", "-", "x=y", "a,b:c/d@e+f%g", "..", "A_b", "0"]
        let canary = FileManager.default.temporaryDirectory.appending(path: "wh-canary-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: canary) }
        for n in samples where !n.hasPrefix("-") {
            let values = ["name": n, "namespace": "ns-" + n, "field": n + "f"]
            let line = try template.render(values)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: shell)
            p.arguments = shell.hasSuffix("zsh") ? ["-f", "-c", line] : ["--norc", "--noprofile", "-c", line]
            p.environment = ["PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).dropLast().map(String.init)
            #expect(lines == ["run", values["name"]!, "--ns=" + values["namespace"]!, "x" + values["field"]! + "y", "--", values["field"]!], "\(shell): \(line)")
        }
        #expect(!FileManager.default.fileExists(atPath: canary.path))
    }
}
#endif
