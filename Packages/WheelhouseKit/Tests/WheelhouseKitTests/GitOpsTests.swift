import Foundation
import Synchronization
import Testing
@testable import WheelhouseKit

// MARK: - Helpers

private func canonical(_ v: JSONValue) -> String {
    let obj = try! JSONSerialization.jsonObject(with: v.data(), options: [.fragmentsAllowed])
    return String(data: try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]), encoding: .utf8)!
}

private func json(_ s: String) -> JSONValue { try! JSONValue.parse(Data(s.utf8)) }

private let fixedNow = Date(timeIntervalSince1970: 1_700_000_000.5)
private let fixedStamp = "2023-11-14T22:13:20.500000000Z"

private let kustomizationKind: ResourceKind = .custom(group: "kustomize.toolkit.fluxcd.io", version: "v1", kind: "Kustomization", plural: "kustomizations", namespaced: true)
private let helmReleaseKind: ResourceKind = .custom(group: "helm.toolkit.fluxcd.io", version: "v2", kind: "HelmRelease", plural: "helmreleases", namespaced: true)
private let gitRepoKind: ResourceKind = .custom(group: "source.toolkit.fluxcd.io", version: "v1", kind: "GitRepository", plural: "gitrepositories", namespaced: true)
private let argoAppKind: ResourceKind = .custom(group: "argoproj.io", version: "v1alpha1", kind: "Application", plural: "applications", namespaced: true)

private let kustomizationJSON = """
{"apiVersion":"kustomize.toolkit.fluxcd.io/v1","kind":"Kustomization","metadata":{"name":"apps","namespace":"flux-system"},
 "spec":{"interval":"10m","path":"./apps/prod","sourceRef":{"kind":"GitRepository","name":"fleet"},"suspend":false,
         "dependsOn":[{"name":"infra"},{"name":"crds","namespace":"other"}]},
 "status":{"conditions":[{"type":"Ready","status":"True","reason":"ReconciliationSucceeded","message":"Applied revision: main@sha1:3f2a9c1d0e","lastTransitionTime":"2026-11-01T10:00:00Z"}],
  "lastAppliedRevision":"main@sha1:3f2a9c1d0e","lastAttemptedRevision":"main@sha1:3f2a9c1d0e",
  "inventory":{"entries":[{"id":"shop_web_apps_Deployment","v":"v1"},{"id":"_shop__Namespace","v":"v1"},{"id":"_system__metrics_rbac.authorization.k8s.io_ClusterRole","v":"v1"}]}}}
"""

private let helmReleaseJSON = """
{"apiVersion":"helm.toolkit.fluxcd.io/v2","kind":"HelmRelease","metadata":{"name":"podinfo","namespace":"apps"},
 "spec":{"interval":"5m","chart":{"spec":{"chart":"podinfo","version":"6.x","sourceRef":{"kind":"HelmRepository","name":"podinfo","namespace":"flux-system"}}},"releaseName":"podinfo","targetNamespace":"podinfo-ns"},
 "status":{"conditions":[{"type":"Ready","status":"False","reason":"InstallFailed","message":"Helm install failed"},{"type":"Stalled","status":"True"}],
  "lastAttemptedRevision":"6.5.4","history":[{"version":2,"chartName":"podinfo","chartVersion":"6.5.3","status":"deployed","lastDeployed":"2026-10-01T10:00:00Z"}]}}
"""

private func argoJSON(history: Bool = true, auto: Bool = false, phase: String? = nil, operation: Bool = false) -> JSONValue {
    var obj = json("""
    {"apiVersion":"argoproj.io/v1alpha1","kind":"Application","metadata":{"name":"checkout","namespace":"argocd"},
     "spec":{"project":"shop","source":{"repoURL":"https://github.com/acme/deploy.git","path":"checkout","targetRevision":"main"},
             "destination":{"server":"https://kubernetes.default.svc","namespace":"checkout"},"syncPolicy":{}},
     "status":{"sync":{"status":"OutOfSync","revision":"0123456789abcdef0123456789abcdef01234567"},"health":{"status":"Degraded","message":"1 pod crashing"},
      "resources":[{"group":"apps","version":"v1","kind":"Deployment","namespace":"checkout","name":"web","status":"OutOfSync","health":{"status":"Degraded"}},
                   {"group":"","version":"v1","kind":"ConfigMap","namespace":"checkout","name":"old-config","status":"OutOfSync","requiresPruning":true},
                   {"group":"batch","version":"v1","kind":"Job","namespace":"checkout","name":"hook","status":"Synced","requiresPruning":true,"hook":true}],
      "history":[{"id":3,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","deployedAt":"2026-10-30T10:00:00Z","source":{"repoURL":"https://github.com/acme/deploy.git","path":"checkout","targetRevision":"main"}},
                 {"id":4,"revision":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","deployedAt":"2026-11-02T10:00:00Z"}]}}
    """)
    if !history { obj["status"]?["history"] = nil }
    if auto { obj["spec"]?["syncPolicy"] = ["automated": ["prune": true, "selfHeal": true]] }
    if let phase { obj["status"]?["operationState"] = ["phase": .string(phase), "message": "syncing"] }
    if operation { obj["operation"] = ["sync": [:]] }
    return obj
}

