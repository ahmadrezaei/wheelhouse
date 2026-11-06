import Testing
import Foundation
@testable import WheelhouseKit
@testable import WheelhouseUI

// MARK: - Deep links (H4, L12)

@Suite struct DeepLinkTests {
    private func link(_ s: String) -> DeepLink? { URL(string: s).flatMap(DeepLink.init(url:)) }

    @Test func podLink() throws {
        let l = try #require(link("wheelhouse://cluster/demo-prod-eu-west/ns/shop/pods/web-1?view=logs&container=app&previous=1"))
        #expect(l.clusterID == "demo-prod-eu-west")
        #expect(l.namespace == "shop")
        #expect(l.resourceRef?.name == "web-1")
        #expect(l.view == "logs" && l.container == "app" && l.previous)
    }

    @Test func shellViewIsNeverHonoured() throws {
        let l = try #require(link("wheelhouse://cluster/c1/ns/shop/pods/web-1?view=shell"))
        #expect(l.view == nil)
        #expect(DeepLink.allowedViews == ["logs", "yaml"])
    }

    @Test func invalidNamesAreRejected() {
        #expect(link("wheelhouse://cluster/c1/ns/Shop/pods/web-1") == nil)         // uppercase namespace
        #expect(link("wheelhouse://cluster/c1/ns/shop/pods/web%2F..%2Fx") == nil)  // encoded slash in name
        #expect(link("wheelhouse://cluster/c1/ns/shop/pods/-bad") == nil)
        #expect(link("wheelhouse://cluster/c1/ns/sh%20op/pods/web") == nil)
        #expect(link("wheelhouse://cluster/c1/ns/shop/pods/web/extra") == nil)
    }

    @Test func containerIsValidated() throws {
        let l = try #require(link("wheelhouse://cluster/c1/ns/shop/pods/web-1?view=logs&container=Bad%20Name"))
        #expect(l.container == nil)
    }

    @Test func nameRules() {
        #expect(KubeNames.isDNSLabel("kube-system"))
        #expect(!KubeNames.isDNSLabel("kube.system"))
        #expect(!KubeNames.isDNSLabel(String(repeating: "a", count: 64)))
        #expect(KubeNames.isObjectName("web-1.cluster.local"))
        #expect(KubeNames.isObjectName("system:node"))
        #expect(!KubeNames.isObjectName("Web"))
        #expect(!KubeNames.isObjectName(""))
    }

    @Test func clusterLinkAndSections() throws {
        let l = try #require(link("wheelhouse://cluster/c1"))
        #expect(l.resourceRef == nil)
    }
}

// MARK: - Confirmation gate (C1, M6)

@Suite @MainActor struct ConfirmGateTests {
    private func config(_ env: ClusterEnvironment, readOnly: Bool = false) -> ClusterConfig {
        ClusterConfig(name: "c", server: URL(string: "https://example.test")!, environment: env, readOnly: readOnly)
    }
    private func request(_ cluster: ClusterConfig, disruptive: Bool) -> ConfirmRequest {
        ConfirmRequest(title: "t", message: "m", verb: "Go", cluster: cluster, resource: "deployment/x", confirmationText: "x", isDisruptive: disruptive, action: {})
    }

    @Test func productionAlwaysRequiresTyping() {
        let prod = config(.production)
        #expect(request(prod, disruptive: false).requiresTyping)   // scale up, uncordon, resume, trigger...
        #expect(request(prod, disruptive: true).requiresTyping)
        #expect(!request(config(.development), disruptive: true).requiresTyping)
    }

    @Test func liveConfigOverridesSnapshot() {
        let snapshot = config(.development)
        var live = snapshot
        live.environment = .production
        let r = request(snapshot, disruptive: false)
        #expect(!r.requiresTyping)
        #expect(r.requiresTyping(for: live))
    }

    @Test func refusesWhenLiveConfigBecomesReadOnlyOrGone() {
        let snapshot = config(.staging)
        var live = snapshot
        live.readOnly = true
        let r = request(snapshot, disruptive: true)
        #expect(r.refusal(live: snapshot) == nil)
        #expect(r.refusal(live: live) != nil)
        #expect(r.refusal(live: nil) != nil)
    }
}

// MARK: - Rollback (M4)

