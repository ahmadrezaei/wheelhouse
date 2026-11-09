#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

// MARK: - Preferences and cache

/// Settings → Landfall, persisted in `landfall.json` under `AppPaths.root`.
public struct LandfallPreferences: Codable, Equatable, Sendable {
    public enum Rescan: String, Codable, CaseIterable, Sendable { case manual, daily }
    public var rescan: Rescan = .manual
    /// "Also merge into ~/.kube/config" (off by default).
    public var mergeIntoUserKubeconfig = false
    /// Account IDs ticked per provider (`CloudProvider.rawValue`).
    public var selectedAccounts: [String: [String]] = [:]
    /// AWS regions to scan; nil = every enabled region.
    public var awsRegions: [String]?
    /// When each provider's last scan finished (`CloudProvider.rawValue`), for the daily cadence.
    public var lastScan: [String: Date] = [:]
    public init() {}

    enum CodingKeys: String, CodingKey { case rescan, mergeIntoUserKubeconfig, selectedAccounts, awsRegions, lastScan }
    /// Missing keys keep their defaults, so adding a field later never resets what the user chose.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rescan = (try? c.decodeIfPresent(Rescan.self, forKey: .rescan)) ?? .manual
        mergeIntoUserKubeconfig = (try? c.decodeIfPresent(Bool.self, forKey: .mergeIntoUserKubeconfig)) ?? false
        selectedAccounts = (try? c.decodeIfPresent([String: [String]].self, forKey: .selectedAccounts)) ?? [:]
        awsRegions = try? c.decodeIfPresent([String].self, forKey: .awsRegions)
        lastScan = (try? c.decodeIfPresent([String: Date].self, forKey: .lastScan)) ?? [:]
    }
}

public extension AppPaths {
    var landfallPreferencesFile: URL { root.appending(path: "landfall.json") }
    var landfallCacheFile: URL { root.appending(path: "landfall-cache.json") }
}

public final class LandfallPreferencesStore: Sendable {
    private let fileURL: URL
    private let state: Mutex<LandfallPreferences>
    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(JSONFile.read(LandfallPreferences.self, from: fileURL) ?? LandfallPreferences())
    }
    public var value: LandfallPreferences { state.withLock { $0 } }
    public func update(_ change: (inout LandfallPreferences) -> Void) throws {
        let v = state.withLock { s -> LandfallPreferences in change(&s); return s }
        try JSONFile.write(v, to: fileURL)
    }
}

/// Discovery results, kept for one hour. Holds endpoints, public CA certificates and tags only; never a token.
struct LandfallCache: Codable, Equatable {
    var accounts: [String: [CloudAccount]] = [:]
    var accountsAt: [String: Date] = [:]
    var scans: [String: AccountScan] = [:]
}

final class LandfallCacheStore: Sendable {
    private let fileURL: URL
    private let state: Mutex<LandfallCache>
    init(fileURL: URL) {
        self.fileURL = fileURL
        self.state = Mutex(JSONFile.read(LandfallCache.self, from: fileURL) ?? LandfallCache())
    }
    var value: LandfallCache { state.withLock { $0 } }
    func update(_ change: (inout LandfallCache) -> Void) {
        let v = state.withLock { s -> LandfallCache in change(&s); return s }
        try? JSONFile.write(v, to: fileURL)
    }
}

// MARK: - Moorings seam

/// A context Landfall is about to write.
public struct LandfallRegistration: Sendable, Equatable {
    public var key: DiscoveredContextKey
    public var suggestedEnvironment: ClusterEnvironment?
    /// The API server the context points at (a change of server resets what the user approved).
    public var server: String?
    public init(key: DiscoveredContextKey, suggestedEnvironment: ClusterEnvironment?, server: String? = nil) {
        self.key = key
        self.server = server
        self.suggestedEnvironment = suggestedEnvironment
    }
}

