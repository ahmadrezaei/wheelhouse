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

    // M4b: Crow's Nest, the Rail and the Compass index.
    /// Writes go to the defaults only while true. A performance scenario sets its own values with `transient`, which must never reach
    /// the person's (or the Debug domain's) saved preferences.
    @ObservationIgnored private var persists = true
    /// The menu bar item and its panel (DESIGN-MAC section 6.15).
    var showsCrowsNest: Bool { didSet { save(showsCrowsNest, "showsCrowsNest"); menuBarChanged?() } }
    /// Closing the last window leaves Crow's Nest running (no Dock icon). Only has an effect with the menu bar item on.
    var keepsRunningInMenuBar: Bool { didSet { save(keepsRunningInMenuBar, "keepsRunningInMenuBar"); menuBarChanged?() } }
    /// Called when the menu bar item or "keep running" changes (the app wires the monitors and the activation policy).
    @ObservationIgnored var menuBarChanged: (() -> Void)?
    /// What the menu bar glyph shows when something needs attention.
    var menuBarBadge: MenuBarBadge { didSet { save(menuBarBadge.rawValue, "menuBarBadge") } }
    /// Open Wheelhouse at login (the SMAppService login item; development builds never register it).
    var opensAtLogin: Bool { didSet { save(opensAtLogin, "opensAtLogin") } }
    /// The Rail strip under the toolbar (⇧⌘B).
    var showsRail: Bool { didSet { save(showsRail, "showsRail") } }
    /// The Rail was filled with the first clusters once; it is never refilled after that.
    var railPrefilled: Bool { didSet { save(railPrefilled, "railPrefilled") } }
    /// The person removed, renamed or moved a Rail item: new clusters no longer pin themselves.
    var railCustomised: Bool { didSet { save(railCustomised, "railCustomised") } }
    /// Clusters Crow's Nest checks besides Production, Staging and Rail clusters.
    var watchedClusterIDs: Set<String> { didSet { save(watchedClusterIDs.sorted(), "watchedClusterIDs") } }
    /// Clusters whose objects the Compass metadata index lists every 5 minutes (opt-in; other clusters contribute live items only).
    var compassIndexedClusterIDs: Set<String> { didSet { save(compassIndexedClusterIDs.sorted(), "compassIndexedClusterIDs"); compassIndexChanged?() } }
    /// Called when the set of clusters the Compass index lists changes (an opt-out prunes the index at once).
    @ObservationIgnored var compassIndexChanged: (() -> Void)?

    enum MenuBarBadge: String, CaseIterable, Sendable { case dot, dotAndCount, off }

    private func save(_ value: Any, _ key: String) { if persists { defaults.set(value, forKey: key) } }

    /// Runs `body` with persistence off (performance scenarios).
    func transient(_ body: (MacPreferences) -> Void) {
        persists = false
        body(self)
        persists = true
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        defaults.register(defaults: ["lockOnSleep": true, "lockOnScreenLock": true, "editorFontSize": 13.0])
        lockOnSleep = defaults.bool(forKey: "lockOnSleep")
        lockOnScreenLock = defaults.bool(forKey: "lockOnScreenLock")
        terminalScrollbackLines = SwiftTermSurface.Scrollback.configured(defaults: defaults)
        editorFontSize = defaults.double(forKey: "editorFontSize")
        showsCrowsNest = defaults.bool(forKey: "showsCrowsNest")
        keepsRunningInMenuBar = defaults.bool(forKey: "keepsRunningInMenuBar")
        menuBarBadge = MenuBarBadge(rawValue: defaults.string(forKey: "menuBarBadge") ?? "") ?? .dot
        opensAtLogin = defaults.bool(forKey: "opensAtLogin")
        showsRail = defaults.object(forKey: "showsRail") as? Bool ?? true
        railPrefilled = defaults.bool(forKey: "railPrefilled")
        railCustomised = defaults.bool(forKey: "railCustomised")
        watchedClusterIDs = Set(defaults.stringArray(forKey: "watchedClusterIDs") ?? [])
        compassIndexedClusterIDs = Set(defaults.stringArray(forKey: "compassIndexedClusterIDs") ?? [])
    }
}
