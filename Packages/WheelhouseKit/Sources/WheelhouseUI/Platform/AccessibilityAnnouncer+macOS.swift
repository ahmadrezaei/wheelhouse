#if os(macOS)
import AppKit

/// Speaks a short status change to VoiceOver (toasts, banners, port-forward state) without moving focus. Does nothing when
/// VoiceOver is off. Tests replace `poster` to capture what was announced.
@MainActor
public enum AccessibilityAnnouncer {
    /// Receives the text and whether it is high priority (interrupts speech in progress).
    public static var poster: (String, Bool) -> Void = { text, high in
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let app = NSApplication.shared
        let element: Any = app.keyWindow ?? app.mainWindow ?? app
        NSAccessibility.post(element: element, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: (high ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
        ])
    }

    public static func announce(_ text: String, high: Bool = false) {
        guard !text.isEmpty else { return }
        poster(text, high)
    }
}
#endif
