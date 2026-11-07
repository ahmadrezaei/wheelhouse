#if os(macOS)
import Foundation

/// Every on-disk location the Mac app uses (ARCHITECTURE-MAC §1.8). Nothing builds a path any other way.
///
/// The root is `Wheelhouse-Debug` whenever the safety gate is active **or** the bundle ID ends in `.debug`, so a local Release
/// build never reads the real `landfall.yaml`, `discovered-clusters.json`, `cluster-settings.json` or `workspace.json`.
public struct AppPaths: Sendable, Equatable {
    public var isolated: Bool
    public var home: URL
    public var temporaryDirectory: URL

    public init(gateActive: Bool, bundleID: String?, home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true),
                temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)) {
        self.isolated = gateActive || (bundleID?.hasSuffix(".debug") ?? false)
        self.home = home
        self.temporaryDirectory = temporaryDirectory
    }

    /// The running app's paths.
    public static var current: AppPaths { AppPaths(gateActive: DevSafety.isActive, bundleID: Bundle.main.bundleIdentifier) }

    public static let releaseBundleID = "com.ahmadrezaei.wheelhouse.mac"

    /// `~/Library/Application Support/Wheelhouse/` or `…/Wheelhouse-Debug/`.
    public var root: URL {
        home.appending(path: "Library/Application Support/\(isolated ? "Wheelhouse-Debug" : "Wheelhouse")", directoryHint: .isDirectory)
    }
    /// `~/Library/Caches/com.ahmadrezaei.wheelhouse.mac[.debug]/`.
    public var caches: URL {
        home.appending(path: "Library/Caches/\(Self.releaseBundleID)\(isolated ? ".debug" : "")", directoryHint: .isDirectory)
    }
    /// `$TMPDIR/wheelhouse[-debug]/sessions/`.
    public var sessions: URL {
        temporaryDirectory.appending(path: "\(isolated ? "wheelhouse-debug" : "wheelhouse")/sessions", directoryHint: .isDirectory)
    }
    /// Where the `wheelhouse-mcp` symlink lives.
    public var binDirectory: URL { root.appending(path: "bin", directoryHint: .isDirectory) }

    public var workspaceFile: URL { root.appending(path: "workspace.json") }
    public var discoveredClustersFile: URL { root.appending(path: "discovered-clusters.json") }
    public var clusterSettingsFile: URL { root.appending(path: "cluster-settings.json") }
    public var landfallKubeconfig: URL { root.appending(path: "kubeconfigs/landfall.yaml") }
    public var activityDatabase: URL { root.appending(path: "activity.sqlite") }

    /// `Wheelhouse-Debug/helm/` (only used when isolated).
    public var helmRoot: URL { root.appending(path: "helm", directoryHint: .isDirectory) }

    /// `HELM_*` for every helm run and every Deck Terminal while isolated, pointing into ``helmRoot``. Empty when not isolated
    /// (the user's own helm configuration applies).
    public var helmEnvironment: [String: String] {
        guard isolated else { return [:] }
        let config = helmRoot.appending(path: "config", directoryHint: .isDirectory)
        let cache = helmRoot.appending(path: "cache", directoryHint: .isDirectory)
        return [
            "HELM_CONFIG_HOME": config.path,
            "HELM_CACHE_HOME": cache.path,
            "HELM_DATA_HOME": helmRoot.appending(path: "data", directoryHint: .isDirectory).path,
            "HELM_REPOSITORY_CONFIG": config.appending(path: "repositories.yaml").path,
            "HELM_REPOSITORY_CACHE": cache.appending(path: "repository", directoryHint: .isDirectory).path,
            "HELM_REGISTRY_CONFIG": config.appending(path: "registry/config.json").path,
        ]
    }

    /// Creates `root` with owner-only permissions.
    public func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }
}
#endif
