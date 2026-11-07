import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The sidebar column: filter field, the resource tree, and the footer with the Add Cluster menu and the ⋯ menu.
struct SidebarPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(AppRouter.self) private var router
    @Environment(ClusterRegistry.self) private var registry
    @FocusState private var filterFocused: Bool

    private var model: SidebarModel { env.sidebar }

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

            SidebarTree(model: model, selectedRowID: model.rowID(for: env.navigation.selection), token: statuses.joined(separator: ","),
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
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 8) {
            Menu {
                Button("Add Cluster with Token…") { router.push(.addCluster) }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Import File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }
                Divider()
                Button("Discover Kubeconfigs…") {}.disabled(true)
                Button("Add from Cloud…") {}.disabled(true)
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
        router.contentPath = []
        router.detailPath = []
        if let id = destination.clusterID { registry.select(id) }
        env.navigation.selection = destination
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
                    Pasteboard.copy(MacNavigation.kubectlCommand(kind: kind, namespace: registry.namespace(for: id), context: cluster.name))
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
