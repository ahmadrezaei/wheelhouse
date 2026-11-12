import AppKit
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
    /// Kubeconfig discovery, exec credentials and the client factory (M3).
    let moorings: MooringsController
    let energy: MacEnergyCoordinator
    let alerts: MacAlertMonitor
    let widgetSnapshots: MacWidgetSnapshotWriter   // M14a
    /// The local audit log (M4a). Opens its database lazily, on the first record or query.
    let activity: ActivityLog
    /// Windows, tabs, panes and Stations (M4a).
    let workspace: WorkspaceController
    let paths: AppPaths
    /// A short description of the safety state (shown in the status line of development builds).
    private(set) var safetySummary: String
    let gateActive: Bool
    /// Where the explicit test kubeconfig stands. Until it is `ready` no client is created (the shell shows a progress view), so
    /// the gate stays fail-closed: the allowed hosts are empty and every host but the reserved fixture names is refused.
    enum HostsState: Equatable { case pending, ready(hosts: Int), failed(String), notConfigured }
    private(set) var hostsState: HostsState = .notConfigured
    var isReady: Bool { hostsState != .pending }
    @ObservationIgnored private var readyBlocks: [@MainActor () -> Void] = []
    @ObservationIgnored private var testKubeconfig: URL?
    @ObservationIgnored private var reader: @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) }
    private var badgeTask: PeriodicTask?
    // M5a: Gangway host. Created on first use; nothing listens until a consumer (Deck Terminal, Chart Room, Tides) asks for the service.
    @ObservationIgnored private(set) lazy var gangway = MacGangway(registry: registry, moorings: moorings, paths: paths, activity: activity)
    // end M5a
    // M12: Beacon (MCP over a Unix socket). Created on first use; it listens only after the person turns it on and authenticates.
    @ObservationIgnored private(set) lazy var beacon: BeaconModel = {
        let model = BeaconModel(registry: registry, paths: paths, activity: activity, gateActive: gateActive, lock: lock)
        BeaconModelHub.shared.model = model
        return model
    }()
    // end M12
    // M5b: the Deck Terminal's confirmation sheets. Created before the first Gangway session, so the real confirmer is in place when the service starts.
    @ObservationIgnored private(set) lazy var gangwaySheets: GangwaySheetCoordinator = {
        let coordinator = GangwaySheetCoordinator(registry: registry, activity: activity)
        gangway.confirmer = coordinator.confirmer
        return coordinator
    }()
    // end M5b
    // M11b: First Mate. Created on first use (the inspector's First Mate segment, Settings → First Mate, the menu); until then nothing runs and
    // the Keychain is not read. A performance run with `-WHPerfFirstMate YES` gets the replay hub (no network, no Keychain).
    @ObservationIgnored private(set) lazy var firstMate: FirstMateHub = {
        let hub = FirstMatePerfReplay.isRequested()
            ? FirstMateHub.replay(registry: registry, settingsStore: moorings.settings, activity: activity, client: FirstMatePerfReplay.client())
            : FirstMateHub.live(registry: registry, settingsStore: moorings.settings, paths: paths, activity: activity)
        hub.start()
        return hub
    }()
    // end M11b
    init(registry: ClusterRegistry, preferences: AppPreferences, macPreferences: MacPreferences, lock: MacLockCoordinator, importer: MacImportCoordinator, moorings: MooringsController,
         paths: AppPaths, safetySummary: String, gateActive: Bool, activity: ActivityLog, workspaceStore: WorkspaceStore) {
        self.registry = registry
        self.preferences = preferences
        self.macPreferences = macPreferences
        self.lock = lock
        self.importer = importer
        self.moorings = moorings
        self.paths = paths
        self.safetySummary = safetySummary
        self.gateActive = gateActive
        self.energy = MacEnergyCoordinator(registry: registry, reportsVisibility: gateActive)
        self.alerts = MacAlertMonitor(registry: registry, preferences: preferences)
        // M14a: the widget snapshot follows the health checks that already run.
        self.widgetSnapshots = MacWidgetSnapshotWriter.live(registry: registry)
        let widgetSnapshots = self.widgetSnapshots
        self.alerts.didCheck = { widgetSnapshots.consider() }
        // end M14a
        self.activity = activity
        self.workspace = WorkspaceController(store: workspaceStore, registry: registry, activity: activity,
                                             sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        let lock = self.lock
        self.workspace.isLocked = { lock.isLocked }
        let workspace = self.workspace
        energy.trimSidebars = { workspace.allModels.forEach { $0.sidebarIfCreated?.trimCaches() } }
        energy.releaseHiddenWindowContent = { workspace.allModels.forEach { $0.releaseContentNow() } }
    }

    /// Every client is built through this: `DesktopClientFactory`. While the gate is active a server that is not an allowed test host
    /// gets a client that refuses every call (no request is made); exec and token-file clusters get their token from their provider.
    /// The factory reads the gate on EVERY call, never a copy: the allowed hosts are configured after launch, and a factory that kept the
    /// gate it saw during `App.init` would block the test cluster for good.
    var clientFactory: ClusterRegistry.ClientFactory { moorings.clientFactory }

    /// Builds the environment. This runs in `App.init` on the main thread: it does NO file read of the test kubeconfig and NO Security
    /// call (the code-signature check and the kubeconfig read happen in `start(reader:)` on a utility queue after launch).
    /// `reader` is a test seam that records where the read happens.
    static func live(reader: @escaping @Sendable (URL) throws -> String = { try String(contentsOf: $0, encoding: .utf8) },
                     testKubeconfig explicitTestFile: URL? = KubeconfigDiscoveryPolicy.explicitTestKubeconfig()) -> MacAppEnvironment {
        let gateActive = DevSafety.isActive
        // While the gate is on (Debug, Profile, local Release) the app group and both keychain groups are forced to the Debug
        // ones, whatever Info.plist says: a local Release build then cannot open the production group container or name the shared
        // iCloud keychain group (its entitlements do not list the Debug groups, so the keychain refuses: fail closed).
        if gateActive { IsolationOverride.install(.debug) }
        let paths = AppPaths.current
        var notes = [gateActive ? "Development safety ON" : "Development safety off"]

        // The explicit test kubeconfig (never ~/.kube) defines the only allowed hosts while the gate is active. It is READ later, off the
        // main thread (`start(reader:)`): it may live in a folder that macOS protects with a prompt, which must never block launch.
        let testFile = gateActive ? explicitTestFile : nil
        if gateActive, testFile == nil { notes.append("no test kubeconfig") }
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
        let keychainMetadata = ClusterMetadataStore(directory: paths.root, useKeychainMirror: !gateActive)
        // Moorings sits on top of the Keychain stores: discovered contexts are listed next to the Keychain clusters and never written to
        // the Keychain or the iCloud mirror. While the gate is active the shell sees only the test kubeconfig (never ~/.kube) and a
        // private kubectl cache; exec plugins get an environment without KUBECONFIG at all.
        let shell = ShellEnvironment(gate: .current, explicitTestKubeconfig: testFile,
                                     kubeCacheDir: paths.root.appending(path: "kubectl-cache", directoryHint: .isDirectory))
        let activity = ActivityLog(url: paths.activityDatabase)
        let moorings = MooringsController(paths: paths, explicitTestKubeconfig: testFile, keychainMetadata: keychainMetadata,
                                          keychainCredentials: KeychainCredentialStore(), shell: shell, activity: activity)
        let registry = ClusterRegistry(credentials: moorings.credentials, metadata: moorings.metadata, defaults: defaults,
                                       clientFactory: moorings.clientFactory)
        moorings.registry = registry
        MooringsController.shared = moorings
        // `-WHResetState` (development builds only): start from an empty cluster list, as UI tests need.
        if gateActive, ProcessInfo.processInfo.arguments.contains("-WHResetState") {
            for c in registry.clusters where !c.isDemo { try? registry.remove(id: c.id) }
        }
        // `-WHDemoMode` (UI tests, screenshots) forces Demo without remembering it; otherwise the saved preference decides.
        let forcedDemo = ProcessInfo.processInfo.arguments.contains("-WHDemoMode")
        if preferences.demoMode || forcedDemo { registry.enterDemoMode(persist: !forcedDemo) }

        let lock = MacLockCoordinator(locked: preferences.appLockEnabled)
        let env = MacAppEnvironment(registry: registry, preferences: preferences, macPreferences: macPreferences, lock: lock,
                                    importer: MacImportCoordinator(moorings: moorings.service), moorings: moorings, paths: paths, safetySummary: notes.joined(separator: " · "), gateActive: gateActive,
                                    activity: activity, workspaceStore: WorkspaceStore(file: workspaceFile(paths: paths, gateActive: gateActive)))
        env.testKubeconfig = testFile
        env.reader = reader
        env.hostsState = testFile == nil ? .notConfigured : .pending
        env.notes = notes
        return env
    }

    /// Where the workspace is saved. Performance scenarios, Demo runs and `-WHResetState` use no file at all (they must never read or
    /// overwrite a person's workspace, and a scenario is applied on top of a clean one); `-WHWorkspaceFile <path>` names a file
    /// (UI tests of restoration). Both are honoured only while the safety gate is active.
    static func workspaceFile(paths: AppPaths, gateActive: Bool, arguments: [String] = ProcessInfo.processInfo.arguments) -> URL? {
        if gateActive {
            if let i = arguments.firstIndex(of: "-WHWorkspaceFile"), arguments.indices.contains(i + 1) { return URL(fileURLWithPath: arguments[i + 1]) }
            // Unit tests build the app environment too: they never touch a person's workspace file.
            if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return nil }
            if arguments.contains("-WHResetState") || arguments.contains("-WHDemoMode") || arguments.contains("-WHPerfScenario") { return nil }
        }
        return paths.workspaceFile
    }

    @ObservationIgnored private var notes: [String] = []

    /// After launch: reads the test kubeconfig on a utility queue, exactly once (a denial or a
    /// failure is reported and never retried). Fail-closed throughout: until it finishes the gate is ON and no host is allowed.
    func start() {
        guard let file = testKubeconfig, hostsState == .pending else { finishHosts(.notConfigured); return }
        let reader = self.reader
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result: HostsState
            if !FileManager.default.fileExists(atPath: file.path) {
                result = .failed("The test kubeconfig \(file.lastPathComponent) was not found.")
            } else {
                do {
                    let hosts = try KubeconfigDiscoveryPolicy.configureAllowedHosts(testKubeconfig: file, read: reader)
                    DevSafety.configureAllowedHosts(hosts)
                    result = .ready(hosts: hosts.count)
                } catch {
                    result = .failed("The test kubeconfig couldn't be read: \(error.localizedDescription) If macOS asked for access to a folder, allow it and relaunch.")
                }
            }
            if case .failed(let message) = result {
                DevSafety.setHostConfigurationError(message)
                DevSafety.configureAllowedHosts([])            // fail closed: nothing but the reserved fixture names
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.finishHosts(result) } }
        }
    }

    private func finishHosts(_ state: HostsState) {
        hostsState = state
        switch state {
        case .ready(let n): safetySummary = (notes + ["\(n) allowed host\(n == 1 ? "" : "s")"]).joined(separator: " · ")
        case .failed(let message): safetySummary = (notes + [message]).joined(separator: " · ")
        default: safetySummary = notes.joined(separator: " · ")
        }
        let blocks = readyBlocks
        readyBlocks = []
        blocks.forEach { $0() }
    }

    /// Runs `block` once the allowed hosts are known (immediately when they already are).
    func whenReady(_ block: @escaping @MainActor () -> Void) {
        if isReady { block() } else { readyBlocks.append(block) }
    }

    /// Starts the services that need a running app (observers, monitors). Called once after the first frame.
    func startServices() {
        lock.start(preferences: preferences, macPreferences: macPreferences)
        energy.start()
        alerts.start()
        gangway.follow(lock: lock)      // M5a: app lock closes Gangway streams (no listener is started here)
        // M12: Beacon starts OFF (a launch with -WHBeaconLaunch does not turn it on). Only the helper symlink and the lock observer.
        beacon.maintainHelperLink()
        beacon.follow(lock: lock)
        // end M12
        gangwaySheets.follow(lock: lock)      // M5b: the app lock dismisses every confirmation sheet
        // M5b: no Direct shell survives a restart, so the credential folders of earlier runs go now, and this run's go at quit.
        let root = paths.root
        DirectKubeconfig.removeAll(root: root)
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in DirectKubeconfig.removeAll(root: root) }
        // Discovery needs the allowed hosts (a context is marked blocked against them), so it starts once they are known.
        whenReady { [moorings] in Task { await moorings.start() } }
        // Landfall (M10): built once the allowed hosts are known. It starts the daily rescan only when the user chose "daily", and never in a
        // development build (the service refuses everything while the gate is active).
        whenReady { [moorings, paths] in
            let landfall = LandfallModel.make(moorings: moorings, paths: paths)
            LandfallHub.shared.model = landfall
            Task { await landfall.start() }
        }
        // Sidebar badges: read from stores that already run, every 5 s while a window is visible (never faster than once a second).
        if badgeTask == nil {
            let workspace = workspace
            let t = PeriodicTask(name: "sidebar.badges", interval: 5, hiddenInterval: nil) { await MainActor.run { workspace.refreshSidebarBadges() } }
            badgeTask = t
            t.start()
        }
    }
}
