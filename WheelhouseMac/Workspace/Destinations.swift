import Foundation
import WheelhouseKit

// FROZEN payload types of `WorkspaceDestination` (ARCHITECTURE-MAC §12.2, §15.3).
//
// Later milestones may only ADD OPTIONAL FIELDS. They never rename, remove or retype a field or a case, and never reorder
// anything that is encoded. `WorkspaceCodingTests` pins the encoding of one sample per case (golden JSON).
//
// Identifier types encode as a single JSON string.

struct ConversationID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

struct StationID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

struct FindingID: Codable, Hashable, Sendable, RawRepresentable, ExpressibleByStringLiteral {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    init(stringLiteral value: String) { rawValue = value }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

/// A Deck Terminal: a local shell, optionally bound to a cluster context. Terminals reopen as NEW shells on restore.
struct TerminalSpec: Codable, Hashable, Sendable {
    var clusterID: ClusterID?
    var namespace: String?
    /// Executable path of a custom shell; nil = the login shell.
    var shell: String?
    /// Directory to start in; nil = the Settings default.
    var startDirectory: String?
    var title: String?
}

enum ChartRoomSection: String, Codable, Hashable, Sendable, CaseIterable {
    case releases, charts, repositories
}

struct HelmReleaseRef: Codable, Hashable, Sendable {
    var clusterID: ClusterID
    var namespace: String
    var name: String
    var revision: Int?
}

struct ChartRef: Codable, Hashable, Sendable {
    /// Repository name as configured in helm; nil for an OCI reference or a local path.
    var repository: String?
    var name: String
    var version: String?
    /// `oci://…` reference, when the chart is not from a named repository.
    var ociReference: String?
}

enum SurveyTab: String, Codable, Hashable, Sendable, CaseIterable {
    case overview, vulnerabilities, access, workload
}

struct SurveyScope: Codable, Hashable, Sendable {
    /// nil = fleet-wide.
    var clusterID: ClusterID?
    var tab: SurveyTab
    var namespace: String?
}

enum TidesTool: String, Codable, Hashable, Sendable { case argoCD, flux }

struct TidesScope: Codable, Hashable, Sendable {
    /// nil = fleet-wide.
    var clusterID: ClusterID?
    var tool: TidesTool?
}

struct RiggingViewRef: Codable, Hashable, Sendable {
    var pack: String
    var view: String
    var clusterID: ClusterID?
    var namespace: String?
}

// `gitopsApp` carries the Kit `ResourceRef` (clusterID, kind, namespace, name), whose Codable shape is pinned by the golden test.