// MARK: - Detection

@Suite("GitOps detection")
struct GitOpsDetectionTests {
    private func resource(_ group: String, _ version: String, _ kind: String, _ plural: String) -> APIResource {
        APIResource(name: plural, singularName: nil, namespaced: true, kind: kind, verbs: ["list", "get", "patch"], shortNames: nil, group: group, version: version)
    }

    @Test func absentWhenNoGroupIsServed() {
        let d = GitOpsDetection.detect(DiscoveryInfo(resources: [resource("apps", "v1", "Deployment", "deployments")]))
        #expect(!d.isPresent && !d.hasFlux && !d.hasArgo)
        #expect(!GitOpsDetection.detect(nil).isPresent)
    }

    @Test func fluxAndArgoAreFoundByGroupAndKind() {
        let info = DiscoveryInfo(resources: [
            resource("kustomize.toolkit.fluxcd.io", "v1", "Kustomization", "kustomizations"),
            resource("source.toolkit.fluxcd.io", "v1beta2", "OCIRepository", "ocirepositories"),
            resource("source.toolkit.fluxcd.io", "v1", "GitRepository", "gitrepositories"),
            resource("notification.toolkit.fluxcd.io", "v1", "Alert", "alerts"),
            resource("argoproj.io", "v1alpha1", "Application", "applications"),
            resource("argoproj.io", "v1alpha1", "Rollout", "rollouts"),
        ])
        let d = GitOpsDetection.detect(info)
        #expect(d.hasFlux && d.hasArgo && d.fluxNotification && !d.fluxImage)
        #expect(d.kustomizations?.version == "v1")
        #expect(d.ociRepositories?.version == "v1beta2")
        #expect(d.helmReleases == nil)
        #expect(d.fluxSources.map(\.kind) == ["GitRepository", "OCIRepository"])
        #expect(d.sourceKind(named: "OCIRepository")?.plural == "ocirepositories")
        #expect(d.appKinds.map(\.kind) == ["Kustomization", "Application"])
        #expect(d.applicationSets == nil)
    }

    @Test func aKindWithoutListIsIgnored() {
        var r = resource("argoproj.io", "v1alpha1", "Application", "applications")
        r.verbs = ["get"]
        #expect(!GitOpsDetection.detect(DiscoveryInfo(resources: [r])).hasArgo)
    }
}

// MARK: - Models

@Suite("GitOps models")
struct GitOpsModelTests {
    @Test func fluxKustomizationRow() throws {
        let app = try #require(GitOpsApp(raw: json(kustomizationJSON), kind: kustomizationKind))
        #expect(app.flavor == .fluxKustomization && app.tool == .flux)
        #expect(app.sync == .synced && app.health == .healthy && !app.suspended && !app.isProblem)
        #expect(app.source == "GitRepository/fleet ./apps/prod")
        #expect(app.liveRevision == "main@sha1:3f2a9c1d0e")
        #expect(GitOpsRevision.short(app.liveRevision) == "main@3f2a9c1")
        #expect(app.message?.contains("Applied revision") == true)
        #expect(app.lastActivity != nil)
    }

