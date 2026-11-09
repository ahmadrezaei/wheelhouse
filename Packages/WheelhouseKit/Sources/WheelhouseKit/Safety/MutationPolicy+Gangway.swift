import Foundation

/// What a streaming (upgrade, exec, attach, port-forward) request is.
public enum GangwayStreamKind: Hashable, Sendable {
    /// `interactive` is true only when the query has `tty=true` and `stdin=true`.
    case exec(interactive: Bool)
    case attach(interactive: Bool)
    case portForward
    case otherUpgrade

    /// Interactive shells and port-forwards keep the button confirmation on Production; everything else is typed.
    public var isInteractiveOrForward: Bool {
        switch self {
        case .exec(let interactive), .attach(let interactive): interactive
        case .portForward: true
        case .otherUpgrade: false
        }
    }
}

/// The class of a request that reaches Gangway (ARCHITECTURE-MAC section 3.6, step 3). It is separate from ``RequestClass``
/// because the iOS app's classes are pinned by existing tests: a dry-run is refused on a read-only cluster there and passes here.
public enum GangwayClass: Hashable, Sendable {
    case read
    case review
    case dryRun
    case stream(GangwayStreamKind)
    /// `pods`, `services` or `nodes` `proxy`, any method (kept exactly as received).
    case proxy(method: String)
    case mutation
}

/// One `Impersonate-*` request header.
public struct ImpersonationHeader: Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A classified request: its class plus every impersonation header. Impersonation is a separate field so that no `switch` over the
/// class can drop it.
public struct GangwayRequestClass: Hashable, Sendable {
    public var kind: GangwayClass
    public var impersonation: [ImpersonationHeader]
    public init(kind: GangwayClass, impersonation: [ImpersonationHeader] = []) {
        self.kind = kind
        self.impersonation = impersonation
    }
}

public extension MutationPolicy {
    /// The Gangway table (ARCHITECTURE-MAC section 3.6, step 4), evaluated against the live cluster configuration.
    static func decide(gangway request: GangwayRequestClass, cluster: ClusterConfig, origin: ChangeOrigin?) -> PolicyVerdict {
        let production = cluster.environment.requiresTypeToConfirm
        if !request.impersonation.isEmpty, cluster.readOnly || production {
            return .refuse("Wheelhouse: impersonation is not allowed on \(cluster.name)")
        }
        switch request.kind {
        case .read, .review, .dryRun:
            return .pass
        case .stream(let kind):
            if cluster.readOnly, !(cluster.allowExecInReadOnly && kind != .otherUpgrade) {
                return .refuse("Wheelhouse: \(cluster.name) is read-only. Allow exec and port-forward in Cluster Settings.")
            }
            guard production else { return .pass }
            return .confirm(requiresTyping: !kind.isInteractiveOrForward)
        case .proxy(let method):
            if cluster.readOnly { return .refuse("Wheelhouse: \(cluster.name) is read-only. Proxy requests are not allowed.") }
            guard production else { return .pass }
            return .confirm(requiresTyping: !(method == "GET" || method == "HEAD"))
        case .mutation:
            if cluster.readOnly { return .refuse("Wheelhouse: \(cluster.name) is read-only. Allow changes in Cluster Settings.") }
            return production ? .confirm(requiresTyping: true) : .pass
        }
    }
}
