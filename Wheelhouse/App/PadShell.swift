import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// iPad regular-width navigation: sidebar (fleet, alerts, sessions, clusters → sections) · content · detail.
struct PadShell: View {
    @Environment(AppRouter.self) private var router
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        @Bindable var router = router
        NavigationSplitView(columnVisibility: $router.columnVisibility) {
            sidebar
        } content: {
            contentColumn
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        // User taps go through `selectSidebar` (clears both stacks). Programmatic `open(...)` sets the selection itself
        // and keeps the detail path it built, so deep links are no longer wiped.
        let selection = Binding<SidebarItem?>(get: { router.sidebarSelection }, set: { router.selectSidebar($0) })
        let unseenAlerts = AlertsSeen.shared.unseenCount(in: FleetModel.shared.alerts(in: registry))
        return List(selection: selection) {
            Label("Search", systemImage: "magnifyingglass").tag(SidebarItem.search)
            Label("Fleet", image: "wheelhouse.helm").tag(SidebarItem.fleet)
            Label("Alerts", systemImage: "bell").badge(unseenAlerts).tag(SidebarItem.alerts)
            Label("Sessions", systemImage: "apple.terminal.on.rectangle").tag(SidebarItem.sessions)
            Section("Clusters") {
                ForEach(registry.clusters) { cluster in
                    DisclosureGroup(isExpanded: Binding(get: { router.expandedClusters.contains(cluster.id) }, set: { if $0 { router.expandedClusters.insert(cluster.id) } else { router.expandedClusters.remove(cluster.id) } })) {
                        ForEach(ClusterSection.allCases, id: \.self) { section in
                            Label(section.title, systemImage: section.symbol).tag(SidebarItem.cluster(cluster.id, section))
                        }
                    } label: {
                        HStack(spacing: 8) {
                            Circle().fill(registry.health(for: cluster.id)?.status.color ?? HealthStatus.unknown.color).frame(width: 9, height: 9)
                            Text(cluster.name).lineLimit(1)
                            EnvBadge(cluster.environment)
                        }
                    }
                }
            }
        }
        .navigationTitle("Wheelhouse")
        .safeAreaInset(edge: .bottom) {
            Button { router.push(.settings) } label: { Label("Settings", systemImage: "gearshape").frame(maxWidth: .infinity) }
                .buttonStyle(.glass).padding(.horizontal).padding(.bottom, 8)
        }
        .onAppear { if let id = registry.currentCluster?.id { router.expandedClusters.insert(id) } }
    }

    // MARK: Content

    @ViewBuilder private var contentRoot: some View {
        switch router.sidebarSelection ?? .fleet {
        case .search: SearchView(initialQuery: router.searchQuery).id(router.searchToken)
        case .fleet: FleetDashboardView()
        case .alerts: AlertsInboxView()
        case .sessions: SessionsView()
        case .cluster(let id, .overview): ResourceSectionsView(clusterID: id)
        case .cluster(let id, .section(let section)):
            ResourceListView(kind: ResourceKind.builtIn(in: section).first ?? .customResourceDefinition, clusterID: id)
        }
    }

    private var contentColumn: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.contentPath) {
            contentRoot
                .id(router.sidebarSelection)
                .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
        .environment(\.routeColumn, .content)
        .navigationSplitViewColumnWidth(min: 320, ideal: 380, max: 480)
    }

    // MARK: Detail

    @ViewBuilder private var detailPlaceholder: some View {
        switch router.sidebarSelection ?? .fleet {
        case .fleet:
            EmptyState(.empty(title: "Select a cluster", systemImage: "server.rack", hint: "Choose a cluster in the list to see its dashboard."))
        case .alerts:
            EmptyState(.empty(title: "Select an alert", systemImage: "bell", hint: "Choose an alert to open the affected resource."))
        case .sessions:
            EmptyState(.empty(title: "Select a session", systemImage: "apple.terminal", hint: "Choose a session to reopen it."))
        case .search:
            EmptyState(.empty(title: "Select a result", systemImage: "magnifyingglass", hint: "Choose a result to see its details."))
        case .cluster:
            EmptyState(.empty(title: "Select a resource", systemImage: "square.stack.3d.up", hint: "Choose an item in the list to see its details."))
        }
    }

    private var detailColumn: some View {
        @Bindable var router = router
        return NavigationStack(path: $router.detailPath) {
            Group {
                if case .cluster(let id, .overview)? = router.sidebarSelection { ClusterDashboardView(clusterID: id) }
                else { detailPlaceholder }
            }
            .navigationDestination(for: Route.self) { RouteDestinationView(route: $0) }
        }
        .environment(\.routeColumn, .detail)
    }
}