@Suite struct RollbackPatchTests {
    private func rs(_ name: String, rev: String, image: String, extra: [String: JSONValue] = [:]) -> Unstructured {
        var ann: [String: JSONValue] = ["deployment.kubernetes.io/revision": .string(rev), "deployment.kubernetes.io/desired-replicas": "3"]
        for (k, v) in extra { ann[k] = v }
        return Unstructured(raw: ["metadata": ["name": .string(name), "annotations": .object(ann), "ownerReferences": [["kind": "Deployment", "name": "web", "uid": "d1"]]],
                                  "spec": ["template": ["metadata": ["labels": ["app": "web", "pod-template-hash": "x"]], "spec": ["containers": [["name": "web", "image": .string(image)]]]]]])
    }
    private func deployment(image: String, paused: Bool = false) -> Unstructured {
        Unstructured(raw: ["metadata": ["name": "web", "uid": "d1", "annotations": ["deployment.kubernetes.io/revision": "2", "deployment.kubernetes.io/revision-history": "1",
                                                                                      "kubectl.kubernetes.io/last-applied-configuration": "{}", "team": "x"]],
                           "spec": ["paused": .bool(paused), "template": ["metadata": ["labels": ["app": "web"]], "spec": ["containers": [["name": "web", "image": .string(image)]]]]]])
    }

    @Test func patchReplacesTemplateAndAnnotations() throws {
        let dep = deployment(image: "web:2")
        let revs = RolloutHistory.revisions(deployment: dep, replicaSets: [rs("a", rev: "1", image: "web:1", extra: ["kubernetes.io/change-cause": "bump"]), rs("b", rev: "2", image: "web:2")])
        guard case .json(let ops)? = RolloutHistory.rollbackPatch(to: revs[1], deploymentAnnotations: dep.metadata.annotations) else { Issue.record("no patch"); return }
        #expect(ops.count == 2)
        #expect(ops[0]["path"]?.stringValue == "/spec/template")
        #expect(ops[0].value(at: "value.metadata.labels")?["pod-template-hash"] == nil)
        #expect(ops[1]["path"]?.stringValue == "/metadata/annotations")
        let ann = try #require(ops[1]["value"]?.objectValue)
        #expect(ann["kubernetes.io/change-cause"]?.stringValue == "bump")             // RS annotation copied
        #expect(ann["deployment.kubernetes.io/revision"]?.stringValue == "2")          // Deployment's own bookkeeping kept
        #expect(ann["deployment.kubernetes.io/revision-history"]?.stringValue == "1")
        #expect(ann["kubectl.kubernetes.io/last-applied-configuration"]?.stringValue == "{}")
        #expect(ann["deployment.kubernetes.io/desired-replicas"] == nil)                // RS bookkeeping NOT copied
        #expect(ann["team"] == nil)                                                    // dropped like kubectl does
    }

    @Test func pausedIsBlocked() {
        #expect(RolloutHistory.rollbackBlocker(deployment: deployment(image: "web:2", paused: true)) != nil)
        #expect(RolloutHistory.rollbackBlocker(deployment: deployment(image: "web:2")) == nil)
    }

    @Test func currentTemplateIsDetected() {
        let dep = deployment(image: "web:2")
        let revs = RolloutHistory.revisions(deployment: dep, replicaSets: [rs("a", rev: "1", image: "web:1"), rs("b", rev: "2", image: "web:2")])
        #expect(RolloutHistory.matchesCurrentTemplate(revs[0], deployment: dep))
        #expect(!RolloutHistory.matchesCurrentTemplate(revs[1], deployment: dep))
    }
}

// MARK: - Secrets (M5, L8)

@Suite struct SecretRedactionTests {
    @Test func stripBlanksValuesButKeepsKeys() {
        let raw: JSONValue = ["kind": "Secret", "metadata": ["name": "s", "annotations": ["kubectl.kubernetes.io/last-applied-configuration": "{\"data\":{}}", "keep": "1"]],
                              "data": ["password": "c2VjcmV0", "user": "YWRtaW4="], "stringData": ["x": "plain"]]
        let out = SecretRedaction.strip(raw)
        #expect(out["data"]?.objectValue?.keys.sorted() == ["password", "user"])
        #expect(out["data"]?["password"]?.stringValue == "")
        #expect(out["stringData"] == nil)
        #expect(out.value(at: "metadata.annotations")?["kubectl.kubernetes.io/last-applied-configuration"] == nil)
        #expect(out.value(at: "metadata.annotations")?["keep"]?.stringValue == "1")
    }

