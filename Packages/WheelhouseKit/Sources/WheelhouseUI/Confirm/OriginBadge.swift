import SwiftUI
import WheelhouseKit

/// Shows where a change request came from (ARCHITECTURE-MAC §1.5, §9.2). M1a ships the plain capsule so every sheet can carry
/// it; M11a gives each `ChangeOrigin` its final visuals.
public struct OriginBadge: View {
    private let origin: ChangeOrigin

    public init(_ origin: ChangeOrigin) { self.origin = origin }

    public var body: some View {
        Label(origin.badgeTitle, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(origin.isNonUI ? Palette.warning.opacity(0.18) : Color.whQuaternaryFill))
            .foregroundStyle(origin.isNonUI ? Palette.warningText : Color.secondary)
            .accessibilityLabel("Requested by \(origin.badgeTitle)")
    }

    private var symbol: String {
        switch origin {
        case .ui: "hand.tap"
        case .chartRoom: "shippingbox"
        case .tides: "water.waves"
        case .survey: "binoculars"
        case .firstMate: "sparkles"
        case .beacon: "antenna.radiowaves.left.and.right"
        case .terminal: "terminal"
        case .rigging: "puzzlepiece.extension"
        }
    }
}
