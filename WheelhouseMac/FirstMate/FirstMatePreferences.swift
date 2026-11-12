import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// Settings → First Mate (DESIGN-MAC section 12): model, caps, retention, redaction patterns. Stored in the app's own defaults domain.
/// The API key is not here: it lives in the Mac-private keychain group (`AnthropicKeyStore`).
@MainActor @Observable
final class FirstMatePreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Quick is Sonnet 5.5 at effort low; the default is Opus 5.5 at effort medium.
    var usesQuickByDefault: Bool { didSet { defaults.set(usesQuickByDefault, forKey: "firstMate.quickByDefault") } }
    var conversationCap: Double { didSet { defaults.set(CostCaps(conversation: conversationCap).conversation, forKey: "firstMate.conversationCap") } }
    var dailyCap: Double { didSet { defaults.set(max(dailyCap, 0), forKey: "firstMate.dailyCap") } }
    var showToolCalls: Bool { didSet { defaults.set(showToolCalls, forKey: "firstMate.showToolCalls") } }
    var retention: ConversationRetention { didSet { defaults.set(retention.rawValue, forKey: "firstMate.retentionDays") } }
    /// User-defined redaction patterns (regular expressions), applied on top of the built-in ones before anything leaves the Mac.
    var redactionPatterns: [String] { didSet { defaults.set(redactionPatterns, forKey: "firstMate.redactionPatterns") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["firstMate.quickByDefault": false, "firstMate.conversationCap": CostCaps.defaultConversation,
                                     "firstMate.dailyCap": CostCaps.defaultDaily, "firstMate.showToolCalls": true, "firstMate.retentionDays": 30])
        usesQuickByDefault = defaults.bool(forKey: "firstMate.quickByDefault")
        conversationCap = defaults.double(forKey: "firstMate.conversationCap")
        dailyCap = defaults.double(forKey: "firstMate.dailyCap")
        showToolCalls = defaults.bool(forKey: "firstMate.showToolCalls")
        retention = ConversationRetention(rawValue: defaults.integer(forKey: "firstMate.retentionDays")) ?? .days30
        redactionPatterns = defaults.stringArray(forKey: "firstMate.redactionPatterns") ?? []
    }

    var defaultProfile: AIModelChoice { usesQuickByDefault ? .quick : .standard }
    var redactor: Redactor { Redactor(userPatterns: redactionPatterns) }
}

/// First Mate access per cluster (Allowed, Ask, Never), kept in the Mac-local cluster settings next to the other Mac-only safety
/// settings and never on `ClusterConfig`. A missing entry means the default for the cluster's environment (Production asks).
struct FirstMateClusterSettings: ToolboxClusterSettings {
    static let key = "firstMateAccess"
    let store: MacClusterSettingsStore

    func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess? {
        store.settings(for: cluster.id)?.extra[Self.key]?.stringValue.flatMap(ClusterAccess.init(rawValue:))
    }

    /// Beacon's scopes belong to M12; First Mate never asks.
    func beaconScope(client: String) -> BeaconScope { BeaconScope() }

    /// `nil` goes back to the environment default.
    func set(_ access: ClusterAccess?, for cluster: ClusterID) {
        try? store.update(cluster) { $0.extra[Self.key] = access.map { .string($0.rawValue) } }
    }
}
