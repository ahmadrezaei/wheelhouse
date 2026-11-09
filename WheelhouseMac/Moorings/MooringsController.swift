import Foundation
import LocalAuthentication
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// Touch ID or the password before changes are allowed on a Production or Production-suggested cluster.
struct DeviceOwnerAuthorizer: ChangeAuthorizing {
    func authorize(reason: String) async -> Bool {
        let context = LAContext()
        do { return try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) } catch { return false }
    }
}

/// Owns the Moorings stack of the Mac app: stores, exec broker, client factory and the discovery service. The app shell builds one
/// with ``make(paths:gate:keychain:shell:)``, passes ``metadata`` and ``credentials`` to `ClusterRegistry(credentials:metadata:clientFactory:)`
/// and ``clientFactory`` as its client factory, and calls ``start()`` once the window exists.
@MainActor @Observable
final class MooringsController {
    /// The running controller (Settings and the Moorings screen read it).
    static var shared: MooringsController?

    let state: MooringsState
    let service: MooringsService
    let settings: MacClusterSettingsStore
    let broker: ExecCredentialBroker
    let shellEnvironment: ShellEnvironment
    let metadata: CompositeMetadataStore
    let credentials: CompositeCredentialStore
    let factory: DesktopClientFactory

    private(set) var contexts: [DiscoveredContext] = []
    private(set) var firstRunRows: [FirstRunRow] = []
    private(set) var shellBanner: String?
    private(set) var issues: [String: String] = [:]
    /// Clusters whose context now points at another server.
    private(set) var serverNotices: [ClusterID: String] = [:]
    var needsFirstRun: Bool { !state.preferences.value.firstRunCompleted && !firstRunRows.isEmpty }
    weak var registry: ClusterRegistry?

    var clientFactory: ClusterRegistry.ClientFactory { factory.clientFactory }

    /// `gate` is read on every use, never copied: the allowed test hosts are configured after launch, while the registry (and with it the
    /// client factory) is built in `App.init`. `explicitTestKubeconfig` is the only kubeconfig discovery uses while the gate is active.
    init(paths: AppPaths, gate: @escaping @Sendable () -> DevSafetyPolicy = { .current }, explicitTestKubeconfig: URL?,
         keychainMetadata: any ClusterMetadataStoring, keychainCredentials: any CredentialStoring,
         shell: ShellEnvironment, activity: any ActivityLogging = NoopActivityLog()) {
        // Stores only use `isActive` and the home folder of the gate, which never change; only the allowed hosts do.
        let fixedGate = gate()
        let snapshotBox = SnapshotBox()
        self.snapshotBox = snapshotBox
        let overrides = DiscoveredClusterStore(fileURL: paths.discoveredClustersFile)
        let prefs = MooringsPreferencesStore(fileURL: paths.mooringsPreferencesFile)
        let state = MooringsState(overrides: overrides, preferences: prefs, gate: fixedGate)
        let settings = MacClusterSettingsStore(fileURL: paths.clusterSettingsFile)
        let home = paths.home
        let box = snapshotBox
        let broker = ExecCredentialBroker(
            locator: { ExecutableLocator(snapshot: box.value, home: home) },
            environment: { EnvironmentBuilder(snapshot: box.value, paths: paths, home: home) },
            activity: activity, gateProvider: gate)
        self.state = state
        self.settings = settings
        self.broker = broker
        self.shellEnvironment = shell
        self.metadata = CompositeMetadataStore(keychain: keychainMetadata, credentials: keychainCredentials, state: state, settings: settings, gate: fixedGate)
        self.credentials = CompositeCredentialStore(keychain: keychainCredentials, state: state, gate: fixedGate, settings: settings,
                                                    index: metadata.servers)
        self.factory = DesktopClientFactory(state: state, settings: settings, broker: broker, gateProvider: gate) { id in
            Task { @MainActor in ClusterEvents.postInvalidated(id, removed: false) }
        }
        let weakBox = WeakBox()
        self.service = MooringsService(
            config: MooringsConfiguration(gateProvider: gate, home: home, explicitTestKubeconfig: explicitTestKubeconfig,
                                          shellKubeconfig: { await shell.current().kubeconfig }),
            state: state, clients: factory, broker: broker, authorizer: DeviceOwnerAuthorizer(),
            onChange: { change in Task { @MainActor in weakBox.controller?.apply(change) } })
        weakBox.controller = self
    }

    /// The latest shell snapshot, readable from the broker's synchronous closures.
    private final class SnapshotBox: @unchecked Sendable {
        private let lock = NSLock()
        private var snapshot: ShellSnapshot?
        var value: ShellSnapshot? { get { lock.withLock { snapshot } } set { lock.withLock { snapshot = newValue } } }
    }
    private let snapshotBox: SnapshotBox

    private final class WeakBox: @unchecked Sendable { weak var controller: MooringsController? }

    func start() async {
        MooringsController.shared = self
        let snapshot = await shellEnvironment.current()
        snapshotBox.value = snapshot
        shellBanner = snapshot.failure
        await service.start()
        // The registry was built in App.init, before any scan: every added cluster was listed as "Source removed" (read-only, grey,
        // no secrets, no token source). Now that the contexts exist, reload so those clusters become real and their sessions are rebuilt.
        registry?.reloadFromStore(invalidating: Set(state.listedConfigs().map(\.id)))
        await refresh()
    }

    func refresh() async {
        contexts = state.contexts
        firstRunRows = await service.firstRunRows()
        issues = await service.issues
        serverNotices = await service.changeNotices
    }

    /// Reload Shell Environment: probes the login shell again, then re-reads every source.
    func reloadShellEnvironment() async {
        let snapshot = await shellEnvironment.reload()
        snapshotBox.value = snapshot
        shellBanner = snapshot.failure
        await service.rescan()
        await refresh()
    }

    private func apply(_ change: MooringsChange) {
        registry?.reloadFromStore(invalidating: Set(change.changed))
        Task { await refresh() }
    }
}
