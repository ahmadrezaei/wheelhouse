import Foundation

/// UserDefaults keys (App Group) for background alerts. `alertsEnabled` and `hideAlertDetailsOnLockScreen`
/// already live on `AppPreferences`; the rest are read here directly so the Settings UI can bind with `@AppStorage(…, store: AppGroup.defaults)`.
public enum AlertKeys {
    public static let enabled = "alertsEnabled"                      // Bool, default true (AppPreferences)
    public static let hideDetails = "hideAlertDetailsOnLockScreen"   // Bool, default false (AppPreferences)
    public static let ruleCrashLoop = "alertRuleCrashLoop"           // Bool, default true
    public static let ruleNodeNotReady = "alertRuleNodeNotReady"     // Bool, default true
    public static let ruleJobFailed = "alertRuleJobFailed"           // Bool, default true
    public static let ruleUnreachable = "alertRuleUnreachable"       // Bool, default false (opt-in)
    public static let quietHoursEnabled = "alertQuietHoursEnabled"   // Bool, default false
    public static let quietStartMinutes = "alertQuietStartMinutes"   // Int minutes after midnight, default 1320 (22:00)
    public static let quietEndMinutes = "alertQuietEndMinutes"       // Int minutes after midnight, default 420 (07:00)
    public static let disabledClusterIDs = "alertDisabledClusterIDs" // [String]; clusters opted out (default: all opted in)
}

public enum AlertRule: String, Codable, Sendable, CaseIterable {
    case crashLoop, nodeNotReady, jobFailed, unreachable

    public init?(_ kind: AttentionKind) {
        switch kind {
        case .crashLoop, .oomKilled: self = .crashLoop
        case .nodeNotReady: self = .nodeNotReady
        case .jobFailed: self = .jobFailed
        case .unreachable: self = .unreachable
        default: return nil
        }
    }
}

public enum AlertLevel: String, Codable, Sendable { case passive, active, timeSensitive }

public struct AlertSettings: Sendable, Equatable {
    public var enabled = true
    public var hideDetails = false
    public var rules: Set<AlertRule> = [.crashLoop, .nodeNotReady, .jobFailed]
    public var quietHoursEnabled = false
    public var quietStartMinutes = 22 * 60
    public var quietEndMinutes = 7 * 60
    public var disabledClusters: Set<String> = []
    public init() {}

    public static func load(from defaults: UserDefaults = AppGroup.defaults) -> AlertSettings {
        func bool(_ key: String, _ fallback: Bool) -> Bool { defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key) }
        func int(_ key: String, _ fallback: Int) -> Int { defaults.object(forKey: key) == nil ? fallback : defaults.integer(forKey: key) }
        var s = AlertSettings()
        s.enabled = bool(AlertKeys.enabled, true)
        s.hideDetails = bool(AlertKeys.hideDetails, false)
        s.rules = []
        if bool(AlertKeys.ruleCrashLoop, true) { s.rules.insert(.crashLoop) }
        if bool(AlertKeys.ruleNodeNotReady, true) { s.rules.insert(.nodeNotReady) }
        if bool(AlertKeys.ruleJobFailed, true) { s.rules.insert(.jobFailed) }
        if bool(AlertKeys.ruleUnreachable, false) { s.rules.insert(.unreachable) }
        s.quietHoursEnabled = bool(AlertKeys.quietHoursEnabled, false)
        s.quietStartMinutes = int(AlertKeys.quietStartMinutes, 22 * 60)
        s.quietEndMinutes = int(AlertKeys.quietEndMinutes, 7 * 60)
        s.disabledClusters = Set(defaults.stringArray(forKey: AlertKeys.disabledClusterIDs) ?? [])
        return s
    }

    public func isEnabled(clusterID: ClusterID) -> Bool { !disabledClusters.contains(clusterID) }

    public mutating func setEnabled(_ on: Bool, clusterID: ClusterID) {
        if on { disabledClusters.remove(clusterID) } else { disabledClusters.insert(clusterID) }
    }

    public func isRuleOn(_ rule: AlertRule) -> Bool { rules.contains(rule) }

    public mutating func setRule(_ rule: AlertRule, on: Bool) {
        if on { rules.insert(rule) } else { rules.remove(rule) }
    }

    /// Writes every setting under the same `AlertKeys` that ``load(from:)`` reads (the master `enabled` / `hideDetails`
    /// toggles are owned by `AppPreferences`; they are written too so a round trip is lossless).
    public func save(to defaults: UserDefaults = AppGroup.defaults) {
        defaults.set(enabled, forKey: AlertKeys.enabled)
        defaults.set(hideDetails, forKey: AlertKeys.hideDetails)
        defaults.set(rules.contains(.crashLoop), forKey: AlertKeys.ruleCrashLoop)
        defaults.set(rules.contains(.nodeNotReady), forKey: AlertKeys.ruleNodeNotReady)
        defaults.set(rules.contains(.jobFailed), forKey: AlertKeys.ruleJobFailed)
        defaults.set(rules.contains(.unreachable), forKey: AlertKeys.ruleUnreachable)
        defaults.set(quietHoursEnabled, forKey: AlertKeys.quietHoursEnabled)
        defaults.set(quietStartMinutes, forKey: AlertKeys.quietStartMinutes)
        defaults.set(quietEndMinutes, forKey: AlertKeys.quietEndMinutes)
        defaults.set(disabledClusters.sorted(), forKey: AlertKeys.disabledClusterIDs)
    }

    /// True when `date` falls inside quiet hours (handles windows that wrap midnight; start == end means never).
    public func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHoursEnabled, quietStartMinutes != quietEndMinutes else { return false }
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minutes = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if quietStartMinutes < quietEndMinutes { return minutes >= quietStartMinutes && minutes < quietEndMinutes }
        return minutes >= quietStartMinutes || minutes < quietEndMinutes
    }
}

