import SwiftUI
import WheelhouseKit

// MARK: - StatusPill

/// 22 pt capsule with a 15 % tinted fill. Colour + symbol + text.
public struct StatusPill: View {
    private let tone: StatusTone
    private let text: String
    private let symbol: String?

    public init(tone: StatusTone, text: String, symbol: String? = nil) {
        self.tone = tone
        self.text = text
        self.symbol = symbol ?? tone.symbol
    }

    public init(_ status: HealthStatus, text: String? = nil, symbol: String? = nil) {
        self.init(tone: StatusTone(status), text: text ?? status.title, symbol: symbol ?? status.symbol)
    }

    public var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).imageScale(.small).symbolRenderingMode(.hierarchical) }
            Text(text).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(tone.textColor)
        .padding(.horizontal, 8)
        .frame(minHeight: 22)
        .background(tone.color.opacity(0.15), in: Capsule())
        .accessibilityElement(children: .combine)
    }
}

// MARK: - EnvBadge

/// 19 pt uppercase badge. Production is filled rose with a shield and is used for nothing else.
public struct EnvBadge: View {
    private let environment: ClusterEnvironment
    public init(_ environment: ClusterEnvironment) { self.environment = environment }

    public var body: some View {
        Group {
            switch environment {
            case .production:
                HStack(spacing: 3) {
                    Image(systemName: "shield.fill").imageScale(.small)
                    Text(environment.badgeText)
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 6)
                .background(Palette.envProduction, in: Capsule())
            case .staging:
                Text(environment.badgeText).foregroundStyle(Palette.envStaging).padding(.horizontal, 6).background(Palette.envStaging.opacity(0.15), in: Capsule())
            case .development:
                Text(environment.badgeText).foregroundStyle(Palette.tintText).padding(.horizontal, 6).background(Palette.tint.opacity(0.15), in: Capsule())
            case .personal:
                Text(environment.badgeText).foregroundStyle(.secondary).padding(.horizontal, 6).background(Palette.fieldFill, in: Capsule())
            }
        }
        .font(.system(size: 10, weight: .bold)).tracking(0.4)
        .frame(minHeight: 19)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(environment.title) cluster")
    }
}

/// Small flat badge for READ-ONLY, DEMO, UNVERIFIED TLS…
public struct FlagBadge: View {
    let text: String
    let tone: StatusTone
    public init(_ text: String, tone: StatusTone = .unknown) { self.text = text; self.tone = tone }
    public var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold)).tracking(0.4)
            .foregroundStyle(tone.textColor)
            .padding(.horizontal, 6).frame(minHeight: 19)
            .background(tone.color.opacity(0.15), in: Capsule())
    }
}

// MARK: - ContextLine

/// Cluster (with environment badge) · namespace · kind, shown under the nav bar on every resource screen and in every sheet.
public struct ContextLine: View {
    private let cluster: ClusterConfig
    private let namespace: String?
    private let kind: String?
    private let showsNamespace: Bool

    /// - Parameter namespace: `nil` shows "All namespaces" when `showsNamespace` is true.
    public init(cluster: ClusterConfig, namespace: String? = nil, kind: String? = nil, showsNamespace: Bool = true) {
        self.cluster = cluster
        self.namespace = namespace
        self.kind = kind
        self.showsNamespace = showsNamespace
    }

