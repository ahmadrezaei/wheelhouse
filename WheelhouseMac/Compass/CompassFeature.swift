import SwiftUI
import WheelhouseKit

/// Stub. M4b replaces the contents of this file (and only this folder).
enum CompassFeature: WheelhouseFeature {
    static var id: FeatureID { .compass }
    static var title: String { "Compass" }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Compass", milestone: "M4b")
    }
}