/// Persisted between background runs (App Group): which conditions were already notified, and unreachable streaks.
public struct AlertState: Codable, Sendable, Equatable {
    /// fingerprint -> first notified.
    public var notified: [String: Date] = [:]
    /// cluster -> consecutive failed checks.
    public var unreachableStreak: [String: Int] = [:]
    /// crash-loop fingerprint -> restart count when it was last notified (a new alert fires when it rises by 3 or more).
    public var restarts: [String: Int] = [:]
    /// crash-loop fingerprint -> last time it was seen active; a crash loop between two back-offs looks healthy for a moment.
    public var lastActive: [String: Date] = [:]
    public init() {}

    private enum CodingKeys: String, CodingKey { case notified, unreachableStreak, restarts, lastActive }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notified = try c.decodeIfPresent([String: Date].self, forKey: .notified) ?? [:]
        unreachableStreak = try c.decodeIfPresent([String: Int].self, forKey: .unreachableStreak) ?? [:]
        restarts = try c.decodeIfPresent([String: Int].self, forKey: .restarts) ?? [:]
        lastActive = try c.decodeIfPresent([String: Date].self, forKey: .lastActive) ?? [:]
    }

    private static let key = "alertState.v1"
    public static func load(from defaults: UserDefaults = AppGroup.defaults) -> AlertState {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AlertState.self, from: $0) } ?? AlertState()
    }
    public func save(to defaults: UserDefaults = AppGroup.defaults) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

public struct AlertCandidate: Sendable, Equatable, Identifiable {
    public var id: String { fingerprint }
    public var fingerprint: String
    public var clusterID: ClusterID
    public var clusterName: String
    public var rule: AlertRule
    public var level: AlertLevel
    public var title: String
    public var body: String
    public var url: URL?
}

public struct AlertPlan: Sendable, Equatable {
    /// Notifications to post now (individual alerts, or a single summary when > 5).
    public var toPost: [AlertCandidate] = []
    /// Set when `toPost` collapsed into one summary notification.
    public var isSummary = false
    /// Fingerprints that recovered; delivered notifications with these identifiers should be removed.
    public var resolved: Set<String> = []
    public var newState = AlertState()
}

