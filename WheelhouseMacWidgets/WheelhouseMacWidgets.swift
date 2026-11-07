import SwiftUI
import WidgetKit

/// Placeholder desktop widget (M14 fills the extension, sharing the iOS widget sources). It exists so the target, its sandbox
/// entitlement and the embedding are proven from M1a. It reads nothing and shows static text.
struct PlaceholderEntry: TimelineEntry { let date: Date }

struct PlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (PlaceholderEntry) -> Void) { completion(PlaceholderEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<PlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [PlaceholderEntry(date: .now)], policy: .never))
    }
}

struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "app.wheelhouse.mac.placeholder", provider: PlaceholderProvider()) { _ in
            Text("Wheelhouse").containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Wheelhouse")
        .description("Fleet health arrives in a later release.")
        .supportedFamilies([.systemSmall])
    }
}

@main
struct WheelhouseMacWidgetsBundle: WidgetBundle {
    var body: some Widget { PlaceholderWidget() }
}
