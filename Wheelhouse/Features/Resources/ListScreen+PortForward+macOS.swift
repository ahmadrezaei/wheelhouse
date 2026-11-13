import SwiftUI
import WheelhouseKit

/// Port Forward in a resource row's context menu (pods and services): one entry per port, plus "Port Forward…".
extension ListScreen {
    func portForwardActions(for row: ListRowModel, ref: ResourceRef) -> [KubeRowAction] {
        guard kind == .pod || kind == .service else { return [] }
        if case .refused = PortForwardGate.decide(session.config) { return [] }
        let ports = ForwardablePorts.ports(kind: kind, raw: row.object.raw)
        let router = router
        var out: [KubeRowAction] = [.separator]
        if ports.count == 1, let only = ports.first {
            out.append(KubeRowAction(title: "Port Forward", symbol: "arrow.left.arrow.right") { router.forward(ref, port: only.port) })
        } else {
            for port in ports.prefix(8) {
                out.append(KubeRowAction(title: "Port Forward \(port.title)", symbol: "arrow.left.arrow.right") { router.forward(ref, port: port.port) })
            }
        }
        out.append(KubeRowAction(title: "Port Forward…", symbol: "arrow.left.arrow.right") { router.forward(ref, configure: true) })
        return out
    }
}
