import SwiftUI
import WidgetKit
import WheelhouseKit

/// Shared helpers for widget views. The views live in WheelhouseUI so they can be rendered in unit tests;
/// the widget extension only supplies providers, intents and `containerBackground`.
public enum WidgetLinks {
    /// Same format as `DeepLink.url(for:)` in the app target: `wheelhouse://cluster/<id>[/ns/<ns>/pods/<name>][?view=logs]`.
    public static func cluster(_ id: ClusterID) -> URL? {
        var c = URLComponents(); c.scheme = "wheelhouse"; c.host = "cluster"; c.path = "/\(id)"; return c.url
    }
    public static func pod(cluster: ClusterID, namespace: String, name: String, logs: Bool = true) -> URL? {
        var c = URLComponents(); c.scheme = "wheelhouse"; c.host = "cluster"
        c.path = "/\(cluster)" + (namespace.isEmpty ? "" : "/ns/\(namespace)") + "/pods/\(name)"
        if logs { c.queryItems = [URLQueryItem(name: "view", value: "logs")] }
        return c.url
    }
    /// Where a fleet-level tap goes: the worst cluster (deep links address clusters, not the fleet).
    public static func fleet(_ snapshot: FleetSnapshot?) -> URL? {
        guard let worst = snapshot?.worstCluster else { return nil }
        return cluster(worst.id)
    }
}

public extension FleetSnapshot {
    /// Highest-severity cluster (unreachable counts as needing attention), ties by order.
    var worstCluster: ClusterEntry? {
        clusters.max { $0.attentionRank < $1.attentionRank }
    }
    func isStale(at now: Date) -> Bool { now.timeIntervalSince(generatedAt) > 2 * 3600 }
    func needAttention(at _: Date = Date()) -> Int { needAttentionCount }
    var fleetCPU: Double? {
        let v = clusters.compactMap(\.cpuFraction); return v.isEmpty ? nil : v.reduce(0, +) / Double(v.count)
    }
    /// Sample data for previews/tests.
    static var sample: FleetSnapshot {
        FleetSnapshot(generatedAt: Date().addingTimeInterval(-12 * 60), isDemo: true, clusters: [
            ClusterEntry(id: "prod", name: "prod-eu-west", environment: .production, status: .critical, nodesReady: 7, nodesTotal: 8, podsRunning: 212, podsTotal: 220, failingPods: 3,
                         cpuFraction: 0.61, memoryFraction: 0.68, topIssue: "payments-api CrashLoopBackOff",
                         failingPodList: [
                            .init(name: "payments-api-7d9f8c6b5-x2k4q", namespace: "payments", reason: "CrashLoopBackOff", restarts: 14),
                            .init(name: "ledger-sync-5c8d-m9p2z", namespace: "payments", reason: "OOMKilled", restarts: 6),
                            .init(name: "mailer-6b7f9-k2jq8", namespace: "comms", reason: "ImagePullBackOff", restarts: 0)],
                         nodeCPU: [0.82, 0.64, 0.55, 0.71, 0.4, 0.93, 0.33, 0.0]),
            ClusterEntry(id: "stg", name: "staging", environment: .staging, status: .healthy, nodesReady: 3, nodesTotal: 3, podsRunning: 64, podsTotal: 64, cpuFraction: 0.34, memoryFraction: 0.41, nodeCPU: [0.3, 0.4, 0.33]),
            ClusterEntry(id: "home", name: "homelab-k3s", environment: .personal, status: .warning, nodesReady: 2, nodesTotal: 3, podsRunning: 31, podsTotal: 33, failingPods: 1, cpuFraction: 0.72, memoryFraction: 0.55,
                         topIssue: "Node NotReady", failingPodList: [.init(name: "grafana-0", namespace: "monitoring", reason: "Pending", restarts: 0)], nodeCPU: [0.7, 0.8, 0.0]),
            ClusterEntry(id: "oslo", name: "edge-oslo", environment: .development, status: .unknown, isReachable: false, topIssue: "Cluster unreachable"),
        ])
    }
}

