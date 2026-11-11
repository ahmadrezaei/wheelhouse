#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Live Deck Terminal tests (ARCHITECTURE-MAC section 15.1, M5b): TEST CLUSTER ONLY, same guards as ``GangwayLiveTests``
/// (`WH_LIVE_TESTS=1`, `WH_TEST_KUBECONFIG` = `<repo>/.testcluster/kubeconfig`). Needs `scripts/testcluster-fixtures.sh --section m5b-terminal`.
///
/// A real zsh runs on a PTY through the real shell integration, in a scratch HOME. Its `KUBECONFIG` is the Gangway session file, which
/// points at the loopback listener; the cluster is treated as Production by the policy while the upstream leg is the test cluster.
@Suite("Live: Deck Terminal with kubectl", .enabled(if: GangwayLive.enabled), .serialized)
@MainActor
struct TerminalLiveTests {
    private final class Sheets: @unchecked Sendable {
        let list = Mutex<[GangwaySheet]>([])
        let answer: Bool
        init(answer: Bool) { self.answer = answer }
    }

    private struct Recording: GangwayConfirming {
        let sheets: Sheets
        func confirm(_ sheet: GangwaySheet) async -> Bool {
            sheets.list.withLock { $0.append(sheet) }
            return sheets.answer
        }
    }

    private final class Output: Sendable {
        private let value = Mutex("")
        func append(_ text: String) { value.withLock { $0 += text } }
        var text: String { value.withLock { $0 } }
    }

    private struct Terminal {
        let model: LocalShellModel
        let output: Output
        func text() -> String { output.text }
    }

    private func open(_ rig: LiveRig) async throws -> Terminal {
        let home = rig.scratch.root.appending(path: "terminal-home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        var cluster = try #require(rig.provider.config(for: rig.clusterID))
        cluster.environment = .production
        let config = LocalShellModel.Configuration(cluster: cluster, namespace: "wh-m5b", shell: URL(fileURLWithPath: "/bin/zsh"),
                                                   baseEnvironment: ["PATH": "/usr/local/bin:/usr/bin:/bin", "HOME": home.path, "LANG": "en_US.UTF-8"],
                                                   userFiles: .init(zshDirectory: home, bashHome: home), home: home, kubeCacheDir: home.appending(path: "cache"),
                                                   directRoot: home, helper: try PTYHelper.url(),
                                                   gate: DevSafetyPolicy(isActive: true, allowedHosts: [rig.verified.host], home: rig.scratch.root))
        let model = LocalShellModel(configuration: config)
        let output = Output()
        model.onOutput = { data in output.append(String(decoding: data, as: UTF8.self)) }
        try await model.start(gangway: rig.service)
        for _ in 0..<100 where model.banner != .guarded { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.banner == .guarded)
        return Terminal(model: model, output: output)
    }

    private func type(_ line: String, into terminal: Terminal, waitFor needle: String, timeout: Duration = .seconds(60)) async throws {
        terminal.model.write(Data((line + "\r").utf8))
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, !terminal.text().contains(needle) { try await Task.sleep(for: .milliseconds(100)) }
    }

    @Test("a Production rollout restart asks once per command, typed, and an aborted one changes nothing")
    func rolloutRestart() async throws {
        let sheets = Sheets(answer: true)
        let rig = try await LiveRig(environment: .production, confirmer: Recording(sheets: sheets))
        defer { rig.stop() }
        let terminal = try await open(rig)
        defer { Task { await terminal.model.close() } }
        try await type("kubectl rollout restart deployment/web -n wh-m5b", into: terminal, waitFor: "restarted")
        #expect(terminal.text().contains("deployment.apps/web restarted"))
        let first = sheets.list.withLock { $0 }
        #expect(first.count == 1)
        if case .command(let line) = first.first?.kind { #expect(line.contains("rollout restart")) } else { Issue.record("expected a command sheet, got \(String(describing: first.first?.kind))") }
        #expect(first.first?.requiresTyping == true)
        // The next command gets its own sheet: a grant never carries over.
        try await type("kubectl rollout restart deployment/web -n wh-m5b", into: terminal, waitFor: "restarted\r\n", timeout: .seconds(60))
        #expect(sheets.list.withLock { $0.count } == 2)
    }

    @Test("a joined command and kubectl proxy get per-request sheets")
    func joinedCommandsGetPerRequestSheets() async throws {
        let sheets = Sheets(answer: false)
        let rig = try await LiveRig(environment: .production, confirmer: Recording(sheets: sheets))
        defer { rig.stop() }
        let terminal = try await open(rig)
        defer { Task { await terminal.model.close() } }
        try await type("kubectl get cm -n wh-m5b; kubectl delete cm base -n wh-m5b", into: terminal, waitFor: "not confirmed")
        let joined = sheets.list.withLock { $0 }
        #expect(joined.count == 1)
        #expect(joined.first?.kind == .requests)
        #expect(terminal.text().contains("change not confirmed"))
        // The ConfigMap is still there.
        try await type("kubectl get cm base -n wh-m5b -o name", into: terminal, waitFor: "configmap/base")
        #expect(terminal.text().contains("configmap/base"))
    }

    @Test("a shell that forges marks is dropped to per-request sheets")
    func forgedMarks() async throws {
        let rig = try await LiveRig(environment: .production, confirmer: Recording(sheets: Sheets(answer: false)))
        defer { rig.stop() }
        let terminal = try await open(rig)
        defer { Task { await terminal.model.close() } }
        let forged = "printf '\\033]633;E;kubectl get po;wh=00000000000000000000000000000000\\007'"
        for _ in 0..<3 { try await type(forged, into: terminal, waitFor: "\u{07}", timeout: .seconds(2)) }
        for _ in 0..<50 where terminal.model.forgedMarks < 3 { try await Task.sleep(for: .milliseconds(100)) }
        #expect(terminal.model.forgedMarks >= 3)
        #expect(terminal.model.banner == .perRequest(LocalShellModel.forgedMessage))
    }

    @Test("a changed session kubeconfig turns the banner Unguarded and ends the session")
    func changedSessionFile() async throws {
        let rig = try await LiveRig(environment: .production, confirmer: Recording(sheets: Sheets(answer: true)))
        defer { rig.stop() }
        let terminal = try await open(rig)
        defer { Task { await terminal.model.close() } }
        let file = try #require(terminal.model.sessionKubeconfig)
        chmod(file.path, 0o600)
        for _ in 0..<50 { terminal.model.checkIntegrity(); if case .unguarded = terminal.model.banner { break }; try await Task.sleep(for: .milliseconds(100)) }
        guard case .unguarded = terminal.model.banner else { Issue.record("expected unguarded"); return }
        try await type("kubectl get ns", into: terminal, waitFor: "session ended")
        #expect(terminal.text().contains("session ended"))
    }
}
#endif
