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
    /// When the last scan finished, for the daily cadence.
    public var lastScan: Date?
    public init() {}
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
    public init(key: DiscoveredContextKey, suggestedEnvironment: ClusterEnvironment?) {
        self.key = key
        self.suggestedEnvironment = suggestedEnvironment
    }
}

/// What Landfall needs from Moorings (`landfall.yaml` is one of its sources). ``MooringsService`` conforms.
public protocol LandfallMoorings: Sendable {
    func registerLandfall(_ rows: [LandfallRegistration]) async throws -> [ClusterID]
    func unregisterLandfall(_ ids: [ClusterID]) async throws
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

public struct LandfallAddOutcome: Sendable, Equatable {
    public var ids: [String: ClusterID]          // CloudCluster.id → cluster id
    public var added: [CloudCluster]
    public var skipped: [String: String]         // CloudCluster.id → reason
    /// Rows that were checked right away (never a Production-suggested one).
    public var checked: [ClusterID]
    public var entries: KubeconfigEntries
    /// The merge into the user's `~/.kube/config`, to be shown and confirmed; nil when the option is off.
    public var mergePlan: KubeconfigMergePlan?
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
    private var dailyTask: PeriodicTask?

    /// How often the daily task wakes to see whether a day has passed.
    static let dailyWake: TimeInterval = 3600
    static let dailyAge: TimeInterval = 86_400
    public static let taskName = "landfall.daily-rescan"

    public init(adapters: [any CloudProviderAdapter], moorings: any LandfallMoorings, landfallFile: URL, cacheFile: URL, preferences: LandfallPreferencesStore,
                gateProvider: @escaping @Sendable () -> DevSafetyPolicy = { .current }, now: @escaping @Sendable () -> Date = { Date() },
                registry: PeriodicTaskRegistry = .shared, ttl: TimeInterval = 3600) {
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
        try? preferences.update { $0.lastScan = now() }
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
        for c in clusters {
            guard c.addable else { skipped[c.id] = c.unsupportedReason ?? "This cluster cannot be added."; continue }
            do {
                let full = try await adapter(c.provider).prepareToAdd(c)
                guard full.caData != nil, full.serverURL != nil else { skipped[c.id] = "The cluster has no endpoint or CA yet (is it still being created?)."; continue }
                prepared.append(full)
            } catch { skipped[c.id] = error.localizedDescription }
        }
        let entries = LandfallKubeconfig.entries(for: prepared)
        guard !prepared.isEmpty else {
            return LandfallAddOutcome(ids: [:], added: [], skipped: skipped, checked: [], entries: entries, mergePlan: nil, mergeNote: nil)
        }
        let file = KubeconfigWriter.resolve(landfallFile)
        let regs = prepared.map { LandfallRegistration(key: DiscoveredContextKey(definingFile: file.path, contextName: $0.contextName),
                                                       suggestedEnvironment: $0.suggestion?.environment) }
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
        for (c, r) in zip(prepared, regs) {
            ids[c.id] = r.key.clusterID
            if !c.isSuggestedProduction { toCheck.append(r.key.clusterID) }
        }
        await moorings.startFirstRunChecks(ids: toCheck)

        var plan: KubeconfigMergePlan?
        var note: String?
        if preferences.value.mergeIntoUserKubeconfig {
            do { plan = try planUserMerge(entries) } catch { note = error.localizedDescription }
        }
        return LandfallAddOutcome(ids: ids, added: prepared, skipped: skipped, checked: toCheck, entries: entries, mergePlan: plan, mergeNote: note)
    }

    /// The user pressed **Check** on a row (the only way a Production-suggested row is contacted).
    @discardableResult
    public func check(_ id: ClusterID) async -> ClusterCheckResult { await moorings.check(id) }

    public nonisolated func checkState(_ id: ClusterID) -> ClusterCheckState { moorings.checkStateOf(id) }

    // MARK: Merge into ~/.kube/config

    /// The exact YAML and the backup name, to show before anything is written. Throws while the gate is active.
    public func planUserMerge(_ entries: KubeconfigEntries) throws -> KubeconfigMergePlan {
        let gate = gateProvider()
        let target = try LandfallMergeTarget.resolve(gate: gate)
        return try KubeconfigWriter(gate: gate).plan(entries: entries, into: target, now: now())
    }

    /// Writes the reviewed plan: backup first, `current-context` untouched, verified, restored on any mismatch.
    @discardableResult
    public func confirmUserMerge(_ plan: KubeconfigMergePlan, entries: KubeconfigEntries) throws -> KubeconfigMergeResult {
        let gate = gateProvider()
        _ = try LandfallMergeTarget.resolve(gate: gate)
        return try KubeconfigWriter(gate: gate).merge(plan: plan, entries: entries)
    }

    // MARK: Daily rescan

    /// Creates the daily task when "daily" is chosen and removes it otherwise. With "manual" no `PeriodicTask` exists at all. The task
    /// wakes hourly (also while no window is visible: that is what the user chose) and scans only when a day has passed since the last scan.
    public func applyRescanPolicy() {
        dailyTask?.stop()
        dailyTask = nil
        guard isEnabled, preferences.value.rescan == .daily else { return }
        let task = PeriodicTask(name: Self.taskName, interval: Self.dailyWake, hiddenInterval: Self.dailyWake, registry: registry) { [weak self] in
            await self?.dailyTick()
        }
        dailyTask = task
        task.start()
    }

    public var hasDailyTask: Bool { dailyTask != nil }

    /// One wake of the daily task.
    public func dailyTick() async {
        guard isEnabled, preferences.value.rescan == .daily else { return }
        if let last = preferences.value.lastScan, now().timeIntervalSince(last) < Self.dailyAge { return }
        for provider in CloudProvider.allCases {
            let selected = Set(preferences.value.selectedAccounts[provider.rawValue] ?? [])
            guard !selected.isEmpty, adapters[provider] != nil else { continue }
            guard let all = try? await accounts(provider, force: true) else { continue }
            _ = try? await scan(provider, accounts: all.filter { selected.contains($0.accountID) }, force: true)
        }
        try? preferences.update { $0.lastScan = now() }
    }
}
#endif