public extension FleetSnapshot.ClusterEntry {
    var attentionRank: Int { isReachable ? status.rank : max(status.rank, HealthStatus.warning.rank) }
    var statusWord: String { isReachable ? status.title : "Unreachable" }
    var displaySymbol: String { isReachable ? status.symbol : "wifi.slash" }
}

enum WidgetFormat {
    static func updated(_ date: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(date))
        if s < 90 { return "Updated just now" }
        if s < 3600 { return "Updated \(Int(s / 60)) min ago" }
        if s < 86400 { return "Updated \(Int(s / 3600)) h ago" }
        return "Updated \(Int(s / 86400)) d ago"
    }
    static func percent(_ f: Double?) -> String { f.map { "\(Int(($0 * 100).rounded()))%" } ?? "—" }
}

/// Status colour in full-colour mode; in accented/vibrant modes colour collapses and symbols carry meaning.
struct WidgetTint {
    let mode: WidgetRenderingMode
    func color(_ status: HealthStatus) -> Color { mode == .fullColor ? status.color : .primary }
    func text(_ status: HealthStatus) -> Color { mode == .fullColor ? status.textColor : .primary }
    var accent: Color { mode == .fullColor ? Palette.tint : .primary }
}

/// Small status dot with symbol so colour is never the only signal.
struct StatusGlyph: View {
    @Environment(\.widgetRenderingMode) private var mode
    let entry: FleetSnapshot.ClusterEntry
    var size: CGFloat = 12
    var body: some View {
        Image(systemName: entry.displaySymbol)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(WidgetTint(mode: mode).color(entry.isReachable ? entry.status : .unknown))
            .widgetAccentable()
            .frame(width: size + 2)
            .accessibilityHidden(true)
    }
}

struct RingGauge: View {
    @Environment(\.widgetRenderingMode) private var mode
    let value: Double
    var lineWidth: CGFloat = 6
    var color: Color = Palette.tint
    var body: some View {
        ZStack {
            Circle().stroke(.secondary.opacity(0.25), lineWidth: lineWidth)
            Circle().trim(from: 0, to: max(0.001, min(1, value)))
                .stroke(mode == .fullColor ? color : .primary, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .widgetAccentable()
        }
    }
}

struct BarMeter: View {
    @Environment(\.widgetRenderingMode) private var mode
    let value: Double?
    var color: Color = Palette.tint
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(.secondary.opacity(0.25))
                if let value { Capsule().fill(mode == .fullColor ? color : .primary).frame(width: max(3, g.size.width * min(1, value))).widgetAccentable() }
            }
        }
        .frame(height: 5)
    }
}

struct WidgetFooter: View {
    let snapshot: FleetSnapshot
    let now: Date
    var showDemo = true
    var body: some View {
        let stale = snapshot.isStale(at: now)
        HStack(spacing: 4) {
            if stale { Image(systemName: "clock.badge.exclamationmark") }
            Text(WidgetFormat.updated(snapshot.generatedAt, now: now))
            if snapshot.isDemo && showDemo { Spacer(minLength: 4); Text("DEMO").fontWeight(.semibold) }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
}

struct WidgetEmptyState: View {
    let family: WidgetFamily
    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "helm").font(.title2).foregroundStyle(.secondary)
            Text("No clusters yet").font(.system(size: 14, weight: .semibold))
            Text("Open Wheelhouse to add a cluster").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

struct EnvTag: View {
    let env: ClusterEnvironment
    var body: some View {
        Text(env.badgeText).font(.system(size: 9, weight: .bold)).padding(.horizontal, 5).padding(.vertical, 1)
            .background(env == .production ? Palette.envProduction.opacity(0.18) : Color.secondary.opacity(0.18), in: Capsule())
            .foregroundStyle(env == .production ? Palette.envProduction : Color.secondary)
    }
}

/// `Link` that keeps its label styling (no accent tint).
struct WidgetLink<Label: View>: View {
    let destination: URL
    @ViewBuilder let label: () -> Label
    var body: some View { Link(destination: destination, label: label).tint(.primary) }
}
