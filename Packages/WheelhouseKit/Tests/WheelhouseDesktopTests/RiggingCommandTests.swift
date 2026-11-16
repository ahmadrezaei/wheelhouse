#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@MainActor
private final class FakeTerminal: TerminalInsertTarget {
    var targetClusterID: ClusterID?
    var targetClusterName: String
    var bracketedPasteEnabled = true
    var isAtPrompt = true
    var written = Data()
    init(cluster: ClusterConfig) { targetClusterID = cluster.id; targetClusterName = cluster.name }
    func writeToShell(_ data: Data) { written.append(data) }
}

private let sample = """
apiVersion: rigging.wheelhouse.app/v1
kind: Pack
metadata: { name: sample, version: 1.0.0 }
views:
  - match: { group: example.io, kind: Widget }
    fields: [ { name: owner, path: ".spec.owner" } ]
commands:
  - title: "Renew"
    for: { group: example.io, kind: Widget }
    terminal: "kubectl describe widget {{name}} -n {{namespace}} -l my.owner={{owner}}"
  - title: "Open Grafana"
    portForward: { service: grafana, namespace: monitoring, port: 3000, open: "http://127.0.0.1:{{localPort}}/" }
  - title: "Forward widget"
    for: { group: example.io, kind: Widget }
    portForward: { pod: "{{name}}", namespace: "{{namespace}}", port: 8080 }
"""

@Suite("Rigging commands")
@MainActor
struct RiggingCommandTests {
    let pack = try! RiggingPackParser.parse(sample)
    let widget = RiggingValues.Subject(name: "w-1", namespace: "prod", kind: "Widget", raw: .object(["spec": .object(["owner": .string("team-a")])]))

    @Test func aTerminalCommandIsInsertedAsABracketedPasteAndNeverRun() throws {
        let cluster = ClusterConfig(name: "prod-eu", server: URL(string: "https://127.0.0.1:6443")!)
        let plan = try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: widget, cluster: cluster.name)
        guard case .insert(let text) = plan else { Issue.record("expected an insert"); return }
        #expect(text == "kubectl describe widget 'w-1' -n 'prod' -l my.owner='team-a'")
        let terminal = FakeTerminal(cluster: cluster)
        #expect(TerminalInserter.insert(text, forCluster: cluster, into: terminal) == .inserted(removed: 0))
        let bytes = [UInt8](terminal.written)
        #expect(Array(bytes.prefix(6)) == Array("\u{1B}[200~".utf8) && Array(bytes.suffix(6)) == Array("\u{1B}[201~".utf8))
        #expect(!bytes.contains(13) && !bytes.contains(10), "no Return is ever written")
    }

    @Test func aTerminalForAnotherClusterRefusesAndWritesNothing() throws {
        let target = ClusterConfig(name: "prod-eu", server: URL(string: "https://127.0.0.1:6443")!)
        let other = FakeTerminal(cluster: ClusterConfig(name: "staging", server: URL(string: "https://127.0.0.1:6443")!))
        guard case .insert(let text) = try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: widget, cluster: target.name) else { return }
        if case .refused = TerminalInserter.insert(text, forCluster: target, into: other) {} else { Issue.record("expected a refusal") }
        #expect(other.written.isEmpty)
    }

    @Test func aTerminalWithoutBracketedPasteOrAtAPromptRefusesAndWritesNothing() throws {
        let cluster = ClusterConfig(name: "c", server: URL(string: "https://127.0.0.1:6443")!)
        let t = FakeTerminal(cluster: cluster)
        t.bracketedPasteEnabled = false
        if case .refused = TerminalInserter.insert("echo", forCluster: cluster, into: t) {} else { Issue.record("expected a refusal") }
        t.bracketedPasteEnabled = true
        t.isAtPrompt = false
        if case .refused = TerminalInserter.insert("echo", forCluster: cluster, into: t) {} else { Issue.record("expected a refusal") }
        #expect(t.written.isEmpty)
    }

    @Test func aHostileFieldValueIsRefusedNotInserted() {
        let hostile = RiggingValues.Subject(name: "w-1", namespace: "prod", kind: "Widget", raw: .object(["spec": .object(["owner": .string("a'; rm -rf ~; '")])]))
        #expect(throws: RiggingTemplate.TemplateError.self) { try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: hostile, cluster: "c") }
        let withNewline = RiggingValues.Subject(name: "w-1", namespace: "prod", kind: "Widget", raw: .object(["spec": .object(["owner": .string("a\nb")])]))
        #expect(throws: RiggingTemplate.TemplateError.self) { try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: withNewline, cluster: "c") }
        let badName = RiggingValues.Subject(name: "W 1; id", namespace: "prod", kind: "Widget")
        #expect(throws: RiggingTemplate.TemplateError.self) { try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: badName, cluster: "c") }
    }

    @Test func aCommandForAnotherKindIsRefused() {
        let pod = RiggingValues.Subject(name: "p", namespace: "ns", kind: "Pod")
        #expect(throws: RiggingTemplate.TemplateError.self) { try RiggingCommandPlanner.plan(pack.allCommands[0], in: pack, subject: pod, cluster: "c") }
    }

    @Test func portForwardPlansCarryATargetAndNeverStartAnything() throws {
        guard case .portForward(let fixed) = try RiggingCommandPlanner.plan(pack.allCommands[1], in: pack, subject: nil, cluster: "c") else { Issue.record("expected a port forward"); return }
        #expect(fixed.target == PortForwardTarget(kind: .service, namespace: "monitoring", name: "grafana", remotePort: 3000))
        #expect(fixed.openURL(localPort: 51000)?.absoluteString == "http://127.0.0.1:51000/")
        guard case .portForward(let bound) = try RiggingCommandPlanner.plan(pack.allCommands[2], in: pack, subject: widget, cluster: "c") else { return }
        #expect(bound.target == PortForwardTarget(kind: .pod, namespace: "prod", name: "w-1", remotePort: 8080))
        #expect(bound.openURL(localPort: 1) == nil)
    }

    /// The plan type has two cases only: text for a terminal and a port forward. A new case would stop this switch compiling, which
    /// is the prompt to decide how it is confirmed.
    @Test func thereAreOnlyTwoWaysACommandActs() throws {
        for command in pack.allCommands {
            let plan = try RiggingCommandPlanner.plan(command, in: pack, subject: command.for == nil ? nil : widget, cluster: "c")
            switch plan {
            case .insert: #expect(command.terminal != nil)
            case .portForward: #expect(command.portForward != nil)
            }
        }
    }

    @Test func theBuiltInPacksOnlyEverPlanInsertsAndPortForwards() throws {
        for loaded in BuiltInRiggingPacks.all {
            for command in loaded.pack.allCommands {
                let subject = command.for.map { RiggingValues.Subject(name: "obj-1", namespace: "ns", kind: $0.kind, raw: .object([:])) }
                _ = try? RiggingCommandPlanner.plan(command, in: loaded.pack, subject: subject, cluster: "c")
            }
        }
    }
}
#endif
