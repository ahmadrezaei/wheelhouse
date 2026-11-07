import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The middle (and, when something is open, right) part of the window. Resource lists get a detail column next to them;
/// dashboards use the full width until something is opened from them.
struct MacContent: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(ClusterRegistry.self) private var registry

    private var selection: SidebarDestination { env.navigation.selection }

    private var showsSplit: Bool {
        if case .kind = selection { return true }
        return !router.detailPath.isEmpty
    }

    var body: some View {
        Group {
            if showsSplit {
                HSplitView {
                    contentStack.frame(minWidth: 380, idealWidth: 560)
                    detailStack.frame(minWidth: 360, idealWidth: 480)
                }
            } else {
                contentStack
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var contentStack: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.contentPath) {
            root(selection)
                .id(selection)
                .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
        .environment(\.routeColumn, .content)
    }

    private var detailStack: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.detailPath) {
            detailPlaceholder
                .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
        .environment(\.routeColumn, .detail)
    }

    @ViewBuilder private func root(_ selection: SidebarDestination) -> some View {
        switch selection {
        case .search: SearchView(initialQuery: router.searchQuery).id(router.searchToken)
        case .fleet: FleetDashboardView()
        case .alerts: AlertsInboxView()
        case .sessions, .portForwards: SessionsView()
        case .clusterOverview(let id): ClusterDashboardView(clusterID: id)
        case .workloadSummary(let id): ResourceSectionsView(clusterID: id)
        case .kind(let id, let kind): ResourceListView(kind: kind, clusterID: id)
        case .feature(let destination):
            if let view = FeatureRegistry.view(for: destination) { view } else { EmptyState(.empty(title: "Not available", systemImage: "hammer", hint: "This view is not part of this build.")) }
        }
    }

    @ViewBuilder private var detailPlaceholder: some View {
        EmptyState(.empty(title: "Select a resource", systemImage: "square.stack.3d.up", hint: "Choose an item in the list to see its details."))
    }
}
