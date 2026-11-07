import Foundation
import Observation
import WheelhouseKit

/// What the content column shows (M1b: one window; M4a replaces it with `WorkspaceStore` tabs and panes). Sidebar clicks set it
/// directly; deep links and notification taps go through `AppRouter` and are mapped here by `MacShell`.
@MainActor @Observable
final class MacNavigation {
    var selection: SidebarDestination = .fleet

    /// The kind list a sidebar section opens when only the section is known (deep links into a section).
    static func destination(for item: SidebarItem) -> SidebarDestination {
        switch item {
        case .search: .search
        case .fleet: .fleet
        case .alerts: .alerts
        case .sessions: .sessions
        case .cluster(let id, .overview): .clusterOverview(id)
        case .cluster(let id, .section(let section)):
            ResourceKind.builtIn(in: section).first.map { .kind(id, $0) } ?? .workloadSummary(id)
        }
    }

    /// Opens a destination from a command or a link: clears both stacks (like a sidebar click) and selects the cluster it belongs to.
    func go(_ destination: SidebarDestination, router: AppRouter, registry: ClusterRegistry) {
        router.contentPath = []
        router.detailPath = []
        if let id = destination.clusterID { registry.select(id) }
        selection = destination
    }

    /// The cluster the current selection belongs to (for the focused cluster's auto-expansion).
    var clusterID: ClusterID? { selection.clusterID }

    /// `kubectl get` for a kind, with the context, as the menu copies it.
    static func kubectlCommand(kind: ResourceKind, namespace: String?, context: String) -> String {
        let resource = kind.group.isEmpty ? kind.plural : "\(kind.plural).\(kind.group)"
        var parts = ["kubectl", "get", resource]
        if kind.namespaced { parts += namespace.map { ["-n", $0] } ?? ["--all-namespaces"] }
        parts += ["--context", context]
        return parts.joined(separator: " ")
    }
}
