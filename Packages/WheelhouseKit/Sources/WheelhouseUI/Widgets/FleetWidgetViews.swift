import SwiftUI
import WidgetKit
import WheelhouseKit

private func resolve(_ snapshot: FleetSnapshot, _ id: ClusterID?) -> FleetSnapshot.ClusterEntry? {
    if let id, let c = snapshot.clusters.first(where: { $0.id == id }) { return c }
    return snapshot.worstCluster
}

private struct ClusterLine: View {
    @Environment(\.widgetRenderingMode) private var mode
    let c: FleetSnapshot.ClusterEntry
    var showCPU = true
    var body: some View {
        HStack(spacing: 7) {
            StatusGlyph(entry: c)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                if showCPU {
                    BarMeter(value: c.isReachable ? c.cpuFraction : nil)
                }
            }
            Spacer(minLength: 4)
            Text(c.isReachable ? (showCPU && !c.isNotLoaded ? WidgetFormat.percent(c.cpuFraction) : c.statusWord) : "Offline")
                .font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(c.name), \(c.statusWord)" + (c.isReachable && c.cpuFraction != nil ? ", CPU \(WidgetFormat.percent(c.cpuFraction))" : ""))
    }
}

private struct Header: View {
    let symbol: String
    let title: String
    var trailing: String?
    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).widgetAccentable()
            Text(title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
            if let trailing { Spacer(minLength: 2); Text(trailing).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1) }
        }
        .foregroundStyle(.primary)
    }
}

private struct StatCell: View {
    let label: String
    let value: String
    var tint: Color = .primary
    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 17, weight: .bold).monospacedDigit()).foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Fleet health

