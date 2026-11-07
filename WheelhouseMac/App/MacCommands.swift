import SwiftUI

/// Menu-bar commands (DESIGN-MAC §8). M1a declares the type so `WheelhouseMacApp` has its `.commands`; M1b fills it:
/// ⌘0 Fleet, ⌘1–9 clusters, ⌘F, ⇧⌘N, ⌘N, and every feature's `commands`.
struct MacCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) { CheckForUpdatesCommand() }
    }
}
