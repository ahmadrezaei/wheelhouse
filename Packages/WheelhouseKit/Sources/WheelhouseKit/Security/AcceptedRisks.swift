import Foundation

/// What an accepted risk covers.
public enum AcceptanceScope: String, Codable, Sendable, CaseIterable, Identifiable {
    /// This finding only.
    case finding
    /// Every finding of this rule in the same namespace (or the same cluster-scoped objects).
    case ruleInNamespace
    /// Every finding of this rule in the cluster.
    case ruleInCluster
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .finding: "This finding"
        case .ruleInNamespace: "This rule in this namespace"
        case .ruleInCluster: "This rule in this cluster"
        }
    }
}

/// A risk the user accepted for a while (DESIGN-MAC §6.9): a reason, an expiry and a scope. Stored locally and exportable.
public struct AcceptedRisk: Codable, Hashable, Sendable, Identifiable {
    public var id: UUID
    public var ruleID: String
    public var clusterID: ClusterID
    public var scope: AcceptanceScope
    /// Set for `finding`.
    public var findingID: String?
    /// Set for `ruleInNamespace` (empty string = cluster-scoped objects).
    public var namespace: String?
    public var reason: String
    public var createdAt: Date
    public var expiresAt: Date

    public init(id: UUID = UUID(), finding: SecurityFinding, scope: AcceptanceScope, reason: String, createdAt: Date = Date(), days: Int) {
        self.id = id
        self.ruleID = finding.ruleID
        self.clusterID = finding.clusterID
        self.scope = scope
        self.findingID = scope == .finding ? finding.id : nil
        self.namespace = scope == .ruleInNamespace ? (finding.namespace ?? "") : nil
        self.reason = reason
        self.createdAt = createdAt
        self.expiresAt = createdAt.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    public func isExpired(now: Date = Date()) -> Bool { expiresAt <= now }

    public func covers(_ finding: SecurityFinding) -> Bool {
        guard finding.ruleID == ruleID, finding.clusterID == clusterID else { return false }
        switch scope {
        case .finding: return finding.id == findingID
        case .ruleInNamespace: return (finding.namespace ?? "") == (namespace ?? "")
        case .ruleInCluster: return true
        }
    }
}

public enum FindingStatus: Hashable, Sendable {
    case open
    case accepted(until: Date, reason: String)
    public var isAccepted: Bool { if case .accepted = self { true } else { false } }
}

/// The set of accepted risks. Expired entries stay in the book (so the list shows them) but no longer cover findings.
public struct AcceptedRiskBook: Codable, Hashable, Sendable {
    public var risks: [AcceptedRisk] = []
    public init(risks: [AcceptedRisk] = []) { self.risks = risks }

    public func status(of finding: SecurityFinding, now: Date = Date()) -> FindingStatus {
        // The latest expiry wins when several entries cover the same finding.
        let covering = risks.filter { !$0.isExpired(now: now) && $0.covers(finding) }.max { $0.expiresAt < $1.expiresAt }
        guard let covering else { return .open }
        return .accepted(until: covering.expiresAt, reason: covering.reason)
    }

    public mutating func accept(_ finding: SecurityFinding, scope: AcceptanceScope, reason: String, days: Int, now: Date = Date()) {
        risks.append(AcceptedRisk(finding: finding, scope: scope, reason: reason, createdAt: now, days: days))
    }

    public mutating func remove(_ id: UUID) { risks.removeAll { $0.id == id } }
    public mutating func removeExpired(now: Date = Date()) { risks.removeAll { $0.isExpired(now: now) } }
}

/// File persistence of the book. M8b moves it into `survey.sqlite` with the scan data; the model is the same.
public enum AcceptedRiskStorage {
    public static func load(from url: URL) -> AcceptedRiskBook {
        guard let data = try? Data(contentsOf: url), let book = try? decoder.decode(AcceptedRiskBook.self, from: data) else { return AcceptedRiskBook() }
        return book
    }

    public static func save(_ book: AcceptedRiskBook, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(book).write(to: url, options: .atomic)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}
