import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

@Suite("First Mate (Mac)")
@MainActor
struct FirstMateTests {
    private func registry() -> ClusterRegistry {
        ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.firstmate.\(UUID().uuidString)")!)
    }

    private func hub(client: any AIMessaging = FirstMatePerfReplay.client(pace: .milliseconds(1)), registry: ClusterRegistry? = nil) -> (FirstMateHub, URL) {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-fm-\(UUID().uuidString)", directoryHint: .isDirectory)
        let settings = MacClusterSettingsStore(fileURL: dir.appending(path: "cluster-settings.json"))
        let defaults = UserDefaults(suiteName: "wh.firstmate.prefs.\(UUID().uuidString)")!
        let secrets = InMemoryAISecrets()
        try? secrets.write("test-key", account: AnthropicKeyStore.account)
        let hub = FirstMateHub(registry: registry ?? self.registry(), settingsStore: settings, preferences: FirstMatePreferences(defaults: defaults),
                               keySecrets: secrets, conversationSecrets: InMemoryAISecrets(), directory: dir.appending(path: "chats"), dailyFile: nil,
                               activity: NoopActivityLog(), clientFactory: { _ in client })
        return (hub, dir)
    }

    @Test func theFirstMateDestinationIsHandledByTheFeature() {
        #expect(FirstMateFeature.handles(.firstMate("inspector")))
        #expect(FirstMateFeature.handles(.firstMate("triage")))
        #expect(!FirstMateFeature.handles(.activity))
    }

    @Test func perClusterAccessIsStoredWithTheMacSettingsAndKeepsOtherFields() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-fm-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let store = MacClusterSettingsStore(fileURL: dir.appending(path: "s.json"))
        let settings = FirstMateClusterSettings(store: store)
        let prod = ClusterConfig(name: "p", server: URL(string: "https://p.example.com")!, environment: .production)
        try store.update(prod.id) { $0.extra["beaconExposure"] = "x" }
        #expect(settings.firstMateAccess(for: prod) == nil)                       // default: the environment's (Production asks)
        #expect(ToolboxPolicy(caller: .firstMate(conversation: "c"), settings: settings).firstMateAccess(for: prod) == .ask)
        settings.set(.never, for: prod.id)
        #expect(settings.firstMateAccess(for: prod) == .never)
        #expect(ToolboxPolicy(caller: .firstMate(conversation: "c"), settings: settings).visibility(of: prod) == .hidden)
        #expect(store.settings(for: prod.id)?.extra["beaconExposure"] == "x")     // another milestone's field survives
        settings.set(nil, for: prod.id)
        #expect(settings.firstMateAccess(for: prod) == nil)
        #expect(FirstMateClusterSettings(store: MacClusterSettingsStore(fileURL: dir.appending(path: "s.json"))).firstMateAccess(for: prod) == nil)
    }

    @Test func slotsMapToConversationsAndNewConversationRepointsTheSlot() async {
        let (hub, _) = hub()
        let first = hub.session(for: "inspector")
        #expect(hub.session(for: "inspector") === first)
        #expect(hub.session(for: "triage") !== first)
        let revision = hub.slotRevision
        let second = hub.newConversation(in: "inspector")
        #expect(second !== first && hub.session(for: "inspector") === second)
        #expect(hub.slotRevision == revision + 1)
        #expect(first.grants !== second.grants)      // grants belong to one conversation
        await hub.delete(second.id)
        #expect(hub.session(for: "inspector") !== second)
    }

    @Test func aReplayedConversationRunsEndToEndAndStaysWithinTheCaps() async {
        let (hub, _) = hub()
        let session = hub.session(for: "inspector")
        for turn in 1...6 {
            session.send(FirstMatePerfReplay.prompt(turn))
            for _ in 0..<2_000 where session.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
            #expect(session.state == .idle, "turn \(turn): \(session.state)")
        }
        #expect(session.usage.cacheReadTokens > 0)
        #expect(session.cacheMissWarnings == 0)
        #expect(session.spentDollars < 0.25)
        // Odd turns call list_clusters first, through the real read-only toolbox.
        let rows = session.items.compactMap { item -> ToolRow? in if case .tool(let row) = item.kind { row } else { nil } }
        #expect(rows.count == 3 && rows.allSatisfy { $0.name == "list_clusters" && $0.finished && !$0.isError })
        #expect(MessageOrdering.violations(session.snapshot.messages).isEmpty)
        // The replay never needed the network: the transport is the scripted one.
        #expect(session.snapshot.sent.count == 9)
    }

    @Test func savedConversationsListOpenAndDelete() async {
        let (hub, _) = hub()
        let session = hub.session(for: "inspector")
        session.send(FirstMatePerfReplay.prompt(2))
        for _ in 0..<2_000 where session.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
        await session.flushStorage()
        await hub.refreshList()
        #expect(hub.recent.map(\.id) == [session.id])
        let other = hub.newConversation(in: "triage")
        await hub.open(session.id, in: "triage")
        #expect(hub.session(for: "triage") === session && hub.session(for: "triage") !== other)
        await hub.deleteAll()
        #expect(hub.recent.isEmpty)
    }

    @Test func theKeyIsIdentifiedByItsLastFourAndRemovable() throws {
        let (hub, _) = hub()
        #expect(hub.hasKey && hub.keyIdentification == "••••" + "-key")
        try hub.removeKey()
        #expect(!hub.hasKey && hub.keyIdentification == nil)
        try hub.saveKey("  another-test-key  ")
        #expect(hub.hasKey && hub.keyIdentification == "••••" + "-key")
    }

    @Test func theReplayIsHonouredOnlyWhileTheGateIsActive() {
        #expect(FirstMatePerfReplay.isRequested(arguments: ["-WHPerfFirstMate", "YES"], gateActive: true))
        #expect(!FirstMatePerfReplay.isRequested(arguments: ["-WHPerfFirstMate", "YES"], gateActive: false))
        #expect(!FirstMatePerfReplay.isRequested(arguments: ["-WHPerfFirstMate"], gateActive: true))
        #expect(!FirstMatePerfReplay.isRequested(arguments: ["-WHPerfFirstMate", "NO"], gateActive: true))
        #expect(!FirstMatePerfReplay.isRequested(arguments: [], gateActive: true))
    }

    @Test func preferencesKeepDocumentedDefaultsAndClampCaps() {
        let prefs = FirstMatePreferences(defaults: UserDefaults(suiteName: "wh.fm.prefs.\(UUID().uuidString)")!)
        #expect(prefs.defaultProfile == .standard && prefs.conversationCap == 2 && prefs.dailyCap == 10 && prefs.showToolCalls && prefs.retention == .days30)
        prefs.usesQuickByDefault = true
        #expect(prefs.defaultProfile == .quick)
        prefs.redactionPatterns = [#"acme-\d+"#]
        #expect(prefs.redactor.redact("see acme-42").contains("redacted"))
    }

    @Test func proposalCardsReviewOnlyPatchesAndManifests() {
        #expect(ProposalText.canReview(.patch(kind: .deployment, name: "a", namespace: "b", patchType: "merge", body: [:])))
        #expect(ProposalText.canReview(.manifest(yaml: "x", documents: [])))
        #expect(!ProposalText.canReview(.command("kubectl get pods")))
        #expect(ProposalText.reviewNote(.command("x")) != nil)
        #expect(ProposalText.copyText(.command("kubectl get pods")) == "kubectl get pods")
        let leaked = ["gh", "p_", String(repeating: "a", count: 36)].joined()
        #expect(!ProposalText.summary(.command("echo \(leaked)")).contains(leaked))
    }
}
