import SwiftUI
import WheelhouseKit

private struct GitOpsOwnerKey: EnvironmentKey { static let defaultValue: GitOpsOwner? = nil }

public extension EnvironmentValues {
    /// The GitOps owner of the object a screen shows. nil until M9 injects the result of its detector (`GitOpsOwnership`).
    var gitOpsOwner: GitOpsOwner? {
        get { self[GitOpsOwnerKey.self] }
        set { self[GitOpsOwnerKey.self] = newValue }
    }
}

/// The ownership badge slot: the editor review sheet and the Chart Room release row place one. Empty (zero size) while no owner is
/// known, which is always true until M9 provides the real detector.
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
