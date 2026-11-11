#if os(macOS)
import Foundation
import WheelhouseKit

/// What helm's dry run printed.
public struct HelmRenderOutput: Sendable {
    public var release: HelmRelease
    /// `helm show crds`; nil when the chart has none or they are skipped.
    public var crdsYAML: String?
}

/// Runs helm through Gangway (ARCHITECTURE-MAC section 5.2): the render under a dry-run-only session, the real run under an object grant
/// bound to the spawned helm process. The caller does the review and the confirmation between the two; `apply` is never reached without it.
public struct HelmRunner: Sendable {
    public let cli: HelmCLI
    public let gangway: GangwayService

    public init(cli: HelmCLI, gangway: GangwayService) {
        self.cli = cli
        self.gangway = gangway
    }

    /// Install and upgrade only: `helm … --dry-run --output json`, plus the chart's CRDs. Changes nothing: the session refuses every
    /// request that is not a read, a review or a dry run.
    public func render(_ op: HelmOperation, cluster: ClusterID, valuesYAML: String, skipCRDs: Bool) async throws -> HelmRenderOutput {
        let chart: String, chartVersion: String?
        switch op {
        case .install(_, let c, let v, _, _), .upgrade(_, let c, let v, _, _): (chart, chartVersion) = (c, v)
        case .rollback, .uninstall: throw HelmCLIError.unsupported("A \(op.verb) is reviewed natively.")
        }
        return try await renderChart(op, chart: chart, chartVersion: chartVersion, cluster: cluster, valuesYAML: valuesYAML, skipCRDs: skipCRDs)
    }

    private func renderChart(_ op: HelmOperation, chart: String, chartVersion: String?, cluster: ClusterID, valuesYAML: String, skipCRDs: Bool) async throws -> HelmRenderOutput {
        let handle = try await gangway.openSession(clusterID: cluster, origin: .chartRoom(operation: "render"), scope: .dryRunOnly, namespace: op.namespace)
        defer { gangway.closeSession(handle, reason: "render finished") }
        let values = try Self.writeValues(valuesYAML, in: handle.directory)
        let args = try cli.renderArguments(op, valuesFile: values)
        let result = try await Subprocess.run(cli.spec(arguments: args, kubeconfig: handle.kubeconfig, timeout: .seconds(180)))
        guard result.exit.succeeded else { throw HelmCLIError.failed(code: result.exitCode, message: Self.message(result)) }
        guard let release = try? HelmReleaseCodec.decode(payload: result.stdout) else { throw HelmCLIError.unreadableOutput }
        var crds: String?
        if !skipCRDs {
            // No cluster involved: no session, no kubeconfig.
            let show = try await Subprocess.run(cli.spec(arguments: cli.showCRDsArguments(chart: chart, version: chartVersion), kubeconfig: nil, timeout: .seconds(120)))
            if show.exit.succeeded, !show.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { crds = show.stdoutString }
        }
        return HelmRenderOutput(release: release, crdsYAML: crds)
    }

    /// The real run. Opens an object session, grants exactly `plan.objects` to the spawned helm (own session and process group, bound
    /// before helm runs), streams its output, and ends the session when helm exits. Returns helm's exit.
    public func apply(_ op: HelmOperation, plan: HelmGrantPlan, cluster: ClusterID, valuesYAML: String, options: HelmApplyOptions,
                      output: @escaping @Sendable (String) -> Void) async throws -> ProcessExit {
        let handle = try await gangway.openSession(clusterID: cluster, origin: .chartRoom(operation: op.verb), scope: .objects, namespace: op.namespace)
        defer { gangway.closeSession(handle, reason: "helm finished") }
        let values = op.rendersWithHelm ? try Self.writeValues(valuesYAML, in: handle.directory) : nil
        let args = try cli.applyArguments(op, valuesFile: values, options: options)
        let lifetime = TimeInterval(options.timeout.components.seconds) + 120
        gangway.grants.setObjects(session: handle.session, objects: plan.objects, lifetime: lifetime)
        let session = handle.session
        let spec = cli.spec(arguments: args, kubeconfig: handle.kubeconfig, timeout: options.timeout + .seconds(120), newSession: true,
                            spawnGate: { session.bindIsolatedGroup($0) })
        var exit: ProcessExit?
        for try await event in Subprocess.stream(spec) {
            switch event {
            case .stdout(let data), .stderr(let data): output(String(decoding: data, as: UTF8.self))
            case .exit(let e): exit = e
            }
        }
        guard let exit else { throw HelmCLIError.unreadableOutput }
        return exit
    }

    static func writeValues(_ text: String, in directory: URL) throws -> URL {
        let file = directory.appending(path: "values.yaml")
        try Data(text.utf8).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return file
    }

    static func message(_ result: ProcessResult) -> String {
        let text = result.stderrString.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "exit code \(result.exitCode.map(String.init) ?? "none")" : text
    }
}
#endif
