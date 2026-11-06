import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Titled opaque card used by both dashboards.
struct DashCard<Content: View, Trailing: View>: View {
    let title: String
    let trailing: Trailing
    let content: Content
    init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }, @ViewBuilder content: () -> Content) {
        self.title = title
        self.trailing = trailing()
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            SectionHeader(title) { trailing }
            content
        }
        .whCard()
    }
}

/// Attention row with a deep link to the resource (or the cluster for cluster-level alerts).
struct AlertRow: View {
    let alert: DashboardAlert
    var clusterName: String?
    var isUnseen = false
    @Environment(AppRouter.self) private var router
    @Environment(\.routeColumn) private var column

    var body: some View {
        Button {
            AlertsSeen.shared.markSeen([alert.id])
            router.push(alert.resource.map { .resourceDetail($0) } ?? .cluster(alert.clusterID), from: column)
        } label: {
            ResourceRow(title: alert.title, subtitle: [clusterName, alert.detail].compactMap { $0 }.joined(separator: " · "),
                        lead: .symbol(alert.symbol, StatusTone(alert.severity)), trailing: alert.since.map { Format.age(from: $0) })
                .overlay(alignment: .topLeading) {
                    if isUnseen { Circle().fill(Palette.info).frame(width: 8, height: 8).offset(x: -4, y: 4).accessibilityHidden(true) }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(alert.severity.title). \(alert.title). \(clusterName.map { "\($0). " } ?? "")\(alert.detail)\(isUnseen ? ". Unseen" : "")")
        .accessibilityHint("Opens details")
    }
}

/// Warning event row: reason, count, age, message, involved object.
struct EventRow: View {
    let clusterID: ClusterID
    let event: KubeEvent
    var clusterName: String?

    private var ref: ResourceRef? {
        guard let kind = event.involvedObject.kind.flatMap(ResourceKind.lookup), let name = event.involvedObject.name else { return nil }
        return ResourceRef(clusterID: clusterID, kind: kind, namespace: kind.namespaced ? event.involvedObject.namespace : nil, name: name)
    }

    var body: some View {
        let content = VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.warning).imageScale(.small)
                Text(event.reason ?? "Warning").font(.subheadline.weight(.semibold))
                if let c = event.count, c > 1 { Text("×\(c)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                Spacer(minLength: 4)
                Text(Format.age(from: event.lastSeen)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            if let m = event.message { Text(m).font(.footnote).lineLimit(2).foregroundStyle(.primary) }
            Text([clusterName, [event.involvedObject.kind, event.involvedObject.name].compactMap { $0 }.joined(separator: "/")].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        if let ref { RouteLink(route: .resourceDetail(ref)) { content } } else { content }
    }
}

/// Donut of cluster health used by the Fleet card.
struct HealthDonut: View {
    struct Slice: Identifiable { var id: String { label }; var label: String; var count: Int; var color: Color }
    let slices: [Slice]
    let centerTitle: String
    let centerCaption: String

    var body: some View {
        ZStack {
            if slices.allSatisfy({ $0.count == 0 }) {
                Circle().stroke(Palette.fieldFill, lineWidth: 14)
            } else {
                Circle().stroke(Palette.fieldFill, lineWidth: 14)
                ForEach(Array(arcs.enumerated()), id: \.offset) { _, arc in
                    Circle().trim(from: arc.from, to: arc.to).stroke(arc.color, style: StrokeStyle(lineWidth: 14, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                }
            }
            VStack(spacing: 0) {
                Text(centerTitle).font(.title2.weight(.semibold).monospacedDigit())
                Text(centerCaption).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(7)
        .accessibilityHidden(true)
    }

    private var arcs: [(from: CGFloat, to: CGFloat, color: Color)] {
        let total = max(slices.reduce(0) { $0 + $1.count }, 1)
        var start: CGFloat = 0
        var out: [(CGFloat, CGFloat, Color)] = []
        for s in slices where s.count > 0 {
            let end = start + CGFloat(s.count) / CGFloat(total)
            out.append((start, max(start, end - 0.006), s.color))
            start = end
        }
        return out
    }
}

/// Compact "live"/source chip.
struct SourceChip: View {
    let text: String
    var live = false
    var body: some View {
        HStack(spacing: 5) {
            if live { LiveDot() }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Palette.fieldFill, in: Capsule())
    }
}

func shortUsage(cpu: Double?, allocatable: Double) -> String {
    guard let cpu else { return "–" }
    return "\(Quantity.formatCPU(cores: cpu)) of \(Quantity.formatCPU(cores: allocatable)) cores"
}
func shortUsage(bytes: Double?, allocatable: Double, binary: Bool = true) -> String {
    guard let bytes else { return "–" }
    return "\(Quantity.formatBytes(bytes, binary: binary)) of \(Quantity.formatBytes(allocatable, binary: binary))"
}
