import SwiftUI

private struct PaneIsVisibleKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while the screen's pane cannot be seen: its Mac window is miniaturised or covered, its tab is not the selected one, or it
    /// is parked behind a zoomed pane (ARCHITECTURE-MAC section 12.3.3). Screens stop drawing and stop periodic refreshes while it is
    /// false; streams keep filling their buffers. Nothing sets it on iOS, so there it is always true and nothing changes.
    var paneIsVisible: Bool {
        get { self[PaneIsVisibleKey.self] }
        set { self[PaneIsVisibleKey.self] = newValue }
    }
}