/// What Landfall needs from Moorings (`landfall.yaml` is one of its sources). ``MooringsService`` conforms.
public protocol LandfallMoorings: Sendable {
    func registerLandfall(_ rows: [LandfallRegistration]) async throws -> [ClusterID: DiscoveredOverride?]
    func unregisterLandfall(_ previous: [ClusterID: DiscoveredOverride?]) async throws
    func rescanSources() async
    func startFirstRunChecks(ids: [ClusterID]) async
    func check(_ id: ClusterID) async -> ClusterCheckResult
    func checkStateOf(_ id: ClusterID) -> ClusterCheckState
}

extension MooringsService: LandfallMoorings {
    public func rescanSources() async { await rescan() }
    public nonisolated func checkStateOf(_ id: ClusterID) -> ClusterCheckState { state.checkState(for: id) }
}

// MARK: - Service

public enum LandfallError: Error, Equatable, Sendable, LocalizedError {
    case unreadableFile(String)
    public var errorDescription: String? {
        switch self {
        case .unreadableFile(let name): "\(name) could not be read, so nothing was added. Fix or remove the file and try again."
        }
    }
}

public struct LandfallAddOutcome: Sendable, Equatable {
    public var ids: [String: ClusterID]          // CloudCluster.id → cluster id
    public var added: [CloudCluster]
    public var skipped: [String: String]         // CloudCluster.id → reason
    /// Rows that were checked right away (never a Production-suggested one).
    public var checked: [ClusterID]
    public var entries: KubeconfigEntries
    /// The merge into the user's `~/.kube/config`, to be shown and confirmed; nil when the option is off.
    public var mergePlan: KubeconfigMergePlan?
    /// The entries the merge will write: only names the user's file does not have yet.
    public var mergeEntries: KubeconfigEntries?
    /// Names the user's file already defines. They are left exactly as they are.
    public var mergeLeftUnchanged: [String] = []
    public var mergeNote: String?
}

