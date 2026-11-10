import SwiftUI
import WheelhouseKit

/// The Activity view: a pane destination (`.activity`) and the Activity window share `ActivityView`.
enum ActivityFeature: WheelhouseFeature {
    static var id: FeatureID { .activity }
    static var title: String { "Activity" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .activity = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        ActivityView()
    }
}
