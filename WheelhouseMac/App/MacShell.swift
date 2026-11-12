import AppKit
import notify
import os
import SwiftUI
import UniformTypeIdentifiers
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// A workspace window (DESIGN-MAC section 3.1): the resource tree on the left, the tab bar, the pane tree of the selected tab, the
/// status bar and, when open, the inspector. State lives in `WorkspaceStore`; this view only shows it.
///
/// Every iOS screen still runs through `AppRouter` and `RouteDestinationView`, one router per PANE (`WorkspaceWindowModel`). The Mac
/// adds the sidebar tree, the lock overlay, file drops and "Open With" for kubeconfigs, and the import sheet with `MacImportPolicy`.
struct MacShell: View {
    let windowID: WorkspaceWindowID
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let model = env.workspace.model(for: windowID)
        WorkspaceWindowContent(model: model)
            .onAppear { connectOpeners() }
            .task {
                // Restore the other windows of the last run, once, after the first window exists.
                env.whenReady {
                    env.startServices()
                    env.workspace.restoreRemainingWindows()
                }
            }
            .focusedSceneValue(\.workspaceModel, model)
    }

    /// The scenes' `openWindow` is how the controller opens windows (⌘N, Move to New Window, Stations, restoration).
    private func connectOpeners() {
        let open = openWindow
        env.workspace.openWorkspaceWindow = { open(value: $0) }
        env.workspace.openDetachedWindow = { open(value: $0) }
    }
}

extension FocusedValues {
    @Entry var workspaceModel: WorkspaceWindowModel?
}

