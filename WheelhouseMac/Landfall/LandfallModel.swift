import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// What the Landfall screen and its Settings pane show (ARCHITECTURE-MAC §8). Every action goes through ``LandfallService``, which
/// refuses all of it while the development gate is active.
@MainActor @Observable
final class LandfallModel {
    /// A merge into the user's `~/.kube/config` waiting for the user's confirmation: the exact YAML and the backup name.
    struct MergeReview: Identifiable {
        let id = UUID()
        var plan: KubeconfigMergePlan
        var entries: KubeconfigEntries
        var clusters: [CloudCluster]
        var leftUnchanged: [String]
    }

    /// A login command to run in the Sign-in sheet.
    struct SignInRequest: Identifiable {
        let id = UUID()
        var title: String
        var spec: ProcessSpec
    }

    enum RowState: Equatable {
        case available
        case alreadyAdded
        case added(ClusterID, ClusterCheckState)
    }

    let service: LandfallService
    private let runner: SubprocessCLIRunner
    private let moorings: MooringsController
    let isEnabled: Bool

    var provider: CloudProvider = .aws
    private(set) var statuses: [CloudProvider: CLIStatus] = [:]
    private(set) var accounts: [CloudProvider: [CloudAccount]] = [:]
    private(set) var scans: [String: AccountScan] = [:]
    private(set) var preferences: LandfallPreferences
    private(set) var isWorking = false
    private(set) var notice: String?
    private(set) var knownServers: Set<String> = []
    private(set) var addedIDs: [String: ClusterID] = [:]
    /// Bumped when a check finishes, so rows re-read their state.
    private(set) var checkTick = 0
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?
    var selection: Set<String> = []
    var mergeReview: MergeReview?
    var signIn: SignInRequest?
    /// A Production-suggested add waiting for the user to see why.
    var productionConfirmation: [CloudCluster]?

    init(service: LandfallService, runner: SubprocessCLIRunner, moorings: MooringsController, isEnabled: Bool) {
        self.service = service
        self.runner = runner
        self.moorings = moorings
        self.isEnabled = isEnabled
        self.preferences = service.preferences.value
    }

    /// Builds Landfall on top of the running Moorings stack. The CLI runner locates the tools through the shell snapshot.
    static func make(moorings: MooringsController, paths: AppPaths) -> LandfallModel {
        let shell = moorings.shellEnvironment
        let home = paths.home
        let runner = SubprocessCLIRunner(locator: { ExecutableLocator(snapshot: await shell.current(), home: home) },
                                         snapshot: { await shell.current() }, paths: paths)
        let adapters: [any CloudProviderAdapter] = [AWSCLI(runner: runner), GCloudCLI(runner: runner), AzureCLI(runner: runner)]
        let service = LandfallService(adapters: adapters, moorings: moorings.service, landfallFile: paths.landfallKubeconfig, cacheFile: paths.landfallCacheFile,
                                      preferences: LandfallPreferencesStore(fileURL: paths.landfallPreferencesFile))
        return LandfallModel(service: service, runner: runner, moorings: moorings, isEnabled: service.isEnabled)
    }