/// Pure rule evaluation + de-duplication. No I/O, fully unit-tested.
public enum AlertPlanner {
    public static let summaryThreshold = 5
    public static let notReadyGrace: TimeInterval = 5 * 60
    public static let unreachableFailuresNeeded = 3
    /// A crash loop alerts again only when the pod restarted this many more times since the last notification.
    public static let restartRiseThreshold = 3
    /// A crash loop that shows as healthy between back-offs keeps its state this long before it counts as recovered.
    public static let crashLoopRecoveryGrace: TimeInterval = 30 * 60

    public static func plan(health: [ClusterHealth], clusterNames: [ClusterID: String], environments: [ClusterID: ClusterEnvironment] = [:],
                            settings: AlertSettings, state: AlertState, now: Date = Date(), calendar: Calendar = .current) -> AlertPlan {
        var plan = AlertPlan()
        var newState = AlertState()
        var active: [String: AlertCandidate] = [:]
        var restartsNow: [String: Int] = [:]
        /// Clusters whose result cannot prove an alert recovered (unreachable, partial or stale): state is carried forward.
        var uncertain: Set<ClusterID> = []
        let checkedClusters = Set(health.map(\.clusterID))

        for h in health where !settings.disabledClusters.contains(h.clusterID) {
            let name = clusterNames[h.clusterID] ?? h.clusterID
            let streak = h.isReachable ? 0 : (state.unreachableStreak[h.clusterID] ?? 0) + 1
            if streak > 0 { newState.unreachableStreak[h.clusterID] = streak }
            if !h.isReachable || h.isPartial || h.isStale { uncertain.insert(h.clusterID) }
            for item in h.items {
                guard let rule = AlertRule(item.kind), settings.rules.contains(rule) else { continue }
                if rule == .nodeNotReady, let since = item.since, now.timeIntervalSince(since) < notReadyGrace { continue }
                if rule == .unreachable, streak < unreachableFailuresNeeded { continue }
                let fp = fingerprint(item)
                active[fp] = candidate(item, fingerprint: fp, rule: rule, clusterName: name, env: environments[h.clusterID], hide: settings.hideDetails)
                if rule == .crashLoop { restartsNow[fp] = item.restarts }
            }
        }
        // Clusters we did not check this run (opted out / timed out) keep their state so we neither re-notify nor lose streaks.
        // Unreachable / partial / stale clusters keep every notified fingerprint too (a timeout or a 403 must not read as "recovered"),
        // except the unreachable alert itself, which resolves normally once the cluster answers again.
        for (fp, date) in state.notified {
            let cluster = fp.split(separator: "|", maxSplits: 1).first.map(String.init) ?? ""
            let isUnreachableAlert = fp.split(separator: "|", maxSplits: 2).dropFirst().first == AlertRule.unreachable.rawValue[...]
            if !checkedClusters.contains(cluster) || settings.disabledClusters.contains(cluster) || (uncertain.contains(cluster) && !isUnreachableAlert) {
                newState.notified[fp] = date
                newState.restarts[fp] = state.restarts[fp]
                newState.lastActive[fp] = state.lastActive[fp]
            }
        }
        for (cluster, n) in state.unreachableStreak where !checkedClusters.contains(cluster) { newState.unreachableStreak[cluster] = n }

        let quiet = settings.isQuiet(at: now, calendar: calendar)
        var fresh: [AlertCandidate] = []
        for (fp, c) in active.sorted(by: { $0.key < $1.key }) {
            let current = restartsNow[fp]
            if current != nil { newState.lastActive[fp] = now }
            if let notifiedAt = state.notified[fp] {
                // Already told; stays until it recovers. A crash loop that kept restarting alerts again.
                newState.notified[fp] = notifiedAt
                let baseline = state.restarts[fp]
                newState.restarts[fp] = baseline ?? current
                if let current, let baseline, current - baseline >= restartRiseThreshold, !quiet, settings.enabled {
                    var again = c
                    again.body = settings.hideDetails ? c.body : "\(c.body) · +\(current - baseline) restarts since the last alert"
                    fresh.append(again)
                    newState.restarts[fp] = current
                }
            } else if !quiet && settings.enabled {                                                 // quiet hours: not recorded, fires later if still active
                fresh.append(c)
                newState.restarts[fp] = current
            }
        }
        // A crash loop looks healthy while the pod waits between back-offs: keep its state for a grace period.
        for (fp, date) in state.notified where newState.notified[fp] == nil && active[fp] == nil {
            guard fp.split(separator: "|", maxSplits: 2).dropFirst().first == AlertRule.crashLoop.rawValue[...],
                  let seen = state.lastActive[fp], now.timeIntervalSince(seen) < crashLoopRecoveryGrace else { continue }
            newState.notified[fp] = date
            newState.restarts[fp] = state.restarts[fp]
            newState.lastActive[fp] = seen
        }
        fresh.sort { ($0.level == .timeSensitive ? 0 : 1, $0.fingerprint) < ($1.level == .timeSensitive ? 0 : 1, $1.fingerprint) }
        for c in fresh { newState.notified[c.fingerprint] = now }

        plan.resolved = Set(state.notified.keys).subtracting(newState.notified.keys).subtracting(active.keys)
        plan.newState = newState
        if fresh.count > summaryThreshold {
            plan.isSummary = true
            let clusters = Set(fresh.map(\.clusterID))
            let first = fresh[0]
            plan.toPost = [AlertCandidate(fingerprint: "summary|\(Int(now.timeIntervalSince1970))", clusterID: first.clusterID, clusterName: "Wheelhouse",
                                          rule: first.rule, level: fresh.contains { $0.level == .timeSensitive } ? .timeSensitive : .active,
                                          title: "\(fresh.count) issues across \(clusters.count) cluster\(clusters.count == 1 ? "" : "s")",
                                          body: settings.hideDetails ? "Issues were detected in your clusters." : "Open Wheelhouse to review them.",
                                          url: clusters.count == 1 ? clusterURL(first.clusterID) : nil)]
        } else {
            plan.toPost = fresh
        }
        return plan
    }

