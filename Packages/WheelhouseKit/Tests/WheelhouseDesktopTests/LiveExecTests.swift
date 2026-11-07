#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

/// Live tests (ARCHITECTURE-MAC §13.3): TEST CLUSTER ONLY.
///
/// They run only with `WH_LIVE_TESTS=1` and refuse unless `WH_TEST_KUBECONFIG` resolves to `<repo>/.testcluster/kubeconfig`, is not
/// under `~/.kube`, holds the context `wheelhouse-test`, and that context's server host equals `.testcluster/server-host`. They need
/// `scripts/testcluster-fixtures.sh --section m3-exec` to have been run. They never read `~/.kube` or `.secrets/`.
enum LiveGuard {
    static var enabled: Bool { ProcessInfo.processInfo.environment["WH_LIVE_TESTS"] == "1" }

    struct Verified {
        var execKubeconfig: URL
        var host: String
        var pluginRuns: URL
    }

    static func verify(file: StaticString = #filePath) throws -> Verified {
        let env = ProcessInfo.processInfo.environment
        let path = try #require(env["WH_TEST_KUBECONFIG"], "WH_TEST_KUBECONFIG is not set")
        let kubeconfig = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        var repo = URL(fileURLWithPath: "\(file)")
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        let expected = repo.appending(path: ".testcluster/kubeconfig").resolvingSymlinksInPath()
        try #require(kubeconfig == expected, "WH_TEST_KUBECONFIG must be <repo>/.testcluster/kubeconfig")
        let kube = URL(fileURLWithPath: NSHomeDirectory()).appending(path: ".kube").resolvingSymlinksInPath().path
        try #require(!kubeconfig.path.hasPrefix(kube + "/"), "the test kubeconfig must not be under ~/.kube")

        let text = try String(contentsOf: kubeconfig, encoding: .utf8)
        let parsed = try KubeconfigParser.parse(text, environment: .desktop(baseDirectory: kubeconfig.deletingLastPathComponent()))
        let test = try #require(parsed.contexts.first { $0.name == "wheelhouse-test" }, "context wheelhouse-test is missing")
        let host = try #require(test.server?.host())
        let recorded = try String(contentsOf: kubeconfig.deletingLastPathComponent().appending(path: "server-host"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(host == recorded, "the server host \(host) differs from the recorded \(recorded)")

        let exec = kubeconfig.deletingLastPathComponent().appending(path: "exec-kubeconfig")
        try #require(FileManager.default.fileExists(atPath: exec.path), "run scripts/testcluster-fixtures.sh --section m3-exec first")
        return Verified(execKubeconfig: exec, host: host, pluginRuns: kubeconfig.deletingLastPathComponent().appending(path: "exec-plugin-runs"))
    }
}

private final class OffsetClock: @unchecked Sendable {
    private let offset = Mutex<TimeInterval>(0)
    var now: Date { Date().addingTimeInterval(offset.withLock { $0 }) }
    func advance(_ s: TimeInterval) { offset.withLock { $0 += s } }
}

@Suite("Live: exec credentials against the test cluster", .enabled(if: LiveGuard.enabled), .serialized)
struct LiveExecTests {
    private struct Rig {
        let service: MooringsService
        let state: MooringsState
        let factory: DesktopClientFactory
        let broker: ExecCredentialBroker
        let scratch: Scratch
        let host: String
    }

    private func makeRig() async throws -> Rig {
        let v = try LiveGuard.verify()
        let s = try Scratch()
        let home = try s.home()
        // The same posture as a development build: the gate is active and only the test cluster's host is allowed.
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: [v.host], home: home)
        let state = MooringsState(overrides: DiscoveredClusterStore(fileURL: s.root.appending(path: "discovered-clusters.json")),
                                  preferences: MooringsPreferencesStore(fileURL: s.root.appending(path: "moorings.json")), gate: gate)
        try state.preferences.update { $0.firstRunCompleted = true }
        let clock = OffsetClock()
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin:/usr/local/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh")
        let paths = AppPaths(gateActive: true, bundleID: "com.ahmadrezaei.wheelhouse.mac.debug", home: s.root)
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(snapshot: snapshot, home: home) },
                                          environment: { EnvironmentBuilder(snapshot: snapshot, paths: paths, home: home) },
                                          gate: gate, timeout: .seconds(20), now: { clock.now })
        let settings = MacClusterSettingsStore(fileURL: s.root.appending(path: "cluster-settings.json"))
        let factory = DesktopClientFactory(state: state, settings: settings, broker: broker, gate: gate)
        let service = MooringsService(config: MooringsConfiguration(gate: gate, home: home, explicitTestKubeconfig: v.execKubeconfig),
                                      state: state, clients: factory, broker: broker)
        await service.rescan()
        return Rig(service: service, state: state, factory: factory, broker: broker, scratch: s, host: v.host)
    }

    private func runs(_ v: LiveGuard.Verified) -> Int { Int((try? String(contentsOf: v.pluginRuns, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0 }

    @Test func theExecContextsAreDiscoveredWithThePluginStanza() async throws {
        let rig = try await makeRig(); defer { rig.scratch.cleanup() }
        let names = Set(rig.state.contexts.map(\.context.name))
        #expect(names == ["wheelhouse-exec", "wheelhouse-exec-beta"])
        let v1 = try #require(rig.state.contexts.first { $0.context.name == "wheelhouse-exec" })
        #expect(v1.authSummary == .exec(command: v1.context.exec?.command ?? ""))
        #expect(v1.context.exec?.apiVersion == "client.authentication.k8s.io/v1")
        #expect(v1.context.exec?.interactiveMode == "Never")
        #expect(v1.context.exec?.provideClusterInfo == true)
        #expect(v1.blockedInDevelopment == false)
        #expect(v1.context.exec?.command.hasSuffix("/.testcluster/exec-plugin.sh") == true)
    }

    @Test func aRealClientAuthenticatesThroughThePluginAndReadsTheFixture() async throws {
        let v = try LiveGuard.verify()
        let rig = try await makeRig(); defer { rig.scratch.cleanup() }
        let ctx = try #require(rig.state.contexts.first { $0.context.name == "wheelhouse-exec" })
        try await rig.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true)])
        let config = try #require(rig.state.listedConfigs().first { $0.id == ctx.id })
        #expect(config.readOnly)
        let secrets = DiscoveredSecrets.resolve(ctx.context, gate: DevSafetyPolicy(isActive: true, allowedHosts: [v.host]))
        let client = rig.factory.make(config: config, secrets: secrets)
        #expect(client is LiveKubeClient)

        let before = runs(v)
        let version = try await client.version()
        #expect(version.gitVersion.hasPrefix("v1."))
        let list = try await client.listRaw(.configMap, namespace: "wh-m3", options: ListOptions())
        let names = list.objectValue?["items"]?.arrayValue?.compactMap { $0.objectValue?["metadata"]?.objectValue?["name"]?.stringValue } ?? []
        #expect(names.contains("m3-fixture"))
        // Several requests, one plugin run: the credential is cached in memory until it expires.
        #expect(runs(v) == before + 1)

        // A streaming call resolves the credential first.
        try await client.prepareStreaming()
        // Discovered clusters start read-only: the shared policy still refuses the socket.
        #expect(throws: KubeError.self) { _ = try client.execWebSocket(namespace: "wh-m3", pod: "none", options: ExecOptions(command: ["sh"], tty: true, stdin: true)) }
    }

    @Test func aWatchStreamIsAuthorizedByThePlugin() async throws {
        let rig = try await makeRig(); defer { rig.scratch.cleanup() }
        let ctx = try #require(rig.state.contexts.first { $0.context.name == "wheelhouse-exec" })
        try await rig.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true)])
        let config = try #require(rig.state.listedConfigs().first { $0.id == ctx.id })
        let client = rig.factory.make(config: config, secrets: DiscoveredSecrets.resolve(ctx.context, gate: DevSafetyPolicy(isActive: true, allowedHosts: [rig.host])))
        var sawFixture = false
        let stream = client.watch(ConfigMap.self, namespace: "wh-m3", options: WatchOptions())
        for try await event in stream {
            if case .added(let cm) = event, cm.metadata.name == "m3-fixture" { sawFixture = true; break }
            if case .modified(let cm) = event, cm.metadata.name == "m3-fixture" { sawFixture = true; break }
        }
        #expect(sawFixture)
    }

    @Test func theCredentialIsRefreshedBeforeItExpiresAndTheBetaPluginIsReusedWithoutExpiry() async throws {
        let v = try LiveGuard.verify()
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let gate = DevSafetyPolicy(isActive: true, allowedHosts: [v.host], home: home)
        let clock = OffsetClock()
        let snapshot = ShellSnapshot(path: "/usr/bin:/bin", kubeconfig: nil, vars: [:], shell: "/bin/sh")
        let broker = ExecCredentialBroker(locator: { ExecutableLocator(snapshot: snapshot, home: home) },
                                          environment: { EnvironmentBuilder(snapshot: snapshot, paths: AppPaths(gateActive: true, bundleID: "x.debug", home: s.root), home: home) },
                                          gate: gate, now: { clock.now })
        let text = try String(contentsOf: v.execKubeconfig, encoding: .utf8)
        let ctxs = try KubeconfigParser.parse(text, environment: .desktop(baseDirectory: v.execKubeconfig.deletingLastPathComponent())).contexts
        let v1 = try #require(ctxs.first { $0.name == "wheelhouse-exec" })
        let beta = try #require(ctxs.first { $0.name == "wheelhouse-exec-beta" })
        let info = ExecClusterInfo(server: v1.server!.absoluteString)

        let p1 = ExecCredentialProvider(spec: try #require(v1.exec), cluster: info, kubeconfigPath: v.execKubeconfig.path, broker: broker)
        let start = runs(v)
        let t1 = try #require(try await p1.authorization())
        #expect(t1.hasPrefix("eyJ") || t1.count > 20)
        _ = try await p1.authorization()
        #expect(runs(v) == start + 1)
        clock.advance(11 * 60)                      // the 10-minute credential is now past its refresh time
        _ = try await p1.authorization()
        #expect(runs(v) == start + 2)

        let p2 = ExecCredentialProvider(spec: try #require(beta.exec), cluster: info, kubeconfigPath: v.execKubeconfig.path, broker: broker)
        _ = try await p2.authorization()
        clock.advance(24 * 3600)
        _ = try await p2.authorization()
        #expect(runs(v) == start + 3)               // no expiry: reused until a 401
    }
}
#endif
