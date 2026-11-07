import SwiftUI
import WheelhouseKit

// MARK: - ResourceRow

/// Standard list row: lead indicator · title/subtitle · trailing metric · chevron.
/// Attach `.swipeActions` / `.contextMenu` at the call site.
public struct ResourceRow: View {
    public enum Lead {
        case status(HealthStatus)
        case ring(ready: Int, desired: Int)
        case symbol(String, StatusTone)
        case none
    }

    private let title: String
    private let subtitle: String?
    private let lead: Lead
    private let trailing: String?
    private let trailingTone: StatusTone?
    private let monospacedTitle: Bool
    private let showsChevron: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(title: String, subtitle: String? = nil, lead: Lead = .none, trailing: String? = nil, trailingTone: StatusTone? = nil,
                monospacedTitle: Bool = false, showsChevron: Bool = true) {
        self.title = title
        self.subtitle = subtitle
        self.lead = lead
        self.trailing = trailing
        self.trailingTone = trailingTone
        self.monospacedTitle = monospacedTitle
        self.showsChevron = showsChevron
    }

    public var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                leadView
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(monospacedTitle ? .whCode.weight(.medium) : .body).lineLimit(typeSize.isAccessibilitySize ? 3 : 1).truncationMode(.middle)
                    if let subtitle { Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(typeSize.isAccessibilitySize ? 3 : 1) }
                }
                if !typeSize.isAccessibilitySize { Spacer(minLength: 4) }
            }
            if let trailing {
                Text(trailing).font(.subheadline.monospacedDigit()).foregroundStyle(trailingTone?.textColor ?? .secondary)
            }
        }
        .frame(minHeight: Spacing.minHit)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var leadView: some View {
        switch lead {
        case .status(let s): Image(systemName: s.symbol).symbolRenderingMode(.palette).foregroundStyle(.white, s.color).font(.title3).frame(width: 32)
        case .ring(let r, let d): ReadyRing(ready: r, desired: d)
        case .symbol(let name, let tone): Image(systemName: name).symbolRenderingMode(.hierarchical).foregroundStyle(tone.color).font(.title3).frame(width: 32)
        case .none: EmptyView()
        }
    }
}

// MARK: - ClusterCard

/// Fleet card and iPad content-column row. Unreachable clusters render grey with a Retry button.
public struct ClusterCard: View {
    private let cluster: ClusterConfig
    private let health: ClusterHealth?
    private let version: String?
    private let cpu: Double?
    private let memory: Double?
    private let sparkline: [Double]
    private let onRetry: (() -> Void)?
    private let credentialsMissing: Bool
    private let credentialsProblem: String?
    private let onEdit: (() -> Void)?

    public init(cluster: ClusterConfig, health: ClusterHealth?, version: String? = nil, cpu: Double? = nil, memory: Double? = nil,
                sparkline: [Double] = [], credentialsMissing: Bool = false, credentialsProblem: String? = nil, onEdit: (() -> Void)? = nil, onRetry: (() -> Void)? = nil) {
        self.cluster = cluster
        self.health = health
        self.version = version
        self.cpu = cpu
        self.memory = memory
        self.sparkline = sparkline
        self.onRetry = onRetry
        self.credentialsProblem = credentialsProblem
        self.credentialsMissing = credentialsMissing || credentialsProblem != nil
        self.onEdit = onEdit
    }

