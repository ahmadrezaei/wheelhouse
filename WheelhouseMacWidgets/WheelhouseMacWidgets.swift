import SwiftUI
import WidgetKit
import WheelhouseKit
import WheelhouseUI

// The desktop widgets read the FleetSnapshot the Mac app writes into the app group (MacWidgetSnapshotWriter). They hold no
// credentials, make no API call and never launch a cluster connection (DESIGN-MAC section 5). The views are the shared WheelhouseUI
// ones; the provider and the cluster intent are the iOS sources, which the extension target compiles too.

/// Picks the shared view for the widget's family (a view can read `widgetFamily`; the widget closure can't).
struct MacFamilyView: View {
    enum Kind { case fleet, cluster }
    @Environment(\.widgetFamily) private var family
    let kind: Kind
    let entry: FleetEntry

    var body: some View {
        Group {
            switch kind {
            case .fleet: FleetWidgetView(snapshot: entry.snapshot, family: family, now: entry.date)
            case .cluster: ClusterWidgetView(snapshot: entry.snapshot, clusterID: entry.clusterID, family: family, now: entry.date)
            }
        }
        .padding(14)
    }
}

struct MacFleetHealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.wheelhouse.mac.widget.fleet", provider: FleetProvider()) { entry in
            MacFamilyView(kind: .fleet, entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Fleet Health")
        .description("Which clusters need attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct MacClusterWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.wheelhouse.mac.widget.cluster", intent: SelectClusterIntent.self, provider: ClusterProvider()) { entry in
            MacFamilyView(kind: .cluster, entry: entry)
                .containerBackground(for: .widget) { Color(nsColor: .windowBackgroundColor) }
        }
        .configurationDisplayName("Cluster")
        .description("Health, nodes and failing pods for one cluster.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

@main
struct WheelhouseMacWidgetsBundle: WidgetBundle {
    var body: some Widget {
        MacFleetHealthWidget()
        MacClusterWidget()
    }
}

#Preview("Fleet small", as: .systemSmall) { MacFleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Fleet medium", as: .systemMedium) { MacFleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Fleet large", as: .systemLarge) { MacFleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Cluster small", as: .systemSmall) { MacClusterWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Cluster medium", as: .systemMedium) { MacClusterWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Cluster large", as: .systemLarge) { MacClusterWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Empty", as: .systemSmall) { MacFleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: nil) }
