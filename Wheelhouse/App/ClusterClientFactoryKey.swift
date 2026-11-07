import SwiftUI
import WheelhouseKit

/// How screens build a cluster client for a configuration they have not saved yet (Test Connection on the add and import screens).
/// iOS uses the default, which is exactly `LiveKubeClient`. The Mac injects the guarded factory, so a development build's Test
/// Connection can only reach the allowed test hosts, like every saved cluster.
private struct ClusterClientFactoryKey: EnvironmentKey {
    static let defaultValue: ClusterRegistry.ClientFactory = ClusterRegistry.defaultClientFactory
}

extension EnvironmentValues {
    var clusterClientFactory: ClusterRegistry.ClientFactory {
        get { self[ClusterClientFactoryKey.self] }
        set { self[ClusterClientFactoryKey.self] = newValue }
    }
}
