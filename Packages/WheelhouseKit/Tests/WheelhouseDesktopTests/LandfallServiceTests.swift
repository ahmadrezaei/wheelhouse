#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Counts every way a cluster can be contacted: a client being built AND a credential plugin source being asked for (which is where an
/// `aws eks get-token` would run).
final class ContactCounter: MooringsClientMaking, @unchecked Sendable {
    private let state = Mutex((clients: 0, plugins: 0))
    var clients: Int { state.withLock { $0.clients } }
    var plugins: Int { state.withLock { $0.plugins } }
    var total: Int { state.withLock { $0.clients + $0.plugins } }
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol {
        state.withLock { $0.clients += 1 }
        return DemoFleet.client(for: DemoFleet.configs[0])
    }
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? {
        state.withLock { $0.plugins += 1 }
        return nil
    }
}

final class LandfallClock: @unchecked Sendable {
    private let state = Mutex(Date(timeIntervalSince1970: 1_800_000_000))
    var now: Date { state.withLock { $0 } }
    func advance(_ s: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(s) } }
}

/// Landfall on top of a real MooringsService (open gate, scratch home, first run completed) with a counting fake client.
final class LandfallHarness: @unchecked Sendable {
    let scratch: Scratch
    let home: URL
    let landfallFile: URL
    let contacts = ContactCounter()
    let state: MooringsState
    let moorings: MooringsService
    let runner: RecordedRunner
    let prefs: LandfallPreferencesStore
    let registry = PeriodicTaskRegistry()
    let clock = LandfallClock()
    let gate: DevSafetyPolicy
    var service: LandfallService!

    init(scratch: Scratch, gate: DevSafetyPolicy? = nil, responder: @escaping RecordedRunner.Responder) throws {
        self.scratch = scratch
        home = try scratch.home()
        let g = gate ?? openGate(home: home)
        self.gate = g
        landfallFile = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: home).landfallKubeconfig
        state = MooringsState(overrides: DiscoveredClusterStore(fileURL: scratch.root.appending(path: "discovered-clusters.json")),
                              preferences: MooringsPreferencesStore(fileURL: scratch.root.appending(path: "moorings.json")), gate: g)
        try state.preferences.update { $0.firstRunCompleted = true }
        moorings = MooringsService(config: MooringsConfiguration(gate: g, home: home, explicitTestKubeconfig: nil, shellKubeconfig: { nil }, registry: registry),
                                   state: state, clients: contacts, authorizer: AllowAuthorizer())
        runner = RecordedRunner(responder)
        prefs = LandfallPreferencesStore(fileURL: scratch.root.appending(path: "landfall.json"))
        let clock = self.clock
        service = LandfallService(adapters: [AWSCLI(runner: runner), GCloudCLI(runner: runner), AzureCLI(runner: runner)], moorings: moorings,
                                  landfallFile: landfallFile, cacheFile: scratch.root.appending(path: "landfall-cache.json"), preferences: prefs,
                                  gateProvider: { g }, now: { clock.now }, registry: registry)
    }

    func advance(_ seconds: TimeInterval) { clock.advance(seconds) }
    var profile: CloudAccount { CloudAccount(provider: .aws, accountID: "platform-prod", name: "platform-prod") }
}

@Suite("Landfall service")
struct LandfallServiceTests {
    func combined(_ parts: RecordedRunner.Responder...) -> RecordedRunner.Responder {
        { p, a in for r in parts { if let out = r(p, a) { return out } }; return nil }
    }

    @Test func productionSuggestedRowsAreNeverContactedUntilCheck() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        #expect(scan.clusters.count == 2)
        // `payments-prd` is Production by its name; `tagged-only` is Production ONLY by its env=prod tag.
        #expect(scan.clusters.allSatisfy { $0.isSuggestedProduction })
        #expect(h.contacts.total == 0)                                    // scanning contacts no cluster either

        let outcome = try await h.service.add(scan.clusters)
        #expect(outcome.added.count == 2 && outcome.skipped.isEmpty)
        #expect(outcome.checked.isEmpty)                                   // nothing is auto-checked
        #expect(h.contacts.total == 0)                                     // no client built, no plugin source asked for

