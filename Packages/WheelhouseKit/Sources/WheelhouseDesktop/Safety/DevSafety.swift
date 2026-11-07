#if os(macOS)
import Foundation
import Synchronization
import WheelhouseKit

public enum DevSafetyError: Error, Equatable, Sendable, LocalizedError {
    /// A path under `~/.kube` (after resolving symlinks) was about to be read while the gate is active.
    case homeKubeconfig(String)
    /// A server host that is not one of the allowed test hosts.
    case hostNotAllowed(String)
    /// The explicit test kubeconfig could not be used.
    case invalidTestKubeconfig(String)
    /// A feature that is switched off while the gate is active (cloud CLIs, `~/.kube/config` merge).
    case disabledInDevelopment(String)

    public var errorDescription: String? {
        switch self {
        case .homeKubeconfig: "Development builds can't read ~/.kube."
        case .hostNotAllowed(let host): "Blocked in development builds: \(host) is not a test cluster."
        case .invalidTestKubeconfig(let why): "The test kubeconfig can't be used: \(why)"
        case .disabledInDevelopment(let what): "\(what) is disabled in development builds."
        }
    }
}

/// The fail-closed development safety gate (ARCHITECTURE-MAC §13.2, decision D22).
///
/// `isActive` is **false only when all three hold**: Info.plist `WHDevSafety` is exactly `NO` (only the `Distribution`
/// configuration sets it; a missing key counts as `YES`), the bundle ID is `com.ahmadrezaei.wheelhouse.mac`, and the running
/// app has a valid Developer ID Application signature for team JCZY58QP3L. `#if DEBUG` is never used for safety.
public enum DevSafety {
    public static let teamID = "JCZY58QP3L"
    public static let distributionBundleID = "com.ahmadrezaei.wheelhouse.mac"

    /// true = development safety ON (the default for every build except Distribution). Evaluated once, at first use, which
    /// the app triggers before any store, client, file watcher or subprocess exists.
    public static let isActive: Bool = evaluate(info: Bundle.main.infoDictionary ?? [:],
                                                bundleID: Bundle.main.bundleIdentifier,
                                                signature: CodeSignature.ofRunningApp())

    /// The pure decision (the truth table of `DevSafetyTests`).
    public static func evaluate(info: [String: Any], bundleID: String?, signature: CodeSignature) -> Bool {
        guard (info["WHDevSafety"] as? String) == "NO" else { return true }          // missing, "YES" or anything else: ON
        guard bundleID == distributionBundleID else { return true }                  // ….mac.debug (Debug, Profile): ON
        guard signature.isValidDeveloperID(team: teamID) else { return true }        // Apple Development, ad hoc, unsigned: ON
        return false
    }

    private static let hosts = AllowedHostsStore()

    /// Server hosts of the clusters in the explicit test kubeconfig (the reserved fixture suffixes are always allowed on top).
    /// Set once at launch by ``configureAllowedHosts(_:)``.
    public static var allowedHosts: Set<String> { hosts.value }

    /// Sets the allowed hosts. Only the FIRST call takes effect (returns true); later calls are ignored, so nothing can widen the
    /// allowlist after launch.
    @discardableResult
    public static func configureAllowedHosts(_ newHosts: Set<String>) -> Bool { hosts.setOnce(newHosts) }

    /// Demo clusters (no server) are always allowed; otherwise only gate-allowed hosts while the gate is active.
    public static func isAllowed(server: URL?) -> Bool { DevSafetyPolicy.current.isAllowed(server: server) }
}

/// A set that can be assigned exactly once.
public final class AllowedHostsStore: Sendable {
    private let state = Mutex<Set<String>?>(nil)
    public init() {}
    public var value: Set<String> { state.withLock { $0 ?? [] } }
    @discardableResult
    public func setOnce(_ hosts: Set<String>) -> Bool {
        state.withLock { current in
            guard current == nil else { return false }
            current = Set(hosts.map { $0.lowercased() })
            return true
        }
    }
}

/// The gate as a value, so tests can inject every input. ``current`` is the running app's gate.
public struct DevSafetyPolicy: Sendable {
    public var isActive: Bool
    public var allowedHosts: Set<String>
    /// The user's home directory (injected in tests).
    public var home: URL

