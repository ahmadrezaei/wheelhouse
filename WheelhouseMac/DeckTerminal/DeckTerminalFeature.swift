import SwiftUI
import WheelhouseKit

/// Stub. M5b replaces the contents of this file (and only this folder).
enum DeckTerminalFeature: WheelhouseFeature {
    static var id: FeatureID { .deckTerminal }
    static var title: String { "Deck Terminal" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .deckTerminal = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Deck Terminal", milestone: "M5b")
    }
}
