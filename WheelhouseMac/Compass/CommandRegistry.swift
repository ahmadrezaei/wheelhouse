import AppKit
import Foundation
import WheelhouseKit

/// One command Compass lists under Actions: a menu command with its path and shortcut, which teaches the shortcuts (DESIGN-MAC
/// section 6.7). The shortcut is display text only; the key itself is bound in `MacCommands`.
struct CompassCommand: Identifiable {
    var id: String
    var title: String
    /// Where the command lives in the menu bar: "Window ▸ Split Right".
    var menuPath: String
    var shortcut: String?
    var symbol: String
    var isEnabled: @MainActor () -> Bool
    var perform: @MainActor () -> Void
}

/// Every menu command with its shortcut (ARCHITECTURE-MAC section 12.4). The menus in `MacCommands` are SwiftUI and stay the source of
/// the key bindings; this list mirrors them one to one for Compass, and `CommandRegistryTests` keep ids and shortcuts unique so a
/// copy that drifts into a collision fails the build. Commands act on the active window; while App Lock is on none is enabled.
@MainActor
struct CommandRegistry {
    let commands: [CompassCommand]

    func command(_ id: String) -> CompassCommand? { commands.first { $0.id == id } }

    init(env: MacAppEnvironment, openSettings: @escaping @MainActor () -> Void = {}, openActivity: @escaping @MainActor () -> Void = {}) {
        let workspace = env.workspace
        let locked: @MainActor () -> Bool = { env.lock.isLocked }
        let hasWindow: @MainActor () -> Bool = { if let m = workspace.activeModel, case .window = m.scope { true } else { false } }
        func make(_ id: String, _ title: String, _ path: String, _ shortcut: String? = nil, _ symbol: String = "command",
                  enabled: (@MainActor () -> Bool)? = nil, _ perform: @escaping @MainActor () -> Void) -> CompassCommand {
            CompassCommand(id: id, title: title, menuPath: path, shortcut: shortcut, symbol: symbol,
                           isEnabled: { !locked() && (enabled?() ?? true) }, perform: perform)
        }
        func onWindow(_ id: String, _ title: String, _ path: String, _ shortcut: String? = nil, _ symbol: String = "command",
                      _ perform: @escaping @MainActor (WorkspaceWindowModel) -> Void) -> CompassCommand {
            make(id, title, path, shortcut, symbol, enabled: hasWindow) { if let m = workspace.activeModel { perform(m) } }
        }
        commands = [
            make("file.newWindow", "New Window", "File", "⌘N", "macwindow") { workspace.newWindowOrReopenLast() },
            onWindow("file.newTab", "New Tab", "File", "⌘T", "plus.square") { $0.newTab() },
            onWindow("file.closeTab", "Close Tab", "File", "⌥⌘W", "xmark.square") { $0.closeTab($0.selectedTab.id) },
            onWindow("file.addCluster", "Add Cluster with Token…", "File", "⇧⌘N", "plus.circle") { $0.focusedRouter.push(.addCluster) },
            onWindow("file.addFromCloud", "Add from Cloud…", "File", nil, "cloud") { $0.openInNewTab(.landfall) },
            make("file.import", "Import File…", "File", nil, "square.and.arrow.down") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) },
            make("file.open", "Open File…", "File", "⌘O", "doc") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) },
            onWindow("view.inspector", "Show Inspector", "View", "⌥⌘0", "sidebar.trailing") { $0.isInspectorOpen.toggle() },
            make("view.rail", "Show or Hide Rail", "View", "⇧⌘B", "bookmark") { env.macPreferences.showsRail.toggle() },
            make("view.compass", "Compass…", "Go", "⌘K", "magnifyingglass") { env.compass.toggle() },
            make("go.kind", "Go to Kind…", "Go", "⇧⌘K", "square.grid.2x2") { env.compass.open(seed: "go ") },
            onWindow("go.search", "Search…", "Go", "⌘F", "magnifyingglass") { $0.selectSidebar(.search) },
            onWindow("go.fleet", "Fleet", "Go", "⌘0", "square.grid.2x2") { $0.selectSidebar(.fleet) },
            onWindow("go.alerts", "Alerts", "Go", "⌥⌘A", "bell") { $0.selectSidebar(.alerts) },
            onWindow("go.sessions", "Sessions", "Go", "⌥⌘E", "point.3.connected.trianglepath.dotted") { $0.selectSidebar(.sessions) },
            onWindow("go.firstMate", "First Mate", "Go", "⌘J", "sparkles") { m in
                m.isInspectorOpen = true
                m.mutate { $0.inspector.segment = .firstMate }
            },
            onWindow("window.nextTab", "Next Tab", "Window", "⇧⌘]", "arrow.right.square") { $0.selectTab(offset: 1) },
            onWindow("window.previousTab", "Previous Tab", "Window", "⇧⌘[", "arrow.left.square") { $0.selectTab(offset: -1) },
            onWindow("window.moveTab", "Move Tab to New Window", "Window", nil, "macwindow.badge.plus") { $0.moveTabToNewWindow() },
            make("window.merge", "Merge All Windows", "Window", nil, "rectangle.stack", enabled: { workspace.models.count > 1 }) { workspace.mergeAllWindows() },
            onWindow("window.splitRight", "Split Right", "Window", "⌘D", "rectangle.split.2x1") { $0.split(.horizontal) },
            onWindow("window.splitDown", "Split Down", "Window", "⇧⌘D", "rectangle.split.1x2") { $0.split(.vertical) },
            onWindow("window.focusLeft", "Focus Pane Left", "Window", "⌥⌘←", "arrow.left") { $0.focusPane(.left) },
            onWindow("window.focusRight", "Focus Pane Right", "Window", "⌥⌘→", "arrow.right") { $0.focusPane(.right) },
            onWindow("window.focusUp", "Focus Pane Up", "Window", "⌥⌘↑", "arrow.up") { $0.focusPane(.up) },
            onWindow("window.focusDown", "Focus Pane Down", "Window", "⌥⌘↓", "arrow.down") { $0.focusPane(.down) },
            onWindow("window.zoom", "Zoom Pane", "Window", "⇧⌘↩", "arrow.up.left.and.arrow.down.right") { $0.zoom() },
            onWindow("window.link", "Link Pane to Previous Pane", "Window", "⌥⌘\\", "link") { $0.toggleLink($0.focusedPaneID) },
            onWindow("window.saveStation", "Save Current Window as Station…", "Window ▸ Stations", nil, "rectangle.split.2x2") { $0.sheet = .saveStation },
            onWindow("window.openStation", "Open Station…", "Window ▸ Stations", "⇧⌘O", "rectangle.split.2x2") { $0.sheet = .stations },
            make("window.activity", "Activity", "Window", nil, "list.bullet.rectangle", openActivity),
            onWindow("rail.pin", "Pin to Rail", "Go", "⌥⌘B", "pin") { m in env.rail.pinSelection(of: m) },
            make("app.settings", "Settings…", "Wheelhouse", "⌘,", "gearshape", openSettings),
            make("app.lock", "Lock Wheelhouse", "Wheelhouse", nil, "lock", enabled: { env.lock.canLock }) { env.lock.lockNow() },
            make("nest.pause", "Pause Crow's Nest Checks for 1 Hour", "Crow's Nest", nil, "pause.circle", enabled: { env.macPreferences.showsCrowsNest }) { env.fleet.pause() },
        ]
    }
}
