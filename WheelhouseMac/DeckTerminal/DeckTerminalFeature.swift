import SwiftUI
import WheelhouseKit

/// The Deck Terminal: a local shell guarded by Gangway (ARCHITECTURE-MAC section 3.4).
enum DeckTerminalFeature: WheelhouseFeature {
    static var id: FeatureID { .deckTerminal }
    static var title: String { "Deck Terminal" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .deckTerminal = destination { return true }
        return false
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        if case .deckTerminal(let spec) = destination { DeckTerminalPane(spec: spec) }
    }
}