        let ids = Array(outcome.ids.values)
        #expect(ids.count == 2)
        for id in ids {
            #expect(h.state.isContactHeld(id))
            #expect(h.state.checkState(for: id) == .notChecked)
            let override = try #require(h.state.overrides.override(for: id))
            #expect(override.added && override.readOnly && override.environment == .production && !override.environmentChosen)
        }
        // The clusters are listed, read-only, as Production.
        let configs = h.state.listedConfigs()
        #expect(configs.count == 2)
        #expect(configs.allSatisfy { $0.readOnly && $0.environment == .production })
        #expect(configs.allSatisfy { if case .kubeconfig = $0.origin { true } else { false } })
        #expect(h.state.contexts.allSatisfy { $0.authSummary.label.hasPrefix("Exec aws") })

        // Check is the only way in.
        let id = try #require(outcome.ids[scan.clusters[1].id])
        _ = await h.service.check(id)
        #expect(h.contacts.clients == 1)
        #expect(h.contacts.plugins == 1)
        #expect(h.state.isContactHeld(id) == false)
        let other = try #require(ids.first { $0 != id })
        #expect(h.state.isContactHeld(other))
        #expect(h.state.checkState(for: other) == .notChecked)
    }

    @Test func aTagOnlyProductionRowStaysHeldEvenWhenAScanSeesItBeforeAddFinishes() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let tagged = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first?.clusters.first { $0.name == "tagged-only" })
        // What Add does, stepwise: register, then a rescan finds the file (as a FileWatcher event would), then the checks.
        let file = KubeconfigWriter.resolve(h.landfallFile)
        let reg = LandfallRegistration(key: DiscoveredContextKey(definingFile: file.path, contextName: tagged.contextName), suggestedEnvironment: tagged.suggestion?.environment)
        try await h.moorings.registerLandfall([reg])
        try KubeconfigWriter(gate: h.gate).merge(entries: LandfallKubeconfig.entries(for: [tagged]), into: h.landfallFile, backup: false)
        await h.moorings.rescan()
        await h.moorings.startFirstRunChecks(ids: [reg.key.clusterID])
        #expect(h.contacts.total == 0)
        #expect(h.state.isContactHeld(reg.key.clusterID))
        // The context itself carries no Production hint (no tag reached Moorings): the hold comes from the registered environment.
        #expect(h.state.context(for: reg.key.clusterID)?.isSuggestedProduction == false)
    }

    @Test func nonProductionRowsStartReadOnlyAndAreCheckedRightAway() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: { p, a in
            if p == .gcp { if a.prefix(3) == ["container", "clusters", "list"] { return ok("gcloud/clusters-lab-2.json") }; if a.first == "version" { return ok("gcloud/version.json") } }
            return nil
        })
        let lab = CloudAccount(provider: .gcp, accountID: "lab-2", name: "Lab")
        let scan = try #require(try await h.service.scan(.gcp, accounts: [lab]).first)
        #expect(scan.clusters.contains { $0.isSuggestedProduction } == false)
        let outcome = try await h.service.add(scan.clusters)
        #expect(outcome.checked.count == 2)
        #expect(h.contacts.clients == 2)                                    // checked, as the spec says for non-Production rows
        for id in outcome.ids.values {
            let config = try #require(h.state.listedConfigs().first { $0.id == id })
            #expect(config.readOnly)
        }
        let yaml = try String(contentsOf: h.landfallFile, encoding: .utf8)
        #expect(yaml.contains("gke_lab-2_europe-west4-a_scratch") && yaml.contains("gke-gcloud-auth-plugin"))
        #expect(!yaml.contains("token:"))
        #expect((try FileManager.default.attributesOfItem(atPath: h.landfallFile.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func addingTwiceDoesNotDuplicateAndRowsThatCannotBeAddedAreSkippedWithAReason() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        var scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        var broken = scan.clusters[0]; broken.addable = false; broken.unsupportedReason = "Local accounts only."
        broken.contextName = "arn:broken"
        scan.clusters.append(broken)
        let first = try await h.service.add(scan.clusters)
        #expect(first.skipped[broken.id] == "Local accounts only.")
        _ = try await h.service.add(scan.clusters)
        let text = try String(contentsOf: h.landfallFile, encoding: .utf8)
        #expect(text.components(separatedBy: "name: arn:aws:eks:eu-west-1:123456789012:cluster/payments-prd").count - 1 == 3)   // cluster, user, context
        #expect(!text.contains("arn:broken"))
        #expect(h.state.contexts.count == 2)
    }

    @Test func aFailedWriteLeavesNothingRegistered() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        // A directory where landfall.yaml should be: the merge cannot write it.
        try FileManager.default.createDirectory(at: h.landfallFile, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { _ = try await h.service.add(scan.clusters) }
        #expect(h.state.overrides.all.isEmpty)
        #expect(h.contacts.total == 0)
    }

    // MARK: Gate

    @Test func everyEntryPointIsRefusedWhileTheGateIsActive() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let h = try LandfallHarness(scratch: s, gate: activeGate(home: home), responder: awsRecording())
        #expect(!h.service.isEnabled)
        #expect(await h.service.status(.aws) == .disabled("Landfall is disabled in development builds."))
        await #expect(throws: DevSafetyError.self) { _ = try await h.service.accounts(.aws) }
        await #expect(throws: DevSafetyError.self) { _ = try await h.service.scan(.aws, accounts: [h.profile]) }
        await #expect(throws: DevSafetyError.self) { _ = try await h.service.add([]) }
        await #expect(throws: DevSafetyError.self) { _ = try await h.service.loginCommand(.aws, account: h.profile) }
        await #expect(throws: DevSafetyError.self) { _ = try await h.service.planUserMerge(KubeconfigEntries()) }
        #expect(h.runner.count == 0)
        #expect(!FileManager.default.fileExists(atPath: h.landfallFile.path))
        try h.prefs.update { $0.rescan = .daily }
        await h.service.applyRescanPolicy()
        #expect(await !h.service.hasDailyTask)
        #expect(h.registry.snapshot().isEmpty)
    }

    @Test func theUserKubeconfigMergeIsPlannedOnlyWhenOptedInAndStaysOffTheRealFileUnderTest() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        let off = try await h.service.add(scan.clusters)
        #expect(off.mergePlan == nil && off.mergeNote == nil)
        try h.prefs.update { $0.mergeIntoUserKubeconfig = true }
        let on = try await h.service.add(scan.clusters)
        // The target is `<home>/.kube/config`; under test the process gate refuses it, so there is a note and no plan, and no file.
        #expect(on.mergePlan == nil)
        #expect(on.mergeNote != nil)
        #expect(!FileManager.default.fileExists(atPath: h.home.appending(path: ".kube/config").path))
    }

    // MARK: Cache and schedule

    @Test func resultsAreCachedForAnHourAndRescanForcesARefresh() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        _ = try await h.service.scan(.aws, accounts: [h.profile])
        let first = h.runner.count
        #expect(first > 0)
        h.advance(1800)
        _ = try await h.service.scan(.aws, accounts: [h.profile])
        #expect(h.runner.count == first)
        h.advance(1900)                                                    // past the hour
        _ = try await h.service.scan(.aws, accounts: [h.profile])
        #expect(h.runner.count == first * 2)
        _ = try await h.service.scan(.aws, accounts: [h.profile], force: true)
        #expect(h.runner.count == first * 3)
        #expect(FileManager.default.fileExists(atPath: s.root.appending(path: "landfall-cache.json").path))
        let cache = try String(contentsOf: s.root.appending(path: "landfall-cache.json"), encoding: .utf8)
        #expect(cache.contains("payments-prd") && !cache.lowercased().contains("token"))
    }

    @Test func noPeriodicTaskExistsUnlessDailyIsChosen() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        await h.service.applyRescanPolicy()
        #expect(h.registry.snapshot().isEmpty)
        #expect(h.registry.effectiveIntervals(windowsVisible: false).isEmpty)
        _ = try await h.service.scan(.aws, accounts: [h.profile])
        #expect(h.registry.snapshot().isEmpty)

        try h.prefs.update { $0.rescan = .daily }
        await h.service.applyRescanPolicy()
        #expect(await h.service.hasDailyTask)
        let info = try #require(h.registry.snapshot().first)
        #expect(info.name == LandfallService.taskName)
        #expect(info.hiddenInterval == nil)                               // §12.3.3: nothing but Crow's Nest runs while hidden
        #expect(info.interval == 900)
        #expect(h.registry.effectiveIntervals(windowsVisible: false).isEmpty)
        #expect(h.registry.effectiveIntervals(windowsVisible: true).map(\.name) == [LandfallService.taskName])
        // Visibility changes park and re-arm the task but never remove it.
        h.registry.setWindowsVisible(false)
        #expect(h.registry.snapshot().count == 1)
        h.registry.setWindowsVisible(true)
        #expect(h.registry.snapshot().count == 1)

        try h.prefs.update { $0.rescan = .manual }
        await h.service.applyRescanPolicy()
        #expect(h.registry.snapshot().isEmpty)
        #expect(await !h.service.hasDailyTask)
    }

    @Test func theDailyTickScansOnlyWhenADayPassedAndOnlyTickedAccounts() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        // Manual: a tick does nothing.
        await h.service.dailyTick()
        #expect(h.runner.count == 0)
        try h.prefs.update { $0.rescan = .daily; $0.selectedAccounts = ["aws": ["platform-prod"]] }
        await h.service.dailyTick()                                        // never scanned: due
        let afterFirst = h.runner.count
        #expect(afterFirst > 0)
        #expect(h.runner.recorded.filter { $0.args.contains("--profile") }.allSatisfy { $0.args.contains("platform-prod") })
        h.advance(3600)
        await h.service.dailyTick()                                        // an hour later: not due, and a visibility change does not reset it
        #expect(h.runner.count == afterFirst)
        h.advance(86_400)
        await h.service.dailyTick()
        #expect(h.runner.count > afterFirst)
    }

    @Test func lastScanIsTrackedPerProvider() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        _ = try await h.service.scan(.aws, accounts: [h.profile])            // a manual AWS scan
        #expect(h.prefs.value.lastScan.keys.sorted() == ["aws"])
        try h.prefs.update { $0.rescan = .daily; $0.selectedAccounts = ["gcp": ["lab-2"]] }
        let before = h.runner.count
        await h.service.dailyTick()                                         // Google was never scanned: due although AWS just was
        #expect(h.runner.count > before)
        #expect(h.prefs.value.lastScan["gcp"] != nil || h.runner.calls(matching: "projects").count > 0)
    }

    // MARK: Names that already exist

    @Test func landfallYamlNeverRepointsAnExistingNameToAnotherServer() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        let first = scan.clusters[0]
        let outcome = try await h.service.add([first])
        let id = try #require(outcome.ids[first.id])
        // The user approved it: changes allowed, environment chosen.
        var o = try #require(h.state.overrides.override(for: id))
        o.readOnly = false; o.environmentChosen = true; o.contactApproved = true
        try h.state.overrides.set(o, for: id)
        let before = try String(contentsOf: h.landfallFile, encoding: .utf8)

        var other = first; other.accountID = "other-profile"; other.endpoint = "https://ZZZZ9999.gr7.eu-west-1.eks.amazonaws.com"
        let second = try await h.service.add([other])
        #expect(second.added.isEmpty)
        #expect(second.skipped[other.id]?.contains("already has a different cluster") == true)
        #expect(try String(contentsOf: h.landfallFile, encoding: .utf8) == before)
        #expect(h.state.overrides.override(for: id) == o)                   // still what the user approved

        // The same cluster again (same server) is fine.
        let again = try await h.service.add([first])
        #expect(again.added.count == 1)
    }

    @Test func anAKSNameFromAnotherSubscriptionGetsASubscriptionQualifiedContextName() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: { p, a in
            guard p == .azure else { return nil }
            if a.prefix(2) == ["aks", "get-credentials"] { return CLIOutput(exitCode: 0, stdout: landfallFixture("az/get-credentials-aad.yaml")) }
            return nil
        })
        func aks(_ sub: String, _ host: String) -> CloudCluster {
            CloudCluster(provider: .azure, accountID: sub, accountName: sub, name: "aks-main", region: "westeurope", endpoint: "https://\(host):443",
                         status: "Active", contextName: "aks-main", resourceGroup: "rg-main")
        }
        let dev = aks("00000000-0000-0000-0000-0000000000aa", "dev-dns.hcp.westeurope.azmk8s.io")
        let prod = aks("11111111-1111-1111-1111-1111111111bb", "prod-dns.hcp.westeurope.azmk8s.io")
        let first = try await h.service.add([dev])
        let devID = try #require(first.ids[dev.id])
        let second = try await h.service.add([prod])
        #expect(second.added.first?.contextName == "aks-main-11111111")
        let prodID = try #require(second.ids[prod.id])
        #expect(prodID != devID)
        let yaml = try String(contentsOf: h.landfallFile, encoding: .utf8)
        #expect(yaml.contains("dev-dns") && yaml.contains("prod-dns"))
    }

    @Test func aChangedServerResetsWhatTheUserApproved() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let file = KubeconfigWriter.resolve(h.landfallFile)
        let key = DiscoveredContextKey(definingFile: file.path, contextName: "ctx")
        var o = DiscoveredOverride()
        o.added = true; o.readOnly = false; o.environmentChosen = true; o.environment = .development; o.contactApproved = true
        o.lastKnown = LastKnownContext(definingFile: file.path, contextName: "ctx", server: "https://old.example.test", tlsServerName: nil, authKind: .none,
                                       insecureSkipTLSVerify: false, namespace: nil, displayName: "ctx", suggestedEnvironment: nil)
        try h.state.overrides.set(o, for: key.clusterID)
        try await h.moorings.registerLandfall([LandfallRegistration(key: key, suggestedEnvironment: nil, server: "https://new.example.test")])
        let after = try #require(h.state.overrides.override(for: key.clusterID))
        #expect(after.readOnly && !after.contactApproved && !after.environmentChosen)
        // The same server keeps the approval.
        try h.state.overrides.set(o, for: key.clusterID)
        try await h.moorings.registerLandfall([LandfallRegistration(key: key, suggestedEnvironment: nil, server: "https://old.example.test")])
        #expect(h.state.overrides.override(for: key.clusterID)?.environmentChosen == true)
    }

    @Test func aLockedLandfallFileFailsTheAddAndUndoesTheRegistration() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        let file = KubeconfigWriter.resolve(h.landfallFile)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "".write(to: file.appendingPathExtension("lock"), atomically: true, encoding: .utf8)     // another add holds the lock
        await #expect(throws: KubeconfigWriteError.locked) { _ = try await h.service.add(scan.clusters) }
        #expect(h.state.overrides.all.isEmpty)
        #expect(h.contacts.total == 0)
    }

    @Test func aPlanThatWouldReplaceUserEntriesIsNotConfirmed() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        let c = scan.clusters[0]
        let target = try s.write("user-kc", "apiVersion: v1\nkind: Config\nclusters:\n- name: \(c.contextName)\n  cluster: {server: \"https://mine.example.test\"}\n")
        let entries = LandfallKubeconfig.entries(for: [c])
        let replacing = try KubeconfigWriter(gate: h.gate).plan(entries: entries, into: target)
        #expect(!replacing.replaced.isEmpty)
        await #expect(throws: KubeconfigWriteError.wouldReplace) { _ = try await h.service.confirmUserMerge(replacing, entries: entries, clusters: [c]) }
        #expect(try String(contentsOf: target, encoding: .utf8).contains("mine.example.test"))
        #expect(h.state.overrides.all.isEmpty)
    }

    @Test func theUserFileMergeNeverReplacesExistingNamesAndRegistersTheCopyAsProduction() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        let payments = scan.clusters[0], tagged = scan.clusters[1]
        // A user file that already has the payments entries (written by `aws eks update-kubeconfig`, with a role).
        let existing = "apiVersion: v1\nkind: Config\ncurrent-context: keep\nclusters:\n- name: \(payments.contextName)\n  cluster: {server: \"https://mine.example.test\"}\nusers: []\ncontexts: []\n"
        let target = try s.write("user-kubeconfig", existing)
        let entries = LandfallKubeconfig.entries(for: [payments, tagged])
        let merge = try await h.service.planUserMerge(entries, target: target)
        let mergePlan = try #require(merge.plan)
        #expect(merge.leftUnchanged == [payments.contextName])
        #expect(merge.entries.clusters.map(\.name) == [tagged.contextName])
        #expect(mergePlan.replaced.isEmpty)
        _ = try await h.service.confirmUserMerge(mergePlan, entries: merge.entries, clusters: [payments, tagged])
        let text = try String(contentsOf: target, encoding: .utf8)
        #expect(text.contains("https://mine.example.test") && text.contains("current-context: keep"))
        // Moorings sees the user's file as a source: the copy of the tag-only Production cluster is registered and held.
        try await h.moorings.addFileSource(target)
        let key = DiscoveredContextKey(definingFile: target.path, contextName: tagged.contextName)
        #expect(h.state.isContactHeld(key.clusterID))
        #expect(h.state.overrides.override(for: key.clusterID)?.environment == .production)
        #expect(h.contacts.total == 0)
    }

    @Test func twoRowsWithOneContextNameAddOnceAndAFailedWriteRestoresEarlierOverrides() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        var twin = scan.clusters[0]; twin.accountID = "other-profile"      // same ARN, another profile
        let outcome = try await h.service.add([scan.clusters[0], twin])
        #expect(outcome.added.count == 1 && outcome.skipped[twin.id]?.contains("same context name") == true)

        let file = KubeconfigWriter.resolve(h.landfallFile)
        let key = DiscoveredContextKey(definingFile: file.path, contextName: "x")
        var earlier = DiscoveredOverride(); earlier.name = "My name"; earlier.hidden = true
        try h.state.overrides.set(earlier, for: key.clusterID)
        let previous = try await h.moorings.registerLandfall([LandfallRegistration(key: key, suggestedEnvironment: nil)])
        #expect(h.state.overrides.override(for: key.clusterID)?.added == true)
        try await h.moorings.unregisterLandfall(previous)
        #expect(h.state.overrides.override(for: key.clusterID) == earlier)
    }

    // MARK: Production is never lowered by a server change

    @Test func aChangedServerKeepsProductionHeldAndReadOnly() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", "current-context: odd\nclusters:\n- {name: c, cluster: {server: \"https://odd.example.test:6443\"}}\nusers:\n- {name: u, user: {token: t}}\ncontexts:\n- {name: odd, context: {cluster: c, user: u}}\n")
        let h = try MooringsHarness(files: [file], firstRunCompleted: true, scratch: s)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        // The user chose Production for a name that does not suggest it, and allowed changes.
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .production, environmentPicked: true, allowChanges: true)])
        try await h.service.markOpened(ctx.id)
        #expect(h.state.overrides.override(for: ctx.id)?.readOnly == false)
        // A tool rewrites the file: same context name, another server.
        try s.write("kc.yaml", try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: "odd.example.test", with: "elsewhere.example.test"))
        await h.service.rescan()
        let o = try #require(h.state.overrides.override(for: ctx.id))
        #expect(o.environment == .production)                      // never lowered
        #expect(o.readOnly && !o.contactApproved && !o.environmentChosen)
        #expect(h.state.isContactHeld(ctx.id))
        let notice = await h.service.issues[ctx.key.definingFile]
        #expect(notice?.contains("different server") == true)
        #expect(h.clients.total == 0)
    }

    @Test func aChangedServerOfALocalClusterGoesBackToItsSuggestion() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let file = try s.write("kc.yaml", "current-context: minikube\nclusters:\n- {name: c, cluster: {server: \"https://127.0.0.1:8443\"}}\nusers:\n- {name: u, user: {token: t}}\ncontexts:\n- {name: minikube, context: {cluster: c, user: u}}\n")
        let h = try MooringsHarness(files: [file], firstRunCompleted: true, scratch: s)
        await h.service.rescan()
        let ctx = try #require(h.state.contexts.first)
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .personal, environmentPicked: true, allowChanges: true)])
        #expect(h.state.overrides.override(for: ctx.id)?.readOnly == false)
        try s.write("kc.yaml", try String(contentsOf: file, encoding: .utf8).replacingOccurrences(of: ":8443", with: ":8444"))
        await h.service.rescan()
        let o = try #require(h.state.overrides.override(for: ctx.id))
        #expect(o.readOnly && !o.contactApproved && !o.environmentChosen)
        #expect(o.environment == .development)                     // the suggestion for a local cluster
    }

    // MARK: Smaller cases

    @Test func anUnreadableLandfallYamlRefusesTheAddAndIsLeftAlone() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let scan = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first)
        try FileManager.default.createDirectory(at: h.landfallFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "this: [is not a kubeconfig".write(to: h.landfallFile, atomically: true, encoding: .utf8)
        await #expect(throws: LandfallError.self) { _ = try await h.service.add(scan.clusters) }
        #expect(try String(contentsOf: h.landfallFile, encoding: .utf8) == "this: [is not a kubeconfig")
        #expect(h.state.overrides.all.isEmpty)
    }

    @Test func whenTheUserFileHasEveryNameThereIsNoPlan() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: awsRecording())
        let c = try #require(try await h.service.scan(.aws, accounts: [h.profile]).first?.clusters.first)
        let target = try s.write("user-kc", "apiVersion: v1\nkind: Config\nclusters:\n- name: \(c.contextName)\n  cluster: {server: \"https://mine.example.test\"}\nusers:\n- name: \(c.contextName)\n  user: {token: t}\ncontexts:\n- name: \(c.contextName)\n  context: {cluster: \(c.contextName), user: \(c.contextName)}\n")
        let merge = try await h.service.planUserMerge(LandfallKubeconfig.entries(for: [c]), target: target)
        #expect(merge.plan == nil)
        #expect(merge.leftUnchanged == [c.contextName])
        #expect(merge.entries.isEmpty)
    }

    @Test func twoAKSClustersOfOneNameInABatchAreBothRenamed() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try LandfallHarness(scratch: s, responder: { p, a in
            guard p == .azure, a.prefix(2) == ["aks", "get-credentials"] else { return nil }
            return CLIOutput(exitCode: 0, stdout: landfallFixture("az/get-credentials-aad.yaml"))
        })
        func aks(_ sub: String, _ host: String) -> CloudCluster {
            CloudCluster(provider: .azure, accountID: sub, accountName: sub, name: "aks-main", region: "we", endpoint: "https://\(host):443", status: "Active",
                         contextName: "aks-main", resourceGroup: "rg-main")
        }
        let outcome = try await h.service.add([aks("00000000-0000-0000-0000-0000000000aa", "a.hcp.we.azmk8s.io"), aks("11111111-1111-1111-1111-1111111111bb", "b.hcp.we.azmk8s.io")])
        #expect(outcome.added.map(\.contextName).sorted() == ["aks-main-00000000", "aks-main-11111111"])
        #expect(outcome.skipped.isEmpty)
    }

    @Test func preferencesKeepTheirDefaultsWhenAFieldIsMissing() throws {
        let json = Data(#"{"rescan":"daily"}"#.utf8)
        let prefs = try JSONDecoder().decode(LandfallPreferences.self, from: json)
        #expect(prefs.rescan == .daily)
        #expect(!prefs.mergeIntoUserKubeconfig && prefs.selectedAccounts.isEmpty && prefs.awsRegions == nil && prefs.lastScan.isEmpty)
        #expect(try JSONDecoder().decode(LandfallPreferences.self, from: Data("{}".utf8)) == LandfallPreferences())
    }
}
#endif
