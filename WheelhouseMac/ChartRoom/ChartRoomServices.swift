import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// What Chart Room needs from the rest of the app, injected through the environment so the feature never edits shared files.
/// Defaults are safe: no GitOps detector (the ownership badge slot stays empty until M9 injects one) and helm paths that follow
/// the isolation rules of the safety gate.
struct ChartRoomServices: Sendable {
    var ownership: any GitOpsOwnership = NoOwnership()
    var helmPaths: HelmPaths = ChartRoomServices.defaultHelmPaths()
    /// Compact repository indexes (`~/Library/Caches/com.ahmadrezaei.wheelhouse.mac[.debug]/helm-index`).
    var indexCache: URL = AppPaths.current.caches.appending(path: "helm-index", directoryHint: .isDirectory)
    var releaseCache: DecodedReleaseCache = .shared

    /// While the safety gate is active the app's isolated `HELM_*` locations win over the process environment, so a development
    /// build never reads the user's real repositories (ARCHITECTURE-MAC §5.2).
    static func defaultHelmPaths(paths: AppPaths = .current, environment: [String: String] = ProcessInfo.processInfo.environment) -> HelmPaths {
        var merged = environment
        for (key, value) in paths.helmEnvironment { merged[key] = value }
        if paths.isolated {
            // Nothing from the shell may point an isolated build at a real helm home.
            for key in ["XDG_CONFIG_HOME", "XDG_CACHE_HOME", "XDG_DATA_HOME"] { merged[key] = nil }
        }
        return HelmPaths.resolve(environment: merged, home: paths.home)
    }
}

private struct ChartRoomServicesKey: EnvironmentKey { static let defaultValue = ChartRoomServices() }

extension EnvironmentValues {
    var chartRoomServices: ChartRoomServices {
        get { self[ChartRoomServicesKey.self] }
        set { self[ChartRoomServicesKey.self] = newValue }
    }
}
