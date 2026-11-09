import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// Landfall: discover managed clusters (EKS, GKE, AKS) through the user's own CLIs and add them read-only (ARCHITECTURE-MAC §8).
enum LandfallFeature: WheelhouseFeature {
    static var id: FeatureID { .landfall }
    static var title: String { "Landfall" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .landfall = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        LandfallScreen()
    }
}
