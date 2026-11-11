#if os(macOS)
import Foundation
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

private func release(manifest: String, hooks: [(name: String, manifest: String)] = []) throws -> HelmRelease {
    let json: [String: Any] = [
        "name": "web", "namespace": "shop", "version": 1,
        "info": ["status": "deployed"], "chart": ["metadata": ["name": "c", "version": "1.0.0"]],
        "manifest": manifest,
        "hooks": hooks.map { ["name": $0.name, "kind": "Job", "path": "t/h.yaml", "manifest": $0.manifest, "events": ["pre-install"]] as [String: Any] },
    ]
    return try HelmReleaseCodec.decode(payload: JSONSerialization.data(withJSONObject: json))
}

private let manifest = """
---
# Source: c/templates/cm.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: web-config
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: other
spec:
  selector:
    matchLabels: {app: web}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: web-reader
"""
private let hookManifest = """
apiVersion: batch/v1
kind: Job
metadata:
  generateName: web-migrate-
"""
private let crds = """
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.example.test
"""

@Suite("Helm grant plan")
struct HelmGrantTests {
    private func objects(_ input: HelmGrantPlan.Inputs) -> Set<GrantedObject> { HelmGrantPlan.build(input).objects }
    private let install = HelmOperation.install(release: "web", chart: "./c", version: nil, namespace: "shop", createNamespace: false)

    @Test("an install grants the rendered objects, hook objects, CRDs and the release records, and nothing else")
    func installSet() throws {
        let rendered = try release(manifest: manifest, hooks: [("migrate", hookManifest)])
        let set = objects(.init(operation: install, next: rendered, crdsYAML: crds))
        #expect(set.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "web-config")), "namespaced objects default to the release namespace")
        #expect(set.contains(GrantedObject(group: "apps", resource: "deployments", namespace: "other", name: "web")), "an explicit namespace wins")
        #expect(set.contains(GrantedObject(group: "rbac.authorization.k8s.io", resource: "clusterroles", namespace: nil, name: "web-reader")))
        #expect(set.contains(GrantedObject(group: "batch", resource: "jobs", namespace: "shop", generateNamePrefix: "web-migrate-")))
        #expect(set.contains(GrantedObject(group: "apiextensions.k8s.io", resource: "customresourcedefinitions", namespace: nil, name: "widgets.example.test")))
        #expect(set.contains(GrantedObject(resource: "secrets", namespace: "shop", namePrefix: "sh.helm.release.v1.web.v")))
        #expect(set.contains(GrantedObject(resource: "configmaps", namespace: "shop", namePrefix: "sh.helm.release.v1.web.v")))
        #expect(!set.contains { $0.resource == "namespaces" }, "no namespace unless --create-namespace")
        #expect(!set.contains { $0.createAnyName })
        #expect(set.count == 7)
    }

    @Test("--skip-crds drops the CRDs, --create-namespace adds the namespace")
    func skipAndCreate() throws {
        let rendered = try release(manifest: manifest)
        let skipped = objects(.init(operation: install, next: rendered, crdsYAML: crds, skipCRDs: true))
        #expect(!skipped.contains { $0.resource == "customresourcedefinitions" })
        let create = HelmOperation.install(release: "web", chart: "./c", version: nil, namespace: "shop", createNamespace: true)
        #expect(objects(.init(operation: create, next: rendered)).contains(GrantedObject(resource: "namespaces", name: "shop")))
    }

