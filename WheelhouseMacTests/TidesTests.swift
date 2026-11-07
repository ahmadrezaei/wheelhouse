import Foundation
import Synchronization
import Testing
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

// MARK: - A scripted client over fixture objects (no cluster)

/// Serves fixture Flux and Argo CD objects, records every list, watch and patch, and forwards everything else to the Demo client.
final class FixtureGitOpsClient: KubeClientProtocol, @unchecked Sendable {
    struct Patch: Sendable { var kind: String; var name: String; var namespace: String?; var body: JSONValue; var dryRun: Bool }
    private let state = Mutex(State())
    struct State { var lists: [String] = []; var watches = 0; var patches: [Patch] = [] }
    private let fallback = DemoKubeClient(config: DemoFleet.configs[0])
    let items: [String: [JSONValue]]
    let resources: [APIResource]

    init(items: [String: [JSONValue]], groups: [(group: String, version: String, kind: String, plural: String)]) {
        self.items = items
        resources = groups.map {
            let v: JSONValue = ["name": .string($0.plural), "namespaced": true, "kind": .string($0.kind), "verbs": ["list", "get", "patch", "watch"],
                                "group": .string($0.group), "version": .string($0.version)]
            return try! v.decode(APIResource.self)
        }
    }
    var listCount: Int { state.withLock { $0.lists.count } }
    var watchCount: Int { state.withLock { $0.watches } }
    var patches: [Patch] { state.withLock { $0.patches } }

    func version() async throws -> KubeVersion { try await fallback.version() }
    func discovery() async throws -> DiscoveryInfo { DiscoveryInfo(resources: resources) }
    func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> {
        state.withLock { $0.lists.append(kind.plural) }
        let json: JSONValue = ["apiVersion": "v1", "kind": "List", "metadata": ["resourceVersion": "1"], "items": .array(items[kind.plural] ?? [])]
        return try json.decode(KubeList<T>.self)
    }
    func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw KubeError.unsupported("fixture") }
    func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { throw KubeError.unsupported("fixture") }
    func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { throw KubeError.unsupported("fixture") }
    func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> {
        state.withLock { $0.watches += 1 }
        return AsyncThrowingStream { continuation in continuation.onTermination = { _ in } }   // open until cancelled
    }
    func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("fixture") }
    func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw KubeError.unsupported("fixture") }
    func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue {
        state.withLock { $0.patches.append(Patch(kind: kind.kind, name: name, namespace: namespace, body: patch.body, dryRun: options.dryRun)) }
        return [:]
    }
    func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw KubeError.unsupported("fixture") }
    func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
    func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
    func nodeMetrics() async throws -> [NodeMetrics] { [] }
    func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
    func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw KubeError.unsupported("fixture") }
    func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw KubeError.unsupported("fixture") }
}

private func json(_ s: String) -> JSONValue { try! JSONValue.parse(Data(s.utf8)) }

private let kustomizationObject = json(#"""
{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"apps","namespace":"flux-system","uid":"k1"},
 "spec":{"interval":"10m","path":"./apps","sourceRef":{"kind":"GitRepository","name":"fleet"}},
 "status":{"conditions":[{"type":"Ready","status":"True","message":"Applied revision: main@sha1:3f2a9c1d0e"}],"lastAppliedRevision":"main@sha1:3f2a9c1d0e","lastAttemptedRevision":"main@sha1:3f2a9c1d0e"}}
"""#)
private let brokenObject = json(#"""
{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"broken","namespace":"flux-system","uid":"k2"},
 "spec":{"interval":"5m","path":"./broken","sourceRef":{"kind":"GitRepository","name":"fleet"}},
 "status":{"conditions":[{"type":"Ready","status":"False","message":"build failed"},{"type":"Stalled","status":"True"}]}}
"""#)
private let argoObject = json(#"""
{"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"checkout","namespace":"argocd","uid":"a1"},
 "spec":{"project":"shop","source":{"repoURL":"https://github.com/acme/deploy.git","path":"checkout","targetRevision":"main"},"destination":{"server":"https://kubernetes.default.svc","namespace":"checkout"}},
 "status":{"sync":{"status":"OutOfSync","revision":"0123456789abcdef0123456789abcdef01234567"},"health":{"status":"Degraded"},
  "resources":[{"group":"apps","kind":"Deployment","namespace":"checkout","name":"web","status":"OutOfSync"},
               {"group":"","kind":"ConfigMap","namespace":"checkout","name":"old-config","status":"OutOfSync","requiresPruning":true},
               {"group":"","kind":"ConfigMap","namespace":"checkout","name":"legacy-flags","status":"OutOfSync","requiresPruning":true}]}}
