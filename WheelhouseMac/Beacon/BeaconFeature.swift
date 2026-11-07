import SwiftUI
import WheelhouseKit

/// Stub. M12 replaces the contents of this file (and only this folder).
enum BeaconFeature: WheelhouseFeature {
    static var id: FeatureID { .beacon }
    static var title: String { "Beacon" }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Beacon", milestone: "M12")
    }
}
