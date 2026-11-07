import Foundation

/// A command a feature contributes to the menu bar and to Compass (ARCHITECTURE-MAC §12.4). M1a freezes the shape; the actions
/// are wired by `MacCommands` (M1b) and `CommandRegistry` (M4b).
struct WorkspaceCommand: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var symbol: String?
    /// Key equivalent character, shown in the menu and by Compass.
    var key: String?
    var needsCommandModifier = true
}
