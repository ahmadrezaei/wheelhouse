import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The sidebar column: filter field, the resource tree, and the footer with the Add Cluster menu and the ⋯ menu.
struct SidebarPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(ClusterRegistry.self) private var registry
    @FocusState private var filterFocused: Bool
    /// This window's runtime: its sidebar state, the focused pane and the router that actions go to.
    let window: WorkspaceWindowModel

    private var model: SidebarModel { window.sidebar }
    private var router: AppRouter { window.focusedRouter }

    var body: some View {
        @Bindable var model = model
        // Reading each cluster's status here makes this view re-evaluate when health changes, so the status dots follow.
        let statuses = registry.clusters.map { "\($0.id):\(registry.health(for: $0.id)?.status.rawValue ?? "-")" }
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease").foregroundStyle(.secondary).imageScale(.small).accessibilityHidden(true)
                TextField("Filter", text: $model.filter)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .accessibilityLabel("Filter sidebar")
                    .accessibilityIdentifier("sidebar.filter")
                    .onSubmit { openFirstMatch() }
                if !model.filter.isEmpty {
                    Button { model.filter = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).accessibilityLabel("Clear filter")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Palette.fieldFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 6)

            SidebarTree(model: model, selectedRowID: window.selectedSidebarDestination.flatMap { model.rowID(for: $0) }, token: statuses.joined(separator: ","),
                        decor: { row, expanded in decor(row, expanded: expanded) }, onSelect: select, menu: menu)
                .accessibilityIdentifier("sidebar.tree")
                .accessibilityElement(children: .contain)

            Divider()
            footer
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sidebar")
        .background(Color.clear)
        .focusedSceneValue(\.sidebarFilterFocus, FocusAction { filterFocused = true })
        // A namespace selection changed: the RBAC filter follows it (the model re-reviews the expanded clusters).
        .onChange(of: selectionTokens) { old, new in
            for id in Self.changedClusters(old: old, new: new) { model.namespaceChanged(cluster: id) }
        }
    }

    /// Each cluster's persisted selection, to notice a change.
    private var selectionTokens: [ClusterID: String] {
        Dictionary(registry.clusters.map { ($0.id, registry.namespaceSelection(for: $0.id).encoded) }, uniquingKeysWith: { first, _ in first })
    }

    /// The clusters whose selection differs between two snapshots (a cluster in only one of them is not a selection change).
    static func changedClusters(old: [ClusterID: String], new: [ClusterID: String]) -> [ClusterID] {
        new.filter { id, selection in old[id].map { $0 != selection } ?? false }.keys.sorted()
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Add Cluster with Token…") { router.push(.addCluster) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }
                Divider()
                Button("Discover Kubeconfigs…") {}.disabled(true)
                #if !WH_MAS   // Landfall is not in the App Store edition
                Button("Add from Cloud…") {}.disabled(true)
                #endif
            } label: { Label("Add Cluster", systemImage: "plus") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityIdentifier("sidebar.add")
            Spacer()
            Menu {
                Toggle("Show Forbidden Kinds", isOn: Binding(get: { model.showsForbiddenKinds }, set: { model.showsForbiddenKinds = $0 }))
                Divider()
                Button("Expand All Groups") { if let id = registry.currentCluster?.id { model.setAllGroups(expanded: true, in: id) } }
                Button("Collapse All Groups") { if let id = registry.currentCluster?.id { model.setAllGroups(expanded: false, in: id) } }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel("Sidebar options")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: Selection

    private func select(_ row: SidebarRow) {
        guard let destination = row.destination else { return }
        // A click opens the row in the focused pane; ⌘-click opens a new tab.
        window.selectSidebar(destination, newTab: NSEvent.modifierFlags.contains(.command))
    }

    private func openFirstMatch() {
        func first(_ rows: [SidebarRow]) -> SidebarRow? {
            for r in rows {
                if r.role == .kind || r.role == .featureNode, r.destination != nil { return r }
                if let f = first(r.children) { return f }
            }
            return nil
        }
        if let row = first(model.rows) { select(row) }
    }

    // MARK: Decoration

    private func decor(_ row: SidebarRow, expanded: Bool) -> SidebarDecor {
        var d = SidebarDecor()
        switch row.role {
        case .cluster:
            if let id = row.clusterID, let c = registry.config(for: id) {
                d.status = registry.health(for: id).map { $0.isReachable ? $0.status : .unknown } ?? .unknown
                d.environment = c.environment
                d.isReadOnly = c.readOnly
                d.syncs = c.iCloudSync
            }
            if !expanded { d.badge = model.badges["agg." + row.id] }
        case .group, .apiGroup:
            if !expanded { d.badge = model.badges["agg." + row.id] }
        case .kind:
            d.badge = model.badges[row.id]
            d.count = model.counts[row.id]
        default: break
        }
        if row.id == "top.alerts" { /* the unseen count badge arrives with Crow's Nest (M4b) */ }
        return d
    }

    // MARK: Context menus

    private func menu(_ row: SidebarRow) -> [SidebarMenuItem] {
        guard let id = row.clusterID, let cluster = registry.config(for: id) else { return [] }
        switch row.role {
        case .kind:
            guard let kind = row.kind else { return [] }
            var items: [SidebarMenuItem] = [
                SidebarMenuItem(title: "Copy kubectl Command", symbol: "terminal") {
                    Pasteboard.copy(MacNavigation.kubectlCommand(kind: kind, selection: registry.namespaceSelection(for: id), context: MacNavigation.kubectlContext(for: cluster)))
                },
            ]
            if !cluster.readOnly, !row.isForbidden {
                items.insert(SidebarMenuItem(title: "New \(kind.kind) from YAML…", symbol: "plus.square.on.square") {
                    router.push(.createYAML(id, namespace: kind.namespaced ? registry.namespace(for: id) : nil))
                }, at: 0)
            }
            items.append(.separator)
            items.append(SidebarMenuItem(title: model.showsForbiddenKinds ? "Hide Forbidden Kinds" : "Show Forbidden Kinds", symbol: "lock") { model.showsForbiddenKinds.toggle() })
            return items
        case .group, .apiGroup:
            return [
                SidebarMenuItem(title: "Expand All", symbol: "chevron.down") { model.setAllGroups(expanded: true, in: id) },
                SidebarMenuItem(title: "Collapse All", symbol: "chevron.right") { model.setAllGroups(expanded: false, in: id) },
            ]
        case .cluster:
            return [
                SidebarMenuItem(title: "Open Overview", symbol: "gauge.with.dots.needle.67percent") { select(row) },
                SidebarMenuItem(title: model.keepExpanded.contains(id) ? "Stop Keeping Expanded" : "Keep Expanded", symbol: "pin") { model.toggleKeepExpanded(id) },
                .separator,
                SidebarMenuItem(title: "Refresh Kinds", symbol: "arrow.clockwise") { model.invalidateDiscovery(cluster: id) },
                SidebarMenuItem(title: "Copy Server URL", symbol: "doc.on.doc") { Pasteboard.copy(cluster.server.absoluteString) },
                SidebarMenuItem(title: "Copy Name", symbol: "textformat") { Pasteboard.copy(cluster.name) },
            ]
        default:
            return []
        }
    }
}

/// A closure that can travel as a focused value (focused values must be Equatable-free but need a stable type).
struct FocusAction: Sendable {
    let run: @MainActor @Sendable () -> Void
    init(_ run: @escaping @MainActor @Sendable () -> Void) { self.run = run }
}

extension FocusedValues {
    @Entry var sidebarFilterFocus: FocusAction?
}
