import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The M1b workspace window: the resource tree on the left, the selected screen in the middle and, for resource lists and anything
/// opened from a screen, the detail on the right (DESIGN-MAC section 3.1; M4a replaces the middle and right with tabs and panes).
///
/// It reuses every iOS screen through `AppRouter` and `RouteDestinationView`. The Mac adds: the sidebar tree, the lock overlay,
/// file drops and "Open With" for kubeconfigs, notification routing, and the import sheet with `MacImportPolicy`.
struct MacShell: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    @State private var router = AppRouter()
    @State private var network = NetworkMonitor()
    @State private var pendingURL: URL?
    @State private var dropTargeted = false

    private var registry: ClusterRegistry { env.registry }
    private var showsWelcome: Bool { registry.clusters.isEmpty && !registry.isDemoMode }

    var body: some View {
        @Bindable var router = router
        @Bindable var importer = env.importer
        ZStack {
            if showsWelcome { WelcomeView().environment(router) } else { workspace }
            if env.lock.isLocked {
                LockScreenView().environment(env.lock.controller).transition(.identity)
            }
        }
        .environment(registry)
        .environment(env.preferences)
        .environment(router)
        .environment(env.lock.controller)
        .environment(network)
        .environment(env.sidebar)
        .environment(\.kubeconfigImportPolicy, env.importer.policy)
        .focusedSceneValue(\.router, router)
        .focusedSceneValue(\.macNavigation, env.navigation)
        .tint(Palette.tint)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $router.sheet) { presented in
            SheetRouteView(route: presented.route)
                .environment(registry).environment(env.preferences).environment(router).environment(env.lock.controller).environment(network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .frame(minWidth: 520, minHeight: 480)
        }
        .sheet(item: $importer.presented) { request in
            NavigationStack { KubeconfigImportView(initialFile: request.url) }
                .environment(registry).environment(env.preferences).environment(router).environment(env.lock.controller).environment(network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .frame(minWidth: 560, minHeight: 520)
        }
        // A tap on a notification, a deep link or a Finder "Open With" lands here.
        .onOpenURL { handle($0) }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(MacImportCoordinator.isImportable)
            guard let first = files.first else { return false }
            env.importer.import(url: first, whileLocked: env.lock.isLocked)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6])).padding(6).allowsHitTesting(false) } }
        .task {
            router.isCompact = false
            env.startServices()
            NotificationCoordinator.shared.install { handle($0) }
            if let id = registry.currentCluster?.id { env.sidebar.focus(cluster: id) }
            openLaunchRequests()
            for route in env.launchRoutes { router.push(route, from: .content) }
            env.launchRoutes = []
        }
        .onChange(of: env.lock.isLocked) { _, locked in
            if locked {
                router.sheet = nil
                env.importer.dismiss()
            } else {
                if let url = pendingURL { pendingURL = nil; handle(url) }
                env.importer.presentDeferred()
            }
        }
        // Deep links and notification taps move the router; the content column follows.
        .onChange(of: router.sidebarSelection) { _, item in if let item { env.navigation.selection = MacNavigation.destination(for: item) } }
        .onChange(of: router.sheet) { _, sheet in
            // Settings is a scene on the Mac, not a sheet.
            if sheet?.route == .settings { router.sheet = nil; openSettings() }
        }
        .onChange(of: registry.clusters.map(\.id)) { _, _ in env.sidebar.rebuild() }
        .onChange(of: registry.currentClusterID) { _, id in env.sidebar.focus(cluster: id) }
        .onChange(of: registry.isDemoMode) { _, _ in env.sidebar.rebuild(); env.navigation.selection = .fleet }
    }

    // MARK: Workspace

    private var workspace: some View {
        NavigationSplitView {
            SidebarPane()
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } content: {
            MacContentColumn()
                .navigationSplitViewColumnWidth(min: 420, ideal: 600)
        } detail: {
            MacDetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
    }

    // MARK: Opening things

    private func handle(_ url: URL) {
        if env.lock.isLocked { pendingURL = url; return }
        if url.isFileURL {
            if MacImportCoordinator.isImportable(url) { env.importer.import(url: url) }
            return
        }
        if DeepLink.isImport(url) { env.importer.presentOpenPanel(); return }
        router.open(url: url, registry: registry)
    }

    /// Development-only launch hooks: `-WHImportFile <path>` opens the import screen on a file exactly like Finder's Open With.
    private func openLaunchRequests() {
        guard env.gateActive else { return }
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-WHImportFile"), args.indices.contains(i + 1) {
            env.importer.import(url: URL(fileURLWithPath: args[i + 1]), whileLocked: env.lock.isLocked)
        }
    }
}

extension FocusedValues {
    @Entry var macNavigation: MacNavigation?
}
