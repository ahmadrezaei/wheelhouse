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

    /// The kubeconfig context a cluster came from; nil for clusters added another way (a token, a cloud discovery), which have no
    /// kubectl context to name. The display name is editable and never a context.
    static func kubectlContext(for config: ClusterConfig) -> String? {
        if case .kubeconfig(_, let context, _)? = config.origin { return context }
        return nil
    }

    /// POSIX single-quotes an argument unless it is made only of characters a shell leaves alone.
    static func shellQuoted(_ argument: String) -> String {
        if argument.range(of: "^[A-Za-z0-9@%+=:,./_-]+$", options: .regularExpression) != nil { return argument }
        return "'" + argument.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `kubectl get` for a kind, with the context (when there is one), as the menu copies it.
    static func kubectlCommand(kind: ResourceKind, namespace: String?, context: String?) -> String {
        let resource = kind.group.isEmpty ? kind.plural : "\(kind.plural).\(kind.group)"
        var parts = ["kubectl", "get", resource]
        if kind.namespaced { parts += namespace.map { ["-n", shellQuoted($0)] } ?? ["--all-namespaces"] }
        if let context { parts += ["--context", shellQuoted(context)] }
        return parts.joined(separator: " ")
    }

    /// The same for a namespace selection: one `-n` command per selected namespace, one per line so a failure in one does not stop
    /// the rest (a kind that is not namespaced, or All namespaces, is one command).
    static func kubectlCommand(kind: ResourceKind, selection: NamespaceSelection, context: String?) -> String {
        guard kind.namespaced, !selection.names.isEmpty else {
            return kubectlCommand(kind: kind, namespace: selection.single, context: context)
        }
        return selection.names.map { kubectlCommand(kind: kind, namespace: $0, context: context) }.joined(separator: "\n")
    }
}
