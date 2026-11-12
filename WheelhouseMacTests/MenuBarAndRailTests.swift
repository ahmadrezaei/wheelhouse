import AppKit
import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// M4b: Crow's Nest, the activation policy, the login item, the Rail and the periodic-work audit.
@MainActor
@Suite("MenuBarAndRailTests")
struct MenuBarAndRailTests {
    // MARK: Fixtures

    private struct Fixture {
        let registry: ClusterRegistry
        let controller: WorkspaceController
        let mac: MacPreferences
        let rail: RailModel
        let ids: [ClusterEnvironment: ClusterID]
    }

    private func defaults() -> UserDefaults { UserDefaults(suiteName: "wh.m4b.\(UUID().uuidString)")! }

    private func fixture(file: URL? = nil, environments: [ClusterEnvironment] = [.development, .staging, .production]) -> Fixture {
        let client = FixtureGitOpsClient(items: [:], groups: [])
        let configs = environments.enumerated().map { i, env in
            ClusterConfig(name: "cluster-\(i)-\(env.rawValue)", server: URL(string: "https://example\(i).invalid:6443")!, environment: env)
        }
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(configs), defaults: defaults(), clientFactory: { _, _ in client })
        let store = WorkspaceStore(file: file)
        let controller = WorkspaceController(store: store, registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        let mac = MacPreferences(defaults: defaults())
        return Fixture(registry: registry, controller: controller, mac: mac, rail: RailModel(store: store, registry: registry, preferences: mac),
                       ids: Dictionary(configs.map { ($0.environment, $0.id) }, uniquingKeysWith: { first, _ in first }))
    }

    // MARK: Fleet summary

    @Test func theSummaryFollowsTheWorstAttentionItem() {
        func item(_ s: HealthStatus) -> AttentionItem { AttentionItem(id: UUID().uuidString, clusterID: "c", severity: s, kind: .unreachable, title: "t", detail: "d") }
        #expect(FleetSummary.make(attention: [], clusterCount: 3) == FleetSummary(level: .healthy, attentionCount: 0, clusterCount: 3))
        #expect(FleetSummary.make(attention: [item(.warning), item(.unknown)], clusterCount: 2).level == .warning)
        let critical = FleetSummary.make(attention: [item(.warning), item(.critical)], clusterCount: 2)
        #expect(critical.level == .critical && critical.attentionCount == 2)
    }

    // MARK: Crow's Nest checks

