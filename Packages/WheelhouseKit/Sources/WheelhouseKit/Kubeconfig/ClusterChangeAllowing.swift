import Foundation

/// Who may turn read-only OFF for a cluster the app does not own outright (a discovered or imported kubeconfig context on the Mac).
/// The Cluster Settings screen asks this before it saves: a managed cluster leaves read-only only through ``allowChanges(id:environment:)``
/// (an explicitly chosen environment, and the owner's Touch ID or password for Production), never through a plain metadata save.
/// iOS has no implementation: every cluster there is saved directly.
public protocol ClusterChangeAllowing: Sendable {
    /// True when `id` is a cluster this seam manages (its read-only flag is owned by Moorings).
    func managesChanges(for id: ClusterID) -> Bool
    /// Leaves read-only with `environment` as the explicitly chosen one. Throws when the owner declines.
    func allowChanges(id: ClusterID, environment: ClusterEnvironment) async throws
}