/// Landfall: discovery through the cloud CLIs, `landfall.yaml`, and the optional merge (ARCHITECTURE-MAC §8).
///
/// - Everything is refused while the gate is active.
/// - Nothing runs in the background unless the user chose "daily": a `PeriodicTask` exists only then.
/// - Add never contacts a Production-suggested cluster; **Check** (``check(_:)``) is the only way.
public actor LandfallService {
    private let adapters: [CloudProvider: any CloudProviderAdapter]
    private let moorings: any LandfallMoorings
    private let landfallFile: URL
    private let cache: LandfallCacheStore
    public nonisolated let preferences: LandfallPreferencesStore
    private let gateProvider: @Sendable () -> DevSafetyPolicy
    private let now: @Sendable () -> Date
    private let registry: PeriodicTaskRegistry
    private let ttl: TimeInterval
    private let userMergeTarget: URL?
    private var dailyTask: PeriodicTask?

    /// How often the daily task wakes to see whether a day has passed.
    static let dailyWake: TimeInterval = 900
    static let dailyAge: TimeInterval = 86_400
    public static let taskName = "landfall.daily-rescan"

    public init(adapters: [any CloudProviderAdapter], moorings: any LandfallMoorings, landfallFile: URL, cacheFile: URL, preferences: LandfallPreferencesStore,
                gateProvider: @escaping @Sendable () -> DevSafetyPolicy = { .current }, now: @escaping @Sendable () -> Date = { Date() },
                registry: PeriodicTaskRegistry = .shared, ttl: TimeInterval = 3600, userMergeTarget: URL? = nil) {
        self.userMergeTarget = userMergeTarget
        self.adapters = Dictionary(adapters.map { ($0.provider, $0) }, uniquingKeysWith: { a, _ in a })
        self.moorings = moorings
        self.landfallFile = landfallFile
        self.cache = LandfallCacheStore(fileURL: cacheFile)
        self.preferences = preferences
        self.gateProvider = gateProvider
        self.now = now
        self.registry = registry
        self.ttl = ttl
    }

    public nonisolated var isEnabled: Bool { gateProvider().allowsCloudCLIs }

    private func requireEnabled() throws {
        let gate = gateProvider()
        try gate.require(gate.allowsCloudCLIs, feature: "Landfall")
    }

    private func adapter(_ p: CloudProvider) throws -> any CloudProviderAdapter {
        guard let a = adapters[p] else { throw CLIError.notInstalled(p.tool) }
        return a
    }

    // MARK: Discovery

    public func status(_ provider: CloudProvider) async -> CLIStatus {
        guard isEnabled else { return .disabled("Landfall is disabled in development builds.") }
        guard let a = adapters[provider] else { return .notFound(installHint: provider.installHint) }
        return await a.status()
    }

    public func accounts(_ provider: CloudProvider, force: Bool = false) async throws -> [CloudAccount] {
        try requireEnabled()
        let key = provider.rawValue
        let c = cache.value
        if !force, let at = c.accountsAt[key], now().timeIntervalSince(at) < ttl, let list = c.accounts[key] { return list }
        let list = try await adapter(provider).accounts()
        let stamp = now()
        cache.update { $0.accounts[key] = list; $0.accountsAt[key] = stamp }
        return list
    }

    /// Scans the accounts (cached for an hour; `force` is Rescan). The CLIs themselves are throttled to 6 at once.
    public func scan(_ provider: CloudProvider, accounts: [CloudAccount], force: Bool = false) async throws -> [AccountScan] {
        try requireEnabled()
        let a = try adapter(provider)
        let options = ScanOptions(awsRegions: preferences.value.awsRegions)
        var results: [AccountScan] = []
        for account in accounts {
            if !force, let cached = cache.value.scans[account.id], now().timeIntervalSince(cached.scannedAt) < ttl, cached.issues.isEmpty {
                results.append(cached)
                continue
            }
            let scan = await a.scan(account: account, options: options, now: now())
            cache.update { $0.scans[account.id] = scan }
            results.append(scan)
        }
        try? preferences.update { $0.lastScan[provider.rawValue] = now() }
        return results
    }

    public func loginCommand(_ provider: CloudProvider, account: CloudAccount?) throws -> CLICommand {
        try requireEnabled()
        return try adapter(provider).loginCommand(for: account)
    }

    // MARK: Add

    /// Adds the clusters: they are marked added (read-only, with the suggested environment) in Moorings FIRST, then written to
    /// `landfall.yaml`, then Moorings rescans. Rows suggested as Production are not checked and no credential plugin runs for them.
    public func add(_ clusters: [CloudCluster]) async throws -> LandfallAddOutcome {
        try requireEnabled()
        var prepared: [CloudCluster] = []
        var skipped: [String: String] = [:]
        var seenContexts = Set<String>()
        // landfall.yaml only ever gains names: a name it already holds for another API server is never overwritten (that would repoint
        // a cluster the user approved). An AKS row is retried under a subscription-qualified name; anything else is skipped with the reason.
        let held = try heldServers()
        // Two AKS clusters of one name in this batch (different subscriptions): both get the subscription-qualified name.
        let azureDupes = Set(Dictionary(grouping: clusters.filter { $0.provider == .azure }, by: \.contextName).filter { $0.value.count > 1 }.keys)
        var originalIDs: [String] = []      // parallel to `prepared`: the row's id before any rename
        for var c in clusters {
            let rowID = c.id
            if c.provider == .azure, azureDupes.contains(c.contextName) { c.contextName = "\(c.name)-\(c.accountID.prefix(8))" }
            if let existing = held[c.contextName], let url = c.serverURL, existing != ServerURL.normalized(url) {
                if c.provider == .azure, !held.keys.contains("\(c.name)-\(c.accountID.prefix(8))") {
                    c.contextName = "\(c.name)-\(c.accountID.prefix(8))"
                } else {
                    skipped[rowID] = "landfall.yaml already has a different cluster named \(c.contextName)."
                    continue
                }
            }
            guard seenContexts.insert(c.contextName).inserted else { skipped[rowID] = "Another selected row has the same context name (\(c.contextName))."; continue }
            guard c.addable else { skipped[rowID] = c.unsupportedReason ?? "This cluster cannot be added."; continue }
            do {
                let full = try await adapter(c.provider).prepareToAdd(c)
                guard full.caData != nil, full.serverURL != nil else { skipped[rowID] = "The cluster has no endpoint or CA yet (is it still being created?)."; continue }
                prepared.append(full); originalIDs.append(rowID)
            } catch { skipped[rowID] = error.localizedDescription }
        }
        let entries = LandfallKubeconfig.entries(for: prepared)
        guard !prepared.isEmpty else {
            return LandfallAddOutcome(ids: [:], added: [], skipped: skipped, checked: [], entries: entries, mergePlan: nil, mergeEntries: nil, mergeNote: nil)
        }
        let file = KubeconfigWriter.resolve(landfallFile)
        let regs = prepared.map { LandfallRegistration(key: DiscoveredContextKey(definingFile: file.path, contextName: $0.contextName),
                                                       suggestedEnvironment: $0.suggestion?.environment, server: $0.endpoint) }
        let created = try await moorings.registerLandfall(regs)
        do {
            try KubeconfigWriter(gate: gateProvider()).merge(entries: entries, into: landfallFile, backup: false)
        } catch {
            try? await moorings.unregisterLandfall(created)
            throw error
        }
        await moorings.rescanSources()
        var ids: [String: ClusterID] = [:]
        var toCheck: [ClusterID] = []
        for ((c, r), rowID) in zip(zip(prepared, regs), originalIDs) {
            ids[rowID] = r.key.clusterID
            if !c.isSuggestedProduction { toCheck.append(r.key.clusterID) }
        }
        await moorings.startFirstRunChecks(ids: toCheck)

        var merge: UserMergePlan?
        var note: String?
        if preferences.value.mergeIntoUserKubeconfig {
            do {
                merge = try planUserMerge(entries)
                if let m = merge, m.plan == nil { note = "Already in ~/.kube/config, left unchanged: \(m.leftUnchanged.joined(separator: ", "))." }
            } catch { note = error.localizedDescription }
        }
        return LandfallAddOutcome(ids: ids, added: prepared, skipped: skipped, checked: toCheck, entries: entries, mergePlan: merge?.plan,
                                  mergeEntries: merge?.entries, mergeLeftUnchanged: merge?.leftUnchanged ?? [], mergeNote: note)
    }

    /// context name → normalised server, for what landfall.yaml holds now.
    private func heldServers() throws -> [String: String] {
        guard FileManager.default.fileExists(atPath: landfallFile.path) else { return [:] }
        // A landfall.yaml that cannot be read is not overwritten: the add is refused.
        guard let text = try? String(contentsOf: landfallFile, encoding: .utf8) else { throw LandfallError.unreadableFile(landfallFile.lastPathComponent) }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return [:] }
        guard let config = try? KubeconfigParser.parse(text, environment: .desktop(baseDirectory: landfallFile.deletingLastPathComponent())) else {
            throw LandfallError.unreadableFile(landfallFile.lastPathComponent)
        }
        return Dictionary(config.contexts.compactMap { c in c.server.map { (c.name, ServerURL.normalized($0)) } }, uniquingKeysWith: { a, _ in a })
    }

    /// The user pressed **Check** on a row (the only way a Production-suggested row is contacted).
    @discardableResult
    public func check(_ id: ClusterID) async -> ClusterCheckResult { await moorings.check(id) }

    public nonisolated func checkState(_ id: ClusterID) -> ClusterCheckState { moorings.checkStateOf(id) }

    // MARK: Merge into ~/.kube/config

    public struct UserMergePlan: Sendable, Equatable {
        /// Nil when the user's file already has every name: there is nothing to merge.
        public var plan: KubeconfigMergePlan?
        public var entries: KubeconfigEntries
        public var leftUnchanged: [String]
    }

    /// The exact YAML and the backup name, to show before anything is written. Throws while the gate is active. Names the user's file
    /// already defines (for instance from `aws eks update-kubeconfig`, perhaps with another role or profile) are NOT replaced: they are left
    /// as they are and listed in `leftUnchanged`. `target` is the user's file (tests pass a scratch file).
    public func planUserMerge(_ entries: KubeconfigEntries, target explicit: URL? = nil) throws -> UserMergePlan {
        let gate = gateProvider()
        let target = try explicit ?? userMergeTarget ?? LandfallMergeTarget.resolve(gate: gate)
        let writer = KubeconfigWriter(gate: gate)
        let first = try writer.plan(entries: entries, into: target, now: now())
        guard !first.replaced.isEmpty else { return UserMergePlan(plan: first, entries: entries, leftUnchanged: []) }
        let existing = Set(first.replaced.map { String($0.split(separator: "/", maxSplits: 1).last ?? "") })
        var kept = entries
        kept.clusters.removeAll { existing.contains($0.name) }
        kept.users.removeAll { existing.contains($0.name) }
        kept.contexts.removeAll { existing.contains($0.name) }
        guard !kept.isEmpty else { return UserMergePlan(plan: nil, entries: kept, leftUnchanged: existing.sorted()) }
        return UserMergePlan(plan: try writer.plan(entries: kept, into: target, now: now()), entries: kept, leftUnchanged: existing.sorted())
    }

    /// Writes the reviewed plan: backup first, `current-context` untouched, verified, restored on any mismatch. The new contexts of the
    /// user's file are registered with Moorings first (Moorings reads `~/.kube/config` too, and would otherwise add a second copy of a
    /// Production-by-tag cluster with no suggestion), and the registration is undone if the write fails.
    @discardableResult
    public func confirmUserMerge(_ plan: KubeconfigMergePlan, entries: KubeconfigEntries, clusters: [CloudCluster] = []) async throws -> KubeconfigMergeResult {
        let gate = gateProvider()
        try gate.require(gate.allowsKubeconfigWrites, feature: "Merging into ~/.kube/config")
        guard plan.replaced.isEmpty else { throw KubeconfigWriteError.wouldReplace }
        let byName = Dictionary(clusters.map { ($0.contextName, $0) }, uniquingKeysWith: { a, _ in a })
        let regs = entries.contexts.map { ctx in
            LandfallRegistration(key: DiscoveredContextKey(definingFile: plan.target.path, contextName: ctx.name),
                                 suggestedEnvironment: byName[ctx.name]?.suggestion?.environment, server: byName[ctx.name]?.endpoint)
        }
        let previous = try await moorings.registerLandfall(regs)
        do { return try KubeconfigWriter(gate: gate).merge(plan: plan, entries: entries) } catch {
            try? await moorings.unregisterLandfall(previous)
            throw error
        }
    }

    // MARK: Daily rescan

    /// Creates the daily task when "daily" is chosen and removes it otherwise. With "manual" no `PeriodicTask` exists at all. The task
    /// wakes hourly (also while no window is visible: that is what the user chose) and scans only when a day has passed since the last scan.
    public func applyRescanPolicy() {
        dailyTask?.stop()
        dailyTask = nil
        guard isEnabled, preferences.value.rescan == .daily else { return }
        let task = PeriodicTask(name: Self.taskName, interval: Self.dailyWake, hiddenInterval: nil, registry: registry) { [weak self] in
            await self?.dailyTick()
        }
        dailyTask = task
        task.start()
    }

    public var hasDailyTask: Bool { dailyTask != nil }

    /// One wake of the daily task.
    public func dailyTick() async {
        guard isEnabled, preferences.value.rescan == .daily else { return }
        for provider in CloudProvider.allCases {
            if let last = preferences.value.lastScan[provider.rawValue], now().timeIntervalSince(last) < Self.dailyAge { continue }
            let selected = Set(preferences.value.selectedAccounts[provider.rawValue] ?? [])
            guard !selected.isEmpty, adapters[provider] != nil else { continue }
            guard let all = try? await accounts(provider, force: true) else { continue }
            _ = try? await scan(provider, accounts: all.filter { selected.contains($0.accountID) }, force: true)
        }
    }
}
#endif
