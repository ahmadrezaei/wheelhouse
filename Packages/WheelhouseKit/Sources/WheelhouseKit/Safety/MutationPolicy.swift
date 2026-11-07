import Foundation

public enum PolicyVerdict: Equatable, Sendable {
    case pass
    case refuse(String)
    case confirm(requiresTyping: Bool)
}

/// The kind of exemption a request asks for from typed confirmation on Production.
public enum TypingExemption: Sendable, Equatable {
    /// An interactive pod shell (exec or attach with a TTY) or a port-forward keeps the button confirmation (decision 9).
    case interactiveShell
}

/// One policy for every path that can change a cluster: ``LiveKubeClient`` (read-only refusal), ``ConfirmRequest``
/// (typed confirmation) and, from M5a, Gangway. Its iOS answers are pinned by the existing tests.
public enum MutationPolicy {
    public static let readOnlyReason = "This cluster is read-only. Turn off read-only mode in cluster settings to make changes."

    /// What may happen to a request of `class` against `cluster`.
    public static func decide(_ requestClass: RequestClass, cluster: ClusterConfig, origin: ChangeOrigin?) -> PolicyVerdict {
        switch requestClass {
        case .read, .review:
            return .pass
        case .mutation:
            if cluster.readOnly { return .refuse(readOnlyReason) }
            return .confirm(requiresTyping: cluster.environment.requiresTypeToConfirm)
        case .exec(let interactive):
            if cluster.readOnly && !cluster.allowExecInReadOnly { return .refuse(readOnlyReason) }
            if interactive { return .confirm(requiresTyping: false) }
            return .confirm(requiresTyping: cluster.environment.requiresTypeToConfirm)
        case .portForward:
            if cluster.readOnly && !cluster.allowExecInReadOnly { return .refuse(readOnlyReason) }
            return .confirm(requiresTyping: false)
        }
    }

    /// Whether the person must type the confirmation text.
    ///
    /// - `alwaysRequireTyping` wins everywhere.
    /// - Otherwise only Production requires typing.
    /// - On Production, typing is required unless the request carries the interactive-shell exemption. A request whose origin is
    ///   an AI, MCP or extension origin can never be exempt: the exemption is ignored for `.firstMate`, `.beacon` and `.rigging`.
    public static func requiresTyping(cluster: ClusterConfig, origin: ChangeOrigin?, exemption: TypingExemption?, alwaysRequireTyping: Bool) -> Bool {
        if alwaysRequireTyping { return true }
        guard cluster.environment.requiresTypeToConfirm else { return false }
        guard let exemption else { return true }
        switch exemption {
        case .interactiveShell:
            switch origin {
            case .firstMate, .beacon, .rigging: return true
            default: return false
            }
        }
    }
}
