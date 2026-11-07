import SwiftUI
import WheelhouseKit

/// Stub. M4b replaces the contents of this file (and only this folder).
enum RailFeature: WheelhouseFeature {
    static var id: FeatureID { .rail }
    static var title: String { "Rail" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .station = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Rail", milestone: "M4b")
    }
}
