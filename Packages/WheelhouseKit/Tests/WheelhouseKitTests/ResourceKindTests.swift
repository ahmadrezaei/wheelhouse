import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct ResourceKindTests {
    @Test func corePaths() {
        #expect(ResourceKind.pod.collectionPath() == "/api/v1/pods")
        #expect(ResourceKind.pod.collectionPath(namespace: "kube-system") == "/api/v1/namespaces/kube-system/pods")
        #expect(ResourceKind.pod.itemPath(name: "web-1", namespace: "prod") == "/api/v1/namespaces/prod/pods/web-1")
        #expect(ResourceKind.pod.itemPath(name: "web-1", namespace: "prod", subresource: "log") == "/api/v1/namespaces/prod/pods/web-1/log")
    }

    @Test func groupedPaths() {
        #expect(ResourceKind.deployment.collectionPath(namespace: "x") == "/apis/apps/v1/namespaces/x/deployments")
        #expect(ResourceKind.deployment.itemPath(name: "api", namespace: "x", subresource: "scale") == "/apis/apps/v1/namespaces/x/deployments/api/scale")
        #expect(ResourceKind.cronJob.collectionPath() == "/apis/batch/v1/cronjobs")
        #expect(ResourceKind.nodeMetrics.collectionPath() == "/apis/metrics.k8s.io/v1beta1/nodes")
    }

    @Test func clusterScopedIgnoresNamespace() {
        #expect(ResourceKind.node.collectionPath(namespace: "ignored") == "/api/v1/nodes")
        #expect(ResourceKind.node.itemPath(name: "n1", namespace: "ignored") == "/api/v1/nodes/n1")
        #expect(ResourceKind.clusterRole.itemPath(name: "view") == "/apis/rbac.authorization.k8s.io/v1/clusterroles/view")
    }

    @Test func customResources() {
        let k = ResourceKind.custom(group: "cert-manager.io", version: "v1", kind: "Certificate", plural: "certificates", namespaced: true)
        #expect(k.collectionPath(namespace: "web") == "/apis/cert-manager.io/v1/namespaces/web/certificates")
        #expect(k.apiVersion == "cert-manager.io/v1")
        #expect(k.section == .custom)
    }

    @Test func idsAreUniqueAndLookupWorks() {
        let ids = ResourceKind.builtIn.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ResourceKind.lookup("deployment") == .deployment)
        #expect(ResourceKind.lookup("pods") == .pod)
        #expect(ResourceKind.lookup("nope") == nil)
    }

    @Test func pathEscapesNames() {
        #expect(ResourceKind.configMap.itemPath(name: "a b", namespace: "x") == "/api/v1/namespaces/x/configmaps/a%20b")
    }

    @Test func requestURLBuilding() async throws {
        let client = LiveKubeClient(config: ClusterConfig(name: "t", server: URL(string: "https://rancher.example.com/k8s/clusters/c-1")!), secrets: ClusterSecrets(token: "abc"))
        let url = try client.makeURL(path: "/api/v1/pods", query: [("labelSelector", "app in (a,b)"), ("limit", "5")])
        #expect(url.absoluteString == "https://rancher.example.com/k8s/clusters/c-1/api/v1/pods?labelSelector=app%20in%20%28a%2Cb%29&limit=5")
        let ws = try client.makeURL(path: "/x", websocket: true)
        #expect(ws.scheme == "wss")
    }
}