    public var body: some View {
        ViewThatFits(in: .horizontal) {
            line
            ScrollView(.horizontal, showsIndicators: false) { line }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var line: some View {
        HStack(spacing: 6) {
            EnvBadge(cluster.environment)
            Text(cluster.name).font(.footnote.weight(.semibold)).lineLimit(1)
            if showsNamespace { dot; Text(namespace ?? "All namespaces").font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            if let kind { dot; Text(kind).font(.footnote).foregroundStyle(.secondary).lineLimit(1) }
            if cluster.readOnly { FlagBadge("READ-ONLY", tone: .info) }
            if cluster.isDemo { FlagBadge("DEMO", tone: .warning) }
            if cluster.allowsInsecureTLS { FlagBadge("UNVERIFIED TLS", tone: .critical) }
        }
    }

    private var dot: some View { Text("·").foregroundStyle(.tertiary) }

    private var accessibilityText: String {
        var parts = ["\(cluster.environment.title) cluster \(cluster.name)"]
        if showsNamespace { parts.append(namespace.map { "namespace \($0)" } ?? "all namespaces") }
        if let kind { parts.append(kind) }
        if cluster.readOnly { parts.append("read-only") }
        if cluster.isDemo { parts.append("demo") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Meter

/// 4–8 pt bar with optional request marker and limit. Turns warning at 85 % and critical at 95 % of the limit (or full track).
public struct Meter: View {
    private let value: Double
    private let request: Double?
    private let limit: Double?
    private let height: CGFloat
    private let tint: Color?

    /// All values are fractions of the full track (0...1). `limit < 1` marks where the container limit ends.
    public init(value: Double, request: Double? = nil, limit: Double? = nil, height: CGFloat = 6, tint: Color? = nil) {
        self.value = value
        self.request = request
        self.limit = limit
        self.height = height
        self.tint = tint
    }

    private var fill: Color {
        let ratio = value / max(limit ?? 1, 0.0001)
        if ratio >= 0.95 { return Palette.critical }
        if ratio >= 0.85 { return Palette.warning }
        return tint ?? Palette.tint
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Palette.fieldFill)
                if let limit, limit < 1 {
                    Capsule().fill(Color.secondary.opacity(0.12)).frame(width: w * limit)
                }
                Capsule().fill(fill).frame(width: max(height, w * min(max(value, 0), 1)))
                if let request {
                    Rectangle().fill(Color.primary.opacity(0.7)).frame(width: 2, height: height + 4)
                        .offset(x: w * min(max(request, 0), 1) - 1)
                }
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Usage")
        .accessibilityValue(Format.percent(value))
    }
}

// MARK: - ReadyRing

/// 32 pt ring showing ready/desired. Green when all ready, red at zero, amber between, grey when nothing is desired.
public struct ReadyRing: View {
    private let ready: Int
    private let desired: Int
    private let size: CGFloat

    public init(ready: Int, desired: Int, size: CGFloat = 32) {
        self.ready = ready
        self.desired = desired
        self.size = size
    }

    private var tone: StatusTone {
        if desired == 0 { return .unknown }
        if ready >= desired { return .healthy }
        return ready == 0 ? .critical : .warning
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tone.color.opacity(0.2), lineWidth: 3.5)
            Circle().trim(from: 0, to: desired == 0 ? 0 : min(1, Double(ready) / Double(desired)))
                .stroke(tone.color, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(ready)/\(desired)").font(.system(size: size * 0.28, weight: .semibold).monospacedDigit()).minimumScaleFactor(0.6)
                .foregroundStyle(tone.textColor)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(ready) of \(desired) ready")
    }
}

// MARK: - KPITile

/// Label, big monospaced value, optional caption and meter. Used in 2×2 / 4-up grids.
public struct KPITile: View {
    private let label: String
    private let value: String
    private let caption: String?
    private let meter: Double?
    private let tone: StatusTone?

    public init(label: String, value: String, caption: String? = nil, meter: Double? = nil, tone: StatusTone? = nil) {
        self.label = label
        self.value = value
        self.caption = caption
        self.meter = meter
        self.tone = tone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.footnote.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.whKPI).foregroundStyle(tone?.textColor ?? Color.primary).contentTransition(.numericText()).lineLimit(1).minimumScaleFactor(0.7)
            if let meter { Meter(value: meter, height: 5) }
            if let caption { Text(caption).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.l).padding(.vertical, 14)
        .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: Radius.tile, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Cards & headers

public extension View {
    /// Opaque grouped card surface (content never uses glass).
    func whCard(padding: CGFloat = 16) -> some View {
        self.padding(.horizontal, padding).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.cardBackground, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
    }
}

public struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let trailing: Trailing
    public init(_ title: String, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.trailing = trailing()
    }
    public var body: some View {
        HStack {
            Text(title).font(.title3.weight(.semibold)).accessibilityAddTraits(.isHeader)
            Spacer()
            trailing.font(.subheadline)
        }
    }
}

/// Green dot for "live". Pulses a few times when it appears, then stays static: an endless symbol animation keeps the
/// render server and the display link running for as long as the screen is open (a measurable battery cost).
/// Static under Reduce Motion, Low Power Mode and thermal pressure.
public struct LiveDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulses = 0
    private let tone: StatusTone
    public init(tone: StatusTone = .healthy) { self.tone = tone }
    public var body: some View {
        Image(systemName: "circle.fill").font(.system(size: 8)).foregroundStyle(tone.color)
            // Discrete effect: runs 3 pulses each time `pulses` changes (on appear), then the symbol is static.
            .symbolEffect(.pulse, options: .repeat(3), value: pulses)
            .onAppear { if !reduceMotion, tone == .healthy, EnergyMonitor.shared.policy.allowsLiveCharts { pulses += 1 } }
            .accessibilityHidden(true)
    }
}
