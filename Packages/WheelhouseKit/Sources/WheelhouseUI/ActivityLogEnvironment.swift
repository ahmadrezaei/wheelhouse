import SwiftUI
import WheelhouseKit

private struct ActivityLogKey: EnvironmentKey {
    static let defaultValue: any ActivityLogging = NoopActivityLog()
}

public extension EnvironmentValues {
    /// Where confirmed mutations are recorded. The default records nothing (iOS); the Mac app injects its SQLite log.
    var activityLog: any ActivityLogging {
        get { self[ActivityLogKey.self] }
        set { self[ActivityLogKey.self] = newValue }
    }
}
