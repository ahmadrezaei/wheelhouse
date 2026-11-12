import SwiftUI
import WheelhouseKit

/// Rigging: declarative packs that add views, commands and health rules for custom resources (ARCHITECTURE-MAC section 11, DESIGN-MAC 6.14).
///
/// A pack is data. Its views read through the shared resource stores while on screen; its commands are inserted into a guarded Deck Terminal
/// (never run) or start a port-forward behind a ConfirmSheet; its health rules feed Alerts. Layout of Custom Resources sub-groups is
/// applied by the sidebar through `RiggingSidebarHook`, because the Custom Resources group is built from discovery rather than from nodes.
enum RiggingFeature: WheelhouseFeature {
    static var id: FeatureID { .rigging }
    static var title: String { "Rigging" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .riggingView = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        if case .riggingView(let ref) = destination { RiggingViewScreen(ref: ref) }
    }
}
