#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Live Chart Room write path (ARCHITECTURE-MAC section 15.1, M6b): TEST CLUSTER ONLY, same gate as `GangwayLiveTests`
/// (`WH_LIVE_TESTS=1`, `WH_TEST_KUBECONFIG` = `<repo>/.testcluster/kubeconfig`). Needs `scripts/testcluster-fixtures.sh --section m6b-helm`.
/// Every helm runs through Gangway with a scratch `HELM_*` home. Helm binaries: `WH_HELM_BINS` (colon separated) or `/opt/homebrew/bin/helm`.
struct HelmBinary: Sendable, CustomTestStringConvertible {
    var path: String
    var testDescription: String { path }
    static let all: [HelmBinary] = {
        let list = ProcessInfo.processInfo.environment["WH_HELM_BINS"]?.split(separator: ":").map(String.init) ?? ["/opt/homebrew/bin/helm"]
        return list.filter { FileManager.default.isExecutableFile(atPath: $0) }.map { HelmBinary(path: $0) }
    }()
}

@Suite("Live: Chart Room write path", .enabled(if: GangwayLive.enabled), .serialized)
struct HelmLiveTests {
    private let ns = "wh-m6b"
    private var chart: String { GangwayLive.repoRoot().appending(path: "scripts/testcluster-fixtures.d/m6b-chart").path }

    private func runner(_ rig: LiveRig, _ bin: HelmBinary) async throws -> HelmRunner {
        let environment = EnvironmentBuilder(snapshot: ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh"), paths: rig.service.paths, home: rig.scratch.root)
        let cli = try await HelmCLI.detect(executable: URL(fileURLWithPath: bin.path), environment: environment)
        return HelmRunner(cli: cli, gangway: rig.service)
    }

    private func configMaps(_ rig: LiveRig) async throws -> String {
        let session = try await rig.open()
        defer { rig.service.closeSession(session) }
        return try await rig.kubectl(GangwayLive.kubectls[0], ["get", "configmap,service", "-n", ns, "-o", "name"], session: session).stdoutString
    }

    @Test("install, upgrade, roll back and uninstall through the review grant", arguments: HelmBinary.all)
    func lifecycle(bin: HelmBinary) async throws {
        let rig = try await LiveRig(environment: .production)
        defer { rig.stop() }
        let helm = try await runner(rig, bin)
        let name = "wh-m6b-" + String(UUID().uuidString.lowercased().prefix(6))
        let values = try String(contentsOf: URL(fileURLWithPath: chart).appending(path: "values.yaml"), encoding: .utf8)
        var lines: [String] = []
        let sink = Sink()

        // install
        let install = HelmOperation.install(release: name, chart: chart, version: nil, namespace: ns, createNamespace: false)
        let rendered = try await helm.render(install, cluster: rig.clusterID, valuesYAML: values, skipCRDs: false)
        #expect(rendered.release.manifest.contains("\(name)-config"))
        #expect(rendered.release.hooks.map(\.name).contains("\(name)-pre"))
        #expect(rendered.crdsYAML?.contains("whm6bwidgets.wheelhouse.test") == true)
        #expect(try await configMaps(rig).contains("\(name)-config") == false, "the render changed nothing")
        let installPlan = HelmGrantPlan.build(.init(operation: install, next: rendered.release, crdsYAML: rendered.crdsYAML))
        var exit = try await helm.apply(install, plan: installPlan, cluster: rig.clusterID, valuesYAML: values, options: HelmApplyOptions(timeout: .seconds(90)), output: sink.append)
        #expect(exit.succeeded, Comment(rawValue: sink.text))
        #expect(try await configMaps(rig).contains("configmap/\(name)-config"))

        // upgrade with new values
        let newValues = values.replacingOccurrences(of: "greeting: hello", with: "greeting: howdy")
        let upgrade = HelmOperation.upgrade(release: name, chart: chart, version: nil, namespace: ns, strategy: .reset)
        let next = try await helm.render(upgrade, cluster: rig.clusterID, valuesYAML: newValues, skipCRDs: true)
        let upgradePlan = HelmGrantPlan.build(.init(operation: upgrade, next: next.release, current: rendered.release, skipCRDs: true))
        sink.reset()
        exit = try await helm.apply(upgrade, plan: upgradePlan, cluster: rig.clusterID, valuesYAML: newValues, options: HelmApplyOptions(timeout: .seconds(90), skipCRDs: true), output: sink.append)
        #expect(exit.succeeded, Comment(rawValue: sink.text))

        // roll back to revision 1
        let rollback = HelmOperation.rollback(release: name, namespace: ns, revision: 1)
        let rollbackPlan = HelmGrantPlan.build(.init(operation: rollback, next: rendered.release, current: next.release))
        sink.reset()
        exit = try await helm.apply(rollback, plan: rollbackPlan, cluster: rig.clusterID, valuesYAML: "", options: HelmApplyOptions(timeout: .seconds(90)), output: sink.append)
        #expect(exit.succeeded, Comment(rawValue: sink.text))

        // a plan that leaves one object out: helm's create of it is refused by Gangway and helm fails
        let uninstall = HelmOperation.uninstall(release: name, namespace: ns, keepHistory: false)
        var short = HelmGrantPlan.build(.init(operation: uninstall, current: rendered.release))
        short.objects = short.objects.filter { $0.name != "\(name)-svc" }
        sink.reset()
        exit = try await helm.apply(uninstall, plan: short, cluster: rig.clusterID, valuesYAML: "", options: HelmApplyOptions(timeout: .seconds(60)), output: sink.append)
        #expect(!exit.succeeded, "deleting an object that is not in the grant must fail")
        #expect(try await configMaps(rig).contains("service/\(name)-svc"), "the refused delete left the Service alone")

        // uninstall with the real plan
        let full = HelmGrantPlan.build(.init(operation: uninstall, current: rendered.release))
        sink.reset()
        exit = try await helm.apply(uninstall, plan: full, cluster: rig.clusterID, valuesYAML: "", options: HelmApplyOptions(timeout: .seconds(90)), output: sink.append)
        #expect(exit.succeeded, Comment(rawValue: sink.text))
        #expect(try await configMaps(rig).contains(name) == false)
        lines.append(sink.text)
        #expect(rig.activity.entries.contains { $0.result.hasPrefix("refused") }, "the refusal is in Activity")
        #expect(rig.service.registry.sessions.isEmpty, "no helm session is left open")
    }
}

/// Collects helm's output from the stream callback.
final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = ""
    var text: String { lock.withLock { buffer } }
    func append(_ chunk: String) { lock.withLock { buffer += chunk } }
    func reset() { lock.withLock { buffer = "" } }
}
#endif
