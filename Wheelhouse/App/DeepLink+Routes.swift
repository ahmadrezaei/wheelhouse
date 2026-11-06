import Foundation
import WheelhouseKit

extension DeepLink {
    /// Routes to push, in order, to land on the target (e.g. detail then logs). Never contains `.shell`.
    var routes: [Route] {
        guard let ref = resourceRef else { return namespace == nil ? [.cluster(clusterID)] : [.resourceSections(clusterID)] }
        switch view {
        case "logs": return [.resourceDetail(ref), .logs(ref, container: container, previous: previous)]
        case "yaml": return [.resourceDetail(ref), .yaml(ref)]
        default: return [.resourceDetail(ref)]
        }
    }
}