    public init(isActive: Bool, allowedHosts: Set<String> = [], home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) {
        self.isActive = isActive
        self.allowedHosts = allowedHosts
        self.home = home
    }

    public static var current: DevSafetyPolicy { DevSafetyPolicy(isActive: DevSafety.isActive, allowedHosts: DevSafety.allowedHosts) }

    /// Reserved names that never resolve, always allowed as fixtures.
    static let reservedSuffixes = [".test", ".example", ".invalid"]

    /// Demo clusters (no server) are always allowed. While inactive everything is allowed. While active only an allowed host
    /// or a reserved fixture name.
    public func isAllowed(server: URL?) -> Bool {
        guard isActive else { return true }
        guard let server else { return true }
        guard let host = server.host()?.lowercased(), !host.isEmpty else { return false }
        if allowedHosts.contains(host) { return true }
        return Self.reservedSuffixes.contains { host.hasSuffix($0) }
    }

    /// Throws ``DevSafetyError/hostNotAllowed(_:)``. Called at client creation and again at connect time.
    public func validate(server: URL?) throws {
        guard isAllowed(server: server) else { throw DevSafetyError.hostNotAllowed(server?.host() ?? server?.absoluteString ?? "unknown host") }
    }

    // MARK: Switched-off features

    /// `~/.kube` and the shell `KUBECONFIG` may be read.
    public var allowsHomeDiscovery: Bool { !isActive }
    /// Landfall, cloud-CLI login commands.
    public var allowsCloudCLIs: Bool { !isActive }
    /// Export Context and the `~/.kube/config` merge.
    public var allowsKubeconfigWrites: Bool { !isActive }
    /// `-WHPerfScenario` is honoured only while the gate is active.
    public var honoursPerfScenario: Bool { isActive }

    /// The Sparkle updater starts only with a feed and with the gate off (Debug and Profile have no feed; a local Release build
    /// has a feed but the gate on).
    public func shouldStartUpdater(feedURL: String?) -> Bool {
        guard !isActive else { return false }
        return !(feedURL ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Fails closed for a feature that is off while the gate is active.
    public func require(_ allowed: Bool, feature: String) throws {
        guard allowed else { throw DevSafetyError.disabledInDevelopment(feature) }
    }

    /// The scenario name from launch arguments (`-WHPerfScenario <name>`), or nil when absent or while the gate is inactive.
    public func perfScenario(arguments: [String]) -> String? {
        guard honoursPerfScenario, let i = arguments.firstIndex(of: "-WHPerfScenario"), arguments.indices.contains(i + 1) else { return nil }
        let name = arguments[i + 1]
        return name.isEmpty ? nil : name
    }

    // MARK: Paths under ~/.kube

    /// `realpath` of `~/.kube` (symlinks resolved), even when it does not exist.
    var resolvedKubeDirectory: URL { home.appending(path: ".kube", directoryHint: .isDirectory).resolvingSymlinksInPath().standardizedFileURL }

    /// (device, inode) of a path, from `stat` (metadata only; the file is never opened or read).
    static func fileIdentity(_ url: URL) -> (dev: UInt64, ino: UInt64)? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        return (UInt64(bitPattern: Int64(st.st_dev)), UInt64(st.st_ino))
    }

    /// True when `url`, after resolving symlinks, is `~/.kube` or inside it, or when it IS `~/.kube/config` or `~/.kube` itself
    /// under another name (a hard link: same device and inode, compared with `stat`).
    public func isUnderHomeKube(_ url: URL) -> Bool {
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
        let kube = resolvedKubeDirectory.path
        if resolved == kube || resolved.hasPrefix(kube + "/") { return true }
        guard let id = Self.fileIdentity(url) else { return false }
        for protected in [resolvedKubeDirectory.appending(path: "config"), resolvedKubeDirectory] {
            if let p = Self.fileIdentity(protected), p.dev == id.dev, p.ino == id.ino { return true }
        }
        return false
    }

    /// Throws ``DevSafetyError/homeKubeconfig(_:)`` for any path under `~/.kube` while the gate is active (every source type).
    public func assertReadable(_ url: URL) throws {
        guard isActive else { return }
        if isUnderHomeKube(url) { throw DevSafetyError.homeKubeconfig(url.path) }
    }
}
#endif
