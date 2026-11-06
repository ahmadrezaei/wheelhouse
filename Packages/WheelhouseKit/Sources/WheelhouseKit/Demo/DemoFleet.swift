import Foundation

/// The mock fleet used for Demo mode, previews and UI tests.
public enum DemoFleet {
    public static let prodID = "demo-prod-eu-west"
    public static let stagingID = "demo-staging"
    public static let homelabID = "demo-homelab-k3s"
    public static let offlineID = "demo-edge-oslo"

    public static let configs: [ClusterConfig] = [
        ClusterConfig(id: prodID, name: "prod-eu-west", server: URL(string: "https://prod-eu-west.demo.wheelhouse.app:6443")!,
                      environment: .production, readOnly: false, defaultNamespace: nil, color: .pink, provider: "EKS", region: "eu-west-1", isDemo: true),
        ClusterConfig(id: stagingID, name: "staging", server: URL(string: "https://staging.demo.wheelhouse.app:6443")!,
                      environment: .staging, color: .indigo, provider: "GKE", region: "europe-west4", isDemo: true),
        ClusterConfig(id: homelabID, name: "homelab-k3s", server: URL(string: "https://192.168.1.20:6443")!,
                      environment: .personal, color: .green, provider: "k3s", region: "home", isDemo: true),
        ClusterConfig(id: offlineID, name: "edge-oslo", server: URL(string: "https://edge-oslo.demo.wheelhouse.app:6443")!,
                      environment: .development, color: .gray, provider: "k3s", region: "oslo", isDemo: true),
    ]

    public static func client(for config: ClusterConfig) -> any KubeClientProtocol {
        DemoKubeClient(config: config)
    }

    /// Convenience for previews: a typed sample object from the demo fleet.
    public static func sample<T: KubeObject>(_ type: T.Type, cluster: ClusterID = prodID) async -> [T] {
        guard let cfg = configs.first(where: { $0.id == cluster }) else { return [] }
        return (try? await DemoKubeClient(config: cfg).list(type).items) ?? []
    }
}
