import Foundation

/// The class of a request to a cluster, as far as the safety policy cares. M1a defines the classes the iOS app already
/// distinguishes; M5a adds the Gangway classes (stream, proxy, impersonation, dry-run delete) in
/// `MutationPolicy+Gangway.swift` without changing these cases.
public enum RequestClass: Hashable, Sendable {
    /// GET, LIST and WATCH.
    case read
    /// `SelfSubjectAccessReview` and `SelfSubjectRulesReview`: POSTs that are read-only in effect.
    case review
    /// Create, replace, patch, delete, eviction. `dryRun` requests are still refused on a read-only cluster (iOS behaviour).
    case mutation(dryRun: Bool)
    /// A pod shell or `kubectl exec` (WebSocket). Refused on a read-only cluster unless `allowExecInReadOnly`.
    case exec(interactive: Bool)
    case portForward
}