    @Test func fluxInventoryAndDependencies() {
        let v = FluxView(raw: json(kustomizationJSON), flavor: .fluxKustomization)
        let inv = v.inventory
        #expect(inv.count == 3)
        #expect(inv[0].namespace == "shop" && inv[0].name == "web" && inv[0].group == "apps" && inv[0].kind == "Deployment")
        #expect(inv[1].namespace == nil && inv[1].name == "shop" && inv[1].group == "" && inv[1].kind == "Namespace")
        #expect(inv[2].name == "system:metrics" && inv[2].group == "rbac.authorization.k8s.io" && inv[2].kind == "ClusterRole")
        #expect(v.dependsOn.map(\.name) == ["infra", "crds"])
        #expect(v.dependsOn.map(\.namespace) == ["flux-system", "other"])
        #expect(v.sourceRef?.namespace == "flux-system")
        #expect(FluxInventoryEntry.parse(id: "broken", version: nil) == nil)
    }

    @Test func fluxFailedHelmRelease() throws {
        let app = try #require(GitOpsApp(raw: json(helmReleaseJSON), kind: helmReleaseKind))
        #expect(app.health == .degraded && app.sync == .outOfSync && app.isProblem && app.isFailedReconcile)
        #expect(app.source == "podinfo 6.x")
        #expect(app.targetRevision == "6.5.4")
        let history = FluxView(raw: app.raw, flavor: .fluxHelmRelease).helmHistory
        #expect(history.first?.chartVersion == "6.5.3" && history.first?.status == "deployed")
    }

    @Test func suspendedWinsOverReadyState() throws {
        var raw = json(kustomizationJSON)
        raw["spec"]?["suspend"] = true
        let app = try #require(GitOpsApp(raw: raw, kind: kustomizationKind))
        #expect(app.suspended && app.health == .suspended)
    }

    @Test func fluxSourceRowUsesTheArtifact() throws {
        let raw = json(#"{"metadata":{"name":"fleet","namespace":"flux-system"},"spec":{"url":"https://github.com/acme/fleet"},"status":{"artifact":{"revision":"main@sha1:abcdef123456","lastUpdateTime":"2026-11-01T10:00:00Z"},"conditions":[{"type":"Ready","status":"True"}]}}"#)
        let app = try #require(GitOpsApp(raw: raw, kind: gitRepoKind))
        #expect(app.flavor.isSource && app.source == "https://github.com/acme/fleet")
        #expect(app.liveRevision == "main@sha1:abcdef123456" && app.health == .healthy)
    }

    @Test func argoApplicationRow() throws {
        let app = try #require(GitOpsApp(raw: argoJSON(), kind: argoAppKind))
        #expect(app.tool == .argoCD && app.project == "shop")
        #expect(app.sync == .outOfSync && app.health == .degraded && app.isProblem)
        #expect(app.source == "github.com/acme/deploy checkout")
        #expect(app.targetRevision == "main")
        #expect(GitOpsRevision.short(app.liveRevision) == "0123456")
        #expect(app.message == "1 pod crashing")
    }

    @Test func argoDetail() {
        let v = ArgoView(raw: argoJSON(auto: true))
        #expect(v.autoSyncEnabled && v.autoPrune && v.selfHeal)
        #expect(v.resources.count == 3 && v.outOfSyncResources.count == 2)
        #expect(v.pruneCandidates.map(\.name) == ["old-config"])      // hooks are never pruned
        #expect(v.history.map(\.id) == [3, 4])
        #expect(v.destinationNamespace == "checkout")
        #expect(!ArgoView(raw: argoJSON()).autoSyncEnabled)
    }

    @Test func revisionShortening() {
        #expect(GitOpsRevision.short("v1.2.3") == "v1.2.3")
        #expect(GitOpsRevision.short("sha256:0123456789abcdef") == "sha256:0123456")
        #expect(GitOpsRevision.short(nil) == nil)
        #expect(GitOpsRevision.short("") == nil)
    }
}

// MARK: - Golden patch bodies (ARCHITECTURE-MAC section 7 table)

@Suite("GitOps action patches")
struct GitOpsActionTests {
    @Test func timestampIsRFC3339Nano() {
        #expect(GitOpsActions.timestamp(fixedNow) == fixedStamp)
    }

    @Test func fluxReconcile() {
        let p = GitOpsActions.fluxReconcile(at: fixedStamp)
        #expect(p.contentType == "application/merge-patch+json")
        #expect(canonical(p.body) == #"{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"2023-11-14T22:13:20.500000000Z"}}}"#)
    }

