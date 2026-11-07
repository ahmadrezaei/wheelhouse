import SwiftUI

#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// View and toolbar modifiers whose spelling differs between iOS and macOS. Call sites use these
/// instead of `#if os(...)`. iOS behaviour is exactly the underlying SwiftUI modifier.
public enum WHKeyboardKind: Sendable { case url, number }

public extension View {
    /// `.navigationBarTitleDisplayMode(.inline)` on iOS; a no-op on macOS.
    @ViewBuilder func whInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// `.textInputAutocapitalization(.never)` on iOS; a no-op on macOS.
    @ViewBuilder func whNoAutocapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    /// `.keyboardType(.URL / .numberPad)` on iOS; a no-op on macOS.
    @ViewBuilder func whKeyboard(_ kind: WHKeyboardKind) -> some View {
        #if os(iOS)
        keyboardType(kind == .url ? .URL : .numberPad)
        #else
        self
        #endif
    }

    /// Inset-grouped lists on iOS; the plain inset style on macOS.
    @ViewBuilder func whGroupedListStyle() -> some View {
        #if os(iOS)
        listStyle(.insetGrouped)
        #else
        listStyle(.inset)
        #endif
    }

    /// A solid navigation or toolbar background (iOS: navigation bar; macOS: window toolbar).
    @ViewBuilder func whToolbarBackground<S: ShapeStyle>(_ style: S, visible: Bool = true) -> some View {
        #if os(iOS)
        toolbarBackground(style, for: .navigationBar).toolbarBackground(visible ? .visible : .automatic, for: .navigationBar)
        #else
        toolbarBackground(style, for: .windowToolbar).toolbarBackground(visible ? .visible : .automatic, for: .windowToolbar)
        #endif
    }

    /// Search field in the navigation bar drawer on iOS; the default toolbar placement on macOS.
    @ViewBuilder func whSearchable(text: Binding<String>, prompt: LocalizedStringKey) -> some View {
        #if os(iOS)
        searchable(text: text, placement: .navigationBarDrawer(displayMode: .automatic), prompt: prompt)
        #else
        searchable(text: text, placement: .toolbar, prompt: prompt)
        #endif
    }
}

public extension ToolbarItemPlacement {
    static var whTrailing: ToolbarItemPlacement {
        #if os(iOS)
        .topBarTrailing
        #else
        .primaryAction
        #endif
    }

    static var whLeading: ToolbarItemPlacement {
        #if os(iOS)
        .topBarLeading
        #else
        .navigation
        #endif
    }
}

// MARK: - Colour

#if canImport(UIKit)
public typealias PlatformColor = UIColor
#else
public typealias PlatformColor = NSColor
#endif

