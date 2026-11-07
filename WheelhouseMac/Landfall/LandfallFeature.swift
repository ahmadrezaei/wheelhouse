import SwiftUI
import WheelhouseKit

/// Stub. M10 replaces the contents of this file (and only this folder).
enum LandfallFeature: WheelhouseFeature {
    static var id: FeatureID { .landfall }
    static var title: String { "Landfall" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .landfall = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Landfall", milestone: "M10")
    }
}
