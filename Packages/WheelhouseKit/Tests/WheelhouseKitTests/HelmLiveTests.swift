#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseKit

/// Live checks against the TEST cluster only (ARCHITECTURE-MAC §13.3). Seed first: `scripts/testcluster-fixtures.sh --section m6a-helm`.
///
///   WH_LIVE_TESTS=1 WH_TEST_KUBECONFIG=<repo>/.testcluster/kubeconfig swift test --filter HelmLive
///
/// The harness refuses to run unless the kubeconfig resolves to `<repo>/.testcluster/kubeconfig`, the context is exactly
/// `wheelhouse-test`, and the server host equals `.testcluster/server-host`. It never reads `~/.kube` or `.secrets/`.
@Suite("Helm live (test cluster only)", .serialized, .enabled(if: ProcessInfo.processInfo.environment["WH_LIVE_TESTS"] == "1"))
struct HelmLiveTests {
    struct Harness {
        var client: LiveKubeClient
        var config: ClusterConfig
        var secrets: ClusterSecrets
        var repoRoot: URL
    }

    static func harness() throws -> Harness {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { root.deleteLastPathComponent() }                      // .../Packages/WheelhouseKit/Tests/WheelhouseKitTests/X.swift
        let env = ProcessInfo.processInfo.environment
        let given = try #require(env["WH_TEST_KUBECONFIG"], "WH_TEST_KUBECONFIG is not set")
        let expected = root.appending(path: ".testcluster/kubeconfig")
        func real(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }
        try #require(real(URL(fileURLWithPath: given)) == real(expected), "WH_TEST_KUBECONFIG must be <repo>/.testcluster/kubeconfig")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["kubectl", "--kubeconfig", given, "--context", "wheelhouse-test", "config", "view", "--raw", "--minify", "--flatten"]
        process.environment = ["PATH": env["PATH"] ?? "/usr/bin:/usr/local/bin:/opt/homebrew/bin", "KUBECACHEDIR": root.appending(path: ".testcluster/kubectl-cache").path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = try #require(String(data: data, encoding: .utf8))
        let parsed = try KubeconfigParser.parse(text)
        let context = try #require(parsed.contexts.first { $0.name == "wheelhouse-test" }, "context wheelhouse-test not found")
        let recorded = try String(contentsOf: root.appending(path: ".testcluster/server-host"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(context.server?.host == recorded, "server host differs from .testcluster/server-host")
        var made = try #require(context.makeClusterConfig())
        // A client certificate needs the keychain, which a command-line test process cannot use (-34018): authenticate with the
        // test cluster's own admin token (`.testcluster/admin.token`, git-ignored) and keep the CA from the kubeconfig.
        let tokenURL = root.appending(path: ".testcluster/admin.token")
        if let token = try? String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            made.secrets = ClusterSecrets(token: token, caPEM: made.secrets.caPEM)
        }
        return Harness(client: LiveKubeClient(config: made.config, secrets: made.secrets, tlsServerName: context.tlsServerName),
                       config: made.config, secrets: made.secrets, repoRoot: root)
    }

    @Test func helm3AndHelm4StyleReleasesListAndDecode() async throws {
        let h = try Self.harness()
        let listing = try await HelmReleaseCatalog.load(client: h.client, namespace: "wh-m6a")
        #expect(listing.failure == nil && listing.storage == .secret)
        let byName = Dictionary(uniqueKeysWithValues: listing.releases.map { ($0.name, $0) })
        #expect(Set(byName.keys) == ["wh-fixture", "wh-failed", "wh-helm4"])
        #expect(byName["wh-failed"]?.current.status == .failed)
        #expect(listing.releases.first?.name == "wh-failed", "problems are pinned on top")
        let fixture = try #require(byName["wh-fixture"])
        #expect(fixture.current.revision == 2 && fixture.history.map(\.revision) == [2, 1])

        let reader = HelmReleaseReader(client: h.client, cluster: h.config.id, cache: DecodedReleaseCache())
        let v2 = try await reader.read(fixture.current)
        #expect(v2.chart.metadata.version == "0.2.0" && v2.hooks.count == 1 && v2.info.status == .deployed)
        #expect(v2.config.value(at: "auth.password")?.stringValue == "fixture-password-2")
        let v1 = try await reader.read(fixture.history[1])
        #expect(v1.chart.metadata.version == "0.1.0" && v1.version == 1)
        let helm4 = try await reader.read(try #require(byName["wh-helm4"]).current)
        #expect(helm4.extra["future_field"] != nil)
    }

    @Test func configMapDriverFallsBackWhenSecretsAreEmpty() async throws {
        let h = try Self.harness()
        let listing = try await HelmReleaseCatalog.load(client: h.client, namespace: "wh-m6a-cm")
        #expect(listing.storage == .configMap && listing.releases.map(\.name) == ["wh-cm"])
        let reader = HelmReleaseReader(client: h.client, cluster: h.config.id, cache: DecodedReleaseCache())
        let release = try await reader.read(try #require(listing.releases.first).current)
        #expect(release.name == "wh-cm" && release.info.status == .deployed)
    }

    @Test func twoHundredReleasesLoadInUnderASecondFromMetadata() async throws {
        let h = try Self.harness()
        let clock = ContinuousClock()
        var times: [Duration] = []
        var count = 0
        for _ in 0..<3 {                                      // the first call also pays the TLS handshake
            let start = clock.now
            let listing = try await HelmReleaseCatalog.load(client: h.client, namespace: "wh-m6a-many")
            times.append(clock.now - start)
            count = listing.releases.count
        }
        print("HELM-LIVE 200 releases: cold \(times[0]), warm \(times[1...])")
        #expect(count == 200)
        let raw = try await h.client.listMetadata(kind: .secret, namespace: "wh-m6a-many", labelSelector: "owner=helm", limit: 1)
        #expect(raw.items.first?.annotations["kubectl.kubernetes.io/last-applied-configuration"] == nil, "records are created, not applied")
        #expect(times.allSatisfy { $0 < .seconds(1) })
    }

    @Test func aSubjectWithoutRBACSeesTheForbiddenState() async throws {
        let h = try Self.harness()
        let tokenFile = h.repoRoot.appending(path: ".testcluster/m6a-nobody.token")
        let token = try String(contentsOf: tokenFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let nobody = LiveKubeClient(config: h.config, secrets: ClusterSecrets(token: token, caPEM: h.secrets.caPEM))
        let listing = try await HelmReleaseCatalog.load(client: nobody, namespace: "wh-m6a")
        #expect(listing.failure == .forbidden(namespace: "wh-m6a") && listing.releases.isEmpty)
    }

    @Test func driftIsDetectedAndClearsAgain() async throws {
        let h = try Self.harness()
        let reader = HelmReleaseReader(client: h.client, cluster: h.config.id, cache: DecodedReleaseCache())
        let listing = try await HelmReleaseCatalog.load(client: h.client, namespace: "wh-m6a")
        let current = try #require(listing.releases.first { $0.name == "wh-fixture" }).current
        let release = try await reader.read(current)
        let discovery = try await h.client.discovery()

        let clean = await HelmDrift.check(manifest: release.manifest, releaseNamespace: "wh-m6a", client: h.client, discovery: discovery)
        #expect(clean.objects.count == 2 && !clean.hasDrift, "\(clean.objects.map { "\($0.object.id) \($0.state)" })")

        let patch = KubePatch.merge(["data": ["replicas": "9"]])
        _ = try await h.client.patch(.configMap, name: "wh-fixture-config", namespace: "wh-m6a", patch: patch)
        let drifted = await HelmDrift.check(manifest: release.manifest, releaseNamespace: "wh-m6a", client: h.client, discovery: discovery)
        #expect(drifted.driftCount == 1)
        #expect(drifted.objects.first { $0.state.isDrift }?.state == .drifted(paths: ["data.replicas"]))

        _ = try await h.client.patch(.configMap, name: "wh-fixture-config", namespace: "wh-m6a", patch: .merge(["data": ["replicas": "2"]]))
        let healed = await HelmDrift.check(manifest: release.manifest, releaseNamespace: "wh-m6a", client: h.client, discovery: discovery)
        #expect(!healed.hasDrift)
    }
}
#endif
