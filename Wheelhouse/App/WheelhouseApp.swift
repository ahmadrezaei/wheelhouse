import SwiftUI
import UserNotifications
import WheelhouseKit
import WheelhouseUI

@main
struct WheelhouseApp: App {
    @State private var registry: ClusterRegistry
    @State private var preferences: AppPreferences
    @State private var lock: AppLockController
    @State private var network = NetworkMonitor()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let preferences = AppPreferences()
        let registry = ClusterRegistry()
        // `-WHDemoMode` launch argument (UI tests, screenshots) forces Demo mode.
        let forcedDemo = ProcessInfo.processInfo.arguments.contains("-WHDemoMode")
        if preferences.demoMode || forcedDemo { registry.enterDemoMode(persist: !forcedDemo) }
        // Cold launch with App Lock on starts locked: no content is ever shown before authentication.
        let lock = AppLockController(locked: preferences.appLockEnabled)
        _preferences = State(initialValue: preferences)
        _registry = State(initialValue: registry)
        _lock = State(initialValue: lock)
        // The overlay window (lock + privacy cover) is installed before the first scene connects.
        LockWindowManager.shared.configure(lock: lock, preferences: preferences, registry: registry)
        // The delegate must exist before launch finishes, or a notification tap that cold-starts the app is lost.
        UNUserNotificationCenter.current().delegate = NotificationCoordinator.shared
        BackgroundRefresh.register()
    }

    var body: some Scene {
        WindowGroup {
            // Router, URL handling and notification routing are per scene (see `SceneRoot`).
            SceneRoot()
                .environment(registry)
                .environment(preferences)
                .environment(lock)
                .environment(network)
                .tint(Palette.tint)
        }
        .onChange(of: scenePhase) { _, phase in handle(phase) }
        .commands { AppCommands(registry: registry) }
    }

    /// Scene-phase hooks: pause watches, resume them, schedule background refresh.
    /// (Locking and the privacy cover are handled synchronously by `LockWindowManager`.)
    private func handle(_ phase: ScenePhase) {
        switch phase {
        case .background:
            registry.stopAllSessions()
            BackgroundRefresh.appDidEnterBackground(registry: registry)
        case .active:
            registry.resumeAllSessions()
        default:
            break
        }
    }
}

/// One per window scene: owns that scene's `AppRouter`, routes URLs and notification taps to it, and holds links
/// that arrive while the app is locked until the user authenticates.
struct SceneRoot: View {
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppLockController.self) private var lock
    @State private var router = AppRouter()
    @State private var pendingURL: URL?

    var body: some View {
        RootView()
            .environment(router)
            .focusedSceneValue(\.router, router)
            // Belt and braces for the first frame, before the overlay window exists: nothing is visible or tappable while locked.
            .allowsHitTesting(!lock.isLocked)
            .accessibilityHidden(lock.isLocked)
            .overlay { if lock.isLocked { Color(uiColor: .systemBackground).ignoresSafeArea() } }
            .onOpenURL { handle($0) }
            #if DEBUG
            // Screenshot/UI-test hook: `-WHOpenURL wheelhouse://…` opens a link at launch (no "Open in…?" system prompt).
            .task {
                let args = ProcessInfo.processInfo.arguments
                if let i = args.firstIndex(of: "-WHOpenURL"), i + 1 < args.count, let url = URL(string: args[i + 1]) {
                    try? await Task.sleep(for: .seconds(1.5))
                    handle(url)
                }
            }
            #endif
            .task { NotificationCoordinator.shared.install { handle($0) } }
            .onChange(of: lock.isLocked, initial: true) { _, locked in
                if locked {
                    router.sheet = nil
                } else if let url = pendingURL {
                    pendingURL = nil
                    handle(url)
                }
            }
    }

    private func handle(_ url: URL) {
        // Links never act while locked; they are replayed right after unlock.
        if lock.isLocked { pendingURL = url; return }
        if url.isFileURL {
            // "Open in Wheelhouse" / Share sheet kubeconfig.
            if KubeconfigInbox.shared.offer(url: url) { router.push(.importKubeconfig) }
            return
        }
        router.open(url: url, registry: registry)
    }
}

/// Menu-bar / hardware keyboard shortcuts (DESIGN.md §8.9). Only the shell-level ones live here;
/// features add their own `.keyboardShortcut`s. Commands act on the focused scene's router.
struct AppCommands: Commands {
    let registry: ClusterRegistry
    @FocusedValue(\.router) private var router

    var body: some Commands {
        CommandMenu("Clusters") {
            Button("Fleet") { router?.open(.fleet, registry: registry) }.keyboardShortcut("0").disabled(router == nil)
            ForEach(Array(registry.clusters.prefix(9).enumerated()), id: \.element.id) { index, cluster in
                Button(cluster.name) { router?.open(.cluster(cluster.id), registry: registry) }
                    .keyboardShortcut(KeyEquivalent(Character(String(index + 1))))
                    .disabled(router == nil)
            }
            Divider()
            Button("Search…") { router?.open(.search(query: nil), registry: registry) }.keyboardShortcut("f").disabled(router == nil)
            Button("Add Cluster…") { router?.push(.addCluster) }.keyboardShortcut("n", modifiers: [.command, .shift]).disabled(router == nil)
            if let id = registry.currentCluster?.id, registry.currentCluster?.readOnly == false {
                Button("Create from YAML…") { router?.push(.createYAML(id, namespace: registry.currentNamespace)) }.keyboardShortcut("n").disabled(router == nil)
            }
        }
    }
}
