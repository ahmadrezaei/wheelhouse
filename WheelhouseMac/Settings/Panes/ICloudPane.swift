import SwiftUI
import WheelhouseKit

/// iCloud: per-cluster Keychain sync (the iOS "iCloud" section). Development builds use their own keychain group, which cannot see
/// the shared iCloud items, so the pane says so instead of offering sync there.
struct ICloudPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(ClusterRegistry.self) private var registry
    @State private var actionError: String?

    var body: some View {
        let real = registry.isDemoMode ? [] : registry.clusters
        Form {
            if env.gateActive {
                Section {
                    Label("Development builds keep their clusters in a separate keychain group. iCloud sync of your real clusters is tested with a Release build on a separate macOS user.", systemImage: "lock.shield")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            Section {
                LabeledContent("Syncing", value: "\(real.filter(\.iCloudSync).count) of \(real.count) clusters")
                ForEach(real) { c in
                    Toggle(c.name, isOn: Binding(get: { c.iCloudSync }, set: { on in
                        var n = c; n.iCloudSync = on
                        do { try registry.update(n) } catch { actionError = "Couldn’t change iCloud sync for \(c.name): \(error.localizedDescription)" }
                    }))
                    .disabled(env.gateActive)
                }
            } header: { Text("iCloud") } footer: {
                Text("Cluster list and credentials sync end-to-end encrypted via iCloud Keychain to your devices signed in with the same Apple Account. Turning sync off removes the item from iCloud, not from this Mac.")
            }
        }
        .formStyle(.grouped)
        .navigationTitle("iCloud")
        .alert("Couldn’t save the change", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }
}