    @Test func fluxForceAndReset() {
        #expect(canonical(GitOpsActions.fluxForce(at: "T").body) == #"{"metadata":{"annotations":{"reconcile.fluxcd.io/forceAt":"T","reconcile.fluxcd.io/requestedAt":"T"}}}"#)
        #expect(canonical(GitOpsActions.fluxReset(at: "T").body) == #"{"metadata":{"annotations":{"reconcile.fluxcd.io/requestedAt":"T","reconcile.fluxcd.io/resetAt":"T"}}}"#)
    }

    @Test func fluxSuspendResume() {
        #expect(canonical(GitOpsActions.fluxSuspend(true).body) == #"{"spec":{"suspend":true}}"#)
        #expect(canonical(GitOpsActions.fluxSuspend(false).body) == #"{"spec":{"suspend":false}}"#)
    }

    @Test func argoRefresh() {
        #expect(canonical(GitOpsActions.argoRefresh(hard: false).body) == #"{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"normal"}}}"#)
        #expect(canonical(GitOpsActions.argoRefresh(hard: true).body) == #"{"metadata":{"annotations":{"argocd.argoproj.io/refresh":"hard"}}}"#)
    }

    @Test func argoSyncBody() {
        let p = GitOpsActions.argoSync(ArgoSyncRequest(revision: "main", prune: true, dryRun: false, applyOutOfSyncOnly: true,
                                                       syncOptions: ["CreateNamespace=true"],
                                                       resources: [ArgoSyncResource(group: "apps", kind: "Deployment", name: "web", namespace: "checkout"),
                                                                   ArgoSyncResource(group: "", kind: "Namespace", name: "checkout")]))
        #expect(p.contentType == "application/merge-patch+json")
        #expect(canonical(p.body) == #"{"operation":{"info":[{"name":"Reason","value":"Wheelhouse"}],"initiatedBy":{"username":"wheelhouse"},"sync":{"dryRun":false,"prune":true,"resources":[{"group":"apps","kind":"Deployment","name":"web","namespace":"checkout"},{"group":"","kind":"Namespace","name":"checkout"}],"revision":"main","syncOptions":["CreateNamespace=true","ApplyOutOfSyncOnly=true"]}}}"#)
    }

    @Test func argoSyncMinimal() {
        #expect(canonical(GitOpsActions.argoSync(ArgoSyncRequest()).body) == #"{"operation":{"info":[{"name":"Reason","value":"Wheelhouse"}],"initiatedBy":{"username":"wheelhouse"},"sync":{"dryRun":false,"prune":false}}}"#)
        #expect(canonical(GitOpsActions.argoSync(ArgoSyncRequest(dryRun: true)).body).contains(#""dryRun":true"#))
    }

    @Test func argoTerminateAndAutoSync() {
        #expect(canonical(GitOpsActions.argoTerminate().body) == #"{"status":{"operationState":{"phase":"Terminating"}}}"#)
        #expect(canonical(GitOpsActions.argoAutoSync(enabled: true, prune: true, selfHeal: false).body) == #"{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":false}}}}"#)
        #expect(canonical(GitOpsActions.argoAutoSync(enabled: false).body) == #"{"spec":{"syncPolicy":{"automated":null}}}"#)
    }

    @Test func argoRollbackUsesTheHistoryEntry() throws {
        let p = try GitOpsActions.argoRollback(app: ArgoView(raw: argoJSON()), historyID: 3)
        #expect(canonical(p.body) == #"{"operation":{"info":[{"name":"Reason","value":"Wheelhouse"}],"initiatedBy":{"username":"wheelhouse"},"sync":{"dryRun":false,"prune":false,"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","source":{"path":"checkout","repoURL":"https://github.com/acme/deploy.git","targetRevision":"main"}}}}"#)
    }

    @Test func rollbackNeedsAutoSyncOffAndAKnownEntry() {
        #expect(throws: GitOpsActionError.autoSyncMustBeOff) { try GitOpsActions.argoRollback(app: ArgoView(raw: argoJSON(auto: true)), historyID: 3) }
        #expect(throws: GitOpsActionError.noSuchHistoryEntry(9)) { try GitOpsActions.argoRollback(app: ArgoView(raw: argoJSON()), historyID: 9) }
    }

