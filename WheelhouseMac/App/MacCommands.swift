import AppKit
import SwiftUI
import WheelhouseKit

/// Menu-bar commands (DESIGN-MAC section 8). They act on the active window (the key window's `WorkspaceWindowModel`): ⌘0 Fleet,
/// ⌘1–9 clusters, ⌘F Search, ⇧⌘N Add Cluster with Token, ⌃⌘N Create from YAML, ⌘N New Window, ⌘T New Tab, split, focus, zoom, Move,
/// Stations and Activity. Compass, the Rail and Crow's Nest add their commands in M4b.
struct MacCommands: Commands {
    let env: MacAppEnvironment
    @FocusedValue(\.sidebarFilterFocus) private var filterFocus
    @Environment(\.openWindow) private var openWindow

    private var registry: ClusterRegistry { env.registry }
    private var workspace: WorkspaceController { env.workspace }
    private var model: WorkspaceWindowModel? { workspace.activeModel }
    /// While App Lock is on every command that reaches content is off; only Lock and Quit (and the app menu) stay.
    private var locked: Bool { env.lock.isLocked }
    /// Tab and pane commands act on a workspace window, never on a detached pane window (a synthesized one-tab window).
    private var hasWindow: Bool { if let m = model, case .window = m.scope { true } else { false } }
    private var focusedCluster: ClusterConfig? {
        model?.focusedPane?.context.clusterID.flatMap { registry.config(for: $0) } ?? registry.currentCluster
    }
    /// While the Welcome screen shows there is no pane: its sheets belong to the window.
    private var commandRouter: AppRouter? {
        guard let model else { return nil }
        return registry.clusters.isEmpty && !registry.isDemoMode ? model.windowRouter : model.focusedRouter
    }
    private var readOnlyCurrent: Bool { focusedCluster?.readOnly ?? true }

    private func go(_ destination: SidebarDestination) {
        model?.selectSidebar(destination)
    }

    // M11b
    private func showFirstMate(newConversation: Bool) {
        guard let model else { return }
        model.isInspectorOpen = true
        model.mutate { $0.inspector.segment = .firstMate }
        if newConversation { env.firstMate.newConversation(in: "inspector") }
    }
    // end M11b

    var body: some Commands {
        // Wheelhouse
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand()
        }
        CommandGroup(replacing: .appSettings) {
            SettingsLink { Text("Settings…") }.keyboardShortcut(",").disabled(locked)
            Button("Lock Wheelhouse") { env.lock.lockNow() }.disabled(!env.lock.canLock)
        }