    /// `(cluster, kind, namespace, name, reason)` — cluster first so state can be partitioned by cluster.
    public static func fingerprint(_ item: AttentionItem) -> String {
        let r = item.resource
        // Crash loops and OOM kills are one alert per pod whatever the container is currently reporting.
        if let rule = AlertRule(item.kind), rule == .crashLoop {
            return [item.clusterID, rule.rawValue, r?.namespace ?? "", r?.name ?? item.id].joined(separator: "|")
        }
        return [item.clusterID, item.kind.rawValue, r?.namespace ?? "", r?.name ?? item.id, item.title].joined(separator: "|")
    }

    static func clusterURL(_ id: ClusterID) -> URL? {
        var c = URLComponents(); c.scheme = "wheelhouse"; c.host = "cluster"; c.path = "/\(id)"; return c.url
    }

    private static func candidate(_ item: AttentionItem, fingerprint: String, rule: AlertRule, clusterName: String,
                                  env: ClusterEnvironment?, hide: Bool) -> AlertCandidate {
        let level: AlertLevel = switch rule { case .crashLoop, .nodeNotReady: .timeSensitive; case .jobFailed: .active; case .unreachable: .passive }
        var url = clusterURL(item.clusterID)
        if let ref = item.resource {
            var c = URLComponents(); c.scheme = "wheelhouse"; c.host = "cluster"
            var path = "/\(ref.clusterID)"
            if let ns = ref.namespace { path += "/ns/\(ns)" }
            c.path = path + "/\(ref.kind.plural)/\(ref.name)"
            url = c.url ?? url
        }
        let envWord = env == .production ? "a production cluster" : "a cluster"
        return AlertCandidate(fingerprint: fingerprint, clusterID: item.clusterID, clusterName: clusterName, rule: rule, level: level,
                              title: hide ? clusterName : "\(clusterName) · \(item.title)",
                              body: hide ? "An issue was detected in \(envWord)." : item.detail, url: url)
    }
}

/// Decisions the background refresh makes before touching notifications. Pure, so it is unit-tested.
public enum BackgroundPolicy {
    /// Demo clusters are sample data: never notify for them, whatever the alert settings say.
    public static func shouldPostAlerts(isDemoMode: Bool, settings: AlertSettings) -> Bool { !isDemoMode && settings.enabled }
}
