import SwiftUI
import WheelhouseKit

private struct GitOpsOwnershipKey: EnvironmentKey { static let defaultValue: any GitOpsOwnership = NoOwnership() }

public extension EnvironmentValues {
    /// The detector the ownership badge uses. `NoOwnership` unless the host app injects one (the Mac app injects
    /// `GitOpsOwnershipDetector`), so iOS shows no badge.
    var gitOpsOwnership: any GitOpsOwnership {
        get { self[GitOpsOwnershipKey.self] }
        set { self[GitOpsOwnershipKey.self] = newValue }
    }
}

private struct ResolveOwnerModifier: ViewModifier {
    let object: JSONValue?
    let cluster: ClusterID
    @Environment(\.gitOpsOwnership) private var detector
    @State private var owner: GitOpsOwner?

    func body(content: Content) -> some View {
        content
            .environment(\.gitOpsOwner, owner)
            .task(id: object) {
                guard let object else { owner = nil; return }
                owner = await detector.owner(of: object, cluster: cluster)
            }
    }
}

public extension View {
    /// Fills the descendants' ``OwnershipBadgeSlot`` from the injected detector, for the object `object` shows.
    func resolvingGitOpsOwner(of object: JSONValue?, cluster: ClusterID) -> some View {
        modifier(ResolveOwnerModifier(object: object, cluster: cluster))
    }
}
