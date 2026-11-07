import Foundation
import Testing
@testable import WheelhouseKit

/// Tides patches against the CRD fixtures (ARCHITECTURE-MAC section 13.3). TEST CLUSTER ONLY.
///
/// Gated by `WH_LIVE_TESTS=1`. It refuses to run unless `WH_TEST_KUBECONFIG` resolves to a kubeconfig file in `<repo>/.testcluster/`, the
/// context is `wheelhouse-test` and the server host matches `.testcluster/server-host`. It never reads `~/.kube` or `.secrets/`.
/// Seed first:  scripts/testcluster-fixtures.sh --section m9-gitops   (namespace wh-m9, Flux and Argo CD CRDs, no controllers)
///
///     WH_LIVE_TESTS=1 WH_TEST_KUBECONFIG=$PWD/.testcluster/kubeconfig-embedded.yaml swift test --filter GitOpsLive
@Suite("GitOps live (test cluster)", .serialized, .enabled(if: GitOpsLive.enabled))
struct GitOpsLiveTests {
    private func client() throws -> LiveKubeClient {
        let (url, repo) = try #require(GitOpsLive.kubeconfig())
        let text = try String(contentsOf: url, encoding: .utf8)
        let cfg = try KubeconfigParser.parse(text)
        let ctx = try #require(cfg.contexts.first { $0.name == "wheelhouse-test" })
        var made = try #require(ctx.makeClusterConfig())
        // `swift test` has no keychain entitlement for a client certificate: use the test cluster's own admin token instead.
        let token = try String(contentsOf: repo.appendingPathComponent(".testcluster/admin.token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        made.config.authKind = .token
        made.secrets = ClusterSecrets(token: token, caPEM: made.secrets.caPEM)
        let recorded = try String(contentsOf: repo.appendingPathComponent(".testcluster/server-host"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        try #require(made.config.server.host == recorded, "server host differs from .testcluster/server-host")
        return LiveKubeClient(config: made.config, secrets: made.secrets, tlsServerName: ctx.tlsServerName)
    }

    private func apps(_ client: LiveKubeClient) async throws -> (GitOpsDetection, [GitOpsApp]) {
        let detection = GitOpsDetection.detect(try await client.discovery())
        var out: [GitOpsApp] = []
        for kind in detection.appKinds + detection.fluxSources {
            let list = try await client.listRaw(kind, namespace: "wh-m9", options: ListOptions())
            for item in list["items"]?.arrayValue ?? [] { if let a = GitOpsApp(raw: item, kind: kind) { out.append(a) } }
        }
        return (detection, out)
    }

    private func fetch(_ c: LiveKubeClient, _ d: GitOpsDetection, _ name: String, _ kind: ResourceKind) async throws -> GitOpsApp {
        let raw = try await c.getRaw(kind, name: name, namespace: "wh-m9")
        return try #require(GitOpsApp(raw: raw, kind: kind))
    }

    /// Puts the fixtures back (idempotent): no annotations of ours, nothing suspended that was not, no queued Argo operation.
    private func restore(_ c: LiveKubeClient, _ d: GitOpsDetection) async throws {
        let strip: KubePatch = .merge(["metadata": ["annotations": [GitOpsActions.requestedAtKey: .null, GitOpsActions.forceAtKey: .null,
                                                                    GitOpsActions.resetAtKey: .null, GitOpsActions.argoRefreshKey: .null]]])
        for (kind, name) in [(d.kustomizations, "apps"), (d.kustomizations, "infra"), (d.helmReleases, "podinfo"), (d.helmReleases, "stuck"),
                             (d.gitRepositories, "fleet"), (d.applications, "checkout"), (d.applications, "catalog")] {
            if let kind { _ = try await c.patch(kind, name: name, namespace: "wh-m9", patch: strip) }
        }
        if let k = d.kustomizations { _ = try await c.patch(k, name: "infra", namespace: "wh-m9", patch: GitOpsActions.fluxSuspend(false)) }
        if let a = d.applications {
            _ = try await c.patch(a, name: "checkout", namespace: "wh-m9", patch: .merge(["operation": .null]))
            _ = try await c.patch(a, name: "checkout", namespace: "wh-m9", patch: GitOpsActions.argoAutoSync(enabled: false))
            _ = try await c.patch(a, name: "syncing", namespace: "wh-m9", patch: .merge(["status": ["operationState": ["phase": "Running"]]]))
        }
    }

    @Test func detectsTheFixtureCRDsAndReadsEveryObject() async throws {
        let c = try client()
        let (d, list) = try await apps(c)
        #expect(d.hasFlux && d.hasArgo && d.kustomizations?.version == "v1" && d.helmReleases?.version == "v2" && d.applications?.version == "v1alpha1")
        let byName = Dictionary(uniqueKeysWithValues: list.map { ("\($0.flavor.rawValue)/\($0.name)", $0) })
        #expect(byName["fluxKustomization/apps"]?.health == .healthy)
        #expect(byName["fluxKustomization/broken"]?.health == .degraded)
        #expect(byName["fluxKustomization/paused"]?.health == .suspended)
        #expect(byName["fluxHelmRelease/stuck"]?.isProblem == true)
        #expect(byName["argoApplication/checkout"]?.sync == .outOfSync)
        #expect(byName["argoApplication/catalog"]?.health == .healthy)
        #expect(ArgoView(raw: byName["argoApplication/checkout"]!.raw).pruneCandidates.count == 2)
        #expect(list.filter(\.flavor.isSource).count == 2)
    }

    @Test func ownershipOfFixtureObjects() async throws {
        let c = try client()
        let detector = GitOpsOwnershipDetector()
        let flux = try await c.getRaw(.configMap, name: "owned-by-flux", namespace: "wh-m9")
        #expect(await detector.owner(of: flux, cluster: "t") == GitOpsOwner(tool: .flux, name: "apps", namespace: "wh-m9"))
        let argo = try await c.getRaw(.configMap, name: "owned-by-argo", namespace: "wh-m9")
        #expect(await detector.owner(of: argo, cluster: "t") == GitOpsOwner(tool: .argoCD, name: "checkout"))
        let plain = try await c.getRaw(.configMap, name: "unmanaged", namespace: "wh-m9")
        #expect(await detector.owner(of: plain, cluster: "t") == nil)
    }

    @Test func fluxPatchesSucceedAndLand() async throws {
        let c = try client()
        let (d, _) = try await apps(c)
        try await restore(c, d)

        let apps = try await fetch(c, d, "apps", d.kustomizations!)
        let reconcile = try GitOpsPlanner.plan(.fluxReconcile, app: apps)
        try await reconcile.dryRun(client: c)
        // The dry-run changed nothing.
        #expect(try await c.getRaw(d.kustomizations!, name: "apps", namespace: "wh-m9").value(at: "metadata.annotations")?[GitOpsActions.requestedAtKey] == nil)
        try await reconcile.execute(client: c)
        let after = try await c.getRaw(d.kustomizations!, name: "apps", namespace: "wh-m9")
        #expect(after.value(at: "metadata.annotations")?[GitOpsActions.requestedAtKey]?.stringValue == reconcile.token)

        // Suspend then resume (resume is the inverse the Undo toast offers).
        let infra = try await fetch(c, d, "infra", d.kustomizations!)
        let suspend = try GitOpsPlanner.plan(.fluxSuspend, app: infra)
        try await suspend.dryRun(client: c)
        try await suspend.execute(client: c)
        let suspended = try await fetch(c, d, "infra", d.kustomizations!)
        #expect(suspended.suspended)
        let resume = try GitOpsPlanner.plan(.fluxResume, app: suspended)
        try await resume.dryRun(client: c)
        try await resume.execute(client: c)
        #expect(try await fetch(c, d, "infra", d.kustomizations!).suspended == false)

        // Force and Reset on HelmReleases set both annotations to the same value.
        let podinfo = try await fetch(c, d, "podinfo", d.helmReleases!)
        let force = try GitOpsPlanner.plan(.fluxForce, app: podinfo)
        try await force.dryRun(client: c)
        try await force.execute(client: c)
        let forced = try await c.getRaw(d.helmReleases!, name: "podinfo", namespace: "wh-m9").value(at: "metadata.annotations")
        #expect(forced?[GitOpsActions.requestedAtKey]?.stringValue == forced?[GitOpsActions.forceAtKey]?.stringValue)
        #expect(forced?[GitOpsActions.forceAtKey]?.stringValue == force.token)
        let stuck = try await fetch(c, d, "stuck", d.helmReleases!)
        let reset = try GitOpsPlanner.plan(.fluxReset, app: stuck)
        try await reset.dryRun(client: c)
        try await reset.execute(client: c)
        #expect(try await c.getRaw(d.helmReleases!, name: "stuck", namespace: "wh-m9").value(at: "metadata.annotations")?[GitOpsActions.resetAtKey]?.stringValue == reset.token)

        // Reconcile with Source: the source is annotated first, then the Kustomization (no controller here, so a short wait).
        let withSource = try GitOpsPlanner.plan(.fluxReconcileWithSource, app: try await fetch(c, d, "apps", d.kustomizations!), detection: d)
        try await withSource.dryRun(client: c)
        try await withSource.execute(client: c, sourceWait: .seconds(2), poll: .milliseconds(500))
        let src = try await c.getRaw(d.gitRepositories!, name: "fleet", namespace: "wh-m9").value(at: "metadata.annotations")
        #expect(src?[GitOpsActions.requestedAtKey]?.stringValue == withSource.token)
        #expect(try await c.getRaw(d.kustomizations!, name: "apps", namespace: "wh-m9").value(at: "metadata.annotations")?[GitOpsActions.requestedAtKey]?.stringValue == withSource.token)
        try await restore(c, d)
    }

    @Test func argoPatchesSucceedAndLand() async throws {
        let c = try client()
        let (d, _) = try await apps(c)
        try await restore(c, d)
        let kind = try #require(d.applications)

        let checkout = try await fetch(c, d, "checkout", kind)
        for hard in [GitOpsActionPlan.Kind.argoRefresh, .argoHardRefresh] {
            let plan = try GitOpsPlanner.plan(hard, app: checkout)
            try await plan.dryRun(client: c)
            try await plan.execute(client: c)
            let value = try await c.getRaw(kind, name: "checkout", namespace: "wh-m9").value(at: "metadata.annotations")?[GitOpsActions.argoRefreshKey]?.stringValue
            #expect(value == (hard == .argoHardRefresh ? "hard" : "normal"))
        }

        // Auto-sync on and off.
        let enable = try GitOpsPlanner.plan(.argoEnableAutoSync, app: checkout, sync: ArgoSyncRequest(prune: true))
        try await enable.dryRun(client: c)
        try await enable.execute(client: c)
        #expect(ArgoView(raw: try await c.getRaw(kind, name: "checkout", namespace: "wh-m9")).autoSyncEnabled)
        let disable = try GitOpsPlanner.plan(.argoDisableAutoSync, app: try await fetch(c, d, "checkout", kind))
        try await disable.execute(client: c)
        #expect(!ArgoView(raw: try await c.getRaw(kind, name: "checkout", namespace: "wh-m9")).autoSyncEnabled)

        // Sync with prune: the plan lists the two prune candidates; the operation lands on the Application.
        let sync = try GitOpsPlanner.plan(.argoSync, app: try await fetch(c, d, "checkout", kind), sync: ArgoSyncRequest(revision: "main", prune: true))
        #expect(sync.pruneList.map(\.name).sorted() == ["legacy-flags", "old-config"])
        try await sync.dryRun(client: c)
        #expect(try await c.getRaw(kind, name: "checkout", namespace: "wh-m9")["operation"] == nil)     // dry-run wrote nothing
        try await sync.execute(client: c)
        let queued = try await c.getRaw(kind, name: "checkout", namespace: "wh-m9")
        #expect(queued.value(at: "operation.sync.prune")?.boolValue == true)
        #expect(queued.value(at: "operation.sync.revision")?.stringValue == "main")
        #expect(queued.value(at: "operation.initiatedBy.username")?.stringValue == "wheelhouse")
        // A second sync is refused while the first is queued.
        #expect(throws: GitOpsActionError.operationPending) { try GitOpsPlanner.plan(.argoSync, app: GitOpsApp(raw: queued, kind: kind)!) }

        // Roll back is refused while an operation is pending and works from a clean Application.
        _ = try await c.patch(kind, name: "checkout", namespace: "wh-m9", patch: .merge(["operation": .null]))
        let rollback = try GitOpsPlanner.plan(.argoRollback, app: try await fetch(c, d, "checkout", kind), historyID: 3)
        try await rollback.dryRun(client: c)
        try await rollback.execute(client: c)
        #expect(try await c.getRaw(kind, name: "checkout", namespace: "wh-m9").value(at: "operation.sync.revision")?.stringValue == "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")

        // Terminate the running sync of `syncing`; a sync of it is refused.
        let running = try await fetch(c, d, "syncing", kind)
        #expect(throws: GitOpsActionError.syncAlreadyRunning) { try GitOpsPlanner.plan(.argoSync, app: running) }
        let terminate = try GitOpsPlanner.plan(.argoTerminate, app: running)
        try await terminate.dryRun(client: c)
        try await terminate.execute(client: c)
        #expect(ArgoView(raw: try await c.getRaw(kind, name: "syncing", namespace: "wh-m9")).operationState?.phase == "Terminating")
        try await restore(c, d)
    }

    /// R18: what the API server's service proxy forwards to the target. Cookie arrives; the API server consumes Authorization.
    @Test func serviceProxyForwardsTheCookieButNotAuthorization() async throws {
        let c = try client()
        let r = try await c.proxyRequest(method: "GET", namespace: "wh-m9", service: "echo", port: "8080", path: "/api/v1/probe", query: ["x": "1"],
                                         headers: ["Cookie": "argocd.token=live-test-token", "Authorization": "Bearer should-not-arrive"], body: nil)
        #expect(r.statusCode == 200)
        let echoed = String(data: r.body, encoding: .utf8) ?? ""
        #expect(echoed.contains("GET /api/v1/probe?x=1"))
        #expect(echoed.contains("Cookie: argocd.token=live-test-token"))
        #expect(!echoed.contains("should-not-arrive"))
        #expect(!echoed.lowercased().contains("authorization:"))
        // Non-2xx from the target (or the proxy) comes back as a status, not a throw.
        let missing = try await c.proxyRequest(method: "GET", namespace: "wh-m9", service: "nosuch", port: "1", path: "x", query: [:], headers: [:], body: nil)
        #expect(missing.statusCode >= 400)
    }
}

enum GitOpsLive {
    /// The test kubeconfig and the repository root, only when every precondition of the live harness holds.
    static func kubeconfig() -> (URL, URL)? {
        let env = ProcessInfo.processInfo.environment
        guard env["WH_LIVE_TESTS"] == "1", let path = env["WH_TEST_KUBECONFIG"] else { return nil }
        // <repo>/Packages/WheelhouseKit/Tests/WheelhouseKitTests/GitOpsLiveTests.swift
        var repo = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { repo.deleteLastPathComponent() }
        // The kubeconfig of the test cluster, or its variant with embedded credentials (the Kit parser reads no file references).
        let allowed = ["kubeconfig", "kubeconfig-embedded.yaml", "kubeconfig-pkcs8.yaml"].map {
            repo.appendingPathComponent(".testcluster/\($0)").resolvingSymlinksInPath().path
        }
        let given = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        guard allowed.contains(given), FileManager.default.fileExists(atPath: given) else { return nil }
        return (URL(fileURLWithPath: given), repo)
    }

    static var enabled: Bool { kubeconfig() != nil }
}
