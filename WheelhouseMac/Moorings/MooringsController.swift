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
    var needsFirstRun: Bool { !state.preferences.value.firstRunCompleted && !firstRunRows.isEmpty }
    weak var registry: ClusterRegistry?

    var clientFactory: ClusterRegistry.ClientFactory { factory.clientFactory }

    init(paths: AppPaths, gate: DevSafetyPolicy, keychainMetadata: any ClusterMetadataStoring, keychainCredentials: any CredentialStoring,
         shell: ShellEnvironment, activity: any ActivityLogging = NoopActivityLog()) {
        let overrides = DiscoveredClusterStore(fileURL: paths.discoveredClustersFile)
        let prefs = MooringsPreferencesStore(fileURL: paths.mooringsPreferencesFile)
        let state = MooringsState(overrides: overrides, preferences: prefs, gate: gate)
        let settings = MacClusterSettingsStore(fileURL: paths.clusterSettingsFile)
        let home = paths.home
        let broker = ExecCredentialBroker(
            locator: { ExecutableLocator(snapshot: nil, home: home) },
            environment: { EnvironmentBuilder(snapshot: nil, paths: paths, home: home) },
            activity: activity, gate: gate)
        self.state = state
        self.settings = settings
        self.broker = broker
        self.shellEnvironment = shell
        self.metadata = CompositeMetadataStore(keychain: keychainMetadata, credentials: keychainCredentials, state: state, settings: settings)
        self.credentials = CompositeCredentialStore(keychain: keychainCredentials, state: state, gate: gate)
        self.factory = DesktopClientFactory(state: state, settings: settings, broker: broker, gate: gate) { id in
            Task { @MainActor in ClusterEvents.postInvalidated(id, removed: false) }
        }
        let weakBox = WeakBox()
        self.service = MooringsService(
            config: MooringsConfiguration(gate: gate, home: home, explicitTestKubeconfig: KubeconfigDiscoveryPolicy.explicitTestKubeconfig(),
                                          shellKubeconfig: { await shell.current().kubeconfig }),
            state: state, clients: factory, broker: broker, authorizer: DeviceOwnerAuthorizer(),
            onChange: { change in Task { @MainActor in weakBox.controller?.apply(change) } })
        weakBox.controller = self
    }

    private final class WeakBox: @unchecked Sendable { weak var controller: MooringsController? }

    func start() async {
        MooringsController.shared = self
        let snapshot = await shellEnvironment.current()
        shellBanner = snapshot.failure
        await service.start()
        await refresh()
    }

    func refresh() async {
        contexts = state.contexts
        firstRunRows = await service.firstRunRows()
        issues = await service.issues
    }

    /// Reload Shell Environment: probes the login shell again, then re-reads every source.
    func reloadShellEnvironment() async {
        shellBanner = await shellEnvironment.reload().failure
        await service.rescan()
        await refresh()
    }

    private func apply(_ change: MooringsChange) {
        registry?.reloadFromStore(invalidating: Set(change.changed))
        Task { await refresh() }
    }
}
