import SwiftUI
import WheelhouseKit

private struct GitOpsOwnerKey: EnvironmentKey { static let defaultValue: GitOpsOwner? = nil }

public extension EnvironmentValues {
    /// The GitOps owner of the object a screen shows. nil unless a host injects a detector (`gitOpsOwnership`) and a screen applies `resolvingGitOpsOwner`.
    var gitOpsOwner: GitOpsOwner? {
        get { self[GitOpsOwnerKey.self] }
        set { self[GitOpsOwnerKey.self] = newValue }
    }
}

/// The ownership badge slot: the editor review sheet and the Chart Room release row place one. Empty (zero size) while no owner is
/// known (always on iOS, which keeps `NoOwnership`).
public struct OwnershipBadgeSlot: View {
    @Environment(\.gitOpsOwner) private var owner

    public init() {}

    public var body: some View {
        if let owner {
            Label("Managed by \(owner.tool == .flux ? "Flux" : "Argo CD"): \(owner.name)", systemImage: "arrow.triangle.2.circlepath")
                .font(.footnote).foregroundStyle(Palette.infoText)
                .accessibilityLabel("Managed by \(owner.tool == .flux ? "Flux" : "Argo CD") \(owner.name)")
        }
    }
}
