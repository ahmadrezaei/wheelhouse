import SwiftUI
import WheelhouseKit

/// How an origin looks, kept apart from the view so every ``ChangeOrigin`` case is covered by a test.
public struct OriginBadgeStyle: Equatable, Sendable {
    public enum Tone: Sendable, Equatable {
        /// A person pressed a button in Wheelhouse itself.
        case own
        /// An AI assistant, an MCP client or an extension asked for the change: the person must look closely.
        case external
        /// A command typed or pasted in the terminal.
        case terminal
    }

    public var title: String
    public var symbol: String
    public var tone: Tone
    /// Who exactly, when the origin says: the Beacon client, the extension pack, the command the terminal reported.
    public var detail: String?
    public var accessibilityLabel: String

    public static func style(for origin: ChangeOrigin) -> OriginBadgeStyle {
        func make(_ symbol: String, _ tone: Tone, detail: String? = nil) -> OriginBadgeStyle {
            let who = detail.map { " (\($0))" } ?? ""
            let label = tone == .own ? "Started in \(origin.badgeTitle)" : "Requested by \(origin.badgeTitle)\(who)"
            return OriginBadgeStyle(title: origin.badgeTitle, symbol: symbol, tone: tone, detail: detail, accessibilityLabel: label)
        }
        switch origin {
        case .ui: return make("hand.tap", .own)
        case .chartRoom: return make("shippingbox", .own)
        case .tides: return make("water.waves", .own)
        case .survey: return make("binoculars", .own)
        case .firstMate: return make("sparkles", .external)
        case .beacon(let client): return make("antenna.radiowaves.left.and.right", .external, detail: trimmed(client))
        case .terminal(_, let command): return make("terminal", .terminal, detail: command.flatMap(trimmed))
        case .rigging(let pack): return make("puzzlepiece.extension", .external, detail: trimmed(pack))
        }
    }

    private static func trimmed(_ text: String) -> String? {
        // Names come from other programs: drop control and format characters (bidi overrides, zero-width marks) first.
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.filter { $0.properties.generalCategory != .control && $0.properties.generalCategory != .format }))
        let t = clean.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}

/// Shows where a change request came from (ARCHITECTURE-MAC sections 1.5 and 9.2). Origins other than the app's own screens
/// are tinted as a warning and name the requester when they can.
public struct OriginBadge: View {
    private let style: OriginBadgeStyle

    public init(_ origin: ChangeOrigin) { style = OriginBadgeStyle.style(for: origin) }

    public var body: some View {
        HStack(spacing: 4) {
            Label(style.title, systemImage: style.symbol)
            if let detail = style.detail {
                Text(detail).fontWeight(.regular).lineLimit(1)
            }
        }
        .font(.caption.weight(.semibold))
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(background))
        .foregroundStyle(foreground)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(style.accessibilityLabel)
    }

    private var background: Color {
        switch style.tone {
        case .own: Color.whQuaternaryFill
        case .external: Palette.warning.opacity(0.18)
        case .terminal: Palette.info.opacity(0.16)
        }
    }

    private var foreground: Color {
        switch style.tone {
        case .own: Color.secondary
        case .external: Palette.warningText
        case .terminal: Palette.infoText
        }
    }
}