"""#)

private let allGroups: [(group: String, version: String, kind: String, plural: String)] = [
    ("kustomize.toolkit.fluxcd.io", "v1", "Kustomization", "kustomizations"),
    ("helm.toolkit.fluxcd.io", "v2", "HelmRelease", "helmreleases"),
    ("source.toolkit.fluxcd.io", "v1", "GitRepository", "gitrepositories"),
    ("argoproj.io", "v1alpha1", "Application", "applications"),
]

private func config(_ env: ClusterEnvironment, readOnly: Bool = false) -> ClusterConfig {
    ClusterConfig(name: "prod-1", server: URL(string: "https://example.invalid:6443")!, environment: env, readOnly: readOnly)
}

private func argoApp() -> GitOpsApp {
    GitOpsApp(raw: argoObject, kind: .custom(group: "argoproj.io", version: "v1alpha1", kind: "Application", plural: "applications", namespaced: true))!
}

// MARK: - Confirmations

@MainActor @Suite("Tides confirmations")
struct TidesConfirmationTests {
    private func request(_ kind: GitOpsActionPlan.Kind, env: ClusterEnvironment, readOnly: Bool = false, sync: ArgoSyncRequest = ArgoSyncRequest(),
                         client: FixtureGitOpsClient = FixtureGitOpsClient(items: [:], groups: allGroups), log: any ActivityLogging = NoopActivityLog()) throws -> ConfirmRequest {
        let plan = try GitOpsPlanner.plan(kind, app: argoApp(), sync: sync)
        return TidesConfirmations.request(plan: plan, cluster: config(env, readOnly: readOnly), client: client, detection: GitOpsDetection(), log: log)
    }

    @Test func productionRequiresTypingTheAppName() throws {
        for kind in [GitOpsActionPlan.Kind.argoRefresh, .argoHardRefresh, .argoSync, .argoEnableAutoSync, .argoDisableAutoSync] {
            let r = try request(kind, env: .production)
            #expect(r.requiresTyping, "\(kind)")
            #expect(r.confirmationText == "checkout")
            #expect(r.origin == .tides)
            #expect(r.dryRun != nil)
        }
    }

    @Test func otherEnvironmentsDoNotRequireTypingButStillDryRun() throws {
        let r = try request(.argoRefresh, env: .development)
        #expect(!r.requiresTyping && r.dryRun != nil)
        #expect(!(try request(.argoRefresh, env: .staging).requiresTyping))
    }

    @Test func tidesNeverUsesTheTypingExemption() throws {
        #expect(try request(.argoRefresh, env: .production).typeToConfirmOnProduction)
    }

    @Test func readOnlyClustersRefuse() throws {
        let r = try request(.argoRefresh, env: .development, readOnly: true)
        #expect(r.refusal(live: r.cluster) != nil)
    }

    @Test func pruneListsEveryResourceItWillDeleteAndIsDestructive() throws {
        let r = try request(.argoSync, env: .production, sync: ArgoSyncRequest(revision: "main", prune: true))
        #expect(r.isDestructive && r.verb == "Sync and Prune")
        let deleted = r.facts.filter { $0.label == "Delete" }.map(\.value)
        #expect(deleted == ["ConfigMap/checkout/old-config", "ConfigMap/checkout/legacy-flags"])
        #expect(r.facts.contains { $0.label == "Prune" && $0.value == "on" })
        #expect(r.facts.contains { $0.label == "Destination namespace" && $0.value == "checkout" })
        let plain = try request(.argoSync, env: .production)
        #expect(!plain.isDestructive && plain.facts.allSatisfy { $0.label != "Delete" })
    }

    @Test func dryRunSendsTheSamePatchWithDryRunAndTheActionSendsItWithout() async throws {
        let client = FixtureGitOpsClient(items: [:], groups: allGroups)
        let log = InMemoryActivityLog()
        let r = try request(.argoHardRefresh, env: .development, client: client, log: log)
        guard case .passed = await r.dryRun!() else { Issue.record("dry run failed"); return }
        #expect(client.patches.count == 1 && client.patches[0].dryRun && client.patches[0].kind == "Application")
        try await r.action()
        #expect(client.patches.count == 2 && !client.patches[1].dryRun)
        #expect(client.patches[0].body == client.patches[1].body)
        #expect(client.patches[1].body.value(at: "metadata.annotations")?["argocd.argoproj.io/refresh"]?.stringValue == "hard")
        #expect(log.entries.count == 1 && log.entries[0].origin == .tides && log.entries[0].result == "ok" && log.entries[0].object == "application/checkout")
    }

    @Test func aFailedDryRunKeepsTheButtonDisabled() async throws {
        struct Failing: Error, LocalizedError { var errorDescription: String? { "denied by admission webhook" } }
        final class Rejecting: KubeClientProtocol, @unchecked Sendable {
            let inner = FixtureGitOpsClient(items: [:], groups: [])
            func version() async throws -> KubeVersion { try await inner.version() }
            func discovery() async throws -> DiscoveryInfo { try await inner.discovery() }
            func list<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> KubeList<T> { try await inner.list(type, kind: kind, namespace: namespace, options: options) }
            func get<T: KubeObject>(_ type: T.Type, kind: ResourceKind, name: String, namespace: String?) async throws -> T { throw Failing() }
            func listRaw(_ kind: ResourceKind, namespace: String?, options: ListOptions) async throws -> JSONValue { .null }
            func getRaw(_ kind: ResourceKind, name: String, namespace: String?) async throws -> JSONValue { .null }
            func watch<T: KubeObject>(_ type: T.Type, kind: ResourceKind, namespace: String?, options: WatchOptions) -> AsyncThrowingStream<WatchEvent<T>, Error> { inner.watch(type, kind: kind, namespace: namespace, options: options) }
            func create(_ kind: ResourceKind, namespace: String?, name: String?, subresource: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw Failing() }
            func replace(_ kind: ResourceKind, name: String, namespace: String?, body: JSONValue, options: MutationOptions) async throws -> JSONValue { throw Failing() }
            func patch(_ kind: ResourceKind, name: String, namespace: String?, subresource: String?, patch: KubePatch, options: MutationOptions) async throws -> JSONValue { throw KubeError.invalid(message: "denied by admission webhook", causes: []) }
            func delete(_ kind: ResourceKind, name: String, namespace: String?, options: DeleteOptions) async throws { throw Failing() }
            func logs(namespace: String, pod: String, options: LogOptions) -> AsyncThrowingStream<String, Error> { AsyncThrowingStream { $0.finish() } }
            func podMetrics(namespace: String?) async throws -> [PodMetrics] { [] }
            func nodeMetrics() async throws -> [NodeMetrics] { [] }
            func proxyGET(namespace: String, service: String, port: String, path: String, query: [String: String]) async throws -> Data { Data() }
            func execWebSocket(namespace: String, pod: String, options: ExecOptions) throws -> KubeWebSocket { throw Failing() }
            func portForwardWebSocket(namespace: String, pod: String, ports: [Int]) throws -> KubeWebSocket { throw Failing() }
        }
        let plan = try GitOpsPlanner.plan(.argoRefresh, app: argoApp())
        let log = InMemoryActivityLog()
        let r = TidesConfirmations.request(plan: plan, cluster: config(.development), client: Rejecting(), detection: GitOpsDetection(), log: log)
        guard case .failed(let message) = await r.dryRun!() else { Issue.record("expected failure"); return }
        #expect(message.contains("denied by admission webhook"))
        await #expect(throws: KubeError.self) { try await r.action() }
        #expect(log.entries.last?.result.hasPrefix("failed") == true)
    }

    @Test func listIsCappedForHugePruneSets() throws {
        var resources: [JSONValue] = []
        for i in 0..<45 { resources.append(["group": "", "kind": "ConfigMap", "namespace": "ns", "name": .string("cm-\(i)"), "status": "OutOfSync", "requiresPruning": true]) }
        var raw = argoObject
        raw["status"]?["resources"] = .array(resources)
        let app = GitOpsApp(raw: raw, kind: .custom(group: "argoproj.io", version: "v1alpha1", kind: "Application", plural: "applications", namespaced: true))!
        let plan = try GitOpsPlanner.plan(.argoSync, app: app, sync: ArgoSyncRequest(prune: true))
        let r = TidesConfirmations.request(plan: plan, cluster: config(.production), client: FixtureGitOpsClient(items: [:], groups: []), detection: GitOpsDetection())
        let deletes = r.facts.filter { $0.label == "Delete" }
        #expect(deletes.count == TidesConfirmations.listLimit + 1 && deletes.last?.value == "and 15 more")
        #expect(r.facts.contains { $0.label == "Will be deleted" && $0.value == "45" })
    }
}

// MARK: - Stores run only while visible

@MainActor @Suite("Tides stores")
struct TidesStoreTests {
    private func model(_ client: FixtureGitOpsClient) -> TidesClusterModel {
        TidesClusterModel(session: ClusterSession(config: config(.development), client: client))
    }

    @Test func detectionAndRowsComeFromTheStores() async throws {
        let client = FixtureGitOpsClient(items: ["kustomizations": [kustomizationObject, brokenObject], "applications": [argoObject]], groups: allGroups)
        let m = model(client)
        await m.loadDiscovery()
        #expect(m.detection.hasFlux && m.detection.hasArgo)
        let stores = m.acquire(includeSources: false)
        defer { m.release(stores) }
        for _ in 0..<100 where m.apps.count < 3 { try await Task.sleep(for: .milliseconds(20)) }
        let apps = m.apps.sorted(by: GitOpsApp.problemsFirst)
        #expect(Set(apps.map(\.name)) == ["apps", "broken", "checkout"])
        #expect(apps.last?.name == "apps")                      // problems first, the healthy one last
        let tally = TidesTally(apps)
        #expect(tally.outOfSync == 2 && tally.degraded == 2 && tally.failedReconcile == 1 && tally.suspended == 0)
    }

    @Test func noWatchStartsUntilAViewAsksAndAllStopWhenItLeaves() async throws {
        let client = FixtureGitOpsClient(items: ["kustomizations": [kustomizationObject], "applications": [argoObject]], groups: allGroups)
        let m = model(client)
        await m.loadDiscovery()
        // Detection and the model alone start nothing.
        try await Task.sleep(for: .milliseconds(150))
        #expect(client.listCount == 0 && client.watchCount == 0)

        let task = Task { await m.run(includeSources: true) }
        for _ in 0..<100 where client.watchCount < m.kinds(includeSources: true).count { try await Task.sleep(for: .milliseconds(20)) }
        let kinds = m.kinds(includeSources: true)
        #expect(kinds.count == 4)                                 // Kustomization, HelmRelease, Application, GitRepository
        #expect(client.listCount >= kinds.count)
        #expect(kinds.allSatisfy { m.store(for: $0).consumerCount == 1 })

        task.cancel()
        await task.value
        #expect(kinds.allSatisfy { m.store(for: $0).consumerCount == 0 })
        // After the view left, no further lists or watches are issued.
        let lists = client.listCount, watches = client.watchCount
        try await Task.sleep(for: .milliseconds(300))
        #expect(client.listCount == lists && client.watchCount == watches)
    }

    @Test func aClusterWithoutGitOpsDetectsNothingAndStartsNoStore() async {
        let client = FixtureGitOpsClient(items: [:], groups: [("apps", "v1", "Deployment", "deployments")])
        let m = model(client)
        await m.loadDiscovery()
        #expect(!m.detection.isPresent && m.kinds(includeSources: true).isEmpty)
        let stores = m.acquire(includeSources: true)
        #expect(stores.isEmpty && client.listCount == 0)
    }
}

// MARK: - Misc

@MainActor @Suite("Tides misc")
struct TidesMiscTests {
    @Test func featureHandlesItsDestinationsOnly() {
        #expect(TidesFeature.handles(.tides(TidesScope(clusterID: nil, tool: nil))))
        #expect(TidesFeature.handles(.gitopsApp(ResourceRef(clusterID: "c", kind: .custom(group: "argoproj.io", version: "v1alpha1", kind: "Application", plural: "applications", namespaced: true), namespace: "argocd", name: "x"))))
        #expect(!TidesFeature.handles(.moorings))
    }

    @Test func argoLocationDefaultsAndPerClusterOverrides() {
        let suite = UserDefaults(suiteName: "tides.test.\(UUID().uuidString)")!
        let store = Mutex<[String: String]>([:])
        let c = ArgoConnection(readToken: { id in store.withLock { $0[id] } }, writeToken: { t, id in store.withLock { $0[id] = t }; return true }, defaults: suite)
        #expect(c.location(for: "a") == ArgoServiceLocation())
        #expect(ArgoServiceLocation().proxyService == "https:argocd-server")
        c.setDefaultLocation(ArgoServiceLocation(namespace: "gitops", service: "argo", port: "80", scheme: "http"))
        #expect(c.location(for: "a").namespace == "gitops")
        c.setLocation(ArgoServiceLocation(namespace: "special"), for: "b")
        #expect(c.location(for: "b").namespace == "special" && c.location(for: "a").namespace == "gitops")
        #expect(!c.hasToken("a"))
        _ = c.writeToken("t", "a")
        #expect(c.hasToken("a"))
    }
}