    @Test func syncIsRefusedWhileOneIsRunningOrQueued() {
        #expect(throws: GitOpsActionError.syncAlreadyRunning) { try GitOpsActions.checkSyncAllowed(ArgoView(raw: argoJSON(phase: "Running"))) }
        #expect(throws: GitOpsActionError.operationPending) { try GitOpsActions.checkSyncAllowed(ArgoView(raw: argoJSON(operation: true))) }
        #expect(throws: Never.self) { try GitOpsActions.checkSyncAllowed(ArgoView(raw: argoJSON(phase: "Succeeded"))) }
        #expect(GitOpsActionError.syncAlreadyRunning.errorDescription == "A sync is already running.")
    }
}

// MARK: - Plans

@Suite("GitOps plans")
struct GitOpsPlanTests {
    private func argoApp(_ raw: JSONValue? = nil) -> GitOpsApp { GitOpsApp(raw: raw ?? argoJSON(), kind: argoAppKind)! }
    private func kustomization() -> GitOpsApp { GitOpsApp(raw: json(kustomizationJSON), kind: kustomizationKind)! }
    private var detection: GitOpsDetection {
        var d = GitOpsDetection()
        d.kustomizations = kustomizationKind
        d.gitRepositories = gitRepoKind
        return d
    }

    @Test func fluxReconcilePlan() throws {
        let plan = try GitOpsPlanner.plan(.fluxReconcile, app: kustomization(), now: fixedNow)
        #expect(plan.verb == "Reconcile" && plan.token == fixedStamp && plan.source == nil && !plan.isDestructive)
        #expect(canonical(plan.patch.body) == canonical(GitOpsActions.fluxReconcile(at: fixedStamp).body))
    }

    @Test func reconcileWithSourceAnnotatesTheSourceFirst() throws {
        let plan = try GitOpsPlanner.plan(.fluxReconcileWithSource, app: kustomization(), detection: detection, now: fixedNow)
        let source = try #require(plan.source)
        #expect(source.kind.kind == "GitRepository" && source.name == "fleet" && source.namespace == "flux-system")
        #expect(canonical(source.patch.body) == canonical(plan.patch.body))
        #expect(throws: GitOpsActionError.missingSource) { try GitOpsPlanner.plan(.fluxReconcileWithSource, app: kustomization(), detection: GitOpsDetection()) }
    }

    @Test func suspendAndResumeAreInverses() throws {
        let s = try GitOpsPlanner.plan(.fluxSuspend, app: kustomization())
        #expect(s.inverse == .fluxResume && canonical(s.patch.body) == #"{"spec":{"suspend":true}}"#)
        let r = try GitOpsPlanner.plan(.fluxResume, app: kustomization())
        #expect(r.inverse == .fluxSuspend)
    }

    @Test func forceIsHelmReleaseOnly() throws {
        #expect(throws: GitOpsActionError.self) { try GitOpsPlanner.plan(.fluxForce, app: kustomization()) }
        let hr = GitOpsApp(raw: json(helmReleaseJSON), kind: helmReleaseKind)!
        #expect(try GitOpsPlanner.plan(.fluxForce, app: hr).isDestructive)
        #expect(try GitOpsPlanner.plan(.fluxReset, app: hr).verb == "Reset and Reconcile")
    }

    @Test func toolMismatchIsRefused() {
        #expect(throws: GitOpsActionError.self) { try GitOpsPlanner.plan(.argoRefresh, app: kustomization()) }
        #expect(throws: GitOpsActionError.self) { try GitOpsPlanner.plan(.fluxSuspend, app: argoApp()) }
    }

    @Test func pruneSyncListsTheResourcesItWillDelete() throws {
        let plan = try GitOpsPlanner.plan(.argoSync, app: argoApp(), sync: ArgoSyncRequest(revision: "main", prune: true))
        #expect(plan.isDestructive && plan.verb == "Sync and Prune")
        #expect(plan.pruneList.map(\.display) == ["ConfigMap/checkout/old-config"])
        #expect(plan.facts.contains { $0.label == "Prune" && $0.value == "on" })
        #expect(plan.facts.contains { $0.label == "Will be deleted" && $0.value == "1" })
        #expect(plan.facts.contains { $0.label == "Destination namespace" && $0.value == "checkout" })
        let noPrune = try GitOpsPlanner.plan(.argoSync, app: argoApp(), sync: ArgoSyncRequest(prune: false))
        #expect(!noPrune.isDestructive && noPrune.pruneList.isEmpty)
    }

    @Test func pruneListIsLimitedToSelectedResources() throws {
        let only = ArgoSyncResource(group: "apps", kind: "Deployment", name: "web", namespace: "checkout")
        let plan = try GitOpsPlanner.plan(.argoSync, app: argoApp(), sync: ArgoSyncRequest(prune: true, resources: [only]))
        #expect(plan.pruneList.isEmpty)
    }

