import Foundation

/// App-wide cluster lifecycle events. `ClusterRegistry` posts these when a cluster is removed or its
/// configuration/credentials change, so long-lived holders (port-forwards, shells, log streams, open
/// screens) can drop anything bound to the old client or config.
public enum ClusterEvents {
    public static let invalidated = Notification.Name("app.wheelhouse.clusterInvalidated")
    /// `userInfo` key carrying the affected `ClusterID` (String).
    public static let clusterIDKey = "clusterID"
    /// `userInfo` key: `true` when the cluster was removed, `false` when it was updated.
    public static let removedKey = "removed"

    @MainActor
    public static func postInvalidated(_ id: ClusterID, removed: Bool) {
        NotificationCenter.default.post(name: invalidated, object: nil,
                                        userInfo: [clusterIDKey: id, removedKey: removed])
    }

    public static func clusterID(from note: Notification) -> ClusterID? {
        note.userInfo?[clusterIDKey] as? ClusterID
    }

    public static func wasRemoved(_ note: Notification) -> Bool {
        (note.userInfo?[removedKey] as? Bool) ?? false
    }
}
