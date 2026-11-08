import Foundation
import WheelhouseKit

/// What selecting a sidebar row opens.
enum SidebarDestination: Hashable, Sendable {
    case search
    case fleet
    case alerts
    case sessions
    case clusterOverview(ClusterID)
    case workloadSummary(ClusterID)
    case kind(ClusterID, ResourceKind)
    case portForwards(ClusterID)
    case feature(WorkspaceDestination)

    var clusterID: ClusterID? {
        switch self {
        case .clusterOverview(let id), .workloadSummary(let id), .kind(let id, _), .portForwards(let id): id
        default: nil
        }
    }
}

/// A problem badge: a coloured dot and a count (critical = red, warning = orange).
struct SidebarBadge: Hashable, Sendable {
    var count: Int
    var severity: HealthStatus

    /// Adds another badge: counts add up, the worst severity wins.
    func merged(with other: SidebarBadge) -> SidebarBadge {
        SidebarBadge(count: count + other.count, severity: max(severity, other.severity))
    }
}

/// One row of the tree (a value type; the outline view keeps its own reference items and diffs against these by `id`).
struct SidebarRow: Identifiable, Hashable, Sendable {
    enum Role: Hashable, Sendable {
        case section        // "CLUSTERS"
        case top            // Search, Fleet, Alerts, Sessions
        case cluster
        case group(SidebarGroupID)
        case kind           // a kind row, workload summary or Wheelhouse-owned extra row
        case apiGroup       // API-group sub-group under Custom Resources
        case featureNode    // a node supplied by a feature (Chart Room, Tides, Survey)
    }

    var id: String
    var role: Role
    /// Disclosure level for VoiceOver: cluster 1, group 2, kind 3, API-group kinds 4 (top-level rows 0).
    var level: Int
    var title: String
    var symbol: String
    var secondary: String?
    var clusterID: ClusterID?
    var kind: ResourceKind?
    var destination: SidebarDestination?
    var isExpandable = false
    var isForbidden = false
    var children: [SidebarRow] = []

    /// Equality of everything the row itself shows (not its children), so the outline view reloads a row only when needed.
    func sameAppearance(as other: SidebarRow) -> Bool {
        id == other.id && title == other.title && symbol == other.symbol && secondary == other.secondary && isExpandable == other.isExpandable
            && isForbidden == other.isForbidden && role == other.role && level == other.level
    }

    var isSelectable: Bool { destination != nil }

    /// Every id below this row, including its own.
    var subtreeIDs: [String] { [id] + children.flatMap(\.subtreeIDs) }
}
