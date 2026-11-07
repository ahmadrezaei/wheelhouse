import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The placeholder workspace window: the Demo Fleet as a plain list, with no polling. M1b replaces it with the sidebar shell and
/// M4a with `WorkspaceWindow` (tabs, panes, inspector).
///
/// Launch argument `-WHPlaceholderFleetDashboard` (development builds only) shows the shared iOS Fleet dashboard instead. It
/// refreshes health every 30 s (about 0.44 % CPU and 57 MB here), so it is not the performance baseline (see
/// `perf/baselines/M1a.json`); it exists to prove the shared screens run on macOS.
struct MacSceneRoot: View {
    @Environment(MacAppEnvironment.self) private var env
    @State private var router = AppRouter()
    @State private var lockState = AppLockController(locked: false)
    @State private var network = NetworkMonitor()
    private let showsDashboard = DevSafety.isActive && ProcessInfo.processInfo.arguments.contains("-WHPlaceholderFleetDashboard")

    var body: some View {
        content
            .environment(env.registry)
            .environment(env.preferences)
            .environment(router)
            .environment(lockState)
            .environment(network)
            .tint(Palette.tint)
            .safeAreaInset(edge: .bottom, spacing: 0) {
                Text(env.safetySummary)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l).padding(.vertical, 4)
                    .background(.bar)
                    .accessibilityIdentifier("safety-summary")
            }
            .frame(minWidth: 720, minHeight: 520)
    }

    @ViewBuilder private var content: some View {
        if showsDashboard {
            NavigationStack { FleetDashboardView() }
        } else {
            PlaceholderFleetList()
        }
    }
}

/// The Demo Fleet, statically: name, environment badge, provider and region. Reads the registry once per change, never polls.
struct PlaceholderFleetList: View {
    @Environment(ClusterRegistry.self) private var registry

    var body: some View {
        List {
            Section {
                ForEach(registry.clusters) { cluster in
                    HStack(spacing: Spacing.m) {
                        Image(systemName: "server.rack").foregroundStyle(Palette.tintText).accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cluster.name).font(.headline)
                            Text([cluster.provider, cluster.region].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        EnvBadge(cluster.environment)
                    }
                    .padding(.vertical, 2)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Demo Fleet")
            } footer: {
                Text("Wheelhouse for Mac is under construction. This window shows the Demo Fleet only.").font(.footnote)
            }
        }
        .accessibilityIdentifier("demo-fleet-list")
    }
}
