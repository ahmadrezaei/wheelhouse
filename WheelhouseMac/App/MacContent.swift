import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The middle column (the selected screen) and the right column (what was opened from it), as on the iPad: three real split-view
/// columns, each with its own navigation stack.
struct MacContentColumn: View {
    /// Column minimums (``ConstantMinimumSize``): sidebar 220 + content 420 + detail 300 leaves room for the dividers in the window's
    /// minimum width of 960.
    static let minimumWidth: CGFloat = 420
    static let minimumHeight: CGFloat = 300

    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(ClusterRegistry.self) private var registry

    private var selection: SidebarDestination { env.navigation.selection }

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.contentPath) {
            root(selection)
                .constantMinimumSize(width: Self.minimumWidth, height: Self.minimumHeight)
                .id(selection)
                .navigationDestination(for: Route.self) {
                    RouteDestinationView(route: $0).constantMinimumSize(width: Self.minimumWidth, height: Self.minimumHeight)
                }
        }
        .environment(\.routeColumn, .content)
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
}

/// The right column: whatever was opened from the middle one.
struct MacDetailColumn: View {
    static let minimumWidth: CGFloat = 300

    @Environment(AppRouter.self) private var router

    var body: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.detailPath) {
            detailPlaceholder
                .constantMinimumSize(width: Self.minimumWidth, height: MacContentColumn.minimumHeight)
                .navigationDestination(for: Route.self) {
                    RouteDestinationView(route: $0).constantMinimumSize(width: Self.minimumWidth, height: MacContentColumn.minimumHeight)
                }
        }
        .environment(\.routeColumn, .detail)
    }

    @ViewBuilder private var detailPlaceholder: some View {
        EmptyState(.empty(title: "Select a resource", systemImage: "square.stack.3d.up", hint: "Choose an item in the list to see its details."))
    }
}
