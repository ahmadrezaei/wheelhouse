import SwiftUI
import Observation
import WheelhouseKit

/// App-wide navigation state. One router per window scene; all tabs and iPad columns read from it.
///
/// - `push(_:)`: relative navigation from the current context (rows, buttons). Picks sheet / content / detail automatically.
/// - `open(_:)` / `open(url:)`: absolute navigation (deep links, notifications, widgets).
@MainActor @Observable
final class AppRouter {
    // iPhone
    var selectedTab: AppTab = .fleet
    var fleetPath: [Route] = []
    var clusterPath: [Route] = []
    var resourcesPath: [Route] = []
    var sessionsPath: [Route] = []
    var searchPath: [Route] = []

    // iPad
    private(set) var sidebarSelection: SidebarItem? = .fleet
    var contentPath: [Route] = []
    var detailPath: [Route] = []
    var columnVisibility: NavigationSplitViewVisibility = .all
    /// Clusters expanded in the iPad sidebar (lives here so `open(chain:)` can reveal the target).
    var expandedClusters: Set<ClusterID> = []

    /// Query for the Search destination (tab or sidebar item); `searchToken` changes whenever a new query is opened.
    var searchQuery: String?
    private(set) var searchToken = UUID()

    /// Sheet currently presented (settings, add cluster, create from YAML…).
    var sheet: PresentedRoute?

    /// Set by the shell so `push` knows which layout is on screen.
    var isCompact = true

    /// Mac workspace: every pane owns a router whose navigation belongs to the pane (a stack of destinations). When set, a pushed
    /// route and an absolute `open` go to these closures instead of the stacks above. Sheets still present on this router.
    /// Always nil on iOS and for the Mac's window-level router, so their behaviour is unchanged.
    struct PaneNavigation {
        var push: @MainActor (Route, RouteColumn) -> Void
        var open: @MainActor (Route) -> Void
        var openChain: @MainActor ([Route]) -> Void
        /// fix-N: hands a selection to the panes that follow this one; false when none does (nothing else happens).
        var follow: @MainActor (Route) -> Bool
        /// fix-N: true when a visible pane follows this one.
        var hasFollowers: @MainActor () -> Bool
        /// fix-N: a push that ignores the modifier keys held right now (a delayed click open must not read them when it fires).
        var pushPlain: @MainActor (Route) -> Void
        init(push: @escaping @MainActor (Route, RouteColumn) -> Void, open: @escaping @MainActor (Route) -> Void, openChain: @escaping @MainActor ([Route]) -> Void,
             follow: @escaping @MainActor (Route) -> Bool = { _ in false }, hasFollowers: @escaping @MainActor () -> Bool = { false },
             pushPlain: (@MainActor (Route) -> Void)? = nil) {
            self.push = push; self.open = open; self.openChain = openChain; self.follow = follow; self.hasFollowers = hasFollowers
            self.pushPlain = pushPlain ?? { push($0, .detail) }
        }
    }
    @ObservationIgnored var paneNavigation: PaneNavigation?

    // fix-P: the Mac starts a port-forward without a sheet. The workspace sets this on every pane router; it is always nil on iOS and
    // for the window-level router, so there `forward` is the old sheet.
    @ObservationIgnored var portForwardStarter: (@MainActor (_ ref: ResourceRef, _ port: Int?, _ configure: Bool) -> Void)?

    /// The Mac's per-pane launcher lives and dies with its router (typed `AnyObject` so iOS needn't know the type).
    @ObservationIgnored var portForwardHost: AnyObject?

    /// Port-forward a service or pod. `port` forwards that port, `configure` asks for the advanced form.
    func forward(_ ref: ResourceRef, port: Int? = nil, configure: Bool = false) {
        if let portForwardStarter { portForwardStarter(ref, port, configure) } else { push(.portForward(ref)) }
    }

    /// User-initiated sidebar selection: switching sections clears both columns' stacks. Programmatic navigation
    /// (`open`) sets `sidebarSelection` directly and keeps the detail path it just built.
    func selectSidebar(_ item: SidebarItem?) {
        guard item != sidebarSelection else { return }
        sidebarSelection = item
        contentPath = []
        detailPath = []
        if case .cluster(let id, _)? = item { expandedClusters.insert(id) }
    }

    func path(for tab: AppTab) -> Binding<[Route]> {
        switch tab {
        case .fleet: Binding(get: { self.fleetPath }, set: { self.fleetPath = $0 })
        case .cluster: Binding(get: { self.clusterPath }, set: { self.clusterPath = $0 })
        case .resources: Binding(get: { self.resourcesPath }, set: { self.resourcesPath = $0 })
        case .sessions: Binding(get: { self.sessionsPath }, set: { self.sessionsPath = $0 })
        case .search: Binding(get: { self.searchPath }, set: { self.searchPath = $0 })
        }
    }

    // MARK: Relative navigation

