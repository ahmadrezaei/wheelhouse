#if os(macOS)
import Foundation
import WheelhouseKit

public extension DesktopClientFactory {
    /// What Gangway needs to open the upstream leg for a cluster: the same token source (exec plugin, token file or stored token) the
    /// cluster's own client uses, so a terminal's kubectl and the app authenticate the same way.
    func gangwayUpstream(config: ClusterConfig, secrets: ClusterSecrets, contactHeld: Bool) -> GangwayUpstream {
        GangwayUpstream(config: config, secrets: secrets, tokenSource: resolveTokenSource(for: config, secrets: secrets), contactHeld: contactHeld)
    }
}
#endif
