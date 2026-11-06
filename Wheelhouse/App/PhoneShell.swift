import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// iPhone (and compact-width iPad) navigation: floating-glass `TabView`, each tab owning a `NavigationStack`.
struct PhoneShell: View {
    @Environment(AppRouter.self) private var router
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        @Bindable var router = router
        TabView(selection: $router.selectedTab) {
            Tab("Fleet", image: "wheelhouse.helm", value: AppTab.fleet) {
                stack(.fleet) { FleetDashboardView() }
            }
            Tab("Cluster", systemImage: "gauge.with.dots.needle.67percent", value: AppTab.cluster) {
                stack(.cluster) { ClusterDashboardView() }
            }
            Tab("Resources", systemImage: "square.stack.3d.up", value: AppTab.resources) {
                stack(.resources) { ResourceSectionsView() }
            }
            Tab("Sessions", systemImage: "apple.terminal.on.rectangle", value: AppTab.sessions) {
                stack(.sessions) { SessionsView() }
            }
            Tab(value: AppTab.search, role: .search) {
                stack(.search) { SearchView(initialQuery: router.searchQuery).id(router.searchToken) }
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
    }

    private func stack<Root: View>(_ tab: AppTab, @ViewBuilder root: () -> Root) -> some View {
        @Bindable var router = router
        return NavigationStack(path: router.path(for: tab)) {
            root().navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
    }
}
