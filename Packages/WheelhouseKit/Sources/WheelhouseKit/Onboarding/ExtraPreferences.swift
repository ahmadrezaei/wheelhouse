import Foundation

/// Extra display preferences owned by the Settings feature (kept out of `AppPreferences` to avoid editing shared code).
public enum ExtraPreferences {
    public static var showManagedFields: Bool {
        get { AppGroup.defaults.bool(forKey: "showManagedFields") }
        set { AppGroup.defaults.set(newValue, forKey: "showManagedFields") }
    }
}
