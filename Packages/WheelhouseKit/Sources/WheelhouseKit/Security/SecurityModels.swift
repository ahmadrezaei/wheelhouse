import Foundation

/// Finding severity (DESIGN-MAC §6.9). `unknown` is used by the vulnerability sources of M8b; the built-in rules never emit it.
public enum Severity: String, Codable, CaseIterable, Sendable, Comparable {
    case critical, high, medium, low, unknown

    /// 0 = most severe.
    public var rank: Int {
        switch self {
        case .critical: 0
        case .high: 1
        case .medium: 2
        case .low: 3
        case .unknown: 4
        }
    }
    public static func < (a: Severity, b: Severity) -> Bool { a.rank < b.rank }
    public var title: String { rawValue.capitalized }
    /// SARIF `level`.
    public var sarifLevel: String {
        switch self {
        case .critical, .high: "error"
        case .medium: "warning"
        case .low, .unknown: "note"
        }
    }
    /// SARIF `properties.security-severity` (CVSS-like 0-10, used by code-scanning tools).
    public var securitySeverity: String {
        switch self {
        case .critical: "9.5"
        case .high: "8.0"
        case .medium: "5.5"
        case .low: "3.0"
        case .unknown: "0.0"
        }
    }
}

public enum FindingCategory: String, Codable, Sendable { case access, workload }

/// An object a finding refers to (a link target in the UI).
public struct FindingObject: Codable, Hashable, Sendable {
    public var kind: String
    public var namespace: String?
    public var name: String
    public init(kind: String, namespace: String? = nil, name: String) {
        self.kind = kind
        self.namespace = namespace
        self.name = name
    }
    /// The built-in kind, when it is one (users and groups are not objects).
    public var resourceKind: ResourceKind? { ResourceKind.builtIn.first { $0.kind == kind } }
}

/// One result of a Survey rule. The `id` is stable across runs for the same rule and the same object, so accepted risks and
/// links keep working.
public struct SecurityFinding: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var ruleID: String
    public var severity: Severity
    public var clusterID: ClusterID
    public var namespace: String?
    /// The primary object: the workload, the role, the binding or the subject (kind `User`, `Group` or `ServiceAccount`).
    public var object: FindingObject
    public var title: String
    /// The exact spec or rule excerpts that triggered the rule.
    public var evidence: [String]
    /// Objects that contribute (bindings, roles, ...), for links.
    public var related: [FindingObject]
    /// Container names involved (workload rules).
    public var containers: [String]
    /// Set for workload findings, for the suggested patch and the GitOps hint.
    public var workload: WorkloadRef?

    public init(ruleID: String, severity: Severity, clusterID: ClusterID, namespace: String?, object: FindingObject, discriminator: String = "",
                title: String, evidence: [String], related: [FindingObject] = [], containers: [String] = [], workload: WorkloadRef? = nil) {
        self.id = SecurityFinding.makeID(ruleID: ruleID, clusterID: clusterID, namespace: namespace, object: object, discriminator: discriminator)
        self.ruleID = ruleID
        self.severity = severity
        self.clusterID = clusterID
        self.namespace = namespace
        self.object = object
        self.title = title
        self.evidence = evidence
        self.related = related
        self.containers = containers
        self.workload = workload
    }

    public static func makeID(ruleID: String, clusterID: ClusterID, namespace: String?, object: FindingObject, discriminator: String) -> String {
        [ruleID, clusterID, namespace ?? "", "\(object.kind)/\(object.namespace.map { $0 + "/" } ?? "")\(object.name)", discriminator].joined(separator: "|")
    }

    public var category: FindingCategory { ruleID.hasPrefix("WH-A") ? .access : .workload }

    /// `cluster/namespace/kind/name` (SARIF logical location; `-` stands for "no namespace").
    public var logicalLocation: String {
        "\(clusterID)/\(namespace.flatMap { $0.isEmpty ? nil : $0 } ?? "-")/\(object.kind)/\(object.namespace.map { $0 + "/" } ?? "")\(object.name)"
    }

    public var catalogueEntry: SecurityRule? { RuleCatalogue.rule(ruleID) }
}

/// A workload that can be edited: a controller or a bare Pod.
public struct WorkloadRef: Codable, Hashable, Sendable {
    public var kind: String
    public var namespace: String
    public var name: String
    public init(kind: String, namespace: String, name: String) {
        self.kind = kind
        self.namespace = namespace
        self.name = name
    }
    public var resourceKind: ResourceKind? { ResourceKind.builtIn.first { $0.kind == kind } }
    public func resourceRef(clusterID: ClusterID) -> ResourceRef? {
        resourceKind.map { ResourceRef(clusterID: clusterID, kind: $0, namespace: namespace, name: name) }
    }
}

/// A suggested change for a workload finding. M8a opens the YAML editor with the snippet on the pasteboard; M7 will show the diff.
public struct SuggestedPatch: Codable, Hashable, Sendable {
    public var summary: String
    /// YAML to merge into the pod template (`spec.template.spec` of the workload, or `spec` of a bare Pod).
    public var yaml: String
    /// Notes that make the patch safe to read (a Pod's security context is immutable, and so on).
    public var caveat: String?
}

/// Why part of the picture is missing (a forbidden kind degrades the findings; DESIGN-MAC §6.9 states).
public struct SurveyLimitation: Codable, Hashable, Sendable, Identifiable {
    public var kind: String
    public var message: String
    public var id: String { kind }
    public init(kind: String, message: String) {
        self.kind = kind
        self.message = message
    }
}
