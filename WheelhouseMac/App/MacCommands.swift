import AppKit
import SwiftUI
import WheelhouseKit

/// Menu-bar commands (DESIGN-MAC section 8). They act on the focused window through `@FocusedValue`. M1b implements what the
/// shell has: ⌘0 Fleet, ⌘1–9 clusters, ⌘F Search, ⇧⌘N Add Cluster with Token, ⌃⌘N Create from YAML, ⌘N New Window (the single
/// window comes to the front until M4a), ⌘O Open File…, Lock Wheelhouse, the Go menu and the sidebar items.
struct MacCommands: Commands {
    let env: MacAppEnvironment
    @FocusedValue(\.router) private var router
    @FocusedValue(\.macNavigation) private var navigation
    @FocusedValue(\.sidebarFilterFocus) private var filterFocus
    @Environment(\.openWindow) private var openWindow

    private var registry: ClusterRegistry { env.registry }
    /// While App Lock is on every command that reaches content is off; only Lock and Quit (and the app menu) stay.
    private var locked: Bool { env.lock.isLocked }
    private var readOnlyCurrent: Bool { registry.currentCluster?.readOnly ?? true }

    private func go(_ destination: SidebarDestination) {
        guard let router, let navigation else { return }
        navigation.go(destination, router: router, registry: registry)
    }

    var body: some Commands {
        // Wheelhouse
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand()
        }
        CommandGroup(after: .appSettings) {
            Button("Lock Wheelhouse") { env.lock.lockNow() }.disabled(!env.lock.canLock)
        }

        // File
        CommandGroup(replacing: .newItem) {
            Group {
            Button("New Window") { openWindow(id: "workspace") }.keyboardShortcut("n")
            Divider()
            Button("Add Cluster with Token…") { router?.push(.addCluster) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(router == nil)
            Button("Import File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }
            Button("Create from YAML…") {
                if let id = registry.currentCluster?.id { router?.push(.createYAML(id, namespace: registry.currentNamespace)) }
            }
            .keyboardShortcut("n", modifiers: [.command, .control])
            .disabled(router == nil || registry.currentCluster == nil || readOnlyCurrent)
            Divider()
            Button("Open File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }.keyboardShortcut("o")
            }
            .disabled(locked)
        }

        // View
        SidebarCommands()
        CommandGroup(after: .sidebar) {
            Group {
            Button("Filter Sidebar…") { filterFocus?.run() }.keyboardShortcut("f", modifiers: [.command, .shift]).disabled(filterFocus == nil)
            Toggle("Show Forbidden Kinds", isOn: Binding(get: { env.sidebar.showsForbiddenKinds }, set: { env.sidebar.showsForbiddenKinds = $0 }))
            Button("Expand All Groups") { if let id = registry.currentCluster?.id { env.sidebar.setAllGroups(expanded: true, in: id) } }
            Button("Collapse All Groups") { if let id = registry.currentCluster?.id { env.sidebar.setAllGroups(expanded: false, in: id) } }
            }
            .disabled(locked)
        }

        // Go
        CommandMenu("Go") {
            Group {
            Button("Search…") { go(.search) }.keyboardShortcut("f").disabled(router == nil)
            Divider()
            Button("Fleet") { go(.fleet) }.keyboardShortcut("0").disabled(router == nil)
            ForEach(Array(registry.clusters.prefix(9).enumerated()), id: \.element.id) { index, cluster in
                Button(cluster.name) { go(.clusterOverview(cluster.id)) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(router == nil)
            }
            Divider()
            Button("Alerts") { go(.alerts) }.keyboardShortcut("a", modifiers: [.command, .option]).disabled(router == nil)
            Button("Sessions") { go(.sessions) }.keyboardShortcut("e", modifiers: [.command, .option]).disabled(router == nil)
            }
            .disabled(locked)
        }
    }
}