    private var status: HealthStatus { health?.status ?? .unknown }
    private var reachable: Bool { !credentialsMissing && (health?.isReachable ?? true) }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Circle().fill(status.color).frame(width: 10, height: 10)
                Text(cluster.name).font(.headline).lineLimit(1).layoutPriority(1)
                EnvBadge(cluster.environment).fixedSize()
                if cluster.isDemo { FlagBadge("DEMO", tone: .warning).fixedSize() }
                Spacer(minLength: 4)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            Text(metaLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            if reachable, health != nil {
                HStack(spacing: 16) {
                    meter("CPU", cpu)
                    meter("Memory", memory)
                    if sparkline.count > 1 { Sparkline(values: sparkline).frame(width: 64, height: 22).accessibilityHidden(true) }
                }
                HStack {
                    if let c = health?.counts { Label("\(c.podsRunning)/\(c.podsTotal) pods running", systemImage: "cube").font(.caption).foregroundStyle(.secondary) }
                }
            }
            HStack(alignment: .firstTextBaseline) {
                if credentialsMissing {
                    Image(systemName: "key.slash").foregroundStyle(Palette.warningText).imageScale(.small)
                    Text(credentialsProblem ?? "Credentials not on this device").font(.footnote).foregroundStyle(Palette.warningText).lineLimit(2)
                    Spacer()
                    if let onEdit { Button("Edit Cluster", action: onEdit).buttonStyle(.bordered).controlSize(.small) }
                } else {
                Image(systemName: status.symbol).foregroundStyle(status.textColor).imageScale(.small)
                Text(health?.issueSummary ?? "Checking…").font(.footnote).foregroundStyle(status == .healthy ? Color.secondary : status.textColor).lineLimit(2)
                Spacer()
                }
                if !credentialsMissing, !reachable, let onRetry { Button("Retry", action: onRetry).buttonStyle(.bordered).controlSize(.small) }
            }
        }
        .whCard()
        .opacity(reachable ? 1 : 0.72)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(cluster.name), \(cluster.environment.title), \(status.title). \(health?.issueSummary ?? "")")
    }

    private var metaLine: String {
        var parts: [String] = []
        if let p = cluster.provider { parts.append(p) }
        if let version { parts.append(version) }
        if let c = health?.counts, c.nodesTotal > 0 { parts.append("\(c.nodesReady)/\(c.nodesTotal) nodes") }
        if !reachable, let t = health?.updatedAt { parts.append("cached \(Format.age(from: t)) ago") }
        return parts.isEmpty ? cluster.host : parts.joined(separator: " · ")
    }

    @ViewBuilder private func meter(_ label: String, _ value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(label).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Text(value.map(Format.percent) ?? "–").font(.caption.monospacedDigit())
            }
            Meter(value: value ?? 0, height: 5)
        }
    }
}

/// Tiny area-less sparkline for cards.
public struct Sparkline: View {
    private let values: [Double]
    private let tone: Color
    public init(values: [Double], tone: Color = Palette.tint) { self.values = values; self.tone = tone }
    public var body: some View {
        GeometryReader { geo in
            let lo = values.min() ?? 0, hi = max(values.max() ?? 1, lo + 0.0001)
            Path { p in
                for (i, v) in values.enumerated() {
                    let pt = CGPoint(x: geo.size.width * CGFloat(i) / CGFloat(max(values.count - 1, 1)), y: geo.size.height * (1 - CGFloat((v - lo) / (hi - lo))))
                    if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                }
            }
            .stroke(tone, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }
        .accessibilityHidden(true)
    }
}

// MARK: - DiagnosisBanner

/// Rule-based explanation of what is wrong and the next step, with an optional deep link (e.g. previous logs).
public struct DiagnosisBanner: View {
    private let diagnosis: PodDiagnosis
    private let actionTitle: String?
    private let action: (() -> Void)?

    public init(_ diagnosis: PodDiagnosis, actionTitle: String? = nil, action: (() -> Void)? = nil) {
        self.diagnosis = diagnosis
        self.actionTitle = actionTitle
        self.action = action
    }

    public var body: some View {
        let tone = StatusTone(diagnosis.severity)
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: diagnosis.symbol).foregroundStyle(tone.color)
                Text(diagnosis.bannerText).font(.subheadline.weight(.semibold)).foregroundStyle(tone.textColor)
            }
            Text(diagnosis.explanation).font(.footnote).foregroundStyle(.primary)
            if let suggestion = diagnosis.suggestion { Text(suggestion).font(.footnote).foregroundStyle(.secondary) }
            if let actionTitle, let action {
                Button(actionTitle, action: action).buttonStyle(.bordered).controlSize(.small).tint(tone.color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(tone.color.opacity(0.12), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - GlassActionRow

public struct GlassAction: Identifiable {
    /// Stable across renders (a per-instance UUID changed on every body evaluation and broke diffing).
    public var id: String { title }
    public var title: String
    public var symbol: String
    public var role: ButtonRole?
    public var isEnabled: Bool
    public var action: () -> Void
    public init(_ title: String, symbol: String, role: ButtonRole? = nil, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.role = role
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// 4–5 Liquid Glass action tiles under a detail header (Scale · Restart · Rollback · Logs · YAML). Hide (don't disable) mutating actions on read-only clusters.
public struct GlassActionRow: View {
    private let actions: [GlassAction]
    public init(_ actions: [GlassAction]) { self.actions = actions }

    public var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ForEach(actions) { a in
                    Button(role: a.role, action: a.action) {
                        VStack(spacing: 4) {
                            Image(systemName: a.symbol).font(.title3).symbolRenderingMode(.hierarchical)
                            Text(a.title).font(.caption2.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity, minHeight: 56)
                        .foregroundStyle(a.role == .destructive ? Palette.criticalText : Color.primary)
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
                    .disabled(!a.isEnabled)
                    .opacity(a.isEnabled ? 1 : 0.45)
                    .accessibilityLabel(a.title)
                }
            }
        }
    }
}
