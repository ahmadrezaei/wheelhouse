import Foundation
import Observation

/// Observable wrapper so the Settings UI can bind to ``AlertSettings`` and persist every change under the same
/// ``AlertKeys`` the background engine reads. Replaces the old `AlertPreferences` / `AlertSettingsModel` pair.
@MainActor @Observable
public final class AlertSettingsEditor {
    public var settings: AlertSettings { didSet { settings.save(to: defaults) } }
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = AppGroup.defaults) {
        self.defaults = defaults
        settings = AlertSettings.load(from: defaults)
    }

    /// Re-reads the defaults (the master toggles live on `AppPreferences`).
    public func reload() { settings = AlertSettings.load(from: defaults) }
}
