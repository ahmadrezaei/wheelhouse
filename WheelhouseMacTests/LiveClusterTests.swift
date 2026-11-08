import Testing
import AppKit
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// Live checks against the TEST cluster only (ARCHITECTURE-MAC section 13.3). They run when `TEST_RUNNER_WH_LIVE_TESTS=1` is set and
/// the test kubeconfig is `<repo>/.testcluster/kubeconfig`; they use only the namespaces `shop` and `batch`, and the pod
/// `wh-term-test` in `shop` (a throw-away alpine pod with vim and htop, created and deleted by hand).
///
/// The cluster is reached the way the app reaches it: the kubeconfig goes through `MacImportPolicy` (file references inlined,
/// dev-safety checks), then `ClusterRegistry`, `ClusterSession` and the Kit clients. Nothing here reads `~/.kube`.
@Suite("Live cluster", .enabled(if: ProcessInfo.processInfo.environment["WH_LIVE_TESTS"] == "1"))
@MainActor
struct LiveClusterTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let kubeconfig = repo.appending(path: ".testcluster/kubeconfig")

    private struct Live {
        var registry: ClusterRegistry
        var session: ClusterSession
        var config: ClusterConfig
    }

    /// Imports the test kubeconfig exactly as the import sheet does: through the policy, then into a registry.
    private func connect(readOnly: Bool = false, environment: ClusterEnvironment = .development) throws -> Live {
        #expect(DevSafety.isActive)
        let path = try #require(ProcessInfo.processInfo.environment["WH_TEST_KUBECONFIG"].map { URL(fileURLWithPath: $0) } ?? Self.kubeconfig as URL?)
        #expect(path.standardizedFileURL.path.hasSuffix("/.testcluster/kubeconfig"), "the live tests only run against .testcluster/kubeconfig")
        let policy = MacImportPolicy()
        let loaded = try policy.loadFile(path)
        let kc = try policy.parse(loaded.text)
        let ctx = try #require(kc.contexts.first { $0.name == "wheelhouse-test" })
        #expect(ctx.status == .ready)
        #expect(policy.blockedReason(for: ctx) == nil, "the test host must be an allowed host")
        var made = try #require(ctx.makeClusterConfig())
        made.config.environment = environment
        made.config.readOnly = readOnly
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.live.tests")!,
                                       clientFactory: MacAppEnvironment.guardedClientFactory())
        try registry.add(made.config, secrets: made.secrets)
        let session = try #require(registry.session(for: made.config.id))
        return Live(registry: registry, session: session, config: made.config)
    }

    @Test func importedTestClusterConnects() async throws {
        let live = try connect()
        let result = await ConnectionTester.run(client: live.session.client, namespace: "shop")
        #expect(result.version != nil, "connection failed: \(String(describing: result.error))")
        #expect(result.error == nil)
        #expect((result.nodeCount ?? 0) >= 1)
    }

    @Test func aClusterWhoseHostIsNotAllowedIsNeverReached() async throws {
        let blocked = ClusterConfig(name: "elsewhere", server: URL(string: "https://203.0.113.9:6443")!, environment: .production)
        let client = ClusterRegistry.defaultClientFactory(MacAppEnvironment.gatedConfig(blocked, gate: .current), ClusterSecrets(token: "x"))
        await #expect(throws: (any Error).self) { _ = try await client.version() }
    }

    @Test func podsListAndWatchOnShopAndBatch() async throws {
        let live = try connect()
        for ns in ["shop", "batch"] {
            let store = live.session.unstructuredStore(kind: .pod, namespace: ns)
            let task = Task { await store.run() }
            for _ in 0..<150 where store.phase != .loaded { try await Task.sleep(for: .milliseconds(100)) }
            #expect(store.phase == .loaded)
            #expect(store.consumerCount == 1)
            #expect(!store.items.isEmpty, "no pods in \(ns)")
            task.cancel()
            _ = await task.value
            #expect(store.consumerCount == 0)
        }
    }

    @Test func discoveryAndTheRulesReviewDriveTheSidebar() async throws {
        let live = try connect()
        let provider = RegistrySidebarProvider(registry: live.registry)
        let model = SidebarModel(provider: provider, features: { FeatureRegistry.enabled })
        model.expand(cluster: live.config.id)
        for _ in 0..<150 where model.discovery[live.config.id] == nil || model.rules[live.config.id] == nil { try await Task.sleep(for: .milliseconds(100)) }
        let cluster = try #require(model.rows.first { $0.role == .cluster })
        let kinds = cluster.children.flatMap { [$0] + $0.children }.map(\.title)
        for expected in ["Overview", "Workloads", "Pods", "Deployments", "Config", "ConfigMaps", "Network", "Services", "Storage", "Namespaces", "Events", "Access Control", "Custom Resources", "Chart Room", "Survey"] {
            #expect(kinds.contains(expected), "\(expected) missing from \(kinds)")
        }
        // The admin context may list everything: nothing is hidden, and the review parsed.
        #expect(model.rules[live.config.id] != nil)
        #expect(model.rules[live.config.id]?.allowsList(.pod) == true)
        // Opening the cluster started no store: the sidebar only looks.
        #expect(live.session.existingUnstructuredStore(kind: .pod, namespace: "shop") == nil)
        #expect(live.session.existingUnstructuredStore(kind: .pod, namespace: nil) == nil)
    }

    @Test func aRunningStoreFeedsTheBadgesAndNothingElseDoes() async throws {
        let live = try connect()
        let model = SidebarModel(provider: RegistrySidebarProvider(registry: live.registry), features: { [] })
        model.expand(cluster: live.config.id)
        for _ in 0..<150 where model.discovery[live.config.id] == nil { try await Task.sleep(for: .milliseconds(100)) }
        live.registry.setNamespace("shop", for: live.config.id)
        model.refreshBadges(now: Date(timeIntervalSince1970: 10))
        let podsRow = try #require(model.rowID(for: .kind(live.config.id, .pod)))
        #expect(model.counts[podsRow] == nil)                                       // nothing runs: no count
        let store = live.session.unstructuredStore(kind: .pod, namespace: "shop")
        let task = Task { await store.run() }
        for _ in 0..<150 where store.phase != .loaded { try await Task.sleep(for: .milliseconds(100)) }
        model.refreshBadges(now: Date(timeIntervalSince1970: 20))
        #expect((model.counts[podsRow] ?? 0) >= 1)
        // `shop` has crash-looping pods: the badge is red.
        #expect(model.badges[podsRow]?.severity == .critical || model.badges[podsRow]?.severity == .warning)
        task.cancel(); _ = await task.value
    }

    @Test func logsStreamIntoACappedBuffer() async throws {
        let live = try connect()
        let pods = try await live.session.client.list(Pod.self, kind: .pod, namespace: "shop", options: ListOptions())
        let pod = try #require(pods.items.first { $0.metadata.name.hasPrefix("web-") && ($0.status?.phase == "Running") })
        let stream = LogStream(capacity: 20_000, limits: .desktop)
        stream.start(client: live.session.client, namespace: "shop", pod: pod.metadata.name, containers: [nil],
                     options: LogOptions(follow: false, timestamps: true, tailLines: 200), scope: live.config.id)
        for _ in 0..<100 where stream.state != .finished && stream.state != .streaming { try await Task.sleep(for: .milliseconds(100)) }
        try await Task.sleep(for: .milliseconds(800))
        #expect(stream.count > 0)
        #expect(stream.buffer.byteCount <= LogLimits.desktop.maxBufferBytes)
        stream.stop(to: .idle)
    }

    @Test func dryRunValidatesWithoutCreatingAndReadOnlyRefuses() async throws {
        let live = try connect()
        let body: JSONValue = ["apiVersion": "v1", "kind": "ConfigMap", "metadata": ["name": "wh-dryrun-check", "namespace": "shop"], "data": ["k": "v"]]
        let created = try await live.session.client.create(.configMap, namespace: "shop", name: nil, subresource: nil, body: body, options: MutationOptions(dryRun: true))
        #expect(created.value(at: "metadata.name")?.stringValue == "wh-dryrun-check")
        await #expect(throws: KubeError.self) { _ = try await live.session.client.get(ConfigMap.self, kind: .configMap, name: "wh-dryrun-check", namespace: "shop") }
        // The same call on a read-only import is refused before any request is made, even as a dry run.
        let ro = try connect(readOnly: true)
        await #expect(throws: KubeError.readOnly) {
            _ = try await ro.session.client.create(.configMap, namespace: "shop", name: nil, subresource: nil, body: body, options: MutationOptions(dryRun: true))
        }
    }

    @Test func productionClustersRequireTypedConfirmation() throws {
        let prod = try connect(environment: .production)
        #expect(MutationPolicy.decide(.mutation(dryRun: false), cluster: prod.config, origin: nil) == .confirm(requiresTyping: true))
        let dev = try connect(environment: .development)
        #expect(MutationPolicy.decide(.mutation(dryRun: false), cluster: dev.config, origin: nil) == .confirm(requiresTyping: false))
    }

    // MARK: Pod shell with a real terminal emulator

    /// Runs keystrokes in `wh-term-test` with a TTY and returns what the surface showed just before the last step (full-screen programs
    /// leave the alternate screen when they quit, so the interesting frame is the one before the quit key).
    private func shell(_ surface: SwiftTermSurface, live: Live, script: [(delay: Duration, keys: String)], cols: Int = 120, rows: Int = 40) async throws -> String {
        let session = ExecSession(client: live.session.client, namespace: "shop", pod: "wh-term-test", options: ExecOptions(command: ["/bin/sh"], tty: true, stdin: true))
        try await session.start(cols: cols, rows: rows)
        let reader = Task { @MainActor in
            for await event in session.events { if case .output(let data) = event { surface.feed(data) } }
        }
        var beforeLast = ""
        for (i, step) in script.enumerated() {
            try await Task.sleep(for: step.delay)
            if i == script.count - 1 { beforeLast = surface.allText() }
            session.send(Data(step.keys.utf8))
        }
        try await Task.sleep(for: .seconds(1))
        session.send(Data("exit\n".utf8))
        try await Task.sleep(for: .milliseconds(300))
        reader.cancel()
        await session.close()
        return beforeLast
    }

    @Test func vimRendersInThePodShell() async throws {
        let live = try connect()
        let surface = SwiftTermSurface(scrollback: 5_000)
        surface.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let frame = try await shell(surface, live: live, script: [(.seconds(1), "export TERM=xterm-256color; stty rows 40 cols 120\n"), (.seconds(1), "vim /tmp/wh-notes.txt\n"),
                                                                (.seconds(2), "ihello from wheelhouse\u{1b}"), (.seconds(1), ":q!\n")])
        #expect(frame.contains("hello from wheelhouse"), "vim did not render: \(frame.suffix(600))")
        #expect(frame.contains("~"))
        #expect(frame.contains("1,21"))                           // vim's ruler after typing 21 characters: cursor addressing works
    }

    @Test func htopRendersInThePodShell() async throws {
        let live = try connect()
        let surface = SwiftTermSurface(scrollback: 5_000)
        surface.view.frame = NSRect(x: 0, y: 0, width: 1_000, height: 700)
        let frame = try await shell(surface, live: live, script: [(.seconds(1), "export TERM=xterm-256color; stty rows 40 cols 120\n"), (.seconds(1), "htop\n"), (.seconds(3), "q")])
        #expect(frame.contains("PID") && frame.contains("Command"), "htop did not render: \(frame.suffix(600))")
        #expect(frame.contains("Mem") || frame.contains("Tasks"))
    }

    // MARK: Port forward

    @Test func portForwardReachesAPodThroughALocalListener() async throws {
        let live = try connect()
        // `wh-http-test` in `shop` serves one file on 8081 (busybox httpd as the pod's main process).
        let manager = PortForwardManager()
        let info = try await manager.start(clusterID: live.config.id, clusterName: live.config.name, client: live.session.client,
                                           target: PortForwardTarget(kind: .pod, namespace: "shop", name: "wh-http-test", remotePort: 8081), localPort: 0)
        #expect(info.localPort > 1024)
        let url = try #require(info.url)
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(data: data, encoding: .utf8)?.contains("wheelhouse-forward-ok") == true)
        await manager.stopAll()
    }
}
