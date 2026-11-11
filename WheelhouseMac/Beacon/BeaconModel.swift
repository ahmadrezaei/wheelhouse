import AppKit
import Foundation
import Observation
import Synchronization
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// Beacon in the Mac app (ARCHITECTURE-MAC section 10): owns the hub, the client store and the sheets, and is what Settings shows.
///
/// Beacon is off at every launch. `-WHBeaconLaunch` (which the helper passes to `open`) only starts the app. Nothing listens, and
/// nothing is scheduled, until the person turns Beacon on and authenticates.
@MainActor @Observable
final class BeaconModel {
    let hub: BeaconHub
    let store: BeaconClientStore
    let presenter: BeaconPresenter
    let config: BeaconClientConfig
    let registry: ClusterRegistry
    private let paths: AppPaths
    private let gateActive: Bool

    private(set) var isOn = false
    private(set) var clients: [BeaconClientRecord] = []
    private(set) var sessionCount = 0
    var lastError: String?
    /// Secrets are shown only for clients created in this launch (they live in the keychain; they are read again on demand).
    var revealed: String?

    /// Mirrors the app lock for the threads Beacon runs on.
    @ObservationIgnored private let lockMirror: LockMirror

    nonisolated final class LockMirror: Sendable {
        private let value = Mutex(false)
        var isLocked: Bool { value.withLock { $0 } }
        func set(_ locked: Bool) { value.withLock { $0 = locked } }
    }

    init(registry: ClusterRegistry, paths: AppPaths, activity: any ActivityLogging, gateActive: Bool, lock: MacLockCoordinator,
         authenticator: any BeaconAuthenticating = LocalAuthenticator(), secrets: any BeaconSecretStoring = KeychainBeaconSecrets()) {
        self.registry = registry
        self.paths = paths
        self.gateActive = gateActive
        let mirror = LockMirror()
        mirror.set(lock.isLocked)
        lockMirror = mirror
        store = BeaconClientStore(fileURL: paths.root.appending(path: "beacon-clients.json"), secrets: secrets)
        presenter = BeaconPresenter(registry: registry, activity: activity)
        let helperID = paths.isolated ? "\(AppPaths.releaseBundleID).mcp.debug" : "\(AppPaths.releaseBundleID).mcp"
        let socket = AppGroup.containerURL.appending(path: "b/s")
        let changes = MacBeaconChanges(registry: registry, presenter: presenter)
        let presenter = presenter
        hub = BeaconHub(store: store, source: RegistryToolboxSource(registry: registry), socketURL: socket,
                        verifier: SecurityPeerVerifier(requirement: BeaconRequirements.helper(identifier: helperID)),
                        approver: PresenterApprover(presenter: presenter), authenticator: authenticator, changes: changes, activity: activity,
                        isLocked: { mirror.isLocked })
        config = BeaconClientConfig(helperPath: paths.binDirectory.appending(path: "wheelhouse-mcp").path, developmentBuild: gateActive || paths.isolated)
        clients = store.records
        terminateObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.shutdown() }
        }
    }

    @ObservationIgnored private var terminateObserver: (any NSObjectProtocol)?

    private struct PresenterApprover: BeaconApproving {
        let presenter: BeaconPresenter
        func approve(_ request: BeaconApprovalRequest) async -> BeaconApprovalDecision { await presenter.ask(request) }
    }

    // MARK: Lifecycle

    /// The symlink the client configs point at, so they survive moving the app. A dev build never replaces the Release symlink
    /// (its folder is `Wheelhouse-Debug`).
    func maintainHelperLink() {
        let helper = Bundle.main.bundleURL.appending(path: "Contents/Helpers/wheelhouse-mcp")
        let link = paths.binDirectory.appending(path: "wheelhouse-mcp")
        let fm = FileManager.default
        guard fm.fileExists(atPath: helper.path) else { return }
        if let current = try? fm.destinationOfSymbolicLink(atPath: link.path), current == helper.path { return }
        try? fm.createDirectory(at: paths.binDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    /// Follows the app lock without polling. A sheet does not survive the lock; approvals that waited start at the unlock.
    func follow(lock: MacLockCoordinator) {
        let locked = lock.isLocked
        lockMirror.set(locked)
        if locked { presenter.withdrawAll() } else { hub.lockChanged() }
        withObservationTracking { _ = lock.isLocked } onChange: { [weak self, weak lock] in
            Task { @MainActor in
                guard let self, let lock else { return }
                self.follow(lock: lock)
            }
        }
    }

    func turnOn() async {
        lastError = nil
        do { try await hub.turnOn() } catch { lastError = error.localizedDescription }
        refresh()
    }

    func turnOff() {
        hub.turnOff()
        presenter.withdrawAll()
        refresh()
    }

    /// Quit: sockets and sheets go with the app.
    func shutdown() {
        hub.turnOff()
        presenter.withdrawAll()
    }

    func refresh() {
        isOn = hub.isOn
        sessionCount = hub.sessionCount
        clients = store.records
    }

    // MARK: Clients

    func createClient(label: String) {
        do {
            let made = try store.createClient(label: label)
            revealed = made.record.id
        } catch { lastError = error.localizedDescription }
        refresh()
    }

    func revoke(_ id: String) {
        do { try hub.revoke(clientID: id) } catch { lastError = error.localizedDescription }
        if revealed == id { revealed = nil }
        refresh()
    }

    func setScope(_ id: String, read: Set<ClusterID>, changeRequests: Set<ClusterID>) async {
        do { try await hub.setScope(clientID: id, read: read, changeRequests: changeRequests) } catch { lastError = error.localizedDescription }
        refresh()
    }

    // MARK: Snippets and "Add to…"

    func claudeCodeCommand(for id: String) -> String? { store.secret(for: id).map { config.claudeCodeCommand(secret: $0) } }
    func projectJSON(for id: String) -> String? { store.secret(for: id).map { config.projectMCPJSON(secret: $0) } }

    /// The snippets hold a secret: copied as concealed, cleared after a minute and at quit.
    func copyToPasteboard(_ text: String) { Pasteboard.copySensitive(text) }

    func addToClaudeCode(_ id: String, locator: ExecutableLocator) async {
        guard let secret = store.secret(for: id) else { return }
        lastError = nil
        do {
            // A development build registers for this repository only (`--scope local`); it needs the repository folder from the build.
            let repo = (Bundle.main.object(forInfoDictionaryKey: "WHRepositoryRoot") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
            try await config.addToClaudeCode(secret: secret, locator: locator, runner: ProcessCommandRunner(), repository: repo)
        } catch { lastError = error.localizedDescription }
    }

    /// Development builds refuse (Claude Desktop's configuration is global); the Release app writes the real file, on click only.
    var canAddToClaudeDesktop: Bool { !gateActive && !config.developmentBuild }

    func addToClaudeDesktop(_ id: String, configURL: URL = BeaconClientConfig.claudeDesktopConfigURL()) {
        guard let secret = store.secret(for: id) else { return }
        lastError = nil
        do { try config.mergeIntoClaudeDesktop(configURL: configURL, secret: secret) } catch { lastError = error.localizedDescription }
    }
}

/// Lets Settings reach the model without the environment (as Landfall's pane does).
@MainActor
final class BeaconModelHub {
    static let shared = BeaconModelHub()
    var model: BeaconModel?
}
