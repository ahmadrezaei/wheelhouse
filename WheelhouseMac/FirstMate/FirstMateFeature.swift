import SwiftUI
import WheelhouseKit

/// Stub. M11b replaces the contents of this file (and only this folder).
enum FirstMateFeature: WheelhouseFeature {
    static var id: FeatureID { .firstMate }
    static var title: String { "First Mate" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .firstMate = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "First Mate", milestone: "M11b")
    }
}
