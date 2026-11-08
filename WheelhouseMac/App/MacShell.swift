import AppKit
import notify
import os
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
    private var locked: Bool { env.lock.isLocked }
    private var clientFactory: ClusterRegistry.ClientFactory { env.clientFactory }

    var body: some View {
        @Bindable var router = router
        @Bindable var importer = env.importer
        ZStack {
            // Demo needs no test kubeconfig, so it never waits for the folder prompt.
            if !env.isReady && !registry.isDemoMode {
                StartingView()
            } else if showsWelcome {
                WelcomeView().environment(router).onAppear { LaunchMarker.firstContentAppeared(gateActive: env.gateActive) }
            } else {
                workspace.disabled(locked).accessibilityHidden(locked)
                    .onAppear { LaunchMarker.firstContentAppeared(gateActive: env.gateActive) }
            }
            if env.lock.isLocked {
                LockScreenView().environment(env.lock.controller).transition(.identity)
            }
        }
        .background(WorkspaceWindowMarker().frame(width: 0, height: 0))
        .environment(registry)
        .environment(env.preferences)
        .environment(router)
        .environment(env.lock.controller)
        .environment(network)
        .environment(env.sidebar)
        .environment(\.kubeconfigImportPolicy, env.importer.policy)
        .environment(\.clusterClientFactory, clientFactory)
        .environment(\.clusterChangeAllowing, env.moorings.service)
        .focusedSceneValue(\.router, router)
        .focusedSceneValue(\.macNavigation, env.navigation)
        .tint(Palette.tint)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $router.sheet) { presented in
            SheetRouteView(route: presented.route)
                .environment(registry).environment(env.preferences).environment(router).environment(env.lock.controller).environment(network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .environment(\.clusterClientFactory, clientFactory)
                .environment(\.clusterChangeAllowing, env.moorings.service)
                .frame(minWidth: 520, minHeight: 480)
        }
        .sheet(item: $importer.presented) { request in
            NavigationStack { KubeconfigImportView(initialFile: request.url) }
                .environment(registry).environment(env.preferences).environment(router).environment(env.lock.controller).environment(network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .environment(\.clusterClientFactory, clientFactory)
                .environment(\.clusterChangeAllowing, env.moorings.service)
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
            NotificationCoordinator.shared.install { handle($0) }
            env.whenReady {
                env.startServices()
                if let id = registry.currentCluster?.id { env.sidebar.focus(cluster: id) }
                openLaunchRequests()
            }
            for route in env.launchRoutes { router.push(route, from: .content) }
            env.launchRoutes = []
        }
        // Routes queued after the window appeared (performance scenarios apply their layout from the app delegate).
        .onChange(of: env.launchRoutes.count) { _, count in
            guard count > 0 else { return }
            for route in env.launchRoutes { router.push(route, from: .content) }
            env.launchRoutes = []
        }
        .onChange(of: env.lock.isLocked) { _, locked in
            if locked {
                router.sheet = nil
                ChartRoomMemory.scrub()
                env.importer.dismiss()
                Self.coverWindows()
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
                .navigationSplitViewColumnWidth(min: MacContentColumn.minimumWidth, ideal: 600)
        } detail: {
            MacDetailColumn()
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Locking takes the keyboard away from every window (a focused text field or table would otherwise keep receiving keys beneath
    /// the overlay) and closes the Settings window, which the overlay of this window does not cover.
    private static func coverWindows() {
        for window in NSApp.windows {
            window.makeFirstResponder(nil)
            if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { window.close() }
        }
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

/// A column screen's minimum size, answered without measuring the screen.
///
/// On the Mac each `NavigationSplitView` column is its own `NSHostingView`, and AppKit asks it for its minimum size in every Auto Layout
/// pass, which follows every SwiftUI update in that column. Measured from the content, that question walked the whole screen (stacks,
/// scroll views, every Text) each time: about 7 ms per update of a log screen's footer, for example (performance pass P1). This layout
/// answers a zero proposal (the minimum) with the constant and passes concrete sizes through, so the screen still fills its column. It
/// sits on each screen inside the column's `NavigationStack` (a modifier outside the stack is not part of the column's measurement).
struct ConstantMinimumSize: ViewModifier {
    let minimum: CGSize

    func body(content: Content) -> some View {
        MinimumSizeLayout(minimum: minimum) { content }
    }

    struct MinimumSizeLayout: Layout {
        let minimum: CGSize

        func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
            guard let width = proposal.width, let height = proposal.height else {
                // An unspecified dimension (ideal size) is the content's answer, never below the minimum.
                let ideal = subviews.first?.sizeThatFits(proposal) ?? minimum
                return CGSize(width: max(ideal.width, minimum.width), height: max(ideal.height, minimum.height))
            }
            return CGSize(width: max(width, minimum.width), height: max(height, minimum.height))
        }

        func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
            subviews.first?.place(at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
        }

        // No alignment guides from the content: the default asks the content for its guides, which measures and places it, and the
        // enclosing stack asks for them while computing the minimum.
        func explicitAlignment(of guide: HorizontalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
        func explicitAlignment(of guide: VerticalAlignment, in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGFloat? { nil }
    }
}

extension View {
    /// See ``ConstantMinimumSize``.
    func constantMinimumSize(width: CGFloat, height: CGFloat) -> some View { modifier(ConstantMinimumSize(minimum: CGSize(width: width, height: height))) }
}

/// Registers the window that hosts the workspace with ``WorkspaceWindows`` (the energy rules count only these windows).
private struct WorkspaceWindowMarker: NSViewRepresentable {
    final class MarkerView: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { WorkspaceWindows.register(window) }
        }
    }

    func makeNSView(context: Context) -> MarkerView { MarkerView() }
    func updateNSView(_ view: MarkerView, context: Context) {}
}

/// The end of the launch path: the first time the shell shows real content (the workspace or the welcome screen) instead of the
/// Starting view. Emits a `FirstContent` signpost (Instruments, `Launch` category) and, in development builds, the Darwin notification
/// `scripts/perf-launch.swift` times (budget `testLaunch.firstContentP90Sec`, ARCHITECTURE-MAC section 12.3.2). Fires once per process.
@MainActor
enum LaunchMarker {
    static let firstContentNotification = "com.ahmadrezaei.wheelhouse.perf.first-content"
    private static let signposter = OSSignposter(subsystem: Bundle.main.bundleIdentifier ?? "Wheelhouse", category: "Launch")
    private(set) static var firstContentSeen = false

    static func firstContentAppeared(gateActive: Bool) {
        guard !firstContentSeen else { return }
        firstContentSeen = true
        // `onAppear` runs before the frame is committed: mark the end of the transaction that carries it.
        DispatchQueue.main.async {
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                signposter.emitEvent("FirstContent")
                if gateActive { notify_post(firstContentNotification) }
            }
            CATransaction.commit()
        }
    }
}

extension FocusedValues {
    @Entry var macNavigation: MacNavigation?
}

/// Shown until the allowed hosts are known. After five seconds it says what it is waiting for: macOS may be asking for access to the
/// folder that holds the test kubeconfig, and the prompt can sit behind other windows.
private struct StartingView: View {
    @State private var waitedLong = false

    var body: some View {
        VStack(spacing: 10) {
            ProgressView().controlSize(.small).accessibilityLabel("Starting")
            if waitedLong {
                Text("Waiting for access to the folder with the test kubeconfig")
                    .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(for: .seconds(5))
            waitedLong = true
        }
    }
}
