import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S1 — first launch. Shown by `RootView` when there are no clusters.
struct WelcomeView: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router
    @Environment(AppPreferences.self) private var preferences

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.xxl) {
                Spacer(minLength: Spacing.xxxl)
                header
                VStack(alignment: .leading, spacing: Spacing.l) {
                    ValueRow(symbol: "gauge.with.dots.needle.67percent", title: "Fleet health at a glance", text: "Every cluster, node and workload in one calm overview.")
                    ValueRow(symbol: "checkmark.shield", title: "Fix problems safely", text: "Dry-run first, typed confirmation on production, read-only mode.")
                    ValueRow(symbol: "apple.terminal", title: "Logs and shell, anywhere", text: "Follow logs, exec into pods and port-forward from your phone.")
                }
                .frame(maxWidth: 440)
                Spacer(minLength: Spacing.l)
                actions
                Text("Credentials stay in this device’s Keychain. No analytics, no tracking.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
            .padding(.horizontal, Spacing.xxl).padding(.bottom, Spacing.xxl)
            .frame(maxWidth: 520).frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(Palette.groupedBackground)
        .onAppear { preferences.hasSeenWelcome = true; DebugLaunch.run(registry: registry, router: router, preferences: preferences) }
    }

    private var header: some View {
        VStack(spacing: Spacing.m) {
            Image("wheelhouse.helm")
                .resizable().scaledToFit().padding(22).frame(width: 112, height: 112)
                .foregroundStyle(Palette.seafoam)
                .background(LinearGradient(colors: [Palette.navy, Palette.navy.opacity(0.82)], startPoint: .top, endPoint: .bottom), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
                .shadow(color: Palette.navy.opacity(0.25), radius: 14, y: 6)
                .accessibilityHidden(true)
            Text("Wheelhouse").font(.largeTitle.bold())
            Text("Every cluster, at the helm.").font(.title3).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var actions: some View {
        VStack(spacing: Spacing.m) {
            Button { router.push(.addCluster) } label: { Text("Add Cluster").frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.glassProminent)
            Button { router.push(.importKubeconfig) } label: { Label("Import kubeconfig", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity, minHeight: 36) }
                .buttonStyle(.glass)
            Button { preferences.demoMode = true; registry.enterDemoMode() } label: {
                Label("Explore Demo", systemImage: "sparkles").frame(minHeight: Spacing.minHit)
            }
            .accessibilityHint("Loads sample clusters. No network needed.")
        }
        .frame(maxWidth: 440)
    }
}

private struct ValueRow: View {
    let symbol: String, title: String, text: String
    var body: some View {
        HStack(alignment: .top, spacing: Spacing.l) {
            Image(systemName: symbol).font(.title2).foregroundStyle(Palette.tint).frame(width: 36).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(text).font(.subheadline).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview { WelcomeView().environment(ClusterRegistry.preview(demo: false)).environment(AppRouter()).environment(AppPreferences()) }


/// DEBUG-only launch arguments for screenshots and UI automation:
/// `-WHOpen settings|search|addCluster|import` and `-WHKubeconfig <path>` (preloads the import screen; `-WHAutoTest` also connects).
enum DebugLaunch {
    static var autoTest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-WHAutoTest")
        #else
        false
        #endif
    }
    @MainActor static func run(registry: ClusterRegistry, router: AppRouter, preferences: AppPreferences) {
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-WHKubeconfig"), i + 1 < args.count, let text = try? String(contentsOfFile: args[i + 1], encoding: .utf8) {
            KubeconfigInbox.shared.pendingText = text; KubeconfigInbox.shared.pendingName = (args[i + 1] as NSString).lastPathComponent
        }
        guard let i = args.firstIndex(of: "-WHOpen"), i + 1 < args.count else { return }
        switch args[i + 1] {
        case "settings": registry.enterDemoMode(); router.push(.settings)
        case "search": registry.enterDemoMode(); DispatchQueue.main.asyncAfter(deadline: .now() + 1) { router.selectedTab = .search }
        case "addCluster": router.push(.addCluster)
        case "import": router.push(.importKubeconfig)
        default: break
        }
        #endif
    }
}
