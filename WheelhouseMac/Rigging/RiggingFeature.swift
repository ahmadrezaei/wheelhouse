import SwiftUI
import WheelhouseKit

/// Stub. M13 replaces the contents of this file (and only this folder).
enum RiggingFeature: WheelhouseFeature {
    static var id: FeatureID { .rigging }
    static var title: String { "Rigging" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .riggingView = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Rigging", milestone: "M13")
    }
}
