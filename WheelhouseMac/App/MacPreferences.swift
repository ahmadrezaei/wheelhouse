import Foundation
import Observation

/// Mac-only preferences that do not exist on iOS (lock triggers, terminal and editor). Stored in the app's own defaults domain,
/// which is the Debug domain while the safety gate is active (the bundle ID ends in `.debug`).
@MainActor @Observable
final class MacPreferences {
    @ObservationIgnored private let defaults: UserDefaults

    /// Lock when the Mac goes to sleep (App Lock only).
    var lockOnSleep: Bool { didSet { defaults.set(lockOnSleep, forKey: "lockOnSleep") } }
    /// Lock when the screen locks (App Lock only).
    var lockOnScreenLock: Bool { didSet { defaults.set(lockOnScreenLock, forKey: "lockOnScreenLock") } }
    /// Terminal scrollback, 1,000 ... 20,000 lines (default 5,000).
    var terminalScrollbackLines: Int { didSet { defaults.set(SwiftTermSurface.Scrollback.clamp(terminalScrollbackLines), forKey: SwiftTermSurface.Scrollback.defaultsKey) } }
    /// Editor font size in points.
    var editorFontSize: Double { didSet { defaults.set(editorFontSize, forKey: "editorFontSize") } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["lockOnSleep": true, "lockOnScreenLock": true, "editorFontSize": 13.0])
        lockOnSleep = defaults.bool(forKey: "lockOnSleep")
        lockOnScreenLock = defaults.bool(forKey: "lockOnScreenLock")
        terminalScrollbackLines = SwiftTermSurface.Scrollback.configured(defaults: defaults)
        editorFontSize = defaults.double(forKey: "editorFontSize")
    }
}
