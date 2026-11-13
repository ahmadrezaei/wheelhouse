import AppKit
import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The P1 constant-minimum gate, per route: only the screens that update many times a second (the resource lists and the log
/// screen) answer their minimum with a constant. Every other screen is measured so its real minimum still holds.
enum PaneMinimums {
    static let width: CGFloat = 320
    static let height: CGFloat = 180
    static let constantWidth: CGFloat = 420
    static let constantHeight: CGFloat = 300

    static func usesConstantMinimum(route: Route) -> Bool {
        switch route {
        case .resourceList, .logs: true
        default: false
        }
    }

    static func usesConstantMinimum(_ destination: WorkspaceDestination) -> Bool {
        if case .route(let route) = destination { return usesConstantMinimum(route: route) }
        return false
    }
}

/// Everything a screen inside a pane reads from its environment. A pane's hosting view starts with an empty environment (nothing
/// crosses an `NSHostingView` boundary), so the leaf root, the pane's sheets and the detached window all apply this.
struct PaneEnvironment: ViewModifier {
    let env: MacAppEnvironment
    let model: WorkspaceWindowModel
    let router: AppRouter
    /// Whether the pane may draw: its window is visible AND its tab is the selected one.
    var visible: Bool? = nil

    func body(content: Content) -> some View {
        content
            .environment(env)
            .environment(env.registry)
            .environment(env.preferences)
            .environment(router)
            .environment(env.lock.controller)
            .environment(env.workspace.network)
            .environment(model.sidebar)
            .environment(\.kubeconfigImportPolicy, env.importer.policy)
            .environment(\.clusterClientFactory, env.clientFactory)
            .environment(\.clusterChangeAllowing, env.moorings.service)
            .environment(\.gitOpsOwnership, GitOpsOwnershipDetector())
            .environment(\.activityLog, env.activity)
            .environment(\.paneIsVisible, visible ?? model.isVisible)
            .tint(Palette.tint)
    }
}

extension View {
    func paneEnvironment(env: MacAppEnvironment, model: WorkspaceWindowModel, router: AppRouter, visible: Bool? = nil) -> some View {
        modifier(PaneEnvironment(env: env, model: model, router: router, visible: visible))
    }
}

/// How an editor inside a pane says whether it holds unapplied edits (the Manifest Editor's draft). Moving a pane to another window
/// rebuilds its screens, so the workspace asks before it discards them; moves inside the window keep every screen and never ask.
struct PaneEditsReporter {
    let report: @MainActor (_ editor: AnyObject, _ dirty: Bool) -> Void
}

extension EnvironmentValues {
    /// Set on every pane's content (a pane's router sheets reset it); nil outside a workspace pane (the Settings window).
    @Entry var paneEditsReporter: PaneEditsReporter? = nil
}

/// One pane: a 28 pt header (context chip, title, link toggle, ⋯ menu, close) and its content, a navigation stack over the pane's
/// destinations. It reads its own state from the store, so the hosting view's root never changes.
struct PaneHost: View {
    let env: MacAppEnvironment
    let model: WorkspaceWindowModel
    let paneID: PaneID
    var body: some View {
        if let pane = model.pane(paneID) {
            let router = model.router(for: paneID)
            // Every entry of the stack counts: a pushed YAML editor under a list keeps the pane's state alive.
            let tearsDown = pane.stack.allSatisfy { WorkspaceWindowModel.tearsDownWhenHidden($0) }
            let state = model.state
            let tabIndex = state.tabIndex(containing: paneID)
            // A pane parked behind a zoomed one is treated like a pane of a hidden tab.
            let parked = tabIndex.map { state.tabs[$0].zoomedPane.map { $0 != paneID } ?? false } ?? false
            let zoomedHere = tabIndex.map { state.tabs[$0].zoomedPane == paneID } ?? false
            let tabIsSelected = (tabIndex.map { state.tabs[$0].id == state.selectedTab } ?? false) && !parked
            let builds = pane.isPlaceholder || pane.stack.isEmpty || !tearsDown || (tabIsSelected && model.buildsContent)
            let isFocused = model.focusedPaneID == paneID
            let multiple = model.selectedTab.panes.count > 1
            VStack(spacing: 0) {
                PaneHeader(model: model, pane: pane, isFocused: isFocused)
                Divider()
                Group {
                    if pane.isPlaceholder {
                        PlaceholderPane { model.closePane(paneID) }
                    } else if pane.stack.isEmpty {
                        EmptyPane(pane: pane, model: model)
                    } else if builds {
                        PaneStack(env: env, model: model, pane: pane, router: router)
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay { if PaneDragState.shared.isActive { PaneDropTarget(model: model, paneID: paneID) } }
            .simultaneousGesture(TapGesture().onEnded { model.focus(pane: paneID) })
            .overlay { if multiple && isFocused { Rectangle().strokeBorder(Palette.tint.opacity(0.55), lineWidth: 1.5).allowsHitTesting(false) } }
            .paneEnvironment(env: env, model: model, router: router, visible: model.isVisible && tabIsSelected)
            // Only the focused (or zoomed) pane of the selected tab puts its items and its search field in the window toolbar, and
            // none does under the lock (the toolbar is above the lock screen).
            .environment(\.paneContributesToolbar, PaneHost.contributesToolbar(isFocused: isFocused, isZoomed: zoomedHere, tabIsSelected: tabIsSelected,
                                                                                locked: env.lock.isLocked))
            .environment(\.paneEditsReporter, PaneEditsReporter { [model, paneID] editor, dirty in model.editorReported(editor, dirty: dirty, in: paneID) })
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Pane: \(pane.title(registry: env.registry))")
            .accessibilityIdentifier("pane")
            // The pane covers itself under the lock (a detached pane window has no workspace around it): outermost, so the pane
            // element itself leaves the accessibility tree, not just its content.
            .disabled(env.lock.isLocked)
            .accessibilityHidden(env.lock.isLocked)
        } else {
            Color.clear
        }
    }

    static func contributesToolbar(isFocused: Bool, isZoomed: Bool, tabIsSelected: Bool, locked: Bool) -> Bool {
        tabIsSelected && (isFocused || isZoomed) && !locked
    }
}

struct PaneHeader: View {
    @Environment(MacAppEnvironment.self) private var env
    let model: WorkspaceWindowModel
    let pane: PaneState
    let isFocused: Bool

    private var tab: TabState { model.selectedTab }
    private var isDetached: Bool { if case .detached = model.scope { true } else { false } }
    private var cluster: ClusterConfig? { pane.context.clusterID.flatMap { env.registry.config(for: $0) } }
    private var source: PaneState? { pane.link.flatMap { tab.root.pane($0) } }

    var body: some View {
        HStack(spacing: 6) {
            contextChip
            Text(pane.title(registry: env.registry))
                .font(.system(size: 12, weight: isFocused ? .semibold : .regular)).lineLimit(1).truncationMode(.middle)
                .accessibilityIdentifier("pane.title")
            Spacer(minLength: 4)
            if let source {
                Label(source.title(registry: env.registry), systemImage: "link").labelStyle(.titleAndIcon).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .accessibilityLabel("Linked to \(source.title(registry: env.registry))")
            }
            if tab.panes.count > 1 && !isDetached {
                Button { model.toggleLink(pane.id) } label: { Image(systemName: pane.link == nil ? "link" : "link.badge.plus") }
                    .buttonStyle(.plain).help(pane.link == nil ? "Follow another pane's selection" : "Stop following").accessibilityLabel("Link pane")
                    .accessibilityIdentifier("pane.link")
            }
            Menu {
                paneMenu
            } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Pane menu").accessibilityIdentifier("pane.menu")
            Button { if isDetached { model.closeWindow() } else { model.closePane(pane.id) } } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).accessibilityLabel("Close pane").accessibilityIdentifier("pane.close").help("Close Pane")
        }
        .padding(.horizontal, 8)
        .frame(height: 28)
        .background { if !isDetached { PaneDragHandle(model: model, paneID: pane.id) } }
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane.header")
    }

    @ViewBuilder private var contextChip: some View {
        Menu {
            ForEach(env.registry.clusters, id: \.id) { c in
                Button { model.setCluster(c.id, namespace: env.registry.namespace(for: c.id), in: pane.id) } label: {
                    if c.id == pane.context.clusterID { Label(c.name, systemImage: "checkmark") } else { Text(c.name) }
                }
            }
            if !tab.panes.isEmpty, tab.panes.count > 1, let id = pane.context.clusterID {
                Divider()
                Button("Apply \(env.registry.config(for: id)?.name ?? "Cluster") to Every Pane in Tab") {
                    model.setCluster(id, namespace: pane.context.namespace, in: pane.id, everyPaneInTab: true)
                }
            }
        } label: {
            HStack(spacing: 4) {
                if let cluster {
                    Circle().fill(color(cluster.environment)).frame(width: 7, height: 7)
                    Text(cluster.name).lineLimit(1)
                    if cluster.environment == .production { Image(systemName: "shield.fill").imageScale(.small).foregroundStyle(Palette.envProduction) }
                    if let ns = env.registry.namespace(for: cluster.id) { Text("· \(ns)").foregroundStyle(.secondary).lineLimit(1) }
                } else {
                    Text("No cluster").foregroundStyle(.secondary)
                }
            }
            .font(.system(size: 11))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel("Cluster of this pane").accessibilityIdentifier("pane.context")
    }

    private func color(_ e: ClusterEnvironment) -> Color {
        switch e {
        case .production: Palette.envProduction
        case .staging: Palette.envStaging
        case .development: Palette.tint
        case .personal: Palette.unknown
        }
    }

    @ViewBuilder private var paneMenu: some View {
        if !isDetached {
            Button("Split Right") { model.split(.horizontal, pane: pane.id) }
            Button("Split Down") { model.split(.vertical, pane: pane.id) }
            Divider()
            Menu("Move") {
                ForEach(MoveDirection.allCases, id: \.self) { d in
                    Button(d.rawValue.capitalized) { model.movePane(pane.id, d) }.disabled(tab.panes.count < 2)
                }
                Divider()
                Button("New Window") { model.detach(pane.id) }.disabled(tab.panes.count < 2 && model.state.tabs.count < 2)
            }
            Button(tab.zoomedPane == pane.id ? "Restore Pane Size" : "Zoom Pane") { model.zoom(pane: pane.id) }.disabled(tab.panes.count < 2)
            Divider()
            Button("Close Pane") { model.closePane(pane.id) }
        } else {
            Button("Move Back to Workspace Window") { model.attachToWorkspace() }
            Divider()
            Button("Close Window") { model.closeWindow() }
        }
    }
}

/// A pane whose saved state could not be read (an unknown destination from a newer build, a payload that no longer decodes).
/// Its JSON is kept and written back unchanged until the pane is closed.
struct PlaceholderPane: View {
    let close: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text("This pane couldn't be restored").font(.headline)
            Text("It was saved by a different version of Wheelhouse. Its saved layout is kept until you close it.").font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Close Pane", action: close).accessibilityIdentifier("pane.placeholder.close")
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane.placeholder")
    }
}

/// A pane with nothing in it: a fresh linked pane before its first selection, or a pane emptied by its owner.
struct EmptyPane: View {
    @Environment(MacAppEnvironment.self) private var env
    let pane: PaneState
    let model: WorkspaceWindowModel

    var body: some View {
        let source = pane.link.flatMap { model.selectedTab.root.pane($0) }
        EmptyState(.empty(title: source == nil ? "Empty pane" : "Select an item in \(source!.title(registry: env.registry))",
                          systemImage: source == nil ? "rectangle.dashed" : "link",
                          hint: source == nil ? "Choose something in the sidebar." : "This pane shows what you select there."))
    }
}

/// The pane's content: a navigation stack whose root is `stack[0]` and whose path is the rest of the pane's stack.
struct PaneStack: View {
    let env: MacAppEnvironment
    let model: WorkspaceWindowModel
    let pane: PaneState
    @Bindable var router: AppRouter
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        NavigationStack(path: Binding(get: { Array(pane.stack.dropFirst()) }, set: { model.setPushed($0, in: pane.id) })) {
            PaneDestinationView(destination: pane.stack[0])
                .id(pane.stack[0])
                .navigationDestination(for: WorkspaceDestination.self) { PaneDestinationView(destination: $0).environment(router) }   // fix-N: pushed screens always get the pane's router
        }
        .sheet(item: $router.sheet) { presented in
            SheetRouteView(route: presented.route)
                .paneEnvironment(env: env, model: model, router: router)
                // A sheet is its own window: it owns its toolbar, and its editors are not the pane's.
                .environment(\.paneContributesToolbar, true)
                .environment(\.paneEditsReporter, nil)
                .frame(minWidth: 520, minHeight: 480)
        }
        .onChange(of: router.sheet) { _, sheet in
            // Settings is a scene on the Mac, not a sheet.
            if sheet?.route == .settings { router.sheet = nil; openSettings() }
        }
        .onChange(of: env.lock.isLocked) { _, locked in if locked { router.sheet = nil } }
    }
}

/// Renders a destination: iOS routes through `RouteDestinationView`, everything else through the feature registry.
struct PaneDestinationView: View {
    let destination: WorkspaceDestination

    var body: some View {
        switch destination {
        case .route(let route):
            RouteDestinationView(route: route)
                .constantMinimumSize(width: PaneMinimums.constantWidth, height: PaneMinimums.constantHeight, enabled: PaneMinimums.usesConstantMinimum(route: route))
        default:
            if let view = FeatureRegistry.view(for: destination) {
                view
            } else {
                EmptyState(.empty(title: "Not available", systemImage: "hammer", hint: "This view is not part of this build."))
            }
        }
    }
}
