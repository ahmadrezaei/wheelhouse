import SwiftUI
import WheelhouseKit

/// Stub. M4a replaces the contents of this file (and only this folder).
enum ActivityFeature: WheelhouseFeature {
    static var id: FeatureID { .activity }
    static var title: String { "Activity" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .activity = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Activity", milestone: "M4a")
    }
}
