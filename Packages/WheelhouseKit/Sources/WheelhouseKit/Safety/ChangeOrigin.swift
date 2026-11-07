import Foundation

/// Where a mutation came from. Every mutation path is badged and audited (ARCHITECTURE-MAC §1.5).
///
/// `nil` on a ``ConfirmRequest`` means ``ui`` (the person at the keyboard pressed a button), so iOS call sites do not change.
public enum ChangeOrigin: Codable, Hashable, Sendable {
    case ui
    case chartRoom
    case tides
    case survey
    case firstMate(conversation: String)
    case beacon(client: String)
    case terminal(session: String, reportedCommand: String?)
    case rigging(pack: String)

    /// True for the origins where the person did not directly press the button that produced the request:
    /// AI proposals, MCP clients, the local terminal and extension packs. These get hardened confirmation sheets.
    public var isNonUI: Bool {
        switch self {
        case .ui, .chartRoom, .tides, .survey: false
        case .firstMate, .beacon, .terminal, .rigging: true
        }
    }

    /// Short label for ``OriginBadge``.
    public var badgeTitle: String {
        switch self {
        case .ui: "Wheelhouse"
        case .chartRoom: "Chart Room"
        case .tides: "Tides"
        case .survey: "Survey"
        case .firstMate: "First Mate"
        case .beacon: "Beacon"
        case .terminal: "Terminal"
        case .rigging: "Rigging"
        }
    }
}

public extension Optional where Wrapped == ChangeOrigin {
    /// A missing origin means the UI.
    var orUI: ChangeOrigin { self ?? .ui }
}
