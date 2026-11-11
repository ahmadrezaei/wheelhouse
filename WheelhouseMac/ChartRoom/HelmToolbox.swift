import Foundation
import WheelhouseDesktop
import WheelhouseKit

/// Chart Room settings (Settings → Chart Room).
enum ChartRoomSettings {
    /// `bundled` (the helm in the app, when there is one, then PATH) or `custom` (the path below).
    static let helmChoice = "chartRoom.helmChoice"
    static let helmPath = "chartRoom.helmPath"
    static let artifactHub = "chartRoom.artifactHub"

    static var isArtifactHubOn: Bool { UserDefaults.standard.bool(forKey: artifactHub) }
}

/// Where the helm binary comes from (ARCHITECTURE-MAC section 5.2): the one in the app, the user's own from PATH, or a path chosen in
/// Settings. If the bundled binary cannot be started the user is offered the PATH one.
enum HelmToolbox {
    enum Source: Equatable { case bundled(URL), custom(URL), path(URL) }

    struct Missing: LocalizedError {
        var errorDescription: String? { "No helm was found. Install helm, or choose one in Settings → Chart Room." }
    }

    static func bundledURL(bundle: Bundle = .main) -> URL? {
        let url = bundle.bundleURL.appending(path: "Contents/Helpers/helm")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url : nil
    }

    static func locate(defaults: UserDefaults = .standard, bundled: URL? = bundledURL(), locator: ExecutableLocator) -> Source? {
        if defaults.string(forKey: ChartRoomSettings.helmChoice) == "custom", let path = defaults.string(forKey: ChartRoomSettings.helmPath),
           FileManager.default.isExecutableFile(atPath: path) {
            return .custom(URL(fileURLWithPath: path))
        }
        if let bundled { return .bundled(bundled) }
        return locator.find("helm").map(Source.path)
    }

    /// The helm adapter for this app: detects the version, and falls back to the PATH helm when the bundled one will not start.
    @MainActor
    static func cli(paths: AppPaths) async throws -> HelmCLI {
        let snapshot = await MooringsController.shared?.shellEnvironment.current()
        let environment = EnvironmentBuilder(snapshot: snapshot, paths: paths, home: paths.home)
        let locator = ExecutableLocator(snapshot: snapshot, home: paths.home)
        guard let source = locate(locator: locator) else { throw Missing() }
        switch source {
        case .bundled(let url):
            do { return try await HelmCLI.detect(executable: url, environment: environment) } catch {
                guard let fallback = locator.find("helm") else { throw error }
                return try await HelmCLI.detect(executable: fallback, environment: environment)
            }
        case .custom(let url), .path(let url):
            return try await HelmCLI.detect(executable: url, environment: environment)
        }
    }
}
