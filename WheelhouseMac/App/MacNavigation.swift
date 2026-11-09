import Foundation
import WheelhouseKit

/// Helpers for what a sidebar row or a deep link opens. The selection itself lives in the focused pane
/// (`WorkspaceWindowModel`, M4a): a row sets the pane's root destination, and the sidebar highlights the focused pane's root.
enum MacNavigation {
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

    /// `kubectl get` for a kind, with the context, as the menu copies it.
    static func kubectlCommand(kind: ResourceKind, namespace: String?, context: String) -> String {
        let resource = kind.group.isEmpty ? kind.plural : "\(kind.plural).\(kind.group)"
        var parts = ["kubectl", "get", resource]
        if kind.namespaced { parts += namespace.map { ["-n", $0] } ?? ["--all-namespaces"] }
        parts += ["--context", context]
        return parts.joined(separator: " ")
    }
}
