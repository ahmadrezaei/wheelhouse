import AppKit
import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

/// The Mac side of the Deck Terminal: the confirmation sheets, and the rules the performance gate pins (no polling, scrollback caps).
@MainActor @Suite("Deck Terminal")
struct DeckTerminalTests {
    private func hold(_ method: String, _ path: String, query: String? = nil, kind: GangwayClass = .mutation, typing: Bool = true, exec: [String] = []) -> GangwayHold {
        GangwayHold(id: UUID(), sessionID: UUID(), clusterID: "c1", clusterName: "prod-eu", request: GangwayRequestClass(kind: kind), method: method, path: path, query: query,
                    bodySHA256: nil, reportedCommand: "kubectl rollout restart deploy/web", execCommand: exec, requiresTyping: typing, origin: .terminal(paneID: "pane-1"))
    }

    private func cluster() -> ClusterConfig {
        ClusterConfig(id: "c1", name: "prod-eu", server: URL(string: "https://prod.test:6443")!, environment: .production)
    }

    @Test func aCommandSheetTypesTheObjectNameAndShowsWhatWillRun() {
        let sheet = GangwaySheet(kind: .command(line: "kubectl rollout restart deploy/web"), holds: [hold("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web")])
        #expect(GangwaySheetBuilder.confirmationText(for: sheet, clusterName: "prod-eu") == "web")
        let request = GangwaySheetBuilder.request(for: sheet, cluster: cluster(), paneName: "Terminal") {}
        #expect(request.requiresTyping)
        #expect(request.confirmationText == "web")
        #expect(request.origin == ChangeOrigin.terminal(session: "pane-1", reportedCommand: nil))
        #expect(request.inputDelay == ConfirmRequest.nonUIInputDelay)
        let facts = request.facts.map { "\($0.label): \($0.value)" }
        #expect(facts.contains("Command (reported by your shell): kubectl rollout restart deploy/web"))
        #expect(facts.contains("Request: PATCH /apis/apps/v1/namespaces/shop/deployments/web"))
    }

    @Test func severalObjectsTypeTheClusterName() {
        let sheet = GangwaySheet(kind: .requests, holds: [hold("DELETE", "/api/v1/namespaces/a/pods/p1"), hold("DELETE", "/api/v1/namespaces/a/pods/p2")])
        #expect(GangwaySheetBuilder.confirmationText(for: sheet, clusterName: "prod-eu") == "prod-eu")
        #expect(GangwaySheetBuilder.title(for: sheet, cluster: "prod-eu") == "Allow 2 changes on prod-eu?")
        let many = GangwaySheet(kind: .requests, holds: (0..<20).map { hold("DELETE", "/api/v1/namespaces/a/pods/p\($0)") })
        #expect(GangwaySheetBuilder.facts(for: many).filter { $0.label == "Request" }.count == GangwaySheetBuilder.listLimit + 1)
    }

    @Test func anInteractiveShellStreamIsAButtonAndANonInteractiveOneIsTyped() {
        let interactive = GangwaySheet(kind: .stream, holds: [hold("POST", "/api/v1/namespaces/a/pods/p/exec", kind: .stream(.exec(interactive: true)), typing: false)])
        let button = GangwaySheetBuilder.request(for: interactive, cluster: cluster(), paneName: "Terminal") {}
        #expect(!button.requiresTyping)
        let batch = GangwaySheet(kind: .stream, holds: [hold("POST", "/api/v1/namespaces/a/pods/p/exec", kind: .stream(.exec(interactive: false)), exec: ["rm", "-rf", "/data"])])
        let typed = GangwaySheetBuilder.request(for: batch, cluster: cluster(), paneName: "Terminal") {}
        #expect(typed.requiresTyping)
        #expect(typed.confirmationText == "p")
        #expect(typed.facts.contains { $0.label == "Runs" && $0.value == "rm -rf /data" })
    }

    private func coordinator() -> GangwaySheetCoordinator {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.deck.tests") ?? .standard)
        return GangwaySheetCoordinator(registry: registry, activity: NoopActivityLog())
    }

    @Test func aHoldFromAPaneWithoutAVisibleWindowIsDeclined() async {
        let coordinator = coordinator()
        let sheet = GangwaySheet(kind: .requests, holds: [hold("PATCH", "/apis/apps/v1/namespaces/shop/deployments/web")])
        #expect(await coordinator.present(sheet) == false)
        coordinator.register(pane: "pane-1", name: "Terminal", window: nil)
        #expect(await coordinator.present(sheet) == false)
        #expect(coordinator.pendingCount == 0)
    }

    @Test func aTerminalTitleIsCleanedBeforeItIsShown() {
        #expect(DeckTerminalSession.cleanTitle("ok\u{1B}[31m\u{202E}x") == "ok[31mx")
        #expect(DeckTerminalSession.cleanTitle(String(repeating: "a", count: 200)).count == 80)
    }

    @Test func scrollbackIsCappedAtTheDefaultAndTheMaximum() {
        #expect(SwiftTermSurface.Scrollback.defaultLines == 5_000)
        #expect(SwiftTermSurface.Scrollback.maxLines == 20_000)
        #expect(SwiftTermSurface(scrollback: 1_000_000).scrollbackLines == 20_000)
        #expect(SwiftTermSurface().scrollbackLines <= 20_000)
    }

    /// The perf gate: nothing in the terminal code polls a child process or keeps a timer (ARCHITECTURE-MAC section 3.4 and 12.3.4).
    @Test func noTerminalCodePollsOrKeepsATimer() throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<2 { root.deleteLastPathComponent() }
        let folders = [root.appending(path: "Packages/WheelhouseKit/Sources/WheelhouseDesktop/Terminal"), root.appending(path: "WheelhouseMac/DeckTerminal")]
        var checked = 0
        for folder in folders {
            for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
                let text = try String(contentsOf: folder.appending(path: name), encoding: .utf8)
                    .split(separator: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                for banned in ["PeriodicTask", "Timer.scheduledTimer", "Timer(timeInterval", "proc_listpids", "proc_pidinfo", "/bin/ps", "DispatchSource.makeTimerSource", "Task.sleep"] {
                    #expect(!text.contains(banned), "\(name) uses \(banned)")
                }
                checked += 1
            }
        }
        #expect(checked >= 8)
    }
}
