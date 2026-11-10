import SwiftUI
import WheelhouseKit

/// What the pane header and the tab bar call a destination.
extension WorkspaceDestination {
    @MainActor
    func title(registry: ClusterRegistry) -> String {
        func cluster(_ id: ClusterID) -> String { registry.config(for: id)?.name ?? "Cluster" }
        switch self {
        case .route(let route):
            switch route {
            case .fleet: return "Fleet"
            case .alerts: return "Alerts"
            case .cluster(let id): return cluster(id)
            case .resourceSections(let id): return "Workloads · \(cluster(id))"
            case .resourceList(_, let kind, _): return kind.displayName
            case .resourceDetail(let ref): return ref.name
            case .yaml(let ref): return "YAML · \(ref.name)"
            case .createYAML: return "Create from YAML"
            case .logs(let ref, _, let previous): return (previous ? "Previous logs · " : "Logs · ") + ref.name
            case .shell(let ref, _): return "Shell · \(ref.name)"
            case .portForward(let ref): return "Port forward · \(ref.name)"
            case .sessions: return "Sessions"
            case .search: return "Search"
            case .settings: return "Settings"
            case .addCluster: return "Add Cluster"
            case .importKubeconfig: return "Import Kubeconfig"
            }
        case .deckTerminal(let spec): return spec.title ?? "Terminal"
        case .chartRoom(_, let section): return "Chart Room · \(section.rawValue.capitalized)"
        case .helmRelease(let ref): return ref.name
        case .helmInstall(let ref): return "Install \(ref.name)"
        case .survey: return "Survey"
        case .surveyFinding(let id): return id.rawValue
        case .tides: return "Tides"
        case .gitopsApp(let ref): return ref.name
        case .landfall: return "Landfall"
        case .firstMate: return "First Mate"
        case .moorings: return "Moorings"
        case .activity: return "Activity"
        case .station: return "Stations"
        case .riggingView(let ref): return ref.view
        }
    }

    var symbol: String {
        switch self {
        case .route(let route):
            switch route {
            case .fleet: "square.grid.2x2"
            case .alerts: "bell"
            case .cluster: "gauge.with.dots.needle.67percent"
            case .resourceSections: "square.stack.3d.up"
            case .resourceList(_, let kind, _): kind.symbol
            case .resourceDetail(let ref): ref.kind.symbol
            case .yaml, .createYAML: "doc.text"
            case .logs: "text.alignleft"
            case .shell: "terminal"
            case .portForward: "arrow.left.arrow.right"
            case .sessions: "bolt.horizontal"
            case .search: "magnifyingglass"
            case .settings: "gearshape"
            case .addCluster, .importKubeconfig: "plus"
            }
        case .deckTerminal: "terminal"
        case .chartRoom, .helmRelease, .helmInstall: "shippingbox"
        case .survey, .surveyFinding: "checkmark.shield"
        case .tides, .gitopsApp: "arrow.triangle.2.circlepath"
        case .landfall: "cloud"
        case .firstMate: "sparkles"
        case .moorings: "link"
        case .activity: "list.bullet.rectangle"
        case .station: "rectangle.3.group"
        case .riggingView: "puzzlepiece.extension"
        }
    }
}

extension PaneState {
    @MainActor
    func title(registry: ClusterRegistry) -> String {
        if isPlaceholder { return "Couldn't be restored" }
        return top?.title(registry: registry) ?? "Empty"
    }
}
