import Foundation
import WheelhouseDesktop
import WheelhouseKit

extension HelmToolbox {
    /// The runner of this app: Gangway (started on first use) and the located helm.
    @MainActor
    static func liveRunner(_ env: MacAppEnvironment) -> @MainActor () async throws -> HelmRunner {
        { HelmRunner(cli: try await cli(paths: env.paths), gangway: try await env.gangway.service()) }
    }

    /// The default values and `values.schema.json` of a chart: read from the folder (a local chart), or from the archive pulled into the
    /// chart cache (`helm pull`, then the tar reader in Kit). nil when the chart cannot be read; the editor then has no hints.
    @MainActor
    static func chartDefaults(chart: String, version: String, env: MacAppEnvironment) async -> (values: String, schema: Data?)? {
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: chart, isDirectory: &isDirectory), isDirectory.boolValue {
            let root = URL(fileURLWithPath: chart, isDirectory: true)
            let values = (try? String(contentsOf: root.appending(path: "values.yaml"), encoding: .utf8)) ?? ""
            return (values, try? Data(contentsOf: root.appending(path: "values.schema.json")))
        }
        guard !chart.hasPrefix("-"), !chart.hasPrefix("/"), let cli = try? await cli(paths: env.paths) else { return nil }
        let repository = chart.hasPrefix("oci://") ? "oci" : String(chart.split(separator: "/").first ?? "")
        let cache = env.paths.caches.appending(path: "charts", directoryHint: .isDirectory)
        guard let file = try? await HelmRepoRunner(cli: cli).pull(chart: chart, version: version, repository: repository, cache: cache),
              let data = try? Data(contentsOf: file, options: .mappedIfSafe), let archive = try? HelmChartArchive.read(tgz: data) else { return nil }
        return (archive.values ?? "", archive.schema.map { Data($0.utf8) })
    }
}

extension HelmFlowModel {
    /// Fills the values editor and its hints from the chart (install, or an upgrade to another chart).
    func loadChartDefaults(env: MacAppEnvironment) async {
        guard !chart.isEmpty, let found = await HelmToolbox.chartDefaults(chart: chart, version: chartVersion, env: env) else { return }
        if valuesText.isEmpty { valuesText = found.values }
        setHints(ValuesSchemaHints(schemaData: found.schema, defaults: found.values))
    }
}
