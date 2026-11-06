import SwiftUI
import WheelhouseKit

/// The ONE place routes become views. Feature code pushes `Route`s; it never constructs another feature's view.
struct RouteDestinationView: View {
    let route: Route

    var body: some View {
        switch route {
        case .fleet: FleetDashboardView()
        case .alerts: AlertsInboxView()
        case .cluster(let id): ClusterDashboardView(clusterID: id)
        case .resourceSections(let id): ResourceSectionsView(clusterID: id)
        case .resourceList(let id, let kind, let namespace): ResourceListView(kind: kind, clusterID: id, namespace: namespace)
        case .resourceDetail(let ref): ResourceDetailView(ref: ref)
        case .yaml(let ref): YAMLEditorView(ref: ref)
        case .createYAML(let id, let namespace): CreateFromYAMLView(clusterID: id, namespace: namespace)
        case .logs(let ref, let container, let previous): LogsView(pod: ref, container: container, previous: previous)
        case .shell(let ref, let container): ExecTerminalView(pod: ref, container: container)
        case .portForward(let ref): PortForwardSetupView(target: ref)
        case .sessions: SessionsView()
        case .search(let query): SearchView(initialQuery: query)
        case .settings: SettingsView()
        case .addCluster: AddClusterView()
        case .importKubeconfig: KubeconfigImportView()
        }
    }
}

/// Wraps a sheet route in its own navigation stack with a Done button.
struct SheetRouteView: View {
    @Environment(AppRouter.self) private var router
    let route: Route

    var body: some View {
        NavigationStack {
            RouteDestinationView(route: route)
                .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
    }
}
