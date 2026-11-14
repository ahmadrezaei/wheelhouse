import Foundation
import WheelhouseKit

/// Where something opens: in the focused pane, a new tab (⌘), a split (⌥) or a new window (⇧). Shared by the Rail and Compass.
enum OpenPlacement: Equatable, Sendable { case here, newTab, split, newWindow }

extension WorkspaceWindowModel {
    /// Shows `destination` at `placement`.
    func show(_ destination: WorkspaceDestination, placement: OpenPlacement) {
        switch placement {
        case .here:
            let pane = focusedPaneID
            guard mayReplaceStack(of: pane) else { return }
            mutate { $0.setRoot(destination, in: pane) }
            focusedPaneChanged()
        case .newTab:
            openInNewTab(destination)
        case .split:
            split(.horizontal)
            let pane = focusedPaneID
            mutate { $0.setRoot(destination, in: pane) }
            focusedPaneChanged()
        case .newWindow:
            openInNewTab(destination)
            moveTabToNewWindow()
        }
    }

    /// A cluster item or result: the focused pane switches to the cluster KEEPING its view (Pods in payments on prod becomes Pods on
    /// staging, in All namespaces); a pane with no cluster of its own shows the cluster overview.
    func activate(cluster id: ClusterID, placement: OpenPlacement) {
        guard registry.config(for: id) != nil else { return }
        if placement == .here, let pane = focusedPane, pane.context.clusterID != nil {
            setCluster(id, namespace: nil, in: pane.id)
        } else {
            registry.select(id)
            show(WorkspaceDestination(.clusterOverview(id)), placement: placement)
        }
    }

    /// A namespace item: the pane's cluster and namespace change together.
    func activate(namespace: String, in cluster: ClusterID, placement: OpenPlacement) {
        guard registry.config(for: cluster) != nil else { return }
        if placement == .here, let pane = focusedPane, pane.context.clusterID != nil {
            setCluster(cluster, namespace: namespace, in: pane.id)
        } else {
            registry.select(cluster)
            registry.setNamespace(namespace, for: cluster)
            show(.route(.resourceList(cluster, .pod, namespace: namespace)), placement: placement)
        }
    }

    /// The destination Compass and the Rail open for an object.
    static func destination(for ref: ResourceRef) -> WorkspaceDestination {
        if ref.kind == .namespace { return .route(.resourceList(ref.clusterID, .pod, namespace: ref.name)) }
        return .route(.resourceDetail(ref))
    }
}

extension RailModel {
    /// ⌥⌘B: pins what the focused pane shows (an object, a namespace list, or the cluster).
    func pinSelection(of model: WorkspaceWindowModel) {
        guard let pane = model.focusedPane else { return }
        switch pane.top {
        case .route(.resourceDetail(let ref)), .route(.yaml(let ref)), .route(.logs(let ref, _, _)), .route(.shell(let ref, _)):
            pin(.resource(ref))
        case .route(.resourceList(let cluster, _, let namespace?)):
            pin(.namespace(namespace, in: cluster))
        case .station(let id):
            pin(.station(id))
        default:
            if let cluster = pane.context.clusterID ?? pane.stack.lazy.compactMap(\.clusterID).first { pin(.cluster(cluster)) }
        }
    }

    /// Activates a Rail item.
    func activate(_ item: RailItem, in model: WorkspaceWindowModel, placement: OpenPlacement, controller: WorkspaceController) {
        guard isAvailable(item) else { return }
        switch item.kind {
        case .cluster:
            if let id = item.clusterID { model.activate(cluster: id, placement: placement) }
        case .namespace:
            if let id = item.clusterID, let ns = item.namespace { model.activate(namespace: ns, in: id, placement: placement) }
        case .resource:
            if let ref = item.resource { model.show(WorkspaceWindowModel.destination(for: ref), placement: placement) }
        case .station:
            if let station = controller.store.stations.first(where: { $0.id.rawValue == item.stationID }) { controller.open(station: station) }
        }
    }
}
