import Foundation
import WheelhouseKit

/// Resource ▸ Port Forward… (⌥⌘P, DESIGN-MAC section 8) and its Compass twin act on the service or pod the focused pane shows.
/// The command is off when the pane shows nothing forwardable, when the cluster is gone, and when `PortForwardGate` refuses
/// (read-only without exec allowed, Demo). It always opens the advanced form ("…"): the one-click path stays on the row actions,
/// and the form goes through the same launcher, so Production still asks for a button confirmation.
extension WorkspaceWindowModel {
    /// The service or pod the destination is about, nil for anything else (or a namespace-less reference).
    static func portForwardTarget(of destination: WorkspaceDestination?) -> ResourceRef? {
        guard case .route(let route)? = destination else { return nil }
        let ref: ResourceRef
        switch route {
        case .resourceDetail(let r), .yaml(let r), .logs(let r, _, _), .shell(let r, _), .portForward(let r): ref = r
        default: return nil
        }
        return (ref.kind == .service || ref.kind == .pod) && ref.namespace != nil ? ref : nil
    }

    /// What ⌥⌘P would forward in the focused pane, nil when the command is unavailable.
    func portForwardCommandTarget(registry: ClusterRegistry) -> ResourceRef? {
        guard let ref = Self.portForwardTarget(of: focusedPane?.top),
              let config = registry.config(for: ref.clusterID),
              case .allowed = PortForwardGate.decide(config) else { return nil }
        return ref
    }

    /// Opens the Port Forward form for the focused pane's target. Does nothing when there is none.
    func performPortForwardCommand(registry: ClusterRegistry) {
        guard let ref = portForwardCommandTarget(registry: registry) else { return }
        focusedRouter.forward(ref, port: nil, configure: true)
    }
}
