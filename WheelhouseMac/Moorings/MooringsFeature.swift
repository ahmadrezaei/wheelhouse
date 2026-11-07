import SwiftUI
import WheelhouseKit

/// Stub. M3 replaces the contents of this file (and only this folder).
enum MooringsFeature: WheelhouseFeature {
    static var id: FeatureID { .moorings }
    static var title: String { "Moorings" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .moorings = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Moorings", milestone: "M3")
    }
}
