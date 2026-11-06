import SwiftUI
import WidgetKit
import WheelhouseKit
import WheelhouseUI

// Widgets read the FleetSnapshot the app / BGAppRefresh writes into the App Group. They never hold credentials or call the API (DESIGN.md §9).

private extension View {
    func widgetBackground() -> some View { containerBackground(for: .widget) { Color(uiColor: .secondarySystemGroupedBackground) } }
}

struct FleetHealthWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.wheelhouse.widget.fleet", provider: FleetProvider()) { e in
            FamilyView(kind: .fleet, entry: e).widgetBackground()
        }
        .configurationDisplayName("Fleet Health")
        .description("Which clusters need attention.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

enum WidgetKind { case fleet, cluster, pods, nodes, accessory }

/// Picks the right view for the family (a view can read `widgetFamily`; the widget closure can't).
struct FamilyView: View {
    @Environment(\.widgetFamily) private var family
    let kind: WidgetKind
    let entry: FleetEntry
    var body: some View {
        Group {
            switch kind {
            case .fleet: FleetWidgetView(snapshot: entry.snapshot, family: family, now: entry.date)
            case .cluster: ClusterWidgetView(snapshot: entry.snapshot, clusterID: entry.clusterID, family: family, now: entry.date)
            case .pods: FailingPodsWidgetView(snapshot: entry.snapshot, clusterID: entry.clusterID, family: family, now: entry.date)
            case .nodes: NodeStatusWidgetView(snapshot: entry.snapshot, clusterID: entry.clusterID, family: family, now: entry.date)
            case .accessory: AccessoryWidgetView(snapshot: entry.snapshot, clusterID: entry.clusterID, family: family)
            }
        }
        .padding(isAccessory ? 0 : 14)
    }
    private var isAccessory: Bool { [.accessoryCircular, .accessoryRectangular, .accessoryInline].contains(family) }
}

struct ClusterWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.wheelhouse.widget.cluster", intent: SelectClusterIntent.self, provider: ClusterProvider()) { e in
            FamilyView(kind: .cluster, entry: e).widgetBackground()
        }
        .configurationDisplayName("Cluster")
        .description("Health, CPU, memory and failing pods for one cluster.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct FailingPodsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.wheelhouse.widget.failingpods", intent: SelectClusterIntent.self, provider: ClusterProvider()) { e in
            FamilyView(kind: .pods, entry: e).widgetBackground()
        }
        .configurationDisplayName("Failing Pods")
        .description("Pods that need attention. Tap one to open its logs.")
        .supportedFamilies([.systemMedium, .systemLarge])
        .contentMarginsDisabled()
    }
}

struct NodeStatusWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.wheelhouse.widget.nodes", intent: SelectClusterIntent.self, provider: ClusterProvider()) { e in
            FamilyView(kind: .nodes, entry: e).widgetBackground()
        }
        .configurationDisplayName("Node Status")
        .description("Nodes ready and CPU per node.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "app.wheelhouse.widget.lockscreen", intent: SelectClusterIntent.self, provider: ClusterProvider()) { e in
            FamilyView(kind: .accessory, entry: e).containerBackground(for: .widget) { Color.clear }
        }
        .configurationDisplayName("Cluster Status")
        .description("CPU gauge, cluster summary or fleet status on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

@main
struct WheelhouseWidgetBundle: WidgetBundle {
    var body: some Widget {
        FleetHealthWidget()
        ClusterWidget()
        FailingPodsWidget()
        NodeStatusWidget()
        LockScreenWidget()
    }
}

#Preview("Fleet small", as: .systemSmall) { FleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Fleet medium", as: .systemMedium) { FleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Fleet large", as: .systemLarge) { FleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Empty", as: .systemSmall) { FleetHealthWidget() } timeline: { FleetEntry(date: .now, snapshot: nil) }
#Preview("Failing pods", as: .systemLarge) { FailingPodsWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
#Preview("Lock", as: .accessoryRectangular) { LockScreenWidget() } timeline: { FleetEntry(date: .now, snapshot: .sample) }