    @Test func syncRefusedWhileRunning() {
        #expect(throws: GitOpsActionError.syncAlreadyRunning) { try GitOpsPlanner.plan(.argoSync, app: argoApp(argoJSON(phase: "Running"))) }
    }

    @Test func terminateNeedsARunningSync() throws {
        #expect(throws: GitOpsActionError.notRunning) { try GitOpsPlanner.plan(.argoTerminate, app: argoApp()) }
        let plan = try GitOpsPlanner.plan(.argoTerminate, app: argoApp(argoJSON(phase: "Running")))
        #expect(canonical(plan.patch.body) == #"{"status":{"operationState":{"phase":"Terminating"}}}"#)
    }

    @Test func rollbackPlan() throws {
        let plan = try GitOpsPlanner.plan(.argoRollback, app: argoApp(), historyID: 3)
        #expect(plan.isDestructive && plan.verb == "Roll Back")
        #expect(plan.facts.contains { $0.label == "Target revision" && $0.value == "aaaaaaa" })
        #expect(throws: GitOpsActionError.autoSyncMustBeOff) { try GitOpsPlanner.plan(.argoRollback, app: argoApp(argoJSON(auto: true)), historyID: 3) }
    }

    @Test func everyPlanOfEveryKindIsPatchableAsMergePatch() throws {
        let hr = GitOpsApp(raw: json(helmReleaseJSON), kind: helmReleaseKind)!
        for kind in GitOpsActionPlan.Kind.allCases {
            let isArgo: Bool = [.argoRefresh, .argoHardRefresh, .argoSync, .argoTerminate, .argoEnableAutoSync, .argoDisableAutoSync, .argoRollback].contains(kind)
            let app = isArgo ? argoApp(argoJSON(phase: kind == .argoTerminate ? "Running" : nil)) : (kind == .fluxForce || kind == .fluxReset ? hr : kustomization())
            let plan = try GitOpsPlanner.plan(kind, app: app, detection: detection, historyID: 3, now: fixedNow)
            #expect(plan.patch.contentType == "application/merge-patch+json", "\(kind)")
            #expect(!plan.title.isEmpty && !plan.verb.isEmpty && !plan.message.isEmpty)
        }
    }
}

// MARK: - Ownership

@Suite("GitOps ownership detector")
struct GitOpsOwnershipTests {
    @Test func fluxKustomizeLabels() {
        let o = GitOpsOwnershipDetector.detect(json(#"{"metadata":{"labels":{"kustomize.toolkit.fluxcd.io/name":"apps","kustomize.toolkit.fluxcd.io/namespace":"flux-system"}}}"#))
        #expect(o == GitOpsOwner(tool: .flux, name: "apps", namespace: "flux-system"))
    }

    @Test func fluxHelmLabels() {
        let o = GitOpsOwnershipDetector.detect(json(#"{"metadata":{"labels":{"helm.toolkit.fluxcd.io/name":"podinfo","helm.toolkit.fluxcd.io/namespace":"apps"}}}"#))
        #expect(o == GitOpsOwner(tool: .flux, name: "podinfo", namespace: "apps"))
    }

    @Test func argoInstanceLabel() {
        #expect(GitOpsOwnershipDetector.detect(json(#"{"metadata":{"labels":{"argocd.argoproj.io/instance":"checkout"}}}"#)) == GitOpsOwner(tool: .argoCD, name: "checkout"))
    }

    @Test func argoTrackingIDWins() {
        let o = GitOpsOwnershipDetector.detect(json(#"{"metadata":{"labels":{"argocd.argoproj.io/instance":"old"},"annotations":{"argocd.argoproj.io/tracking-id":"checkout:apps/Deployment:shop/web"}}}"#))
        #expect(o == GitOpsOwner(tool: .argoCD, name: "checkout"))
        let ns = GitOpsOwnershipDetector.detect(json(#"{"metadata":{"annotations":{"argocd.argoproj.io/tracking-id":"team-a_checkout:apps/Deployment:shop/web"}}}"#))
        #expect(ns == GitOpsOwner(tool: .argoCD, name: "checkout", namespace: "team-a"))
    }

    @Test func fieldManagersAreTheLastResort() {
        #expect(GitOpsOwnershipDetector.detect(json(#"{"metadata":{"managedFields":[{"manager":"kubectl"},{"manager":"kustomize-controller"}]}}"#))?.tool == .flux)
        #expect(GitOpsOwnershipDetector.detect(json(#"{"metadata":{"managedFields":[{"manager":"helm-controller"}]}}"#))?.name == "helm-controller")
        #expect(GitOpsOwnershipDetector.detect(json(#"{"metadata":{"managedFields":[{"manager":"argocd-controller"}]}}"#))?.tool == .argoCD)
    }

    @Test func unmanagedObjectsHaveNoOwner() async {
        #expect(GitOpsOwnershipDetector.detect(json(#"{"metadata":{"name":"x","labels":{"app":"x"},"managedFields":[{"manager":"kubectl-client-side-apply"}]}}"#)) == nil)
        #expect(await GitOpsOwnershipDetector().owner(of: [:], cluster: "c") == nil)
    }

    @Test func helmReleaseOwnerComesFromTheHelmReleaseObject() {
        let hr = GitOpsApp(raw: json(helmReleaseJSON), kind: helmReleaseKind)!
        #expect(GitOpsOwnershipDetector.owner(ofRelease: "podinfo", namespace: "podinfo-ns", among: [hr]) == GitOpsOwner(tool: .flux, name: "podinfo", namespace: "apps"))
        #expect(GitOpsOwnershipDetector.owner(ofRelease: "podinfo", namespace: "elsewhere", among: [hr]) == nil)
    }
}

// MARK: - Proxy and Argo API

/// Records every request that reaches the wire (method, URL, headers, body) and answers from a per-host script.
final class ProxyCapturingProtocol: URLProtocol, @unchecked Sendable {
    struct Captured: Sendable { var method: String; var url: URL; var headers: [String: String]; var body: Data? }
    private static let captured = Mutex<[String: [Captured]]>([:])
    private static let responses = Mutex<[String: [(Int, String)]]>([:])

    static func script(host: String, _ responses: [(Int, String)]) { Self.responses.withLock { $0[host] = responses } }
    static func requests(host: String) -> [Captured] { captured.withLock { $0[host] ?? [] } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data(); var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buf, maxLength: buf.count); if n <= 0 { break }; data.append(buf, count: n) }
            stream.close(); body = data
        }
        let host = request.url?.host ?? ""
        Self.captured.withLock { $0[host, default: []].append(Captured(method: request.httpMethod ?? "GET", url: request.url!, headers: request.allHTTPHeaderFields ?? [:], body: body)) }
        let (status, text) = Self.responses.withLock { all -> (Int, String) in
            guard var list = all[host], !list.isEmpty else { return (200, "{}") }
            let first = list.count > 1 ? list.removeFirst() : list[0]
            all[host] = list
            return first
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "X-Echo": "1"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@Suite("Service proxy and Argo CD API")
struct ProxyTests {
    private func make(readOnly: Bool = false) -> (LiveKubeClient, String) {
        let host = "proxy-\(UUID().uuidString.lowercased().prefix(8)).test"
        let config = ClusterConfig(name: "t", server: URL(string: "https://\(host):6443")!, environment: .development, readOnly: readOnly)
        return (LiveKubeClient(config: config, secrets: ClusterSecrets(token: "kube-token"), protocolClasses: [ProxyCapturingProtocol.self]), host)
    }

    @Test func pathAndQueryThroughTheServiceProxy() async throws {
        let (client, host) = make()
        ProxyCapturingProtocol.script(host: host, [(200, #"{"ok":true}"#)])
        let r = try await client.proxyRequest(method: "get", namespace: "argocd", service: "https:argocd-server", port: "443",
                                              path: "/api/v1/applications/a b/managed-resources", query: ["appNamespace": "argocd", "z": "1"], headers: [:], body: nil)
        #expect(r.statusCode == 200 && String(data: r.body, encoding: .utf8) == #"{"ok":true}"#)
        #expect(r.headers["X-Echo"] == "1")
        let req = try #require(ProxyCapturingProtocol.requests(host: host).first)
        #expect(req.method == "GET")
        #expect(req.url.absoluteString.contains("/api/v1/namespaces/argocd/services/https:argocd-server:443/proxy/api/v1/applications/a%20b/managed-resources?appNamespace=argocd&z=1"))
        #expect(req.headers["Authorization"] == "Bearer kube-token")
    }

    @Test func callerHeadersAreForwardedButNeverReplaceTheClusterCredential() async throws {
        let (client, host) = make()
        _ = try await client.proxyRequest(method: "GET", namespace: "n", service: "s", port: "80", path: "x", query: [:],
                                          headers: ["Cookie": "argocd.token=abc", "Authorization": "Bearer evil", "Host": "evil", "Accept": "text/plain"], body: nil)
        let req = try #require(ProxyCapturingProtocol.requests(host: host).first)
        #expect(req.headers["Cookie"] == "argocd.token=abc")
        #expect(req.headers["Authorization"] == "Bearer kube-token")
        #expect(req.headers["Accept"] == "text/plain")
        #expect(req.headers["Host"] == nil)
    }

    @Test func nonSuccessStatusesAreReturnedNotThrown() async throws {
        let (client, host) = make()
        ProxyCapturingProtocol.script(host: host, [(401, "nope")])
        let r = try await client.proxyRequest(method: "GET", namespace: "n", service: "s", port: "80", path: "x", query: [:], headers: [:], body: nil)
        #expect(r.statusCode == 401)
    }

    @Test func postCarriesTheBodyAndFollowsReadOnly() async throws {
        let (client, host) = make()
        _ = try await client.proxyRequest(method: "POST", namespace: "n", service: "s", port: "80", path: "x", query: [:], headers: ["Content-Type": "application/json"], body: Data("{}".utf8))
        let req = try #require(ProxyCapturingProtocol.requests(host: host).first)
        #expect(req.method == "POST" && req.body == Data("{}".utf8) && req.headers["Content-Type"] == "application/json")
        let (ro, roHost) = make(readOnly: true)
        await #expect(throws: KubeError.readOnly) { _ = try await ro.proxyRequest(method: "POST", namespace: "n", service: "s", port: "80", path: "x", query: [:], headers: [:], body: nil) }
        #expect(ProxyCapturingProtocol.requests(host: roHost).isEmpty)
        // A read-only cluster still reads.
        _ = try await ro.proxyRequest(method: "GET", namespace: "n", service: "s", port: "80", path: "x", query: [:], headers: [:], body: nil)
        #expect(ProxyCapturingProtocol.requests(host: roHost).count == 1)
    }

    @Test func argoManagedResourcesUseTheCookie() async throws {
        let (client, host) = make()
        let body = #"{"items":[{"group":"apps","kind":"Deployment","namespace":"shop","name":"web","modified":true,"normalizedLiveState":"{\"spec\":{\"replicas\":2}}","predictedLiveState":"{\"spec\":{\"replicas\":3}}"},{"group":"","kind":"Namespace","namespace":"","name":"shop"}]}"#
        ProxyCapturingProtocol.script(host: host, [(200, body)])
        let api = ArgoAPI(client: client, location: ArgoServiceLocation(), token: "tok123")
        let items = try await api.managedResources(application: "checkout", appNamespace: "argocd")
        #expect(items.count == 2 && items[0].modified && items[1].namespace == nil)
        let diff = items[0].diff()
        #expect(diff.contains { $0.kind == .removed && $0.text.contains("replicas: 2") } && diff.contains { $0.kind == .added && $0.text.contains("replicas: 3") })
        let reqs = ProxyCapturingProtocol.requests(host: host)
        #expect(reqs.count == 1 && reqs[0].method == "GET")
        #expect(reqs[0].headers["Cookie"] == "argocd.token=tok123")
        #expect(reqs[0].url.path.hasSuffix("/services/https:argocd-server:443/proxy/api/v1/applications/checkout/managed-resources"))
    }

    @Test func argoUnauthorizedTriesTheHeaderOnceThenFails() async throws {
        let (client, host) = make()
        ProxyCapturingProtocol.script(host: host, [(401, "{}"), (401, "{}")])
        let api = ArgoAPI(client: client, location: ArgoServiceLocation(), token: "tok")
        await #expect(throws: ArgoAPIError.unauthorized) { _ = try await api.managedResources(application: "x") }
        #expect(ProxyCapturingProtocol.requests(host: host).count == 2)
    }

    @Test func demoClientProxiesGetOnly() async {
        let demo = DemoKubeClient(config: DemoFleet.configs[0])
        await #expect(throws: KubeError.self) { _ = try await demo.proxyRequest(method: "POST", namespace: "n", service: "s", port: "80", path: "x", query: [:], headers: [:], body: nil) }
    }
}
