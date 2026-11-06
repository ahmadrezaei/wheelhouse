import SwiftUI
import Testing
import WidgetKit
@testable import WheelhouseKit
@testable import WheelhouseUI

/// Renders widget views to PNGs under $WHEELHOUSE_SHOTS (when set) so they can be inspected visually.
@MainActor @Suite struct WidgetRenderTests {
    static let sizes: [(String, WidgetFamily, CGSize)] = [
        ("small", .systemSmall, CGSize(width: 170, height: 170)),
        ("medium", .systemMedium, CGSize(width: 364, height: 170)),
        ("large", .systemLarge, CGSize(width: 364, height: 382)),
    ]

    func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme, mode: WidgetRenderingMode = .fullColor, name: String, accessory: Bool = false) throws {
        guard let dir = ProcessInfo.processInfo.environment["WHEELHOUSE_SHOTS"] else { return }
        let bg: Color = scheme == .dark ? Color(white: 0.11) : Color(white: 0.96)
        let framed = view.padding(accessory ? 0 : 14).frame(width: size.width, height: size.height)
            .background(accessory ? Color.gray.opacity(0.4) : bg)
            .clipShape(RoundedRectangle(cornerRadius: accessory ? 12 : 24))
            .environment(\.colorScheme, scheme)
            .environment(\.widgetRenderingMode, mode)
        let r = ImageRenderer(content: framed.padding(8).background(scheme == .dark ? Color.black : Color.white))
        r.scale = 3
        if let data = r.uiImage?.pngData() {
            try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
            try data.write(to: URL(fileURLWithPath: dir).appending(path: "\(name)-\(scheme == .dark ? "dark" : "light").png"))
        }
    }

    @Test func rendersAll() throws {
        let snap = FleetSnapshot.sample
        let stale = { var s = FleetSnapshot.sample; s.generatedAt = Date().addingTimeInterval(-3 * 3600); return s }()
        for scheme in [ColorScheme.light, .dark] {
            for (n, f, size) in Self.sizes {
                try render(FleetWidgetView(snapshot: snap, family: f), size: size, scheme: scheme, name: "fleet-\(n)")
                if f != .systemLarge { try render(ClusterWidgetView(snapshot: snap, clusterID: "stg", family: f), size: size, scheme: scheme, name: "cluster-\(n)") }
                if f != .systemSmall { try render(FailingPodsWidgetView(snapshot: snap, clusterID: nil, family: f), size: size, scheme: scheme, name: "pods-\(n)") }
                if f != .systemLarge { try render(NodeStatusWidgetView(snapshot: snap, clusterID: nil, family: f), size: size, scheme: scheme, name: "nodes-\(n)") }
                try render(FleetWidgetView(snapshot: nil, family: f), size: size, scheme: scheme, name: "empty-\(n)")
            }
            try render(FleetWidgetView(snapshot: stale, family: .systemMedium), size: CGSize(width: 364, height: 170), scheme: scheme, name: "stale-medium")
            try render(FleetWidgetView(snapshot: snap, family: .systemMedium), size: CGSize(width: 364, height: 170), scheme: scheme, mode: .accented, name: "accented-medium")
            try render(FailingPodsWidgetView(snapshot: snap, clusterID: nil, family: .systemLarge), size: CGSize(width: 364, height: 382), scheme: scheme, mode: .accented, name: "accented-pods-large")
            try render(AccessoryWidgetView(snapshot: snap, clusterID: "stg", family: .accessoryCircular), size: CGSize(width: 76, height: 76), scheme: scheme, name: "acc-circular-gauge", accessory: true)
            try render(AccessoryWidgetView(snapshot: snap, clusterID: nil, family: .accessoryCircular), size: CGSize(width: 76, height: 76), scheme: scheme, name: "acc-circular-fail", accessory: true)
            try render(AccessoryWidgetView(snapshot: snap, clusterID: nil, family: .accessoryRectangular), size: CGSize(width: 172, height: 76), scheme: scheme, name: "acc-rect", accessory: true)
            try render(AccessoryWidgetView(snapshot: snap, clusterID: nil, family: .accessoryInline), size: CGSize(width: 172, height: 24), scheme: scheme, name: "acc-inline", accessory: true)
        }
    }

    @Test func deepLinkFormat() {
        #expect(WidgetLinks.cluster("abc")?.absoluteString == "wheelhouse://cluster/abc")
        #expect(WidgetLinks.pod(cluster: "abc", namespace: "shop", name: "api-1")?.absoluteString == "wheelhouse://cluster/abc/ns/shop/pods/api-1?view=logs")
        #expect(WidgetLinks.fleet(.sample)?.absoluteString == "wheelhouse://cluster/prod")
    }
}
