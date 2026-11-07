import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Clusters: the ordered list (status, environment, read-only, sync), edit, add, import and remove (the iOS "Clusters" section).
struct ClustersPane: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppPreferences.self) private var preferences
    @State private var router = AppRouter()
    @State private var network = NetworkMonitor()
    @State private var pendingDelete: ClusterConfig?
    @State private var editing: ClusterConfig?
    @State private var adding = false
    @State private var actionError: String?

    var body: some View {
        Form {
            Section {
                ForEach(registry.clusters) { c in
                    HStack {
                        ClusterRow(cluster: c)
                        if !registry.isDemoMode {
                            Button("Edit…") { editing = c }
                            Button("Remove…", role: .destructive) { pendingDelete = c }
                        }
                    }
                }
                .onMove { registry.move(fromOffsets: $0, toOffset: $1) }
                .moveDisabled(registry.isDemoMode)
                if registry.clusters.isEmpty { Text("No clusters yet.").foregroundStyle(.secondary) }
                if registry.isDemoMode {
                    Label("These are sample clusters. Exit Demo Mode to manage real ones.", systemImage: "sparkles").font(.footnote).foregroundStyle(.secondary)
                }
            } header: { Text("Clusters") } footer: {
                if registry.clusters.count > 1 && !registry.isDemoMode { Text("Drag to reorder. The order is used in the sidebar and for ⌘1–9.") }
            }
            Section {
                Button("Add Cluster with Token…") { adding = true }
                Button("Import File…") { env.importer.presentOpenPanel(whileLocked: env.lock.isLocked) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Clusters")
        .sheet(isPresented: $adding) { sheet { AddClusterView() } }
        .sheet(item: $editing) { cfg in sheet { AddClusterView(editing: cfg, registry: registry) } }
        .confirmationDialog("Remove \(pendingDelete?.name ?? "cluster")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("Remove Cluster", role: .destructive) {
                if let c = pendingDelete {
                    do { try registry.remove(id: c.id) } catch { actionError = "Couldn’t remove \(c.name): \(error.localizedDescription)" }
                }
                pendingDelete = nil
            }
        } message: { Text("Deletes the cluster and its credentials from this Mac\(pendingDelete?.iCloudSync == true ? " and from iCloud Keychain" : ""). The cluster itself is not touched.") }
        .alert("Couldn’t save the change", isPresented: Binding(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(actionError ?? "") }
    }

    private func sheet<V: View>(@ViewBuilder _ content: () -> V) -> some View {
        NavigationStack { content() }
            .environment(registry).environment(preferences).environment(router).environment(network)
            .environment(\.kubeconfigImportPolicy, env.importer.policy)
            .frame(minWidth: 520, minHeight: 480)
            .onChange(of: router.sheet) { _, _ in }
    }
}

struct ClusterRow: View {
    let cluster: ClusterConfig
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(cluster.color.color).frame(width: 12, height: 12).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(cluster.name)
                Text(cluster.isDemo ? "Demo · \(cluster.provider ?? "")" : cluster.host).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            HStack(spacing: 4) {
                if cluster.readOnly { FlagBadge("READ-ONLY", tone: .info) }
                if cluster.allowsInsecureTLS { FlagBadge("UNVERIFIED TLS", tone: .critical) }
                if cluster.iCloudSync { Image(systemName: "icloud").font(.footnote).foregroundStyle(.secondary).accessibilityLabel("Synced with iCloud") }
                EnvBadge(cluster.environment)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
