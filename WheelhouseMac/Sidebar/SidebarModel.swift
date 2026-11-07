import Foundation
import Observation
import WheelhouseKit

/// The sidebar's state. M1a declares the type and its catalogue-derived structure; M1b adds discovery, RBAC hiding, badges and
/// the `NSOutlineView` tree (`SidebarTree`), and M4a adds focus-follow and per-window state.
@MainActor @Observable
final class SidebarModel {
    /// Free-text filter over rows and kind names (matches short names and singular forms).
    var filter = ""
    /// Clusters that are expanded. Collapsed clusters trigger no request and no timer (ARCHITECTURE-MAC §12.3.3).
    var expandedClusters: Set<ClusterID> = []
    /// Show Forbidden Kinds: hidden kinds are shown dimmed with a lock.
    var showsForbiddenKinds = false

    init() {}

    /// Catalogue kinds that match the current filter (name, singular, plural, short name).
    func matchingKinds(in group: SidebarGroup) -> [SidebarKindEntry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return group.kinds }
        return group.kinds.filter { entry in SidebarCatalog.filterTerms(for: entry.kind).contains { $0.contains(q) } }
    }
}