        // File
        CommandGroup(replacing: .newItem) {
            Group {
                Button("New Window") { workspace.newWindowOrReopenLast() }.keyboardShortcut("n")
                Button("New Tab") { model?.newTab() }.keyboardShortcut("t").disabled(!hasWindow)
                Button("Close Tab") { if let m = model { m.closeTab(m.selectedTab.id) } }.keyboardShortcut("w", modifiers: [.command, .option]).disabled(!hasWindow)
                Divider()
                Button("Add Cluster with Token…") { commandRouter?.push(.addCluster) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(!hasWindow)
                Button("Import File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }
                Button("Create from YAML…") {
                    if let id = focusedCluster?.id { commandRouter?.push(.createYAML(id, namespace: model?.focusedPane?.context.namespace ?? registry.namespace(for: id))) }
                }
                .keyboardShortcut("n", modifiers: [.command, .control])
                .disabled(!hasWindow || focusedCluster == nil || readOnlyCurrent)
                Divider()
                Button("Open File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }.keyboardShortcut("o")
            }
            .disabled(locked)
        }

        // View
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Group {
                Button("Show Inspector") { model?.isInspectorOpen.toggle() }.keyboardShortcut("0", modifiers: [.command, .option]).disabled(!hasWindow)
                Divider()
                Button("Filter Sidebar…") { filterFocus?.run() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(filterFocus == nil)
                Toggle("Show Forbidden Kinds", isOn: Binding(get: { model?.sidebar.showsForbiddenKinds ?? false }, set: { model?.sidebar.showsForbiddenKinds = $0 }))
                Button("Expand All Groups") { if let id = focusedCluster?.id { model?.sidebar.setAllGroups(expanded: true, in: id) } }
                Button("Collapse All Groups") { if let id = focusedCluster?.id { model?.sidebar.setAllGroups(expanded: false, in: id) } }
            }
            .disabled(locked)
        }

        // Go
        CommandMenu("Go") {
            Group {
                Button("Search…") { go(.search) }.keyboardShortcut("f").disabled(!hasWindow)
                Divider()
                Button("Fleet") { go(.fleet) }.keyboardShortcut("0").disabled(!hasWindow)
                ForEach(Array(registry.clusters.prefix(9).enumerated()), id: \.element.id) { index, cluster in
                    Button(cluster.name) { go(.clusterOverview(cluster.id)) }
                        .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                        .disabled(!hasWindow)
                }
                Divider()
                Button("Alerts") { go(.alerts) }.keyboardShortcut("a", modifiers: [.command, .option]).disabled(!hasWindow)
                Button("Sessions") { go(.sessions) }.keyboardShortcut("e", modifiers: [.command, .option]).disabled(!hasWindow)
                // M11b: First Mate. Opens the inspector on First Mate, bound to the focused pane's selection (Stop is ⌘. in the panel).
                Divider()
                Button("First Mate") { showFirstMate(newConversation: false) }.keyboardShortcut("j").disabled(!hasWindow)
                Button("New First Mate Conversation") { showFirstMate(newConversation: true) }.keyboardShortcut("j", modifiers: [.command, .option]).disabled(!hasWindow)
                // end M11b
            }
            .disabled(locked)
        }

        // Window: tabs, panes, Stations and Activity
        CommandGroup(after: .windowArrangement) {
            Group {
                Divider()
                Button("Next Tab") { model?.selectTab(offset: 1) }.keyboardShortcut("]", modifiers: [.command, .shift]).disabled(!hasWindow)
                Button("Previous Tab") { model?.selectTab(offset: -1) }.keyboardShortcut("[", modifiers: [.command, .shift]).disabled(!hasWindow)
                Button("Move Tab to New Window") { model?.moveTabToNewWindow() }.disabled((model?.state.tabs.count ?? 0) < 2)
                Button("Merge All Windows") { workspace.mergeAllWindows() }.disabled(workspace.models.count < 2)
                Divider()
                Button("Split Right") { model?.split(.horizontal) }.keyboardShortcut("d").disabled(!hasWindow)
                Button("Split Down") { model?.split(.vertical) }.keyboardShortcut("d", modifiers: [.command, .shift]).disabled(!hasWindow)
                Button("Focus Pane Left") { model?.focusPane(.left) }.keyboardShortcut(.leftArrow, modifiers: [.command, .option]).disabled(!hasWindow)
                Button("Focus Pane Right") { model?.focusPane(.right) }.keyboardShortcut(.rightArrow, modifiers: [.command, .option]).disabled(!hasWindow)
                Button("Focus Pane Up") { model?.focusPane(.up) }.keyboardShortcut(.upArrow, modifiers: [.command, .option]).disabled(!hasWindow)
                Button("Focus Pane Down") { model?.focusPane(.down) }.keyboardShortcut(.downArrow, modifiers: [.command, .option]).disabled(!hasWindow)
                Button("Zoom Pane") { model?.zoom() }.keyboardShortcut(.return, modifiers: [.command, .shift]).disabled(!hasWindow)
                Button("Link Pane to Previous Pane") { if let m = model { m.toggleLink(m.focusedPaneID) } }.keyboardShortcut("\\", modifiers: [.command, .option]).disabled(!hasWindow)
                Menu("Move Pane") {
                    ForEach(MoveDirection.allCases, id: \.self) { d in
                        Button(d.rawValue.capitalized) { if let m = model { m.movePane(m.focusedPaneID, d) } }
                    }
                    Divider()
                    Button("New Window") { if let m = model { m.detach(m.focusedPaneID) } }
                }
                .disabled(!hasWindow)
                Divider()
                Menu("Stations") {
                    Button("Save Current Window as Station…") { model?.sheet = .saveStation }.disabled(!hasWindow)
                    Button("Open Station…") { model?.sheet = .stations }.keyboardShortcut("o", modifiers: [.command, .shift]).disabled(!hasWindow)
                    Divider()
                    ForEach(workspace.store.stations.filter { $0.raw == nil }) { station in
                        Button(station.name) { workspace.open(station: station) }
                    }
                }
                Button("Activity") { openWindow(id: "activity") }
            }
            .disabled(locked)
        }
    }
}
