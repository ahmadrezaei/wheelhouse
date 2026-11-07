import Foundation
import Synchronization
@testable import WheelhouseKit

/// Settings with explicit per-cluster choices.
struct StaticToolboxSettings: ToolboxClusterSettings {
    var firstMate: [ClusterID: ClusterAccess] = [:]
    var beacon: [String: BeaconScope] = [:]
    func firstMateAccess(for cluster: ClusterConfig) -> ClusterAccess? { firstMate[cluster.id] }
    func beaconScope(client: String) -> BeaconScope { beacon[client] ?? BeaconScope() }
}

/// A source over fixed clusters that records which clusters anything tried to reach.
final class FakeToolboxSource: ToolboxClusterSource {
    let all: [ClusterConfig]
    private let touched = Mutex<[ClusterID]>([])
    private let makeAccess: @Sendable (ClusterConfig) -> ReadOnlyKubeAccess

    init(_ clusters: [ClusterConfig], access: @escaping @Sendable (ClusterConfig) -> ReadOnlyKubeAccess = FakeToolboxSource.standardAccess) {
        all = clusters
        makeAccess = access
    }

    /// Clusters whose client was requested (a hidden or asking cluster must never appear here).
    var touchedClusters: [ClusterID] { touched.withLock { $0 } }

    func clusters() async -> [ClusterConfig] { all }
    func access(for cluster: ClusterID) async -> ReadOnlyKubeAccess? {
        touched.withLock { $0.append(cluster) }
        return all.first { $0.id == cluster }.map(makeAccess)
    }
    func reachability(of cluster: ClusterID) async -> String { "reachable" }

    static let standardAccess: @Sendable (ClusterConfig) -> ReadOnlyKubeAccess = { cluster in
        ReadOnlyKubeAccess(
            discovery: { DiscoveryInfo(resources: []) },
            listRaw: { kind, _, _ in
                ["items": [["metadata": ["name": .string("web-\(cluster.id)"), "namespace": "apps"]]]]
            },
            getRaw: { kind, name, namespace in
                ["apiVersion": "apps/v1", "kind": .string(kind.kind), "metadata": ["name": .string(name), "namespace": .string(namespace ?? "")]]
            },
            logs: { _, _, _ in AsyncThrowingStream { $0.yield("started\n"); $0.finish() } },
            podMetrics: { _ in [] },
            nodeMetrics: { [] },
            canI: { _ in true })
    }
}

func testCluster(_ id: String, env: ClusterEnvironment = .development, readOnly: Bool = false) -> ClusterConfig {
    ClusterConfig(id: id, name: "\(id)-name", server: URL(string: "https://\(id).example.com")!, environment: env, readOnly: readOnly)
}

/// A valid input for each read tool against `cluster`.
func sampleInput(_ tool: ReadTool, cluster: String) -> JSONValue {
    let c: JSONValue = .string(cluster)
    switch tool {
    case .listClusters: return [:]
    case .search: return ["query": "web"]
    case .listResources: return ["cluster": c, "kind": "deployments"]
    case .getResource: return ["cluster": c, "kind": "deployment", "name": "web", "namespace": "apps"]
    case .getLogs: return ["cluster": c, "namespace": "apps", "pod": "web-1"]
    case .getEvents: return ["cluster": c]
    case .getMetrics: return ["cluster": c, "scope": "nodes"]
    case .describeOwnerChain: return ["cluster": c, "kind": "deployment", "name": "web", "namespace": "apps"]
    case .helmRelease, .helmGetRelease: return ["cluster": c, "release": "web"]
    case .helmListReleases, .gitopsStatus, .surveyFindings: return ["cluster": c]
    case .rbacCanI: return ["cluster": c, "verb": "get", "resource": "pods"]
    case .explainField: return ["cluster": c, "kind": "Deployment", "path": "spec"]
    }
}
