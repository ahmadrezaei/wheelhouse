import Foundation
import WheelhouseKit
import WidgetKit

/// Keeps the widget snapshot (`FleetSnapshot` in the app group) current for the Mac widgets (DESIGN-MAC section 5, Widgets).
///
/// It owns no timer and no watch. The health monitors call ``consider(force:)`` at the end of a check they were running anyway (the
/// alert monitor with a window visible, Crow's Nest in menu-bar mode), so a hidden app never wakes just for a widget. A snapshot is
/// written when its content changed (the generation time and the restart counts are ignored, so a crash-looping pod does not force
/// a write every time) or when the last write is older than ``heartbeat`` (30 minutes, so the widget's "Updated" label and its
/// 2-hour stale dimming do not run out while the fleet is steady). Writes are at most one every ``minimumInterval`` (5 minutes);
/// `force` skips that floor only (a cluster was removed, or Demo mode toggled) and never writes unchanged content.
///
/// Demo clusters are not real: while Demo mode is on the snapshot is written empty, never the demo fleet. The snapshot type has no
/// secret or credential field, and this class adds nothing to it. The write goes through `WidgetDataStore`, which resolves the app
/// group through `AppGroup`, so a development build writes the isolated dev group and never the shipped one.
@MainActor
final class MacWidgetSnapshotWriter {
    static let minimumInterval: TimeInterval = 5 * 60
    static let heartbeat: TimeInterval = 30 * 60

    private let make: @MainActor (_ previous: FleetSnapshot?) -> FleetSnapshot
    private let write: (FleetSnapshot) throws -> Void
    private let reload: @MainActor () -> Void
    private let now: @Sendable () -> Date
    private(set) var lastWritten: FleetSnapshot?
    private(set) var lastWriteDate: Date?
    private(set) var writes = 0

    init(make: @escaping @MainActor (_ previous: FleetSnapshot?) -> FleetSnapshot, write: @escaping (FleetSnapshot) throws -> Void,
         reload: @escaping @MainActor () -> Void, now: @escaping @Sendable () -> Date = { Date() }) {
        self.make = make
        self.write = write
        self.reload = reload
        self.now = now
    }

    /// Writes the snapshot when it changed (or the heartbeat is due) and the interval allows. Returns whether a write happened.
    @discardableResult
    func consider(force: Bool = false) -> Bool {
        let date = now()
        let age = lastWriteDate.map { date.timeIntervalSince($0) }
        if !force, let age, age < Self.minimumInterval { return false }
        let built = make(lastWritten)
        let snapshot = built.isDemo ? FleetSnapshot(clusters: []) : built
        let heartbeatDue = age.map { $0 >= Self.heartbeat } ?? true
        if let lastWritten, !heartbeatDue, Self.sameContent(lastWritten, snapshot) { return false }
        do { try write(snapshot) } catch { return false }
        lastWritten = snapshot
        lastWriteDate = date
        writes += 1
        reload()
        return true
    }

    /// Equal apart from `generatedAt` and the restart counts, which change on every build or every crash.
    static func sameContent(_ a: FleetSnapshot, _ b: FleetSnapshot) -> Bool {
        normalized(a) == normalized(b)
    }

    private static func normalized(_ snapshot: FleetSnapshot) -> FleetSnapshot {
        var copy = snapshot
        copy.generatedAt = .distantPast
        for i in copy.clusters.indices {
            for j in copy.clusters[i].failingPodList.indices { copy.clusters[i].failingPodList[j].restarts = 0 }
        }
        return copy
    }
}

extension MacWidgetSnapshotWriter {
    /// The writer the app uses: the registry's health as the source, the app group file as the sink.
    static func live(registry: ClusterRegistry) -> MacWidgetSnapshotWriter {
        MacWidgetSnapshotWriter(
            // The usage gauges (CPU, memory) need a metrics call the Mac app does not make for this; the widget shows no gauge.
            make: { previous in registry.makeSnapshot(previous: previous ?? WidgetDataStore.read()) },
            write: { try WidgetDataStore.write($0) },
            reload: { WidgetCenter.shared.reloadAllTimelines() })
    }
}
