import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Settings ▸ General: Crow's Nest, the login item, the Rail and the Compass index (DESIGN-MAC section 12, General).
struct MenuBarSettingsSection: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(ClusterRegistry.self) private var registry
    @State private var loginError: String?

    var body: some View {
        @Bindable var mac = env.macPreferences
        Section {
            Toggle("Show Crow's Nest in the menu bar", isOn: $mac.showsCrowsNest)
            Toggle("Keep running in the menu bar when the last window closes", isOn: $mac.keepsRunningInMenuBar).disabled(!mac.showsCrowsNest)
            Picker("Menu bar badge", selection: $mac.menuBarBadge) {
                Text("Dot").tag(MacPreferences.MenuBarBadge.dot)
                Text("Dot and count").tag(MacPreferences.MenuBarBadge.dotAndCount)
                Text("Off").tag(MacPreferences.MenuBarBadge.off)
            }
            .disabled(!mac.showsCrowsNest)
            Toggle("Show the Rail (⇧⌘B)", isOn: $mac.showsRail)
            loginToggle
        } header: { Text("Menu bar and Rail") } footer: {
            Text("Crow's Nest checks Production, Staging, Rail and watched clusters once a minute, including with every window closed. It never starts a watch.")
        }
        if !registry.clusters.isEmpty {
            Section {
                ForEach(registry.clusters) { cluster in
                    HStack {
                        Text(cluster.name)
                        EnvBadge(cluster.environment)
                        Spacer()
                        Toggle("Watch in menu bar", isOn: membership($mac.watchedClusterIDs, cluster.id)).toggleStyle(.checkbox)
                        Toggle("Compass index", isOn: membership($mac.compassIndexedClusterIDs, cluster.id)).toggleStyle(.checkbox)
                    }
                }
            } header: { Text("Clusters") } footer: {
                Text("Compass lists the names, namespaces and labels of the objects of the clusters you choose every 5 minutes while a window is open (about 600 bytes per object, at most 64 MB in all). Secret values are never read. Other clusters contribute only what is already on screen.")
            }
        }
    }

    private func membership(_ set: Binding<Set<String>>, _ id: String) -> Binding<Bool> {
        Binding(get: { set.wrappedValue.contains(id) }, set: { on in
            if on { set.wrappedValue.insert(id) } else { set.wrappedValue.remove(id) }
        })
    }

    @ViewBuilder private var loginToggle: some View {
        let item = env.loginItem
        let status = item.status
        Toggle("Open Wheelhouse at login", isOn: Binding(get: { env.macPreferences.opensAtLogin }, set: { on in
            env.macPreferences.opensAtLogin = on
            do { try item.setEnabled(on); loginError = nil } catch { loginError = error.localizedDescription }
        }))
        .disabled(status == .unavailable)
        if status == .unavailable { Text("Not available in development builds.").font(.caption).foregroundStyle(.secondary) }
        if status == .requiresApproval { Text("Approve Wheelhouse under System Settings ▸ General ▸ Login Items.").font(.caption).foregroundStyle(.secondary) }
        if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
    }
}
