import Foundation
import WheelhouseKit

/// Every destination in the app. Views never build other views directly; they push a `Route`
/// and `RouteDestinationView` maps it to the feature entry view.
enum Route: Hashable, Codable, Sendable {
    case fleet
    case alerts
    case cluster(ClusterID)
    case resourceSections(ClusterID)
    case resourceList(ClusterID, ResourceKind, namespace: String?)
    case resourceDetail(ResourceRef)
    case yaml(ResourceRef)
    case createYAML(ClusterID, namespace: String?)
    case logs(ResourceRef, container: String?, previous: Bool)
    case shell(ResourceRef, container: String?)
    case portForward(ResourceRef)
    case sessions
    case search(query: String?)
    case settings
    case addCluster
    case importKubeconfig

    /// Routes presented as sheets rather than pushed.
    var isSheet: Bool {
        switch self {
        case .settings, .addCluster, .importKubeconfig, .createYAML, .portForward: true
        default: false
        }
    }

    /// Routes that open in the iPad detail column (everything about a single object); others use the content column.
    var isDetail: Bool {
        switch self {
        case .cluster, .resourceDetail, .yaml, .logs, .shell: true
        default: false
        }
    }

    var clusterID: ClusterID? {
        switch self {
        case .cluster(let id), .resourceSections(let id), .resourceList(let id, _, _), .createYAML(let id, _): id
        case .resourceDetail(let r), .yaml(let r), .logs(let r, _, _), .shell(let r, _), .portForward(let r): r.clusterID
        default: nil
        }
    }
}

/// Wrapper so a sheet `Route` is `Identifiable`.
struct PresentedRoute: Identifiable, Hashable {
    let route: Route
    var id: Route { route }
}

enum AppTab: String, Hashable, CaseIterable {
    case fleet, cluster, resources, sessions, search
}

/// Cluster sections shown under each cluster in the iPad sidebar.
enum ClusterSection: Hashable, CaseIterable {
    case overview
    case section(ResourceSection)

    static var allCases: [ClusterSection] { [.overview] + ResourceSection.allCases.map { .section($0) } }
    var title: String { if case .section(let s) = self { s.title } else { "Overview" } }
    var symbol: String { if case .section(let s) = self { s.symbol } else { "gauge.with.dots.needle.67percent" } }
}

enum SidebarItem: Hashable {
    case search
    case fleet
    case alerts
    case sessions
    case cluster(ClusterID, ClusterSection)
}
