import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// App-global services of the Mac app (ARCHITECTURE-MAC section 12.1). Later milestones add Moorings, Gangway, Beacon and the
/// workspace store here.
///
/// SAFETY: the gate (`DevSafety`) is evaluated FIRST, before any store, client, file watcher or subprocess exists. While it is active
/// the app group and both keychain groups are forced to the Debug ones (`IsolationOverride`), `AppPaths` points at
/// `Wheelhouse-Debug`, every client is limited to the hosts of the explicit test kubeconfig, and nothing reads `~/.kube`.
@MainActor @Observable
final class MacAppEnvironment {
    let registry: ClusterRegistry
    let preferences: AppPreferences
    let macPreferences: MacPreferences
    let lock: MacLockCoordinator
    let importer: MacImportCoordinator
    let energy: MacEnergyCoordinator
    let alerts: MacAlertMonitor
    let sidebar: SidebarModel
    let navigation = MacNavigation()
    let paths: AppPaths
    /// A short description of the safety state (shown in the status line of development builds).
    let safetySummary: String
    let gateActive: Bool
    private var badgeTask: PeriodicTask?
    /// Routes to open once the window exists (performance scenarios, launch hooks).
    var launchRoutes: [Route] = []

    init(registry: ClusterRegistry, preferences: AppPreferences, macPreferences: MacPreferences, lock: MacLockCoordinator, importer: MacImportCoordinator,
         paths: AppPaths, safetySummary: String, gateActive: Bool) {
        self.registry = registry
        self.preferences = preferences
        self.macPreferences = macPreferences
        self.lock = lock
        self.importer = importer
        self.paths = paths
        self.safetySummary = safetySummary
        self.gateActive = gateActive
        self.energy = MacEnergyCoordinator(registry: registry)
        self.alerts = MacAlertMonitor(registry: registry, preferences: preferences)
        self.sidebar = SidebarModel(provider: RegistrySidebarProvider(registry: registry))
    }

    /// Every client is built through this: while the gate is active a server that is not an allowed test host is pointed at a
    /// reserved name that never resolves (`*.invalid`), so it can only fail. M3's `DesktopClientFactory` replaces it.
    nonisolated static func guardedClientFactory(gate: DevSafetyPolicy) -> ClusterRegistry.ClientFactory {
        let base = ClusterRegistry.defaultClientFactory
        return { config, secrets in base(gatedConfig(config, gate: gate), secrets) }
    }

    /// The config a client is built from: unchanged for Demo clusters, allowed hosts and an inactive gate; otherwise the server is
    /// replaced by a name that can never resolve.
    nonisolated static func gatedConfig(_ config: ClusterConfig, gate: DevSafetyPolicy) -> ClusterConfig {
        guard gate.isActive, !config.isDemo, !gate.isAllowed(server: config.server) else { return config }
        var blocked = config
        blocked.server = URL(string: "https://blocked-in-development.invalid")!
        return blocked
    }

    static func live() -> MacAppEnvironment {
        let gateActive = DevSafety.isActive
        // While the gate is on (Debug, Profile, local Release) the app group and both keychain groups are forced to the Debug
        // ones, whatever Info.plist says: a local Release build then cannot open the production group container or name the shared
        // iCloud keychain group (its entitlements do not list the Debug groups, so the keychain refuses: fail closed).
        if gateActive { IsolationOverride.install(.debug) }
        let paths = AppPaths.current
        var notes = [gateActive ? "Development safety ON" : "Development safety off"]

        // The explicit test kubeconfig (never ~/.kube) defines the only allowed hosts while the gate is active.
        if gateActive {
            if let file = KubeconfigDiscoveryPolicy.explicitTestKubeconfig() {
                if FileManager.default.fileExists(atPath: file.path) {
                    do {
                        let hosts = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: file)
                        DevSafety.configureAllowedHosts(hosts)
                        notes.append("\(hosts.count) allowed host\(hosts.count == 1 ? "" : "s")")
                    } catch {
                        notes.append("test kubeconfig refused: \(error.localizedDescription)")
                    }
                } else {
                    notes.append("test kubeconfig not found")
                }
            } else {
                notes.append("no test kubeconfig")
            }
        }
        try? paths.prepare()

        // Preferences use the app's own (bundle-ID) defaults domain. The Mac keeps 20,000 log lines by default (iOS 50,000).
        let defaults = UserDefaults.standard
        let preferences = AppPreferences(defaults: defaults)
        if let bundle = Bundle.main.bundleIdentifier, defaults.persistentDomain(forName: bundle)?["logMaxLines"] == nil {
            preferences.logMaxLines = 20_000
        }
        let macPreferences = MacPreferences(defaults: defaults)

        // Real clusters live in the Debug keychain group (credentials) and a JSON file under the isolated app-support folder
        // (list). The iCloud mirror is used only when the gate is off (Distribution).
        let gate = DevSafetyPolicy.current
        let metadata = ClusterMetadataStore(directory: paths.root, useKeychainMirror: !gateActive)
        let registry = ClusterRegistry(credentials: KeychainCredentialStore(), metadata: metadata, defaults: defaults,
                                       clientFactory: guardedClientFactory(gate: gate))
        // `-WHResetState` (development builds only): start from an empty cluster list, as UI tests need.
        if gateActive, ProcessInfo.processInfo.arguments.contains("-WHResetState") {
            for c in registry.clusters where !c.isDemo { try? registry.remove(id: c.id) }
        }
        // `-WHDemoMode` (UI tests, screenshots) forces Demo without remembering it; otherwise the saved preference decides.
        let forcedDemo = ProcessInfo.processInfo.arguments.contains("-WHDemoMode")
        if preferences.demoMode || forcedDemo { registry.enterDemoMode(persist: !forcedDemo) }

        let lock = MacLockCoordinator(locked: preferences.appLockEnabled)
        let env = MacAppEnvironment(registry: registry, preferences: preferences, macPreferences: macPreferences, lock: lock,
                                    importer: MacImportCoordinator(), paths: paths, safetySummary: notes.joined(separator: " · "), gateActive: gateActive)
        return env
    }

    /// Starts the services that need a running app (observers, monitors). Called once after the first frame.
    func startServices() {
        lock.start(preferences: preferences, macPreferences: macPreferences)
        energy.start()
        alerts.start()
        // Sidebar badges: read from stores that already run, every 5 s while a window is visible (never faster than once a second).
        if badgeTask == nil {
            let sidebar = sidebar
            let t = PeriodicTask(name: "sidebar.badges", interval: 5, hiddenInterval: nil) { await MainActor.run { sidebar.refreshBadges() } }
            badgeTask = t
            t.start()
        }
    }
}
