import Foundation
import WheelhouseKit
import WidgetKit

/// Keeps the widget snapshot (`FleetSnapshot` in the app group) current for the Mac widgets (DESIGN-MAC section 5, Widgets).
///
/// It owns no timer and no watch. The health monitors call ``consider()`` at the end of a check they were running anyway (the alert
/// monitor with a window visible, Crow's Nest in menu-bar mode), so a hidden app never wakes just for a widget. A snapshot is written
/// only when its content changed (the generation time is ignored) and at most once every ``minimumInterval`` (5 minutes); a change
/// that arrives sooner is kept and written by the first check after the interval.
///
/// The snapshot type has no secret or credential field (names, counts, fractions and a short issue title), and this class adds
/// nothing to it. The write goes through `WidgetDataStore`, which resolves the app group through `AppGroup`, so a development build
/// writes the isolated dev group and never the shipped one.
@MainActor
final class MacWidgetSnapshotWriter {
    static let minimumInterval: TimeInterval = 5 * 60

    private let make: @MainActor () -> FleetSnapshot
    private let write: (FleetSnapshot) throws -> Void
    private let reload: @MainActor () -> Void
    private let now: @Sendable () -> Date
    private(set) var lastWritten: FleetSnapshot?
    private(set) var lastWriteDate: Date?
    private(set) var writes = 0

    init(make: @escaping @MainActor () -> FleetSnapshot, write: @escaping (FleetSnapshot) throws -> Void,
         reload: @escaping @MainActor () -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.make = make
        self.write = write
        self.reload = reload
        self.now = now
    }

    /// Writes the snapshot when it changed and the interval allows. Returns whether a write happened.
    @discardableResult
    func consider() -> Bool {
        let date = now()
        if let lastWriteDate, date.timeIntervalSince(lastWriteDate) < Self.minimumInterval { return false }
        let snapshot = make()
        if let lastWritten, Self.sameContent(lastWritten, snapshot) { return false }
        do { try write(snapshot) } catch { return false }
        lastWritten = snapshot
        lastWriteDate = date
        writes += 1
        reload()
        return true
    }

    /// Equal apart from `generatedAt`, which changes on every build.
    static func sameContent(_ a: FleetSnapshot, _ b: FleetSnapshot) -> Bool {
        var a = a, b = b
        a.generatedAt = .distantPast
        b.generatedAt = .distantPast
        return a == b
    }
}

extension MacWidgetSnapshotWriter {
    /// The writer the app uses: the registry's health as the source, the app group file as the sink.
    static func live(registry: ClusterRegistry) -> MacWidgetSnapshotWriter {
        MacWidgetSnapshotWriter(
            make: { registry.makeSnapshot(previous: WidgetDataStore.read()) },
            write: { try WidgetDataStore.write($0) },
            reload: { WidgetCenter.shared.reloadAllTimelines() })
    }
}
