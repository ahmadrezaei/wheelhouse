import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// App-global services of the Mac app (ARCHITECTURE-MAC §12.1). M1a holds only what the placeholder window needs; later
/// milestones add Moorings, Gangway, Beacon and the workspace store here.
///
/// SAFETY: this build uses an in-memory credential store and NO keychain mirror, and starts in Demo mode with the Demo Fleet
/// only. Nothing here reads `~/.kube`, the shared iCloud keychain group or any cluster.
@MainActor @Observable
final class MacAppEnvironment {
    let registry: ClusterRegistry
    let preferences: AppPreferences
    let lock: MacLockCoordinator
    let importer: MacImportCoordinator
    let paths: AppPaths
    /// A short description of the safety state, shown in the placeholder window.
    let safetySummary: String

    init(registry: ClusterRegistry, preferences: AppPreferences, lock: MacLockCoordinator, importer: MacImportCoordinator,
         paths: AppPaths, safetySummary: String) {
        self.registry = registry
        self.preferences = preferences
        self.lock = lock
        self.importer = importer
        self.paths = paths
        self.safetySummary = safetySummary
    }

    /// Evaluates the safety gate FIRST, before any store, client, file watcher or subprocess exists.
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

        // Preferences use the app's own (bundle-ID) defaults domain: no app-group access in M1a.
        let preferences = AppPreferences(defaults: .standard)
        let metadata = ClusterMetadataStore(directory: paths.root, useKeychainMirror: false)
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: metadata, defaults: .standard)
        registry.enterDemoMode(persist: false)
        return MacAppEnvironment(registry: registry, preferences: preferences, lock: MacLockCoordinator(), importer: MacImportCoordinator(),
                                 paths: paths, safetySummary: notes.joined(separator: " · "))
    }
}