    @Test func strippingClientRedactsListsAndRawLists() async throws {
        let cfg = try #require(DemoFleet.configs.first)
        let client = SecretStrippingClient(DemoKubeClient(config: cfg))
        let list = try await client.list(Unstructured.self, kind: .secret, namespace: nil, options: ListOptions())
        #expect(!list.items.isEmpty)
        for item in list.items {
            for (_, v) in item.raw["data"]?.objectValue ?? [:] { #expect(v.stringValue == "") }
        }
        let raw = try await client.listRaw(.secret, namespace: nil, options: ListOptions())
        for item in raw["items"]?.arrayValue ?? [] {
            for (_, v) in item["data"]?.objectValue ?? [:] { #expect(v.stringValue == "") }
        }
    }

    @Test func maskFingerprintsNonStringValues() {
        let a = SecretMasking.masked(["kind": "Secret", "data": ["k": 1]])
        let b = SecretMasking.masked(["kind": "Secret", "data": ["k": 2]])
        #expect(a["data"]?["k"]?.stringValue != b["data"]?["k"]?.stringValue)
    }
}

// MARK: - Drain (M9)

/// Minimal scripted client: only `create` (eviction), `patch` (cordon) and `list` (empty) do anything.
private struct ShellScriptedClient: KubeClientProtocol {
    var evict: @Sendable (String) throws -> Void

    func version() async throws -> KubeVersion { throw KubeError.unsupported("test") }
    func discovery() async throws -> DiscoveryInfo { throw KubeError.unsupported("test") }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { KubeList<T>(items: []) }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.notFound(message: nil) }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("test") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("test") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { AsyncThrowingStream { $0.finish() } }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue {
        try evict(name ?? "")
        return .null
    }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { .null }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { .null }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws {}
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("test") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("test") }
}

@Suite @MainActor struct DrainRunnerTests {
    private func plan(_ pods: [(String, DrainDisposition)]) -> DrainPlan {
        DrainPlan(node: "n1", pods: pods.map { DrainPodPlan(namespace: "shop", name: $0.0, uid: nil, disposition: $0.1, usesEmptyDir: false, controller: "ReplicaSet/x", blockingBudgets: []) })
    }
    private func finish(_ runner: DrainRunner, seconds: Double = 8) async {
        let deadline = Date().addingTimeInterval(seconds)
        while runner.phase.isRunning || runner.phase == .idle, Date() < deadline { try? await Task.sleep(for: .milliseconds(50)) }
    }
    private func tooMany() -> KubeError { .server(Status(status: "Failure", message: "pdb", reason: "TooManyRequests", code: 429)) }

    @Test func notFoundMeansGone() async {
        let runner = DrainRunner(client: ShellScriptedClient(evict: { _ in throw KubeError.notFound(message: nil) }), plan: plan([("a", .evict)]), options: DrainOptions())
        runner.start()
        await finish(runner)
        #expect(runner.phase == .completed)
        #expect(runner.pods.first?.state == .gone)
    }

    @Test func blockedByPDBTimesOut() async {
        var opts = DrainOptions(); opts.timeout = 0.3
        let err = tooMany()
        let runner = DrainRunner(client: ShellScriptedClient(evict: { _ in throw err }), plan: plan([("a", .evict)]), options: opts)
        runner.start()
        await finish(runner)
        #expect(runner.phase == .timedOut)
    }

    @Test func cancelKeepsCordonAndMarksCancelled() async {
        let err = tooMany()
        let runner = DrainRunner(client: ShellScriptedClient(evict: { _ in throw err }), plan: plan([("a", .evict)]), options: DrainOptions())
        runner.start()
        try? await Task.sleep(for: .milliseconds(300))
        runner.cancel()
        #expect(runner.phase == .cancelled)
    }

    @Test func cancelledErrorWithoutCancelledTaskDoesNotStickOnDraining() async {
        let runner = DrainRunner(client: ShellScriptedClient(evict: { _ in throw KubeError.cancelled }), plan: plan([("a", .evict)]), options: DrainOptions())
        runner.start()
        await finish(runner)
        #expect(!runner.phase.isRunning)
        if case .failed = runner.phase {} else { Issue.record("expected .failed, got \(runner.phase)") }
    }

    @Test func terminatingPodsAreTrackedAndWaitedFor() async {
        // The scripted client lists no pods, so a terminating pod is observed "gone" on the first refresh.
        let runner = DrainRunner(client: ShellScriptedClient(evict: { _ in }), plan: plan([("t", .terminating), ("a", .evict)]), options: DrainOptions())
        #expect(runner.pods.map(\.name) == ["t", "a"])
        #expect(runner.pods.first?.state == .terminating)
        runner.start()
        await finish(runner)
        #expect(runner.phase == .completed)
    }
}
