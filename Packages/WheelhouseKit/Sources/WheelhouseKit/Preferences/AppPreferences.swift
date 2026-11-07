import Foundation
import Observation

public enum AppGroup {
    /// The iOS app group. Used whenever Info.plist has no `WHAppGroup` (every iOS target).
    public static let defaultIdentifier = "group.com.ahmadrezaei.wheelhouse"

    /// `WHAppGroup` from the bundle's Info.plist when present and non-empty (Mac: a team-prefixed group), else ``defaultIdentifier``.
    public static func identifier(in bundle: Bundle) -> String {
        guard let custom = bundle.object(forInfoDictionaryKey: "WHAppGroup") as? String else { return defaultIdentifier }
        let trimmed = custom.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? defaultIdentifier : trimmed
    }

    private static let mainIdentifier: String = identifier(in: .main)

    /// The app group of this process: the installed development-isolation override if any (Mac, gate on), else `WHAppGroup`.
    public static var identifier: String { IsolationOverride.current?.appGroup ?? mainIdentifier }
    /// Shared container, falling back to Application Support when the entitlement is unavailable (previews, tests, unsigned simulator builds).
    public static var containerURL: URL {
        if let url = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier) { return url }
        let fallback = URL.applicationSupportDirectory.appending(path: "Wheelhouse", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }
    public static var defaults: UserDefaults { UserDefaults(suiteName: identifier) ?? .standard }
}

public enum NamespaceBehavior: String, Codable, CaseIterable, Sendable { case rememberPerCluster, alwaysAll }
public enum LockTimeout: Int, Codable, CaseIterable, Sendable {
    case immediately = 0, oneMinute = 60, fiveMinutes = 300, fifteenMinutes = 900
}

/// User preferences stored in the App Group defaults. Add new keys here; views bind with `@Bindable`.
@MainActor @Observable
public final class AppPreferences {
    private let defaults: UserDefaults

    public var appLockEnabled: Bool { didSet { defaults.set(appLockEnabled, forKey: "appLockEnabled") } }
    public var lockTimeout: LockTimeout { didSet { defaults.set(lockTimeout.rawValue, forKey: "lockTimeout") } }
    public var hideInAppSwitcher: Bool { didSet { defaults.set(hideInAppSwitcher, forKey: "hideInAppSwitcher") } }
    public var revealSecretsOncePerSession: Bool { didSet { defaults.set(revealSecretsOncePerSession, forKey: "revealSecretsOncePerSession") } }
    /// Seconds between automatic refreshes of fleet health; 0 = manual.
    public var refreshInterval: Int { didSet { defaults.set(refreshInterval, forKey: "refreshInterval") } }
    public var namespaceBehavior: NamespaceBehavior { didSet { defaults.set(namespaceBehavior.rawValue, forKey: "namespaceBehavior") } }
    public var logFontSize: Double { didSet { defaults.set(logFontSize, forKey: "logFontSize") } }
    public var logMaxLines: Int { didSet { defaults.set(logMaxLines, forKey: "logMaxLines") } }
    public var terminalFontSize: Double { didSet { defaults.set(terminalFontSize, forKey: "terminalFontSize") } }
    public var useBinaryUnits: Bool { didSet { defaults.set(useBinaryUnits, forKey: "useBinaryUnits") } }
    public var alertsEnabled: Bool { didSet { defaults.set(alertsEnabled, forKey: "alertsEnabled") } }
    public var hideAlertDetailsOnLockScreen: Bool { didSet { defaults.set(hideAlertDetailsOnLockScreen, forKey: "hideAlertDetailsOnLockScreen") } }
    public var demoMode: Bool { didSet { defaults.set(demoMode, forKey: "demoMode") } }
    public var hasSeenWelcome: Bool { didSet { defaults.set(hasSeenWelcome, forKey: "hasSeenWelcome") } }

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            "refreshInterval": 30, "logFontSize": 12.0, "logMaxLines": 50_000, "terminalFontSize": 13.0,
            "useBinaryUnits": true, "alertsEnabled": true, "hideInAppSwitcher": true, "lockTimeout": 0,
            "namespaceBehavior": NamespaceBehavior.rememberPerCluster.rawValue,
        ])
        appLockEnabled = defaults.bool(forKey: "appLockEnabled")
        lockTimeout = LockTimeout(rawValue: defaults.integer(forKey: "lockTimeout")) ?? .immediately
        hideInAppSwitcher = defaults.bool(forKey: "hideInAppSwitcher")
        revealSecretsOncePerSession = defaults.bool(forKey: "revealSecretsOncePerSession")
        refreshInterval = defaults.integer(forKey: "refreshInterval")
        namespaceBehavior = NamespaceBehavior(rawValue: defaults.string(forKey: "namespaceBehavior") ?? "") ?? .rememberPerCluster
        logFontSize = defaults.double(forKey: "logFontSize")
        logMaxLines = defaults.integer(forKey: "logMaxLines")
        terminalFontSize = defaults.double(forKey: "terminalFontSize")
        useBinaryUnits = defaults.bool(forKey: "useBinaryUnits")
        alertsEnabled = defaults.bool(forKey: "alertsEnabled")
        hideAlertDetailsOnLockScreen = defaults.bool(forKey: "hideAlertDetailsOnLockScreen")
        demoMode = defaults.bool(forKey: "demoMode")
        hasSeenWelcome = defaults.bool(forKey: "hasSeenWelcome")
    }
}
