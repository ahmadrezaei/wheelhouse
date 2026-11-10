import Foundation
import WheelhouseKit

/// Which cluster a destination belongs to, and the same destination moved to another cluster. Used by the context switcher
/// (switch a pane's cluster keeping its view) and by template Stations (placeholders replaced by the chosen clusters).
extension Route {
    func replacingClusters(_ map: (ClusterID) -> ClusterID) -> Route {
        func ref(_ r: ResourceRef) -> ResourceRef { var c = r; c.clusterID = map(r.clusterID); return c }
        switch self {
        case .cluster(let id): return .cluster(map(id))
        case .resourceSections(let id): return .resourceSections(map(id))
        case .resourceList(let id, let kind, let ns): return .resourceList(map(id), kind, namespace: ns)
        case .resourceDetail(let r): return .resourceDetail(ref(r))
        case .yaml(let r): return .yaml(ref(r))
        case .createYAML(let id, let ns): return .createYAML(map(id), namespace: ns)
        case .logs(let r, let container, let previous): return .logs(ref(r), container: container, previous: previous)
        case .shell(let r, let container): return .shell(ref(r), container: container)
        case .portForward(let r): return .portForward(ref(r))
        case .fleet, .alerts, .sessions, .search, .settings, .addCluster, .importKubeconfig: return self
        }
    }
}

extension WorkspaceDestination {
    /// The cluster the destination is about (nil for fleet-wide ones).
    var clusterID: ClusterID? {
        switch self {
        case .route(let r): r.clusterID
        case .deckTerminal(let s): s.clusterID
        case .chartRoom(let id, _): id
        case .helmRelease(let r): r.clusterID
        case .survey(let s): s.clusterID
        case .tides(let s): s.clusterID
        case .gitopsApp(let r): r.clusterID
        case .riggingView(let r): r.clusterID
        case .helmInstall, .surveyFinding, .landfall, .firstMate, .moorings, .activity, .station: nil
        }
    }

    /// Every cluster the destination mentions, mapped through `map` (a nil cluster stays nil).
    func replacingClusters(_ map: (ClusterID) -> ClusterID) -> WorkspaceDestination {
        switch self {
        case .route(let r): return .route(r.replacingClusters(map))
        case .deckTerminal(var s): s.clusterID = s.clusterID.map(map); return .deckTerminal(s)
        case .chartRoom(let id, let section): return .chartRoom(map(id), section)
        case .helmRelease(var r): r.clusterID = map(r.clusterID); return .helmRelease(r)
        case .survey(var s): s.clusterID = s.clusterID.map(map); return .survey(s)
        case .tides(var s): s.clusterID = s.clusterID.map(map); return .tides(s)
        case .gitopsApp(var r): r.clusterID = map(r.clusterID); return .gitopsApp(r)
        case .riggingView(var r): r.clusterID = r.clusterID.map(map); return .riggingView(r)
        case .helmInstall, .surveyFinding, .landfall, .firstMate, .moorings, .activity, .station: return self
        }
    }

    /// Where the sidebar highlights this destination (the selected row), when it has a row.
    var sidebarDestination: SidebarDestination? {
        switch self {
        case .route(.fleet): .fleet
        case .route(.alerts): .alerts
        case .route(.sessions): .sessions
        case .route(.search): .search
        case .route(.cluster(let id)): .clusterOverview(id)
        case .route(.resourceSections(let id)): .workloadSummary(id)
        case .route(.resourceList(let id, let kind, _)): .kind(id, kind)
        default: .feature(self)
        }
    }

    /// What a sidebar row opens in a pane.
    init(_ row: SidebarDestination) {
        switch row {
        case .search: self = .route(.search(query: nil))
        case .fleet: self = .route(.fleet)
        case .alerts: self = .route(.alerts)
        case .sessions, .portForwards: self = .route(.sessions)
        case .clusterOverview(let id): self = .route(.cluster(id))
        case .workloadSummary(let id): self = .route(.resourceSections(id))
        case .kind(let id, let kind): self = .route(.resourceList(id, kind, namespace: nil))
        case .feature(let d): self = d
        }
    }
}

extension TabState {
    func replacingClusters(_ map: (ClusterID) -> ClusterID) -> TabState {
        var copy = self
        copy.root = root.mapPanes { pane in
            guard !pane.isPlaceholder else { return pane }
            var p = pane
            p.stack = pane.stack.map { $0.replacingClusters(map) }
            p.context.clusterID = pane.context.clusterID.map(map)
            return p
        }
        return copy
    }

    /// Every cluster mentioned by a pane of the tab, in first-seen order.
    var clusterIDs: [ClusterID] {
        var seen: [ClusterID] = []
        for pane in panes where !pane.isPlaceholder {
            for id in ([pane.context.clusterID].compactMap { $0 } + pane.stack.compactMap(\.clusterID)) where !seen.contains(id) { seen.append(id) }
        }
        return seen
    }
}