public struct FleetWidgetView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: FleetSnapshot?
    let family: WidgetFamily
    let now: Date
    public init(snapshot: FleetSnapshot?, family: WidgetFamily, now: Date = Date()) { self.snapshot = snapshot; self.family = family; self.now = now }

    public var body: some View {
        if let snapshot, !snapshot.clusters.isEmpty {
            content(snapshot)
                .widgetURL(WidgetLinks.fleet(snapshot))
                .opacity(snapshot.isStale(at: now) ? 0.7 : 1)
        } else {
            WidgetEmptyState(family: family)
        }
    }

    private func ring(_ s: FleetSnapshot, size: CGFloat) -> some View {
        let healthy = s.clusters.filter { $0.status == .healthy && $0.isReachable }.count
        let worst = s.worstCluster?.status ?? .healthy
        return ZStack {
            RingGauge(value: Double(healthy) / Double(max(1, s.clusters.count)), lineWidth: size / 7, color: WidgetTint(mode: mode).color(s.needAttentionCount > 0 ? worst : s.unknownCount + s.unknownStatusCount > 0 ? .unknown : .healthy))
            VStack(spacing: 0) {
                Text("\(healthy)").font(.system(size: size * 0.36, weight: .bold).monospacedDigit())
                Text("of \(s.clusters.count)").font(.system(size: size * 0.16)).foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(healthy) of \(s.clusters.count) clusters healthy")
    }

    @ViewBuilder private func content(_ s: FleetSnapshot) -> some View {
        switch family {
        case .systemMedium:
            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 6) {
                    Header(symbol: "helm", title: "Fleet")
                    ring(s, size: 76)
                    Text(s.shortTitle).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                }
                .frame(width: 100, alignment: .leading)
                VStack(spacing: 0) {
                    ForEach(s.clusters.prefix(4)) { c in
                        WidgetLink(destination: WidgetLinks.cluster(c.id) ?? URL(fileURLWithPath: "/")) { ClusterLine(c: c).padding(.vertical, 4) }
                    }
                    Spacer(minLength: 0)
                    WidgetFooter(snapshot: s, now: now)
                }
            }
        case .systemLarge, .systemExtraLarge:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    ring(s, size: 58)
                    VStack(alignment: .leading, spacing: 2) {
                        Header(symbol: "helm", title: "Fleet")
                        Text(s.title).font(.system(size: 17, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                }
                VStack(spacing: 0) {
                    ForEach(s.clusters.prefix(5)) { c in
                        WidgetLink(destination: WidgetLinks.cluster(c.id) ?? URL(fileURLWithPath: "/")) { ClusterLine(c: c).padding(.vertical, 4) }
                    }
                }
                let items = attention(s)
                if !items.isEmpty {
                    Text("NEEDS ATTENTION").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.top, 2)
                    ForEach(items.prefix(4), id: \.id) { i in
                        WidgetLink(destination: i.url ?? URL(fileURLWithPath: "/")) {
                            HStack(spacing: 6) {
                                Image(systemName: i.symbol).font(.system(size: 11)).foregroundStyle(WidgetTint(mode: mode).color(i.status)).widgetAccentable()
                                Text(i.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(i.cluster).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
                WidgetFooter(snapshot: s, now: now)
            }
        default: // small
            VStack(alignment: .leading, spacing: 6) {
                Header(symbol: "helm", title: "Fleet")
                HStack(spacing: 8) {
                    ring(s, size: 46)
                    Text(s.shortTitle)
                        .font(.system(size: 13, weight: .bold)).lineLimit(2).minimumScaleFactor(0.8)
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(s.clusters.sorted { $0.attentionRank > $1.attentionRank }.prefix(3)) { c in
                        HStack(spacing: 5) {
                            StatusGlyph(entry: c, size: 10)
                            Text(c.name).font(.system(size: 12)).lineLimit(1)
                        }
                    }
                }
                Spacer(minLength: 0)
                WidgetFooter(snapshot: s, now: now, showDemo: false)
            }
        }
    }

    private struct Attn { var id: String; var title: String; var cluster: String; var status: HealthStatus; var symbol: String; var url: URL? }
    private func attention(_ s: FleetSnapshot) -> [Attn] {
        var out: [Attn] = []
        for c in s.clusters.sorted(by: { $0.attentionRank > $1.attentionRank }) where c.attentionRank >= HealthStatus.warning.rank {
            if c.failingPodList.isEmpty {
                out.append(Attn(id: c.id, title: c.topIssue ?? c.statusWord, cluster: c.name, status: c.status, symbol: c.displaySymbol, url: WidgetLinks.cluster(c.id)))
            } else {
                for p in c.failingPodList.prefix(2) {
                    out.append(Attn(id: "\(c.id)/\(p.id)", title: "\(p.name) · \(p.reason)", cluster: c.name, status: c.status, symbol: c.status.symbol,
                                    url: WidgetLinks.pod(cluster: c.id, namespace: p.namespace, name: p.name)))
                }
            }
        }
        return out
    }
}

// MARK: - Cluster (small/medium, configurable)

public struct ClusterWidgetView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: FleetSnapshot?
    let clusterID: ClusterID?
    let family: WidgetFamily
    let now: Date
    public init(snapshot: FleetSnapshot?, clusterID: ClusterID?, family: WidgetFamily, now: Date = Date()) {
        self.snapshot = snapshot; self.clusterID = clusterID; self.family = family; self.now = now
    }

    public var body: some View {
        if let snapshot, let c = resolve(snapshot, clusterID) {
            HStack(alignment: .top, spacing: 14) {
                main(snapshot, c)
                if family == .systemMedium || family == .systemLarge { pods(c).frame(maxWidth: .infinity, alignment: .topLeading) }
            }
            .widgetURL(WidgetLinks.cluster(c.id))
            .opacity(snapshot.isStale(at: now) ? 0.7 : 1)
        } else {
            WidgetEmptyState(family: family)
        }
    }

    private func main(_ s: FleetSnapshot, _ c: FleetSnapshot.ClusterEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                StatusGlyph(entry: c, size: 13)
                VStack(alignment: .leading, spacing: 0) {
                    Text(c.name).font(.system(size: 14, weight: .bold)).lineLimit(1).minimumScaleFactor(0.8)
                    Text(c.statusWord).font(.system(size: 12, weight: .semibold)).foregroundStyle(WidgetTint(mode: mode).text(c.isReachable ? c.status : .unknown))
                }
            }
            if c.isReachable && !c.isNotLoaded {
                HStack(spacing: 12) {
                    gauge("CPU", c.cpuFraction)
                    gauge("MEM", c.memoryFraction)
                }
                HStack(spacing: 10) {
                    Label("\(c.failingPods)", systemImage: "xmark.octagon").foregroundStyle(c.failingPods > 0 ? WidgetTint(mode: mode).text(.critical) : .secondary)
                    Label("\(c.nodesReady)/\(c.nodesTotal)", systemImage: "server.rack").foregroundStyle(.secondary)
                }
                .font(.system(size: 12, weight: .semibold).monospacedDigit()).labelStyle(.titleAndIcon)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(c.failingPods) failing pods, \(c.nodesReady) of \(c.nodesTotal) nodes ready")
            } else {
                Text(c.isNotLoaded ? "Not loaded yet" : c.topIssue ?? "Can't reach the API server").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            WidgetFooter(snapshot: s, now: now, showDemo: false)
        }
        .frame(width: family == .systemMedium || family == .systemLarge ? 140 : nil, alignment: .leading)
    }

    private func gauge(_ label: String, _ v: Double?) -> some View {
        VStack(spacing: 2) {
            ZStack {
                RingGauge(value: v ?? 0, lineWidth: 5, color: Palette.tint)
                Text(WidgetFormat.percent(v)).font(.system(size: 11, weight: .semibold).monospacedDigit())
            }
            .frame(width: 44, height: 44)
            Text(label).font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(WidgetFormat.percent(v))")
    }

    private func pods(_ c: FleetSnapshot.ClusterEntry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(c.failingPodList.isEmpty ? "NO FAILING PODS" : "FAILING PODS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            if c.failingPodList.isEmpty {
                Label(c.isNotLoaded ? "Not loaded yet" : c.isReachable ? "All workloads healthy" : "No data", systemImage: c.isNotLoaded ? "circle.dotted" : c.isReachable ? "checkmark.circle" : "wifi.slash")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            ForEach(c.failingPodList.prefix(4)) { p in
                WidgetLink(destination: WidgetLinks.pod(cluster: c.id, namespace: p.namespace, name: p.name) ?? URL(fileURLWithPath: "/")) {
                    PodLine(pod: p)
                }
            }
        }
    }
}

struct PodLine: View {
    @Environment(\.widgetRenderingMode) private var mode
    let pod: FleetSnapshot.FailingPod
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(pod.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
            HStack(spacing: 4) {
                Text(pod.reason).foregroundStyle(WidgetTint(mode: mode).text(.critical))
                if pod.restarts > 0 { Text("· \(pod.restarts)× restarts").foregroundStyle(.secondary) }
            }
            .font(.system(size: 10, weight: .semibold)).lineLimit(1)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pod.name), \(pod.reason)" + (pod.restarts > 0 ? ", \(pod.restarts) restarts" : ""))
    }
}

// MARK: - Failing pods (medium/large)

public struct FailingPodsWidgetView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: FleetSnapshot?
    let clusterID: ClusterID?
    let family: WidgetFamily
    let now: Date
    public init(snapshot: FleetSnapshot?, clusterID: ClusterID?, family: WidgetFamily, now: Date = Date()) {
        self.snapshot = snapshot; self.clusterID = clusterID; self.family = family; self.now = now
    }

    public var body: some View {
        if let snapshot, let c = resolve(snapshot, clusterID) {
            let large = family != .systemMedium
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    StatusGlyph(entry: c, size: 13)
                    Text(c.name).font(.system(size: 15, weight: .bold)).lineLimit(1)
                    EnvTag(env: c.environment)
                    Spacer(minLength: 0)
                }
                if large {
                    HStack {
                        StatCell(label: "FAILING", value: "\(c.failingPods)", tint: c.failingPods > 0 ? WidgetTint(mode: mode).text(.critical) : .primary)
                        StatCell(label: "CPU", value: WidgetFormat.percent(c.cpuFraction))
                        StatCell(label: "MEMORY", value: WidgetFormat.percent(c.memoryFraction))
                        StatCell(label: "NODES", value: "\(c.nodesReady)/\(c.nodesTotal)")
                    }
                }
                Text("FAILING PODS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                if c.failingPodList.isEmpty {
                    Label(c.isNotLoaded ? "Not loaded yet" : c.isReachable ? "No failing pods" : "Cluster unreachable", systemImage: c.isNotLoaded ? "circle.dotted" : c.isReachable ? "checkmark.circle" : "wifi.slash")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
                ForEach(c.failingPodList.prefix(large ? 5 : 2)) { p in
                    WidgetLink(destination: WidgetLinks.pod(cluster: c.id, namespace: p.namespace, name: p.name) ?? URL(fileURLWithPath: "/")) {
                        HStack {
                            PodLine(pod: p)
                            Spacer(minLength: 4)
                            Text(p.namespace).font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                }
                if large && !c.nodeCPU.isEmpty {
                    Text("NODE CPU").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    NodeStrip(values: c.nodeCPU)
                }
                Spacer(minLength: 0)
                HStack {
                    WidgetFooter(snapshot: snapshot, now: now, showDemo: false)
                    Spacer(minLength: 0); Text("Tap a pod for logs").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            .widgetURL(WidgetLinks.cluster(c.id))
            .opacity(snapshot.isStale(at: now) ? 0.7 : 1)
        } else {
            WidgetEmptyState(family: family)
        }
    }
}

struct NodeStrip: View {
    @Environment(\.widgetRenderingMode) private var mode
    let values: [Double]
    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(values.prefix(12).enumerated()), id: \.offset) { _, v in
                RoundedRectangle(cornerRadius: 3)
                    .fill(v <= 0 ? Color.secondary.opacity(0.25) : (mode == .fullColor ? (v > 0.85 ? Palette.critical : v > 0.7 ? Palette.warning : Palette.tint) : Color.primary.opacity(0.3 + 0.7 * v)))
                    .frame(height: 12)
                    .widgetAccentable()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Node CPU, " + values.map { WidgetFormat.percent($0) }.joined(separator: ", "))
    }
}

// MARK: - Node status

public struct NodeStatusWidgetView: View {
    @Environment(\.widgetRenderingMode) private var mode
    let snapshot: FleetSnapshot?
    let clusterID: ClusterID?
    let family: WidgetFamily
    let now: Date
    public init(snapshot: FleetSnapshot?, clusterID: ClusterID?, family: WidgetFamily, now: Date = Date()) {
        self.snapshot = snapshot; self.clusterID = clusterID; self.family = family; self.now = now
    }

    public var body: some View {
        if let snapshot, !snapshot.clusters.isEmpty {
            if family == .systemMedium {
                VStack(alignment: .leading, spacing: 4) {
                    Header(symbol: "server.rack", title: "Nodes", trailing: "\(snapshot.clusters.reduce(0) { $0 + $1.nodesReady })/\(snapshot.clusters.reduce(0) { $0 + $1.nodesTotal }) ready")
                    ForEach(snapshot.clusters.prefix(4)) { c in
                        WidgetLink(destination: WidgetLinks.cluster(c.id) ?? URL(fileURLWithPath: "/")) {
                            HStack(spacing: 8) {
                                StatusGlyph(entry: c, size: 11)
                                Text(c.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).frame(width: 110, alignment: .leading)
                                if c.nodeCPU.isEmpty { Spacer() } else { NodeStrip(values: c.nodeCPU) }
                                Text(c.isReachable && !c.isNotLoaded ? "\(c.nodesReady)/\(c.nodesTotal)" : "—").font(.system(size: 12, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(c.nodesReady < c.nodesTotal ? WidgetTint(mode: mode).text(.warning) : .secondary)
                                    .frame(width: 32, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    Spacer(minLength: 0)
                    WidgetFooter(snapshot: snapshot, now: now)
                }
                .widgetURL(WidgetLinks.fleet(snapshot))
            } else if let c = resolve(snapshot, clusterID) {
                VStack(alignment: .leading, spacing: 5) {
                    Header(symbol: "server.rack", title: "Nodes")
                    Text(c.name).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(c.isReachable && !c.isNotLoaded ? "\(c.nodesReady)" : "—").font(.system(size: 34, weight: .bold).monospacedDigit())
                        Text("/ \(c.nodesTotal) ready").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !c.nodeCPU.isEmpty { NodeStrip(values: c.nodeCPU) }
                    Spacer(minLength: 0)
                    WidgetFooter(snapshot: snapshot, now: now, showDemo: false)
                }
                .widgetURL(WidgetLinks.cluster(c.id))
            }
        } else {
            WidgetEmptyState(family: family)
        }
    }
}

// MARK: - Lock Screen accessories (iOS only)

#if os(iOS)
public struct AccessoryWidgetView: View {
    let snapshot: FleetSnapshot?
    let clusterID: ClusterID?
    let family: WidgetFamily
    public init(snapshot: FleetSnapshot?, clusterID: ClusterID?, family: WidgetFamily) { self.snapshot = snapshot; self.clusterID = clusterID; self.family = family }

    public var body: some View {
        if let snapshot, !snapshot.clusters.isEmpty {
            let c = resolve(snapshot, clusterID)
            switch family {
            case .accessoryCircular:
                if let c, c.isReachable, c.failingPods == 0, let cpu = c.cpuFraction {
                    Gauge(value: cpu) { Text("CPU") } currentValueLabel: { Text(Int((cpu * 100).rounded()), format: .number) }
                        .gaugeStyle(.accessoryCircular)
                        .accessibilityLabel("\(c.name) CPU \(WidgetFormat.percent(cpu))")
                } else {
                    ZStack {
                        AccessoryWidgetBackground()
                        VStack(spacing: 0) {
                            Image(systemName: c?.isNotLoaded == true ? "circle.dotted" : c?.isReachable == false ? "wifi.slash" : (c?.failingPods ?? 0) > 0 ? "xmark.octagon.fill" : "checkmark.circle.fill").font(.system(size: 14))
                            Text(c?.isNotLoaded == true ? "–" : c?.isReachable == false ? "Off" : "\(c?.failingPods ?? 0)").font(.system(size: 16, weight: .bold).monospacedDigit())
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(c?.name ?? "Cluster"), \(c?.failingPods ?? 0) failing pods")
                }
            case .accessoryRectangular:
                if c != nil, AppGroup.defaults.bool(forKey: AlertKeys.hideDetails) {
                    // "Hide details on Lock Screen": no cluster names or issue text.
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) { Image(systemName: "helm"); Text("Wheelhouse").fontWeight(.semibold) }.font(.system(size: 13)).widgetAccentable()
                        Text(snapshot.shortTitle).font(.system(size: 12)).lineLimit(2)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityLabel("Wheelhouse, \(snapshot.title)")
                } else if let c {
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 4) { Image(systemName: c.displaySymbol); Text(c.name).fontWeight(.semibold).lineLimit(1) }.font(.system(size: 13)).widgetAccentable()
                        Text(c.topIssue ?? (c.isNotLoaded ? "Not loaded yet" : c.isReachable ? "All workloads healthy" : "Unreachable")).font(.system(size: 12)).lineLimit(2)
                        Text(c.isNotLoaded ? "Waiting for first refresh" : c.isReachable ? "Nodes \(c.nodesReady)/\(c.nodesTotal) · CPU \(WidgetFormat.percent(c.cpuFraction))" : "Last seen \(WidgetFormat.updated(snapshot.generatedAt, now: Date()).dropFirst(8))")
                            .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .privacySensitive()
                }
            default: // inline
                Label(snapshot.title, systemImage: snapshot.needAttentionCount > 0 ? "exclamationmark.triangle" : snapshot.unknownCount + snapshot.unknownStatusCount > 0 ? "circle.dotted" : "checkmark.circle")
            }
        } else if family == .accessoryInline {
            Label("Wheelhouse: add a cluster", systemImage: "helm")
        } else {
            VStack(spacing: 1) { Image(systemName: "helm"); Text("No data").font(.system(size: 11)) }
        }
    }
}
#endif