    /// `column` is the iPad column the tapped control lives in (`\.routeColumn`). From the content column a detail route
    /// REPLACES the detail stack; from the detail column it is pushed (drill-down). Ignored on iPhone.
    func push(_ route: Route, from column: RouteColumn = .detail) {
        if route.isSheet { sheet = PresentedRoute(route: route); return }
        if let paneNavigation { paneNavigation.push(route, column); return }
        if isCompact {
            switch selectedTab {
            case .fleet: fleetPath.append(route)
            case .cluster: clusterPath.append(route)
            case .resources: resourcesPath.append(route)
            case .sessions: sessionsPath.append(route)
            case .search: searchPath.append(route)
            }
        } else if route.isDetail {
            if column == .content { detailPath = [route] } else { detailPath.append(route) }
        } else {
            contentPath.append(route)
        }
    }

    /// fix-N: a selection that only a linked pane shows (arrow keys in a list); a no-op on iOS and in a pane nobody follows.
    func follow(_ route: Route) { _ = paneNavigation?.follow(route) }

    /// fix-N: true when a visible linked pane shows what this pane selects.
    var hasFollowers: Bool { paneNavigation?.hasFollowers() ?? false }

    /// fix-N: `push` with the modifiers of the click that started it (none), for a navigation that runs after a delay.
    func pushFromClick(_ route: Route, from column: RouteColumn = .detail) {
        if route.isSheet || paneNavigation == nil { push(route, from: column) } else { paneNavigation?.pushPlain(route) }
    }

    func dismissSheet() { sheet = nil }

    func popToRoot() {
        fleetPath = []; clusterPath = []; resourcesPath = []; sessionsPath = []; searchPath = []
        contentPath = []; detailPath = []
    }

    // MARK: Absolute navigation

    func open(_ route: Route, registry: ClusterRegistry) {
        if let id = route.clusterID { registry.select(id) }
        if route.isSheet { sheet = PresentedRoute(route: route); return }
        if let paneNavigation { paneNavigation.open(route); return }
        switch route {
        case .fleet: showFleet()
        case .alerts: selectedTab = .fleet; fleetPath = [.alerts]; sidebarSelection = .alerts; contentPath = []; detailPath = []
        case .sessions: selectedTab = .sessions; sidebarSelection = .sessions; contentPath = []; detailPath = []
        case .search(let q):
            searchQuery = q; searchToken = UUID()
            selectedTab = .search; searchPath = []
            sidebarSelection = .search; contentPath = []; detailPath = []
        case .cluster(let id): showCluster(id)
        case .resourceSections(let id):
            selectedTab = .resources; resourcesPath = []
            sidebarSelection = .cluster(id, .overview); expandedClusters.insert(id); contentPath = []; detailPath = []
        default: open(chain: [route], registry: registry)
        }
    }

    /// Opens a deep link. Only call this while the app is unlocked (the scene root queues links while locked).
    func open(url: URL, registry: ClusterRegistry) {
        guard let link = DeepLink(url: url), registry.config(for: link.clusterID) != nil else { return }
        registry.select(link.clusterID)
        if let ns = link.namespace { registry.setNamespace(ns, for: link.clusterID) }
        if link.resourceRef == nil { open(link.routes[0], registry: registry) } else { open(chain: link.routes, registry: registry) }
    }

    /// Lands on the last route with the earlier ones beneath it (detail → logs).
    private func open(chain: [Route], registry: ClusterRegistry) {
        if let paneNavigation { paneNavigation.openChain(chain); return }
        if isCompact {
            selectedTab = .resources
            resourcesPath = chain
        } else {
            if let first = chain.first, let id = first.clusterID {
                let section: ResourceSection
                switch first {
                case .resourceDetail(let ref), .yaml(let ref), .logs(let ref, _, _), .shell(let ref, _): section = ref.kind.section
                case .resourceList(_, let kind, _): section = kind.section
                default: section = .workloads
                }
                sidebarSelection = .cluster(id, .section(section))
                expandedClusters.insert(id)
            }
            contentPath = []
            detailPath = chain
        }
    }

    private func showFleet() {
        selectedTab = .fleet; fleetPath = []; sidebarSelection = .fleet; contentPath = []; detailPath = []
    }

    private func showCluster(_ id: ClusterID) {
        selectedTab = .cluster; clusterPath = []
        sidebarSelection = .cluster(id, .overview); expandedClusters.insert(id); contentPath = []; detailPath = []
    }
}

/// Which iPad column a control lives in. Set by `PadShell`; `RouteLink` passes it to the router.
enum RouteColumn: Hashable, Sendable { case content, detail }

private struct RouteColumnKey: EnvironmentKey { static let defaultValue = RouteColumn.detail }
extension EnvironmentValues {
    var routeColumn: RouteColumn {
        get { self[RouteColumnKey.self] }
        set { self[RouteColumnKey.self] = newValue }
    }
}

extension FocusedValues {
    /// The router of the focused scene, for menu commands.
    @Entry var router: AppRouter?
}

/// Tappable row/label that navigates through the router (works in both the tab and split-view layouts).
struct RouteLink<Label: View>: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.routeColumn) private var column
    let route: Route
    @ViewBuilder var label: Label

    var body: some View {
        Button { router.push(route, from: column) } label: { label.contentShape(Rectangle()) }
            .buttonStyle(.plain)
    }
}
