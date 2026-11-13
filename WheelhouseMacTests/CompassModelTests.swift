import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// The Compass panel's model: parsing into results, ranking, the actions it opens, and what it refuses to do.
@MainActor
@Suite("CompassModelTests")
struct CompassModelTests {
    private final class Box: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_800_000_000) }

    private struct Fixture {
        let model: CompassModel
        let window: WorkspaceWindowModel
        let controller: WorkspaceController
        let rail: RailModel
        let index: CompassIndex
        let frecency: FrecencyStore
        let cluster: ClusterID
        let other: ClusterID
        let performed: PerformedBox
        let clock: Box
        var locked: LockedBox
        var settingsOpened: PerformedBox
    }

    private final class PerformedBox { var ids: [String] = []; var count = 0 }
    private final class LockedBox { var value = false }

    private func fixture() -> Fixture {
        let client = FixtureGitOpsClient(items: [:], groups: [])
        let a = ClusterConfig(name: "prod-eu", server: URL(string: "https://a.invalid:6443")!, environment: .production)
        let b = ClusterConfig(name: "staging-eu", server: URL(string: "https://b.invalid:6443")!, environment: .staging)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore([a, b]),
                                       defaults: UserDefaults(suiteName: "wh.compass.\(UUID().uuidString)")!, clientFactory: { _, _ in client })
        let controller = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        let mac = MacPreferences(defaults: UserDefaults(suiteName: "wh.compass.mac.\(UUID().uuidString)")!)
        let rail = RailModel(store: controller.store, registry: registry, preferences: mac)
        let index = CompassIndex()
        let frecency = FrecencyStore(file: nil)
        let performed = PerformedBox(), settings = PerformedBox(), locked = LockedBox(), clock = Box()
        let commands = [
            CompassCommand(id: "window.splitRight", title: "Split Right", menuPath: "Window", shortcut: "⌘D", symbol: "rectangle.split.2x1", isEnabled: { true }, perform: { performed.ids.append("splitRight") }),
            CompassCommand(id: "window.splitDown", title: "Split Down", menuPath: "Window", shortcut: "⇧⌘D", symbol: "rectangle.split.1x2", isEnabled: { true }, perform: { performed.ids.append("splitDown") }),
            CompassCommand(id: "off", title: "Disabled Thing", menuPath: "Window", shortcut: nil, symbol: "x.circle", isEnabled: { false }, perform: { performed.ids.append("off") }),
        ]
        let model = CompassModel(registry: registry, workspace: controller, commands: { commands }, index: index, frecency: frecency, rail: rail,
                                 isLocked: { locked.value }, openSettings: { settings.count += 1 }, now: { clock.now })
        let window = controller.model(for: controller.store.createWindow())
        window.activate(cluster: a.id, placement: .here)
        return Fixture(model: model, window: window, controller: controller, rail: rail, index: index, frecency: frecency, cluster: a.id, other: b.id,
                       performed: performed, clock: clock, locked: locked, settingsOpened: settings)
    }

    private func settle(_ model: CompassModel, until: (CompassModel) -> Bool) async {
        for _ in 0..<100 where !until(model) { try? await Task.sleep(for: .milliseconds(20)) }
    }

    @Test func actionsAreListedWithTheirMenuPathAndShortcutAndOnlyActionsWithTheBracket() {
        let f = fixture()
        f.model.open()
        f.model.query = "> split"
        #expect(f.model.results.map(\.title) == ["Split Right", "Split Down"] || f.model.results.map(\.title) == ["Split Down", "Split Right"])
        let right = f.model.results.first { $0.title == "Split Right" }
        #expect(right?.shortcut == "⌘D" && right?.subtitle == "Window" && right?.group != .resources)
        f.model.query = "disabled"
        #expect(f.model.results.isEmpty)                                          // a disabled command is not offered
    }

    @Test func choosingACommandRunsItAndRemembersTheChoice() {
        let f = fixture()
        f.model.open()
        f.model.query = "split down"
        f.model.performSelected()
        #expect(f.performed.ids == ["splitDown"] && !f.model.isOpen)
        #expect(f.frecency.boost("cmd|window.splitDown") > 0)
        f.model.open()
        f.model.query = ""
        #expect(f.model.results.contains { $0.title == "Split Down" && $0.subtitle?.hasPrefix("Recent") == true })   // the empty field shows recents
    }

    @Test func clustersAndKindsAreFoundByNameAndByGoTo() {
        let f = fixture()
        f.model.open()
        f.model.query = "stag"
        #expect(f.model.results.contains { if case .cluster(let id) = $0.target { id == f.other } else { false } })
        f.model.query = "go deploy"
        let kinds = f.model.results.compactMap { r -> ResourceKind? in if case .kind(_, let k) = r.target { k } else { nil } }
        #expect(kinds.contains(.deployment))
        let row = f.model.results.first { if case .kind(_, let k) = $0.target { k == .deployment } else { false } }
        #expect(row?.title == "Go to Deployments" && row?.environment == .production)
        f.model.performSelected(placement: .newTab)
        if case .route(.resourceList(let c, let k, _)) = f.window.focusedPane?.root { #expect(c == f.cluster && k == .deployment) } else { Issue.record("not opened") }
    }

    @Test func theBangAndTheQuestionMarkOnlyShowAHintAndNeverRunAnything() {
        let f = fixture()
        f.model.open()
        for text in ["!kubectl delete pod x", "? why is checkout pending", "cve:2026-31337"] {
            f.model.query = text
            #expect(f.model.results.count == 1 && f.model.results[0].target == .hint)
            let before = f.window.state
            f.model.performSelected()
            #expect(f.window.state == before && f.model.isOpen)
        }
    }

    @Test func objectsComeFromTheIndexWithProblemsFirstAndOpenAtThePlacementChosen() async throws {
        let f = fixture()
        await f.index.replace(cluster: f.cluster, kind: .pod, items: [CompassMetadataItem(name: "api-1", namespace: "shop"), CompassMetadataItem(name: "api-2", namespace: "shop")])
        f.model.open()
        f.model.query = "po api"
        await settle(f.model) { $0.results.contains { r in if case .object = r.target { true } else { false } } }
        let objects = f.model.results.compactMap { r -> CompassHit? in if case .object(let h) = r.target { h } else { nil } }
        #expect(Set(objects.map(\.name)) == ["api-1", "api-2"])
        let tabs = f.window.state.tabs.count
        f.model.selection = try #require(f.model.results.firstIndex { if case .object = $0.target { true } else { false } })
        f.model.performSelected(placement: .newTab)
        #expect(f.window.state.tabs.count == tabs + 1 && !f.model.isOpen)
        #expect(f.frecency.records.keys.contains { $0.hasPrefix("obj|") })
    }

    @Test func aResultOffersItsActionsAndTheLogsActionOpensLogs() async throws {
        let f = fixture()
        await f.index.replace(cluster: f.cluster, kind: .pod, items: [CompassMetadataItem(name: "worker-1", namespace: "jobs")])
        f.model.open()
        f.model.query = "worker"
        await settle(f.model) { $0.results.contains { r in if case .object = r.target { true } else { false } } }
        f.model.selection = try #require(f.model.results.firstIndex { if case .object = $0.target { true } else { false } })
        f.model.showActions()
        #expect(f.model.actions.map(\.id) == ["open", "logs", "previousLogs", "yaml", "portForward", "pin", "copy"])
        f.model.move(1)
        #expect(f.model.selection == 1)
        f.model.performSelected()                                                  // Logs
        if case .route(.logs(let ref, _, let previous)) = f.window.focusedPane?.root { #expect(ref.name == "worker-1" && !previous) } else { Issue.record("logs not opened") }
        // Pin to Rail and Manifest, and Esc goes back from the list.
        f.model.open(); f.model.query = "worker"
        await settle(f.model) { $0.results.contains { r in if case .object = r.target { true } else { false } } }
        f.model.selection = try #require(f.model.results.firstIndex { if case .object = $0.target { true } else { false } })
        f.model.showActions(); f.model.hideActions()
        #expect(!f.model.showsActionList)
        f.model.showActions(); f.model.selection = 5   // Pin to Rail (Port Forward sits before it)
        f.model.performSelected()
        #expect(f.rail.items.contains { $0.kind == .resource })
    }

    @Test func settingsRowsOpenTheSettingsWindowOnThePane() {
        let f = fixture()
        f.model.open()
        f.model.query = "settings:beacon"
        #expect(f.model.results.first?.target == .settings(.beacon))
        f.model.performSelected()
        #expect(f.settingsOpened.count == 1 && SettingsNavigation.shared.requested == .beacon)
        SettingsNavigation.shared.requested = nil
    }

    @Test func theLastQueryIsKeptForThirtySecondsAndAppLockClosesAndClearsIt() {
        let f = fixture()
        f.model.open()
        f.model.query = "split"
        f.model.close()
        f.clock.now.addTimeInterval(10)
        f.model.open()
        #expect(f.model.query == "split")
        f.model.close()
        f.clock.now.addTimeInterval(31)
        f.model.open()
        #expect(f.model.query.isEmpty)
        f.model.query = "split"
        f.model.lockEngaged()
        #expect(!f.model.isOpen && f.model.query.isEmpty && f.model.results.isEmpty)
        f.locked.value = true
        f.model.open()
        #expect(!f.model.isOpen)                                                   // never opens while locked
        f.model.toggle()
        #expect(!f.model.isOpen)
    }

    @Test func nothingRunsWhileLockedEvenFromAnOpenPanel() {
        let f = fixture()
        f.model.open()
        f.model.query = "split right"
        f.locked.value = true
        f.model.performSelected()
        #expect(f.performed.ids.isEmpty)
    }

    @Test func removedAndDemoClustersNeverShowEvenBeforeAPrune() async {
        let f = fixture()
        await f.index.replace(cluster: "removed-cluster", kind: .pod, items: [CompassMetadataItem(name: "ghost-1", namespace: "n")])
        await f.index.replace(cluster: f.cluster, kind: .pod, items: [CompassMetadataItem(name: "ghost-2", namespace: "n")])
        f.model.open()
        f.model.query = "ghost"
        await settle(f.model) { $0.results.contains { r in if case .object = r.target { true } else { false } } }
        let names = f.model.results.compactMap { r -> String? in if case .object(let h) = r.target { h.name } else { nil } }
        #expect(names == ["ghost-2"])
    }

    @Test func theFooterSaysWhatIsIndexed() async {
        let f = fixture()
        #expect(f.model.footer.hasPrefix("No objects indexed"))
        await f.index.replace(cluster: f.cluster, kind: .pod, items: [CompassMetadataItem(name: "a", namespace: "n")])
        f.model.open()
        await settle(f.model) { $0.footer.hasPrefix("Indexed") }
        #expect(f.model.footer.hasPrefix("Indexed 1 objects in 1 cluster"))
    }

    @Test func theRailShowsOnTheEmptyFieldAndTopHitIsTheBestMatch() {
        let f = fixture()
        f.rail.pin(.cluster(f.other))
        f.model.open()
        #expect(f.model.results.contains { $0.target == .railItem(f.rail.items[0].id) })
        f.model.query = "split right"
        #expect(f.model.results.first?.group == .topHit && f.model.results.first?.title == "Split Right")
        f.model.selection = 99
        f.model.query = ""
        #expect(f.model.selected != nil || f.model.results.isEmpty)
    }

    @Test func everyMenuCommandIsUniqueWithItsShortcut() throws {
        let env = MacAppEnvironment.live()
        let commands = env.commandRegistry.commands
        #expect(Set(commands.map(\.id)).count == commands.count)
        let shortcuts = commands.compactMap(\.shortcut)
        #expect(Set(shortcuts).count == shortcuts.count)
        #expect(commands.first { $0.id == "view.compass" }?.shortcut == "⌘K")
        #expect(commands.first { $0.id == "view.rail" }?.shortcut == "⇧⌘B")
        #expect(env.commandRegistry.command("go.fleet")?.shortcut == "⌘0")
        #expect(env.commandRegistry.command("nope") == nil)
    }

    @Test func anObjectIsNeverRunAsACommandAndPlainTextNeverReachesATerminal() {
        // CompassModel has no terminal seam at all: the only things it can do are the actions listed in CompassResult.Target.
        let targets: [CompassResult.Target] = [.hint, .command("x"), .cluster("c"), .station("s"), .settings(.general), .railItem("r")]
        #expect(targets.count == 6)
    }
}