    @Test func theMonitorChecksProductionStagingRailAndWatchedClustersOnly() {
        let f = fixture(environments: [.development, .development, .staging, .production, .personal])
        let dev = f.registry.clusters.filter { $0.environment == .development }.map(\.id)
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [dev[0]] }, process: { _, _ in })
        func names() -> Set<String> { Set(monitor.watched().map(\.config.name)) }
        #expect(names() == ["cluster-0-development", "cluster-2-staging", "cluster-3-production"])   // Rail + staging + production
        f.mac.watchedClusterIDs = [dev[1]]
        #expect(names().contains("cluster-1-development"))
        #expect(!names().contains("cluster-4-personal"))
    }

    @Test func aCheckPostsAlertsFromMenuBarModeThroughTheInjectedCenter() async {
        let f = fixture()
        let periodic = PeriodicTaskRegistry()
        periodic.setWindowsVisible(false)                           // menu-bar mode: no window
        var processed: [[ClusterHealth]] = []
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                      process: { health, _ in processed.append(health) }, alertSettings: { AlertSettings() }, periodicRegistry: periodic)
        await monitor.tick()
        await monitor.tick()
        #expect(processed.count == 2 && processed[1].count == 2)    // staging and production; the development cluster is not watched
        #expect(monitor.checks == 2 && monitor.lastCheck != nil)
        // Alerts off: the check still updates the summary and posts nothing.
        let quiet = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                    process: { _, _ in Issue.record("posted with alerts off") }, alertSettings: { var s = AlertSettings(); s.enabled = false; return s })
        await quiet.tick(force: true)
        #expect(quiet.checks == 1)
    }

    @Test func withNoWindowACheckIsAProbeAndTheFullEvaluationIsSlowAndOneClusterAtATime() async {
        let f = fixture()                                           // development, staging, production
        let periodic = PeriodicTaskRegistry()
        periodic.setWindowsVisible(false)
        let box = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                      process: { _, _ in }, now: { box.value }, alertSettings: { AlertSettings() }, periodicRegistry: periodic)
        await monitor.tick()
        #expect(monitor.deepChecks == 1)                            // never-evaluated clusters go one per check
        await monitor.tick()
        #expect(monitor.deepChecks == 2)
        await monitor.tick()
        #expect(monitor.deepChecks == 2)                            // a probe only
        box.value.addTimeInterval(301)
        await monitor.tick()
        #expect(monitor.deepChecks == 3)                            // production is due after 5 minutes, staging is not
        box.value.addTimeInterval(301)
        await monitor.tick()
        #expect(monitor.deepChecks == 4)                            // production again; staging waits for 15 minutes
        box.value.addTimeInterval(301)
        await monitor.tick()
        #expect(monitor.deepChecks == 5)                            // staging is the most overdue
        await monitor.tick()
        #expect(monitor.deepChecks == 6)                            // one per check: production follows
        await monitor.tick()
        #expect(monitor.deepChecks == 6)
    }

    @Test func pausingStopsChecksForAnHourAndAForcedCheckStillRuns() async {
        let f = fixture()
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        let box = ClockBox(clock)
        var count = 0
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                      process: { _, _ in count += 1 }, now: { box.value }, alertSettings: { AlertSettings() })
        monitor.pause()
        #expect(monitor.isPaused)
        await monitor.tick()
        #expect(count == 0)
        await monitor.tick(force: true)
        #expect(count == 1)
        clock.addTimeInterval(3_601); box.value = clock
        #expect(!monitor.isPaused)
        await monitor.tick()
        #expect(count == 2)
        monitor.pause(); monitor.resume()
        #expect(!monitor.isPaused)
    }

    @Test func thermalCriticalChecksOnlyProductionClusters() async {
        let f = fixture()
        var seen: [Int] = []
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                      process: { health, _ in seen.append(health.count) },
                                      policy: { EnergyPolicy(isLowPowerMode: false, thermalState: .critical) }, alertSettings: { AlertSettings() })
        await monitor.tick()
        #expect(seen == [1])
    }

    // MARK: Periodic work audit (ARCHITECTURE-MAC 12.3.4 item 7)

    @Test func withNoWindowVisibleOnlyTheCrowsNestCheckRunsAndNeverUnderAMinute() {
        let f = fixture()
        let periodic = PeriodicTaskRegistry()
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] }, process: { _, _ in }, periodicRegistry: periodic)
        let indexer = CompassMetadataIndexer(index: CompassIndex(), registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        // The alert monitor stops while Crow's Nest is on; the others of the app have no hidden cadence.
        let sidebar = PeriodicTask(name: "sidebar.badges", interval: 5, hiddenInterval: nil, registry: periodic) {}
        let alerts = PeriodicTask(name: "alerts.health", interval: 60, hiddenInterval: nil, registry: periodic) {}
        for t in [sidebar, alerts] { t.start() }
        monitor.start(); indexer.start()
        alerts.stop()
        defer { for t in [sidebar] { t.stop() }; monitor.stop(); indexer.stop() }
        let visible = periodic.effectiveIntervals(windowsVisible: true).map(\.name)
        #expect(visible.contains("crowsnest.health") && visible.contains("compass.index") && !visible.contains("alerts.health"))
        let hidden = periodic.effectiveIntervals(windowsVisible: false)
        #expect(hidden.map(\.name) == ["crowsnest.health"])            // the metadata index stops with no window visible
        #expect(hidden.allSatisfy { $0.interval >= 60 })
        let info = periodic.snapshot().first { $0.name == "crowsnest.health" }
        #expect(info?.interval == 60 && info?.hiddenInterval == 60 && info?.tolerance == 30)
        // Thermal serious doubles it, never shortens it.
        #expect(periodic.effectiveIntervals(windowsVisible: false, policy: EnergyPolicy(isLowPowerMode: true)).allSatisfy { $0.interval >= 120 })
    }

    @Test func theIndexerOnlyRefreshesWhileAWindowIsVisibleAndStopsOnCriticalMemory() async {
        let f = fixture()
        let periodic = PeriodicTaskRegistry()
        f.mac.compassIndexedClusterIDs = Set(f.registry.clusters.map(\.id))
        let index = CompassIndex()
        let indexer = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        periodic.setWindowsVisible(false)
        await indexer.tick()
        #expect(indexer.refreshes == 0)
        periodic.setWindowsVisible(true)
        await indexer.tick()
        #expect(indexer.refreshes == 1)
        indexer.memoryPressure(critical: true, focused: [])
        #expect(indexer.stopped)
        await indexer.tick()
        #expect(indexer.refreshes == 1)
        indexer.resumeIfStopped()
        await indexer.tick()
        #expect(indexer.refreshes == 2)
        indexer.memoryPressure(critical: false, focused: [])
        // On battery every second tick is skipped.
        let battery = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, onBattery: { true }, periodicRegistry: periodic)
        await battery.tick(); await battery.tick(); await battery.tick(); await battery.tick()
        #expect(battery.refreshes == 2)
    }

    @Test func theIndexerListsMetadataPagesAndKeepsOldEntriesOnFailure() async throws {
        let f = fixture(environments: [.development])
        let id = try #require(f.registry.clusters.first?.id)
        let index = CompassIndex()
        let periodic = PeriodicTaskRegistry()
        let indexer = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        let pages = PagedSource()
        await indexer.refreshMetadata(cluster: id, fetch: { try await pages.page($0, $1, $2) })
        let hits = await index.search(.parse("web"))
        #expect(hits.filter { $0.kind == .pod }.map(\.name).sorted() == ["web-1", "web-2"])     // two pages joined
        #expect(pages.kinds.contains("Secret"))
        #expect(await index.search(.parse("db-credentials")).map(\.name) == ["db-credentials"])
        #expect(await index.search(.parse("leak-sentinel")).isEmpty)
        pages.fail = true
        await indexer.refreshMetadata(cluster: id, fetch: { try await pages.page($0, $1, $2) })
        #expect(await index.search(.parse("web")).filter { $0.kind == .pod }.count == 2)         // the failed refresh left them
    }

    @Test func theIndexerStartsOverAfterACriticalWarningEvenWithAWindowVisible() async {
        let f = fixture()
        let periodic = PeriodicTaskRegistry()
        f.mac.compassIndexedClusterIDs = Set(f.registry.clusters.map(\.id))
        let indexer = CompassMetadataIndexer(index: CompassIndex(), registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        indexer.memoryPressure(critical: true, focused: [])
        await indexer.tick()
        #expect(indexer.refreshes == 0 && indexer.stopped)
        await indexer.tick()                                        // one scheduled interval later
        #expect(!indexer.stopped && indexer.refreshes == 1)
    }

    @Test func removedOptedOutAndDemoClustersLeaveTheIndex() async throws {
        let f = fixture(environments: [.development, .staging])
        let a = try #require(f.ids[.development]), b = try #require(f.ids[.staging])
        let index = CompassIndex()
        let periodic = PeriodicTaskRegistry()
        f.mac.compassIndexedClusterIDs = [a, b]
        let indexer = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        await index.replace(cluster: "removed-cluster", kind: .secret, items: [CompassMetadataItem(name: "old-secret", namespace: "n")])
        await indexer.refresh()
        await index.replace(cluster: a, kind: .secret, items: [CompassMetadataItem(name: "a-secret", namespace: "n")])
        #expect(!(await index.indexedClusters).contains("removed-cluster"))
        f.mac.compassIndexedClusterIDs = [b]                        // a opts out
        await indexer.refresh()
        #expect(await index.search(.parse("a-secret")).isEmpty)
        f.registry.enterDemoMode(persist: false)
        await indexer.refresh()
        #expect(await index.indexedClusters.isEmpty)
    }

    @Test func commandNumbersReachTheFirstClustersWhileTheRailIsEmpty() throws {
        let f = fixture()
        #expect(f.rail.items.isEmpty && f.rail.item(number: 2)?.clusterID == f.registry.clusters[1].id && f.rail.shortcutItems.count == 3)
        f.rail.pin(.cluster(f.registry.clusters[2].id))
        #expect(f.rail.item(number: 1)?.clusterID == f.registry.clusters[2].id && f.rail.item(number: 2) == nil)
    }

    @Test func aLinkWhileLockedWithNoWindowAsksForAWindowThatShowsTheLockScreen() {
        let f = fixture()
        var asked = 0
        f.controller.needsWindow = { asked += 1 }
        f.controller.isLocked = { true }
        f.controller.handle(url: URL(string: "wheelhouse://cluster/x")!)
        #expect(asked == 1 && f.controller.pendingURL != nil)
    }

    @Test func aRecoveredClusterIsEvaluatedAtTheNextMenuBarCheck() async {
        let f = fixture(environments: [.production])
        let periodic = PeriodicTaskRegistry()
        periodic.setWindowsVisible(false)
        let box = ClockBox(Date(timeIntervalSince1970: 1_800_000_000))
        let monitor = MacFleetMonitor(registry: f.registry, preferences: AppPreferences(defaults: defaults()), mac: f.mac, railClusters: { [] },
                                      process: { _, _ in }, now: { box.value }, alertSettings: { AlertSettings() }, periodicRegistry: periodic)
        await monitor.tick()                                        // evaluated once, healthy
        #expect(monitor.deepChecks == 1)
        let session = f.registry.session(for: f.registry.clusters[0].id)
        #expect(session?.health?.isReachable == true)
    }

    @Test func pruneHidesRemovedOptedOutAndDemoClustersWithoutAListing() async throws {
        let f = fixture(environments: [.development, .staging])
        let a = try #require(f.ids[.development]), b = try #require(f.ids[.staging])
        let index = CompassIndex()
        let indexer = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, periodicRegistry: PeriodicTaskRegistry())
        f.mac.compassIndexedClusterIDs = [a, b]
        await index.replace(cluster: "removed", kind: .configMap, items: [CompassMetadataItem(name: "old-config", namespace: "n")])
        await index.replace(cluster: a, kind: .configMap, items: [CompassMetadataItem(name: "a-config", namespace: "n")])
        await index.replace(cluster: b, kind: .configMap, items: [CompassMetadataItem(name: "b-config", namespace: "n")])
        await indexer.refresh()                                                   // marks a and b as metadata-indexed
        await index.replace(cluster: a, kind: .configMap, items: [CompassMetadataItem(name: "a-config", namespace: "n")])
        await index.replace(cluster: "removed", kind: .configMap, items: [CompassMetadataItem(name: "old-config", namespace: "n")])
        let before = indexer.refreshes
        await indexer.prune()
        let afterPrune = await index.indexedClusters
        #expect(!afterPrune.contains("removed"))                                   // no refresh, no listing
        f.mac.compassIndexedClusterIDs = [b]
        await indexer.prune()
        let aHits = await index.search(.parse("a-config")), bHits = await index.search(.parse("b-config"))
        #expect(aHits.isEmpty && !bHits.isEmpty)
        f.registry.enterDemoMode(persist: false)
        await indexer.prune()
        let remaining = await index.indexedClusters
        #expect(remaining.isEmpty && indexer.refreshes == before)
    }

    @Test func theOptInChangeAndTheClusterListPruneTheIndexAtOnce() async throws {
        let env = MacAppEnvironment.live()
        let id = try #require(env.registry.clusters.first?.id) as ClusterID
        env.frecency.record("obj|gone-cluster|v1/pods|n|a"); env.frecency.record("obj|\(id)|v1/pods|n|b"); env.frecency.record("cmd|x")
        await env.compassIndex.replace(cluster: "gone-cluster", kind: .pod, items: [CompassMetadataItem(name: "ghost", namespace: "n")])
        env.pruneCompass()
        for _ in 0..<50 where !(await env.compassIndex.indexedClusters).isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        let left = await env.compassIndex.indexedClusters
        #expect(left.isEmpty)
        #expect(env.frecency.records.keys.contains("cmd|x") && !env.frecency.records.keys.contains("obj|gone-cluster|v1/pods|n|a"))
    }

    @Test func aCancelledRefreshNeverCommitsAPartialKind() async throws {
        let f = fixture(environments: [.development])
        let id = try #require(f.registry.clusters.first?.id)
        let index = CompassIndex()
        let indexer = CompassMetadataIndexer(index: index, registry: f.registry, mac: f.mac, periodicRegistry: PeriodicTaskRegistry())
        await index.replace(cluster: id, kind: .pod, items: [CompassMetadataItem(name: "keep-me", namespace: "n")])
        let task = Task { @MainActor in
            await indexer.refreshMetadata(cluster: id, fetch: { kind, token, _ in
                // The first page of Pods arrives and the task is cancelled before the second.
                if kind.kind == "Pod", token == nil {
                    withUnsafeCurrentTask { $0?.cancel() }
                    return CompassMetadataPage(items: [CompassMetadataItem(name: "partial", namespace: "n")], continueToken: "more")
                }
                return CompassMetadataPage(items: [])
            })
        }
        await task.value
        #expect(await index.search(.parse("partial")).isEmpty)
        #expect(await index.search(.parse("keep-me")).map(\.name) == ["keep-me"])
    }

    @Test func twoRefreshesNeverRunTogether() async {
        let f = fixture()
        f.mac.compassIndexedClusterIDs = Set(f.registry.clusters.map(\.id))
        let periodic = PeriodicTaskRegistry()
        let indexer = CompassMetadataIndexer(index: CompassIndex(), registry: f.registry, mac: f.mac, periodicRegistry: periodic)
        async let first: Void = indexer.refresh()
        async let second: Void = indexer.refresh()
        _ = await (first, second)
        #expect(indexer.refreshes + indexer.overlapsSkipped == 2 && !indexer.isRefreshing)
    }

    @Test func aRailItemKeepsTheFieldsAThisBuildDoesNotKnowThroughRenameAndMove() throws {
        let f = fixture()
        let b = try #require(f.ids[.staging])
        let future: JSONValue = ["id": "k1", "kind": "cluster", "clusterID": .string(b), "shortcut": "F5", "pack": ["name": "x"]]
        f.controller.store.setRail([future, ["id": "k2", "kind": "cluster", "clusterID": .string(b), "title": "Old"]])
        f.rail.rename("k1", to: "Renamed")
        f.rail.move("k1", before: nil)
        f.rail.rename("k2", to: "")
        let stored = f.controller.store.rail
        guard case .object(let first) = stored[1], case .object(let second) = stored[0] else { Issue.record("shape"); return }
        #expect(first["shortcut"] == "F5" && first["pack"] == ["name": "x"] && first["title"] == "Renamed")
        #expect(second["title"] == nil && second["id"] == "k2")                  // an emptied name is removed, not kept from the old JSON
    }

    @Test func demoModeHidesTheRailAndNumbersFallBackToTheClusters() {
        let f = fixture()
        f.rail.pin(.cluster("gone"))                                              // a Rail with nothing available
        #expect(f.rail.shortcutItems.count == 3 && f.rail.shortcutItems.allSatisfy { f.rail.isAvailable($0) })
        f.rail.pin(.cluster(f.registry.clusters[0].id))
        #expect(f.rail.shortcutItems.count == 2)                                  // one available item: the Rail itself
        f.registry.enterDemoMode(persist: false)
        #expect(f.rail.shortcutItems.allSatisfy { $0.id.hasPrefix("auto-") } && !f.rail.shortcutItems.isEmpty)
    }

    // MARK: Activation policy

    @Test func theActivationPolicyIsAccessoryOnlyWithNoWindowAndKeepRunning() {
        #expect(ActivationPolicyController.policy(keepsRunning: true, hasContentWindow: false) == .accessory)
        #expect(ActivationPolicyController.policy(keepsRunning: true, hasContentWindow: true) == .regular)
        #expect(ActivationPolicyController.policy(keepsRunning: false, hasContentWindow: false) == .regular)
        #expect(!ActivationPolicyController.hasContentWindow([]))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        #expect(!ActivationPolicyController.hasContentWindow([window]))        // never shown
    }

    @Test func theControllerSwitchesWhenTheLastWindowLeavesAndBeforeOneOpens() {
        var keeps = true
        var current = NSApplication.ActivationPolicy.regular
        let controller = ActivationPolicyController(keepsRunning: { keeps }, windows: { [] }, currentPolicy: { current }, apply: { current = $0 })
        controller.evaluate()
        #expect(current == .accessory && controller.switches == 1)
        controller.evaluate()
        #expect(controller.switches == 1)                                      // no change, no call
        controller.prepareForWindow()
        #expect(current == .regular)
        controller.evaluate()
        #expect(current == .accessory)
        keeps = false
        controller.evaluate()
        #expect(current == .regular)
    }

    @Test func theControllerStaysOutOfQuitAndOfKeepVisibleRuns() {
        var current = NSApplication.ActivationPolicy.regular
        let controller = ActivationPolicyController(keepsRunning: { true }, windows: { [] }, currentPolicy: { current }, apply: { current = $0 })
        controller.isTerminating = true
        controller.evaluate()
        #expect(current == .regular)
        controller.isTerminating = false
        controller.isInert = true
        controller.evaluate()
        controller.prepareForWindow()
        #expect(current == .regular && controller.switches == 0)
    }

    // MARK: Login item

    @Test func theLoginItemIsInertInDevelopmentBuildsAndInTests() throws {
        let gated = LoginItems.make(gateActive: true, environment: [:])
        #expect(gated is InertLoginItem && gated.status == .unavailable)
        // A test process is inert even if the gate were off.
        let testProcess = LoginItems.make(gateActive: false, environment: ["XCTestConfigurationFilePath": "/x"])
        #expect(testProcess is InertLoginItem)
        try testProcess.setEnabled(true)
        let inert = try #require(testProcess as? InertLoginItem)
        #expect(inert.requested && inert.requests == 1 && inert.status == .unavailable)
        // The running test process itself is inert whatever the gate says.
        #expect(LoginItems.make(gateActive: false) is InertLoginItem)
    }

    // MARK: Preferences

    @Test func menuBarPreferencesPersistExceptTransientOnes() {
        let d = defaults()
        let mac = MacPreferences(defaults: d)
        #expect(!mac.showsCrowsNest && !mac.keepsRunningInMenuBar && mac.showsRail && mac.menuBarBadge == .dot)
        var changes = 0
        mac.menuBarChanged = { changes += 1 }
        mac.showsCrowsNest = true; mac.keepsRunningInMenuBar = true; mac.menuBarBadge = .dotAndCount; mac.watchedClusterIDs = ["a"]; mac.compassIndexedClusterIDs = ["b"]
        #expect(changes == 2)
        let reloaded = MacPreferences(defaults: d)
        #expect(reloaded.showsCrowsNest && reloaded.keepsRunningInMenuBar && reloaded.menuBarBadge == .dotAndCount && reloaded.watchedClusterIDs == ["a"] && reloaded.compassIndexedClusterIDs == ["b"])
        mac.transient { $0.showsCrowsNest = false; $0.watchedClusterIDs = ["z"] }
        #expect(!mac.showsCrowsNest)
        #expect(MacPreferences(defaults: d).showsCrowsNest && MacPreferences(defaults: d).watchedClusterIDs == ["a"])   // nothing was saved
    }

    // MARK: Rail

    @Test func theRailPinsOnceReordersRenamesAndRemoves() throws {
        let f = fixture()
        let a = try #require(f.ids[.development]), b = try #require(f.ids[.staging]), c = try #require(f.ids[.production])
        #expect(f.rail.pin(.cluster(a)) && f.rail.pin(.cluster(b)) && f.rail.pin(.cluster(c)))
        #expect(!f.rail.pin(.cluster(a)))                                           // the same pin is one item
        #expect(f.rail.item(number: 1)?.clusterID == a && f.rail.item(number: 3)?.clusterID == c && f.rail.item(number: 4) == nil && f.rail.item(number: 0) == nil)
        let first = f.rail.items[0].id, last = f.rail.items[2].id
        f.rail.move(last, before: first)
        #expect(f.rail.items.map(\.clusterID) == [c, a, b])
        f.rail.move(last, before: nil)
        #expect(f.rail.items.map(\.clusterID) == [a, b, c])
        f.rail.rename(first, to: "Dev box")
        #expect(f.rail.title(for: f.rail.items[0]) == "Dev box")
        f.rail.rename(first, to: "  ")
        #expect(f.rail.title(for: f.rail.items[0]) == "cluster-0-development")
        f.rail.remove(first)
        #expect(f.rail.items.count == 2 && f.mac.railCustomised)
        #expect(f.rail.clusterIDs == [b, c])
        #expect(f.rail.title(for: .namespace("payments", in: b)) == "payments @ cluster-1-staging")
        let ref = ResourceRef(clusterID: b, kind: .deployment, namespace: "shop", name: "web")
        #expect(f.rail.title(for: .resource(ref)) == "deployment web")
        #expect(f.rail.isAvailable(.cluster(b)) && !f.rail.isAvailable(.cluster("gone")) && !f.rail.isAvailable(.station("none")) && f.rail.isAvailable(.station(BuiltInStations.all[0].id)))
        #expect(f.rail.title(for: .cluster("gone")) == "Removed cluster")
        #expect(f.rail.title(for: .station("none")) == "Station")
    }

    @Test func theRailKeepsItemsFromANewerBuildAndSurvivesARestart() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "rail-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appending(path: "workspace.json")
        let f = fixture(file: file)
        let future: JSONValue = ["id": "x1", "kind": "riggingCommand", "payload": ["pack": "cert-manager", "n": 3]]
        f.controller.store.setRail([future])
        let b = try #require(f.ids[.staging])
        f.rail.pin(.cluster(b))
        #expect(f.rail.items.count == 1)                                           // the newer item takes no slot and no ⌘ number
        f.rail.move(f.rail.items[0].id, before: nil)
        f.controller.store.flush()
        let reopened = WorkspaceStore(file: file)
        #expect(reopened.rail.count == 2 && reopened.rail[0] == future)           // unchanged and still first
        #expect(RailModel(store: reopened, registry: f.registry, preferences: f.mac).items.first?.clusterID == b)
    }

    @Test func prefillRunsOnceNinePinnedAndNewClustersJoinUntilFive() throws {
        let f = fixture(environments: Array(repeating: .development, count: 11))
        f.rail.prefillOnce()
        #expect(f.rail.items.count == 5 && f.mac.railPrefilled)
        f.rail.remove(f.rail.items[0].id)
        f.rail.prefillOnce()
        #expect(f.rail.items.count == 4)                                           // never refilled
        // A fresh install: the first clusters pin themselves as they are added.
        let g = fixture(environments: [.development])
        g.rail.pinNewClusters()
        #expect(g.rail.items.isEmpty)                                              // not before the first run
        g.rail.prefillOnce()
        #expect(g.rail.items.count == 1)
        let h = fixture(environments: Array(repeating: .development, count: 7))
        h.mac.railPrefilled = true
        h.rail.pinNewClusters()
        #expect(h.rail.items.count == 5)
        let custom = fixture(environments: [.development, .development])
        custom.mac.railPrefilled = true; custom.mac.railCustomised = true
        custom.rail.pinNewClusters()
        #expect(custom.rail.items.isEmpty)
        let demo = fixture(environments: [.development])
        demo.registry.enterDemoMode(persist: false)
        demo.rail.prefillOnce()
        #expect(demo.rail.items.isEmpty && !demo.mac.railPrefilled)
    }

    @Test func activatingRailItemsKeepsTheViewOrOpensTabsAndSplits() throws {
        let f = fixture()
        let a = try #require(f.ids[.development]), b = try #require(f.ids[.staging])
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.show(.route(.resourceList(a, .pod, namespace: "shop")), placement: .here)
        f.rail.activate(.cluster(b), in: model, placement: .here, controller: f.controller)
        #expect(model.focusedPane?.context.clusterID == b)
        if case .route(.resourceList(let c, let kind, _)) = model.focusedPane?.root { #expect(c == b && kind == .pod) } else { Issue.record("the view was not kept") }
        let tabs = model.state.tabs.count
        f.rail.activate(.cluster(a), in: model, placement: .newTab, controller: f.controller)
        #expect(model.state.tabs.count == tabs + 1)
        let panes = model.selectedTab.panes.count
        f.rail.activate(.cluster(b), in: model, placement: .split, controller: f.controller)
        #expect(model.selectedTab.panes.count == panes + 1)
        // Namespace and resource items.
        f.rail.activate(.namespace("payments", in: a), in: model, placement: .here, controller: f.controller)
        #expect(model.focusedPane?.context.namespace == "payments")
        let ref = ResourceRef(clusterID: a, kind: .deployment, namespace: "shop", name: "web")
        f.rail.activate(.resource(ref), in: model, placement: .here, controller: f.controller)
        #expect(model.focusedPane?.root == .route(.resourceDetail(ref)))
        // An item of a removed cluster does nothing.
        let before = model.state
        f.rail.activate(.cluster("gone"), in: model, placement: .here, controller: f.controller)
        #expect(model.state == before)
        // ⌥⌘B pins what the pane shows.
        f.rail.pinSelection(of: model)
        #expect(f.rail.items.last?.resource == ref)
        model.show(.route(.resourceList(a, .deployment, namespace: "shop")), placement: .here)
        f.rail.pinSelection(of: model)
        #expect(f.rail.items.last?.kind == .namespace)
        model.show(WorkspaceDestination(.clusterOverview(b)), placement: .here)
        f.rail.pinSelection(of: model)
        #expect(f.rail.items.last?.clusterID == b)
    }

    @Test func aStationOnTheRailAsksForClustersAndTheNewWindowPlacementOpensAWindow() throws {
        let f = fixture()
        let station = try #require(f.controller.store.stations.first)
        let model = f.controller.model(for: f.controller.store.createWindow())
        f.rail.activate(.station(station.id), in: model, placement: .here, controller: f.controller)
        #expect(model.sheet != nil)                                                // a template with several clusters to choose from
        var opened = 0
        f.controller.openWorkspaceWindow = { _ in opened += 1 }
        let a = try #require(f.ids[.development])
        model.show(WorkspaceDestination(.clusterOverview(a)), placement: .newWindow)
        #expect(opened == 1)
    }

    @Test func aNotificationLinkWithNoWindowAsksForOne() {
        let f = fixture()
        var asked = 0
        f.controller.needsWindow = { asked += 1 }
        f.controller.handle(url: URL(string: "wheelhouse://cluster/x")!)
        #expect(asked == 1 && f.controller.pendingURL != nil)      // replayed by the new window's first task
    }

    @Test func focusingAClusterTellsTheCompassIndex() throws {
        let f = fixture()
        let b = try #require(f.ids[.staging])
        var focused: [ClusterID] = []
        f.controller.clusterFocused = { focused.append($0) }
        let model = f.controller.model(for: f.controller.store.createWindow())
        model.activate(cluster: b, placement: .here)
        #expect(focused.contains(b))
    }
}

private final class ClockBox: @unchecked Sendable {
    var value: Date
    init(_ value: Date) { self.value = value }
}

/// Canned metadata pages: two pages of pods and one page of every other kind. The Secret carries a label and an owner sentinel that
/// the index must drop (a Secret keeps its name and namespace only).
private final class PagedSource: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    var fail = false
    var kinds: [String] { lock.withLock { recorded } }

    func page(_ kind: ResourceKind, _ token: String?, _ limit: Int) async throws -> CompassMetadataPage {
        lock.withLock { recorded.append(kind.kind) }
        if fail { throw KubeError.unsupported("down") }
        switch (kind.kind, token) {
        case ("Pod", nil): return CompassMetadataPage(items: [CompassMetadataItem(name: "web-1", namespace: "shop")], continueToken: "next")
        case ("Pod", _): return CompassMetadataPage(items: [CompassMetadataItem(name: "web-2", namespace: "shop")])
        case ("Secret", _): return CompassMetadataPage(items: [CompassMetadataItem(name: "db-credentials", namespace: "shop", labels: ["leak": "leak-sentinel"], ownerName: "leak-sentinel")])
        default: return CompassMetadataPage(items: [])
        }
    }
}