public extension Color {
    /// The primary system background (iOS `systemBackground`, macOS window background).
    static var whSystemBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// Grouped list background (iOS `systemGroupedBackground`).
    static var whGroupedBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .systemGroupedBackground)
        #else
        Color(nsColor: .underPageBackgroundColor)
        #endif
    }

    /// Card background on a grouped surface (iOS `secondarySystemGroupedBackground`).
    static var whCardBackground: Color {
        #if canImport(UIKit)
        Color(uiColor: .secondarySystemGroupedBackground)
        #else
        Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// Hairline separator colour.
    static var whSeparator: Color {
        #if canImport(UIKit)
        Color(uiColor: .separator)
        #else
        Color(nsColor: .separatorColor)
        #endif
    }

    /// Faint fill for text fields and chips (iOS `quaternarySystemFill`).
    static var whQuaternaryFill: Color {
        #if canImport(UIKit)
        Color(uiColor: .quaternarySystemFill)
        #else
        Color(nsColor: .quaternarySystemFill)
        #endif
    }

    /// A colour that resolves to `light` or `dark` with the appearance.
    init(light: UInt32, dark: UInt32) {
        #if canImport(UIKit)
        self.init(uiColor: UIColor { traits in
            Self.platformRGB(traits.userInterfaceStyle == .dark ? dark : light)
        })
        #else
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return Self.platformRGB(isDark ? dark : light)
        })
        #endif
    }

    fileprivate static func platformRGB(_ hex: UInt32) -> PlatformColor {
        PlatformColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Pasteboard

public enum Pasteboard {
    /// Plain copy. With `localOnly` the string stays on this device (no Universal Clipboard) on iOS;
    /// macOS has no equivalent, so it behaves like a plain copy there.
    public static func copy(_ string: String, localOnly: Bool = false) {
        #if os(iOS)
        if localOnly {
            UIPasteboard.general.setItems([[UIPasteboard.typeAutomatic: string]], options: [.localOnly: true])
        } else {
            UIPasteboard.general.string = string
        }
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(string, forType: .string)
        #endif
    }

    /// Copy for secrets: kept on this device and removed after `clearAfter` seconds.
    /// iOS: local only with an expiry date. macOS: flagged concealed and transient for clipboard managers,
    /// then cleared after the delay if nothing else has been copied since. The Mac app's termination
    /// handler must also call `clearSensitiveIfUnchanged()` so a secret does not outlive the app (wired in M1a).
    public static func copySensitive(_ string: String, clearAfter seconds: TimeInterval = 60) {
        #if os(iOS)
        UIPasteboard.general.setItems([["public.utf8-plain-text": string]], options: [.localOnly: true, .expirationDate: Date().addingTimeInterval(seconds)])
        #else
        let pb = NSPasteboard.general
        pb.clearContents()
        let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
        let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
        pb.declareTypes([.string, concealed, transient], owner: nil)
        pb.setString(string, forType: .string)
        pb.setString("", forType: concealed)
        pb.setString("", forType: transient)
        sensitiveChangeCount = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            clearSensitiveIfUnchanged()
        }
        #endif
    }

    #if os(macOS)
    private nonisolated(unsafe) static var sensitiveChangeCount: Int?
    #endif

    /// Clears the pasteboard only if it still holds the last `copySensitive` value (the change count is
    /// unchanged). Called after the delay and, on macOS, from the app's termination handler. No-op on iOS,
    /// where the system expiry date handles it.
    public static func clearSensitiveIfUnchanged() {
        #if os(macOS)
        let pb = NSPasteboard.general
        if let count = sensitiveChangeCount, pb.changeCount == count { pb.clearContents() }
        sensitiveChangeCount = nil
        #endif
    }

    public static var hasString: Bool {
        #if os(iOS)
        UIPasteboard.general.hasStrings
        #else
        NSPasteboard.general.availableType(from: [.string]) != nil
        #endif
    }
}

// MARK: - Haptics

public enum Haptics {
    public enum Style: Sendable { case light, medium, heavy }
    public enum Outcome: Sendable { case success, warning, error }

    @MainActor public static func impact(_ style: Style = .medium) {
        #if os(iOS)
        let s: UIImpactFeedbackGenerator.FeedbackStyle = switch style { case .light: .light; case .medium: .medium; case .heavy: .heavy }
        UIImpactFeedbackGenerator(style: s).impactOccurred()
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
        #endif
    }

    @MainActor public static func notify(_ outcome: Outcome) {
        #if os(iOS)
        let t: UINotificationFeedbackGenerator.FeedbackType = switch outcome { case .success: .success; case .warning: .warning; case .error: .error }
        UINotificationFeedbackGenerator().notificationOccurred(t)
        #else
        NSHapticFeedbackManager.defaultPerformer.perform(.levelChange, performanceTime: .now)
        #endif
    }
}

// MARK: - Platform actions and info

public enum PlatformActions {
    /// The URL that opens this app's notification settings.
    public static var notificationSettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")
        #endif
    }

    /// The URL that opens the Face ID / Touch ID settings.
    public static var biometrySettingsURL: URL? {
        #if os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        URL(string: "x-apple.systempreferences:com.apple.Touch-ID-Settings.extension")
        #endif
    }
}

public enum PlatformInfo {
    /// The operating-system version as `ProcessInfo` reports it (for example "27.0" when the patch version is 0).
    public static var osVersionString: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "\(v.majorVersion).\(v.minorVersion)" + (v.patchVersion > 0 ? ".\(v.patchVersion)" : "")
    }
}
