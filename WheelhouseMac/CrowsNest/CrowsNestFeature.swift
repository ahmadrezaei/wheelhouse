import SwiftUI
import WheelhouseKit

/// Stub. M4b replaces the contents of this file (and only this folder).
enum CrowsNestFeature: WheelhouseFeature {
    static var id: FeatureID { .crowsNest }
    static var title: String { "Crow's Nest" }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Crow's Nest", milestone: "M4b")
    }
}