    @Test("an upgrade also grants everything in the current release, so helm can delete what the new revision drops")
    func upgradeSet() throws {
        let current = try release(manifest: manifest + "\n---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: old-secret\n")
        let next = try release(manifest: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: web-config\n")
        let op = HelmOperation.upgrade(release: "web", chart: "./c", version: nil, namespace: "shop", strategy: .reset)
        let set = objects(.init(operation: op, next: next, current: current))
        #expect(set.contains(GrantedObject(resource: "secrets", namespace: "shop", name: "old-secret")))
        #expect(set.contains(GrantedObject(group: "apps", resource: "deployments", namespace: "other", name: "web")))
    }

    @Test("a rollback and an uninstall are built from the current and target revisions")
    func rollbackAndUninstall() throws {
        let current = try release(manifest: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: now\n")
        let target = try release(manifest: "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: then\n")
        let rollback = objects(.init(operation: .rollback(release: "web", namespace: "shop", revision: 1), next: target, current: current))
        #expect(rollback.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "now")))
        #expect(rollback.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "then")))
        let uninstall = objects(.init(operation: .uninstall(release: "web", namespace: "shop", keepHistory: false), current: current))
        #expect(uninstall.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "now")))
        #expect(!uninstall.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "then")))
    }

    @Test("a request outside the set is refused by the object grant, a create by body name included")
    func outsideTheSet() throws {
        let rendered = try release(manifest: manifest, hooks: [("migrate", hookManifest)])
        let plan = HelmGrantPlan.build(.init(operation: install, next: rendered, crdsYAML: crds))
        let registry = SessionRegistry(gate: { DevSafetyPolicy(isActive: false) })
        let cluster = ClusterConfig(id: "k", name: "k", server: URL(string: "https://k.test:6443")!, environment: .production)
        let session = try registry.create(cluster: cluster, origin: .chartRoom(operation: "install"), scope: .objects, binding: .isolatedGroup(4242)).session
        let grants = GrantStore()
        grants.setObjects(session: session, objects: plan.objects)
        let peer = PeerProcess(pid: 4242, session: 4242, group: 4242)
        func covers(_ path: String, _ method: String, _ created: CreatedName? = nil) throws -> Bool {
            let shape = RequestClassifier.shape(of: try RequestClassifier.canonicalSegments(of: path))
            return grants.covers(GrantRequest(kind: .mutation, shape: shape, method: method, createdName: created), session: session, peer: peer)
        }
        #expect(try covers("/api/v1/namespaces/shop/configmaps", "POST", .name("web-config")))
        #expect(try !covers("/api/v1/namespaces/shop/configmaps", "POST", .name("somebody-elses")))
        #expect(try covers("/api/v1/namespaces/shop/secrets", "POST", .name("sh.helm.release.v1.web.v1")))
        #expect(try !covers("/api/v1/namespaces/kube-system/secrets", "POST", .name("sh.helm.release.v1.web.v1")))
        #expect(try covers("/apis/batch/v1/namespaces/shop/jobs", "POST", .generateName("web-migrate-")))
        #expect(try !covers("/apis/batch/v1/namespaces/shop/jobs", "POST", .generateName("other-")))
        #expect(try covers("/api/v1/namespaces/shop/configmaps/web-config", "DELETE"), "a listed object may be deleted")
        #expect(try !covers("/api/v1/namespaces/shop/configmaps/other", "DELETE"))
        #expect(try !covers("/api/v1/nodes/n1", "PATCH"))
        #expect(try covers("/apis/apiextensions.k8s.io/v1/customresourcedefinitions", "POST", .name("widgets.example.test")))
    }

    @Test("the review warns about immutable changes and PVC deletion")
    func warnings() throws {
        let old = try release(manifest: """
        apiVersion: apps/v1
        kind: Deployment
        metadata: {name: web}
        spec: {selector: {matchLabels: {app: a}}}
        ---
        apiVersion: v1
        kind: Service
        metadata: {name: svc}
        spec: {type: ClusterIP}
        ---
        apiVersion: v1
        kind: PersistentVolumeClaim
        metadata: {name: data}
        """)
        let new = try release(manifest: """
        apiVersion: apps/v1
        kind: Deployment
        metadata: {name: web}
        spec: {selector: {matchLabels: {app: b}}}
        ---
        apiVersion: v1
        kind: Service
        metadata: {name: svc}
        spec: {type: LoadBalancer}
        """)
        let op = HelmOperation.upgrade(release: "web", chart: "./c", version: nil, namespace: "shop", strategy: .reset)
        let text = HelmGrantPlan.build(.init(operation: op, next: new, current: old)).warnings.joined(separator: "\n")
        #expect(text.contains("selector changed"))
        #expect(text.contains("type changes from ClusterIP to LoadBalancer"))
        #expect(text.contains("PersistentVolumeClaim data will be deleted"))
        let uninstall = HelmGrantPlan.build(.init(operation: .uninstall(release: "web", namespace: "shop", keepHistory: false), current: old)).warnings
        #expect(uninstall.contains { $0.contains("PersistentVolumeClaim data") })
    }
}

@Suite("HelmCLI argv")
struct HelmCLITests {
    private func cli(_ version: HelmVersion) -> HelmCLI {
        HelmCLI(executable: URL(fileURLWithPath: "/bin/helm"), version: version, environment: EnvironmentBuilder(snapshot: nil, home: URL(fileURLWithPath: "/tmp/h")))
    }
    private let values = URL(fileURLWithPath: "/s/values.yaml")
    private let install = HelmOperation.install(release: "web", chart: "repo/web", version: "1.2.3", namespace: "shop", createNamespace: true)
    private let upgrade = HelmOperation.upgrade(release: "web", chart: "repo/web", version: nil, namespace: "shop", strategy: .reset)

    @Test("versions parse")
    func versions() {
        #expect(HelmVersion(parsing: "v3.11.2\n") == HelmVersion(3, 11, 2))
        #expect(HelmVersion(parsing: "4.0.0") == HelmVersion(4, 0, 0))
        #expect(HelmVersion(parsing: "v3.14.0-rc.1+g1") == HelmVersion(3, 14, 0))
        #expect(HelmVersion(parsing: "banana") == nil)
        #expect(HelmVersion(3, 9) < HelmVersion(3, 14) && HelmVersion(4, 0) > HelmVersion(3, 99))
    }

    @Test("render argv, per version")
    func render() throws {
        #expect(try cli(HelmVersion(3, 11, 2)).renderArguments(install, valuesFile: values)
            == ["install", "web", "repo/web", "--namespace", "shop", "--create-namespace", "--version", "1.2.3", "--values", "/s/values.yaml", "--dry-run", "--output", "json"])
        #expect(try cli(HelmVersion(3, 14, 0)).renderArguments(upgrade, valuesFile: values)
            == ["upgrade", "web", "repo/web", "--namespace", "shop", "--reset-values", "--values", "/s/values.yaml", "--dry-run=server", "--output", "json"])
        #expect(try cli(HelmVersion(4, 0, 0)).renderArguments(install, valuesFile: nil)
            == ["install", "web", "repo/web", "--namespace", "shop", "--create-namespace", "--version", "1.2.3", "--dry-run=server", "--output", "json"])
    }

    @Test("apply argv, per version and operation")
    func apply() throws {
        let options = HelmApplyOptions(wait: true, timeout: .seconds(300), rollbackOnFailure: true, skipCRDs: true)
        #expect(try cli(HelmVersion(3, 11, 2)).applyArguments(install, valuesFile: values, options: options)
            == ["install", "web", "repo/web", "--namespace", "shop", "--create-namespace", "--version", "1.2.3", "--values", "/s/values.yaml", "--skip-crds", "--atomic", "--wait", "--timeout", "300s"])
        #expect(try cli(HelmVersion(4, 0, 0)).applyArguments(upgrade, valuesFile: values, options: options)
            == ["upgrade", "web", "repo/web", "--namespace", "shop", "--reset-values", "--values", "/s/values.yaml", "--skip-crds", "--rollback-on-failure", "--wait", "--timeout", "300s"])
        let plain = HelmApplyOptions(wait: false, timeout: .seconds(60))
        #expect(try cli(HelmVersion(4, 0, 0)).applyArguments(.rollback(release: "web", namespace: "shop", revision: 2), valuesFile: nil, options: plain)
            == ["rollback", "web", "2", "--namespace", "shop", "--timeout", "60s"])
        #expect(try cli(HelmVersion(3, 17, 0)).applyArguments(.uninstall(release: "web", namespace: "shop", keepHistory: true), valuesFile: nil, options: options)
            == ["uninstall", "web", "--namespace", "shop", "--keep-history", "--wait", "--timeout", "300s"])
    }

    @Test("an option the detected helm lacks is refused")
    func refusals() {
        let keep = HelmOperation.upgrade(release: "web", chart: "c", version: nil, namespace: "shop", strategy: .resetThenReuse)
        #expect(throws: HelmCLIError.self) { try cli(HelmVersion(3, 11, 2)).renderArguments(keep, valuesFile: nil) }
        #expect(throws: HelmCLIError.self) { try cli(HelmVersion(3, 13, 0)).applyArguments(keep, valuesFile: nil, options: HelmApplyOptions()) }
        #expect(throws: Never.self) { try cli(HelmVersion(3, 14, 0)).renderArguments(keep, valuesFile: nil) }
        #expect(throws: HelmCLIError.self) { try cli(HelmVersion(4, 0, 0)).renderArguments(.uninstall(release: "w", namespace: "n", keepHistory: false), valuesFile: nil) }
    }

    @Test("values never reach argv, and the environment carries the session kubeconfig and no inherited KUBECONFIG")
    func environment() {
        let spec = cli(HelmVersion(3, 14, 0)).spec(arguments: ["list"], kubeconfig: URL(fileURLWithPath: "/s/kubeconfig"), timeout: .seconds(5), newSession: true)
        #expect(spec.environment["KUBECONFIG"] == "/s/kubeconfig")
        #expect(spec.newSession && spec.quitGroup == "helm")
        #expect(cli(HelmVersion(3, 14, 0)).spec(arguments: ["show"], kubeconfig: nil, timeout: .seconds(5)).environment["KUBECONFIG"] == nil)
        #expect(cli(HelmVersion(3, 14, 0)).showCRDsArguments(chart: "r/c", version: "1.0") == ["show", "crds", "r/c", "--version", "1.0"])
    }
}
#endif