    /// Called once after launch: starts the daily rescan only when "daily" is chosen (and never in development builds).
    func start() async {
        guard isEnabled else { return }
        // A cloud CLI still running when the app quits is sent SIGTERM (its own observer: the app delegate is not touched).
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            Subprocess.terminateAll(group: SubprocessCLIRunner.quitGroup)
        }
        await service.applyRescanPolicy()
    }

    // MARK: Loading

    func loadStatus() async {
        guard isEnabled else { return }
        refreshKnownServers()
        for p in CloudProvider.allCases { statuses[p] = await service.status(p) }
        if case .installed = statuses[provider] { await loadAccounts(force: false) }
    }

    func loadAccounts(force: Bool) async {
        guard isEnabled else { return }
        isWorking = true
        defer { isWorking = false }
        do {
            accounts[provider] = try await service.accounts(provider, force: force)
            notice = nil
            if statuses[provider] == .signedOut { statuses[provider] = await service.status(provider) }
        } catch {
            if CLIFailure.classify(error) == .signedOut {
                statuses[provider] = .signedOut
                notice = nil
            } else {
                notice = error.localizedDescription
            }
        }
    }

    var selectedAccountIDs: Set<String> { Set(preferences.selectedAccounts[provider.rawValue] ?? []) }

    func toggleAccount(_ account: CloudAccount, on: Bool) {
        try? service.preferences.update { p in
            var set = Set(p.selectedAccounts[account.provider.rawValue] ?? [])
            if on { set.insert(account.accountID) } else { set.remove(account.accountID) }
            p.selectedAccounts[account.provider.rawValue] = set.sorted()
        }
        preferences = service.preferences.value
    }

    /// Scans the ticked accounts (cached for an hour; `force` is Rescan).
    func scan(force: Bool) async {
        guard isEnabled else { return }
        let chosen = (accounts[provider] ?? []).filter { selectedAccountIDs.contains($0.accountID) }
        guard !chosen.isEmpty else { notice = "Tick at least one \(provider.accountNoun.lowercased()) to scan."; return }
        isWorking = true
        defer { isWorking = false }
        do {
            for s in try await service.scan(provider, accounts: chosen, force: force) { scans[s.account.id] = s }
            notice = nil
        } catch { notice = error.localizedDescription }
        refreshKnownServers()
    }

    var currentScans: [AccountScan] { (accounts[provider] ?? []).compactMap { scans[$0.id] } }
    var clusters: [CloudCluster] { currentScans.flatMap(\.clusters) }
    var issues: [LandfallIssue] { currentScans.flatMap(\.issues) }
    var needsSignIn: Bool { statuses[provider] == .signedOut || issues.contains { $0.needsSignIn } }

    // MARK: Rows

    func rowState(_ cluster: CloudCluster) -> RowState {
        _ = checkTick
        if let id = addedIDs[cluster.id] { return .added(id, service.checkState(id)) }
        if let url = cluster.serverURL, knownServers.contains(ServerURL.normalized(url)) { return .alreadyAdded }
        return .available
    }

    func refreshKnownServers() {
        var set = Set<String>()
        for c in moorings.registry?.clusters ?? [] { set.insert(ServerURL.normalized(c.server)) }
        for ctx in moorings.state.contexts where moorings.state.overrides.override(for: ctx.id).map({ $0.added && !$0.hidden }) == true {
            if let s = ctx.server { set.insert(ServerURL.normalized(s)) }
        }
        knownServers = set
    }

    // MARK: Add and Check

    /// **Add** on one row or several. Production-suggested rows are explained first.
    func requestAdd(_ rows: [CloudCluster]) {
        let addable = rows.filter { $0.addable && rowState($0) == .available }
        guard !addable.isEmpty else { return }
        if addable.contains(where: \.isSuggestedProduction) { productionConfirmation = addable } else { Task { await add(addable) } }
    }

    func add(_ rows: [CloudCluster]) async {
        productionConfirmation = nil
        isWorking = true
        defer { isWorking = false }
        do {
            let outcome = try await service.add(rows)
            addedIDs.merge(outcome.ids) { _, new in new }
            let skipped = outcome.skipped.values.sorted()
            notice = skipped.isEmpty ? nil : skipped.joined(separator: "\n")
            selection.subtract(outcome.ids.keys)
            if let plan = outcome.mergePlan, let entries = outcome.mergeEntries {
                mergeReview = MergeReview(plan: plan, entries: entries, clusters: outcome.added, leftUnchanged: outcome.mergeLeftUnchanged)
            }
            else if let why = outcome.mergeNote { notice = [notice, "Not merged into ~/.kube/config: \(why)"].compactMap { $0 }.joined(separator: "\n") }
        } catch { notice = error.localizedDescription }
        await moorings.refresh()
        refreshKnownServers()
        checkTick += 1
    }

    /// **Check** on a row (the only way a Production-suggested row is contacted).
    func check(_ cluster: CloudCluster) async {
        guard case .added(let id, _) = rowState(cluster) else { return }
        _ = await service.check(id)
        await moorings.refresh()
        checkTick += 1
    }

    func confirmMerge(_ review: MergeReview) async {
        mergeReview = nil
        do {
            let result = try await service.confirmUserMerge(review.plan, entries: review.entries, clusters: review.clusters)
            notice = "Merged \(result.added.count + result.replaced.count) entries into \(result.target.path). Backup: \(result.backup?.lastPathComponent ?? "none")."
        } catch { notice = error.localizedDescription }
    }

    // MARK: Sign in

    func requestSignIn(account: CloudAccount? = nil) async {
        do {
            let command = try await service.loginCommand(provider, account: account ?? accounts[provider]?.first { selectedAccountIDs.contains($0.accountID) })
            let spec = try await runner.makeSpec(command.provider, command.arguments, environment: command.environment, qos: .userInitiated)
            signIn = SignInRequest(title: "Sign in to \(provider.displayName)", spec: spec)
        } catch { notice = error.localizedDescription }
    }

    func signInFinished() async {
        signIn = nil
        statuses[provider] = await service.status(provider)
        await loadAccounts(force: true)
    }

    // MARK: Settings

    func setRescan(_ value: LandfallPreferences.Rescan) async {
        try? service.preferences.update { $0.rescan = value }
        preferences = service.preferences.value
        await service.applyRescanPolicy()
    }

    func setMerge(_ on: Bool) {
        try? service.preferences.update { $0.mergeIntoUserKubeconfig = on }
        preferences = service.preferences.value
    }

    func setAWSRegions(_ text: String) {
        let list = text.split(whereSeparator: { ", ".contains($0) }).map(String.init)
        try? service.preferences.update { $0.awsRegions = list.isEmpty ? nil : list }
        preferences = service.preferences.value
    }
}

/// Holds the running model where views observe it (the model is built after launch, once the allowed hosts are known).
@MainActor @Observable
final class LandfallHub {
    static let shared = LandfallHub()
    var model: LandfallModel?
}
