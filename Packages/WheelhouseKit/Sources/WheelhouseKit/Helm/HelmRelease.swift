import Foundation

/// Release lifecycle states, as Helm names them in `info.status` and in the `status` label.
public enum HelmReleaseStatus: String, Sendable, Hashable, CaseIterable {
    case unknown, deployed, uninstalled, superseded, failed, uninstalling
    case pendingInstall = "pending-install"
    case pendingUpgrade = "pending-upgrade"
    case pendingRollback = "pending-rollback"

    public init(label: String?) { self = label.flatMap(HelmReleaseStatus.init(rawValue:)) ?? .unknown }

    /// Failed and pending-* releases are pinned on top of the table.
    public var needsAttention: Bool {
        switch self {
        case .failed, .pendingInstall, .pendingUpgrade, .pendingRollback: true
        default: false
        }
    }

    public var isPending: Bool { self == .pendingInstall || self == .pendingUpgrade || self == .pendingRollback }
}

/// A fully decoded Helm release record (`sh.helm.release.v1.<name>.v<N>`). Decoding is lenient: a missing or retyped field
/// leaves its default, and unknown fields are kept in `extra` so a newer Helm never breaks the screen.
public struct HelmRelease: Sendable, Hashable {
    public struct Info: Sendable, Hashable {
        public var firstDeployed: Date?
        public var lastDeployed: Date?
        public var deleted: Date?
        public var description: String
        public var status: HelmReleaseStatus
        public var notes: String
        public var extra: JSONValue
    }

    public struct Maintainer: Sendable, Hashable { public var name: String; public var email: String?; public var url: String? }

    public struct Dependency: Sendable, Hashable {
        public var name: String
        public var version: String?
        public var repository: String?
        public var condition: String?
        public var alias: String?
    }

    public struct ChartMetadata: Sendable, Hashable {
        public var name: String
        public var version: String
        public var appVersion: String?
        public var description: String?
        public var icon: String?
        public var apiVersion: String?
        public var home: String?
        public var kubeVersion: String?
        public var type: String?
        public var keywords: [String]
        public var sources: [String]
        public var maintainers: [Maintainer]
        public var dependencies: [Dependency]
        public var extra: JSONValue
    }

    public struct Chart: Sendable, Hashable {
        public var metadata: ChartMetadata
        /// The chart's default values (`values.yaml`).
        public var values: JSONValue
        /// `values.schema.json`, decoded from its base64 form.
        public var schema: Data?
        public var templateCount: Int
        public var fileNames: [String]
    }

    public struct HookRun: Sendable, Hashable {
        public var phase: String
        public var startedAt: Date?
        public var completedAt: Date?
    }

    public struct Hook: Sendable, Hashable, Identifiable {
        public var name: String
        public var kind: String
        public var path: String
        public var manifest: String
        public var events: [String]
        public var weight: Int
        public var deletePolicies: [String]
        public var lastRun: HookRun?
        public var id: String { "\(kind)/\(name)/\(path)" }
    }

    public var name: String
    public var namespace: String
    public var version: Int
    public var info: Info
    public var chart: Chart
    /// The user-supplied values (`helm get values`).
    public var config: JSONValue
    public var manifest: String
    public var hooks: [Hook]
    public var labels: [String: String]
    /// Unknown top-level fields.
    public var extra: JSONValue
    /// Size of the decompressed JSON, used as the cache cost.
    public var payloadBytes: Int

    /// Computed values (`helm get values --all`): chart defaults with the user values merged over them.
    public var computedValues: JSONValue { Self.merge(chart.values, config) }

    static func merge(_ base: JSONValue, _ overlay: JSONValue) -> JSONValue {
        guard case .object(var result) = base, case .object(let over) = overlay else {
            return overlay.isNull ? base : overlay
        }
        for (key, value) in over {
            if let existing = result[key], case .object = existing, case .object = value {
                result[key] = merge(existing, value)
            } else if value.isNull {
                result[key] = nil                       // Helm: an explicit null deletes the default
            } else {
                result[key] = value
            }
        }
        return .object(result)
    }
}
