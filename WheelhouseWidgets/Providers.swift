import AppIntents
import WidgetKit
import WheelhouseKit
import WheelhouseUI

struct FleetEntry: TimelineEntry {
    let date: Date
    let snapshot: FleetSnapshot?
    var clusterID: ClusterID?
}

/// Entries every 15 min for 2 h so the "Updated N min ago" label and the stale (> 2 h) state advance without the app running.
private func makeTimeline(snapshot: FleetSnapshot?, clusterID: ClusterID?) -> Timeline<FleetEntry> {
    let start = Date()
    let entries = (0...9).map { FleetEntry(date: start.addingTimeInterval(Double($0) * 15 * 60), snapshot: snapshot, clusterID: clusterID) }
    return Timeline(entries: entries, policy: .after(start.addingTimeInterval(2.5 * 3600)))
}

struct FleetProvider: TimelineProvider {
    func placeholder(in context: Context) -> FleetEntry { FleetEntry(date: .now, snapshot: .sample) }
    func getSnapshot(in context: Context, completion: @escaping (FleetEntry) -> Void) {
        completion(FleetEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetDataStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<FleetEntry>) -> Void) {
        completion(makeTimeline(snapshot: WidgetDataStore.read(), clusterID: nil))
    }
}

struct ClusterProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> FleetEntry { FleetEntry(date: .now, snapshot: .sample) }
    func snapshot(for configuration: SelectClusterIntent, in context: Context) async -> FleetEntry {
        FleetEntry(date: .now, snapshot: context.isPreview ? .sample : WidgetDataStore.read(), clusterID: configuration.cluster?.id)
    }
    func timeline(for configuration: SelectClusterIntent, in context: Context) async -> Timeline<FleetEntry> {
        makeTimeline(snapshot: WidgetDataStore.read(), clusterID: configuration.cluster?.id)
    }
}