/// The window's content for one model. Also the content of the tests that host a whole window.
struct WorkspaceWindowContent: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.openSettings) private var openSettings
    let model: WorkspaceWindowModel
    @State private var dropTargeted = false

    private var registry: ClusterRegistry { env.registry }
    private var showsWelcome: Bool { registry.clusters.isEmpty && !registry.isDemoMode }
    private var locked: Bool { env.lock.isLocked }
    /// The router that serves the window itself (the welcome screen); panes have their own.
    private var windowRouter: AppRouter { model.windowRouter }

    var body: some View {
        @Bindable var importer = env.importer
        @Bindable var model = model
        @Bindable var windowRouter = windowRouter
        ZStack {
            // Demo needs no test kubeconfig, so it never waits for the folder prompt.
            if !env.isReady && !registry.isDemoMode {
                StartingView()
            } else if showsWelcome {
                WelcomeView().environment(windowRouter).onAppear { LaunchMarker.firstContentAppeared(gateActive: env.gateActive) }
            } else {
                workspace.disabled(locked).accessibilityHidden(locked)
                    .onAppear { LaunchMarker.firstContentAppeared(gateActive: env.gateActive) }
            }
            if env.lock.isLocked {
                LockScreenView().environment(env.lock.controller).transition(.identity)
            }
        }
        .background(WorkspaceWindowMarker(model: model).frame(width: 0, height: 0))
        .environment(registry)
        .environment(env.preferences)
        .environment(windowRouter)
        .environment(env.lock.controller)
        .environment(env.workspace.network)
        .environment(model.sidebar)
        .environment(\.kubeconfigImportPolicy, env.importer.policy)
        .environment(\.clusterClientFactory, env.clientFactory)
        .environment(\.clusterChangeAllowing, env.moorings.service)
        .environment(\.activityLog, env.activity)
        .tint(Palette.tint)
        .frame(minWidth: 960, minHeight: 600)
        .sheet(item: $importer.presented) { request in
            NavigationStack { KubeconfigImportView(initialFile: request.url) }
                .environment(registry).environment(env.preferences).environment(windowRouter).environment(env.lock.controller).environment(env.workspace.network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .environment(\.clusterClientFactory, env.clientFactory)
                .environment(\.clusterChangeAllowing, env.moorings.service)
                .frame(minWidth: 560, minHeight: 520)
        }
        // The sheet routes the Welcome screen pushes (Add Cluster, Import) and, like every pane, Settings as its own scene.
        .sheet(item: $windowRouter.sheet) { presented in
            SheetRouteView(route: presented.route)
                .environment(env).environment(registry).environment(env.preferences).environment(windowRouter).environment(env.lock.controller).environment(env.workspace.network)
                .environment(\.kubeconfigImportPolicy, env.importer.policy)
                .environment(\.clusterClientFactory, env.clientFactory)
                .environment(\.clusterChangeAllowing, env.moorings.service)
                .frame(minWidth: 520, minHeight: 480)
        }
        .onChange(of: windowRouter.sheet) { _, sheet in
            if sheet?.route == .settings { windowRouter.sheet = nil; openSettings() }
        }
        .sheet(item: $model.sheet) { sheet in
            Group {
                switch sheet {
                case .saveStation: SaveStationSheet(model: model)
                case .stations: StationsView().environment(env).safeAreaInset(edge: .bottom) { HStack { Spacer(); Button("Done") { model.sheet = nil } }.padding() }
                case .pickClusters(let id, let fromLink):
                    if let station = env.workspace.store.stations.first(where: { $0.id == id }) { StationClusterPicker(station: station, fromLink: fromLink).environment(env) }
                }
            }
            .environment(env).environment(registry)
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(MacImportCoordinator.isImportable)
            guard let first = files.first else { return false }
            env.importer.import(url: first, whileLocked: env.lock.isLocked)
            return true
        } isTargeted: { dropTargeted = $0 }
        .overlay { if dropTargeted { RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.tint, style: StrokeStyle(lineWidth: 3, dash: [8, 6])).padding(6).allowsHitTesting(false) } }
        .task {
            NotificationCoordinator.shared.install { env.workspace.handle(url: $0) }
            env.whenReady {
                env.startServices()
                model.focusedPaneChanged()
                // A link that launched the app waited for the first window.
                if !env.lock.isLocked, let url = env.workspace.pendingURL { env.workspace.pendingURL = nil; env.workspace.handle(url: url) }
                openLaunchRequests()
            }
        }
        .onChange(of: env.lock.isLocked) { _, locked in
            if locked {
                model.dismissSheetsForLock()
                Self.lockEngaged(env: env)
            } else {
                if let url = env.workspace.pendingURL { env.workspace.pendingURL = nil; env.workspace.handle(url: url) }
                env.importer.presentDeferred()
            }
        }
        .onChange(of: registry.clusters.map(\.id)) { _, _ in model.sidebar.rebuild() }
        .onChange(of: registry.isDemoMode) { _, _ in
            model.sidebar.rebuild()
            model.mutate { state in for pane in state.selected.panes where !pane.isPlaceholder { state.setRoot(.route(.fleet), in: pane.id) } }
        }
        // A window with an unapplied editor draft cannot be closed with its close button or ⌘W (it would lose the draft); the pane
        // and window menus ask instead.
        .windowDismissBehavior(model.windowHasUnsavedEdits ? .disabled : .automatic)
        .navigationTitle(model.focusedPane?.title(registry: registry) ?? "Wheelhouse")
        .task { env.workspace.announceMovedAsideFileOnce() }
    }

    // MARK: Workspace

    private var workspace: some View {
        let state = model.state
        let hosted = state.tabs.filter { $0.id == state.selectedTab || $0.panes.contains { !$0.stack.allSatisfy { WorkspaceWindowModel.tearsDownWhenHidden($0) } } }
        return NavigationSplitView {
            SidebarPane(window: model)
                .navigationSplitViewColumnWidth(min: 220, ideal: 248, max: 320)
        } detail: {
            VStack(spacing: 0) {
                TabBar(model: model)
                Divider()
                ZStack {
                    ForEach(hosted, id: \.id) { tab in
                        PaneTreeLayout(env: env, model: model, tab: tab, isSelected: tab.id == state.selectedTab)
                        .accessibilityHidden(tab.id != state.selectedTab)
                    }
                }
                Divider()
                StatusBar(model: model)
            }
            .inspector(isPresented: Binding(get: { model.isInspectorOpen }, set: { model.isInspectorOpen = $0 })) {
                InspectorView(model: model).inspectorColumnWidth(min: 300, ideal: 340, max: 480)
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { model.isInspectorOpen.toggle() } label: { Label("Inspector", systemImage: "sidebar.trailing") }
                        .help("Show or Hide Inspector").accessibilityIdentifier("toolbar.inspector")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// App Lock engaged. Everything above the overlays goes: every window's sheets (Stations, Save Station, the cluster picker, Add
    /// Cluster) and every sheet presented by a screen of any window (sign-in, merge review, scanner setup). Run by every workspace
    /// window and by every detached pane window, so it also happens when only detached windows are open. Idempotent.
    static func lockEngaged(env: MacAppEnvironment) {
        for other in env.workspace.allModels { other.dismissSheetsForLock() }
        ChartRoomMemory.scrub()
        env.importer.dismiss()
        coverWindows()
    }

    /// Locking takes the keyboard away from every window (a focused text field or table would otherwise keep receiving keys beneath
    /// the overlay) and closes the Settings window, which the overlay of this window does not cover.
    private static func coverWindows() {
        for window in NSApp.windows {
            for sheet in window.sheets { window.endSheet(sheet) }
            window.makeFirstResponder(nil)
            if window.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true { window.close() }
        }
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

/// A pane torn off into its own window (DESIGN-MAC section 3.4): compact chrome, one pane, no sidebar.
struct DetachedPaneWindow: View {
    let paneID: PaneID
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        let model = env.workspace.detachedModel(for: paneID)
        VStack(spacing: 0) {
            ZStack {
                PaneHost(env: env, model: model, paneID: paneID)
                if env.lock.isLocked { LockScreenView().environment(env.lock.controller).transition(.identity) }
            }
        }
        .background(WorkspaceWindowMarker(model: model).frame(width: 0, height: 0))
        .frame(minWidth: 480, minHeight: 320)
        // With only detached pane windows open, no workspace window is there to react to the lock.
        .onChange(of: env.lock.isLocked) { _, locked in if locked { WorkspaceWindowContent.lockEngaged(env: env) } }
        .windowDismissBehavior(model.windowHasUnsavedEdits ? .disabled : .automatic)
        .navigationTitle(model.pane(paneID)?.title(registry: env.registry) ?? "Pane")
        .focusedSceneValue(\.workspaceModel, model)
    }
}

/// A column screen's minimum size, answered without measuring the screen.
///
/// On the Mac each `NavigationSplitView` column is its own `NSHostingView`, and AppKit asks it for its minimum size in every Auto Layout
/// pass, which follows every SwiftUI update in that column. Measured from the content, that question walked the whole screen (stacks,
/// scroll views, every Text) each time: about 7 ms per update of a log screen's footer, for example (performance pass P1). This layout
/// answers a zero proposal (the minimum) with the constant and passes concrete sizes through, so the screen still fills its column. It
/// sits on a screen inside the column's `NavigationStack` (a modifier outside the stack is not part of the column's measurement), and
/// only on the screens that update many times a second and whose content fits the constant (the resource lists and the log screen).
/// Every other screen (Chart Room and Survey split views, for example, need 840-940 pt) is measured as before, so its real minimum
/// still holds the column open.
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
    /// See ``ConstantMinimumSize``. With `enabled` false the view is unchanged (measured as usual).
    @ViewBuilder
    func constantMinimumSize(width: CGFloat, height: CGFloat, enabled: Bool = true) -> some View {
        if enabled { modifier(ConstantMinimumSize(minimum: CGSize(width: width, height: height))) } else { self }
    }
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
