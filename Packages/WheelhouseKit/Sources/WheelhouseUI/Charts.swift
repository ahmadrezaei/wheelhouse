import SwiftUI
import Charts
import WheelhouseKit

public enum MetricUnit: Sendable {
    case cores, bytes, percent, count

    func format(_ v: Double) -> String {
        switch self {
        case .cores: Quantity.formatCPU(cores: v)
        case .bytes: Quantity.formatBytes(v)
        case .percent: Format.percent(v)
        case .count: v.formatted(.number.precision(.fractionLength(0...1)))
        }
    }
}

public struct ChartSeries: Identifiable {
    public enum Style { case area, line, requests }
    public let id: String
    public var name: String
    public var color: Color
    public var style: Style
    public var points: [MetricPoint]
    public init(id: String? = nil, name: String, color: Color = Palette.chartCPU, style: Style = .area, points: [MetricPoint]) {
        self.id = id ?? name
        self.name = name
        self.color = color
        self.style = style
        self.points = points
    }
}

/// Swift Charts area + line + dashed requests line, optional capacity rule, drag-to-inspect selection.
public struct MetricChart: View {
    private let series: [ChartSeries]
    private let unit: MetricUnit
    private let capacity: Double?
    private let title: String
    private let height: CGFloat
    @State private var selection: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(title: String, series: [ChartSeries], unit: MetricUnit, capacity: Double? = nil, height: CGFloat = 150) {
        self.title = title
        self.series = series
        self.unit = unit
        self.capacity = capacity
        self.height = height
    }

    private var summary: String {
        guard let main = series.first(where: { $0.style != .requests }), let last = main.points.last, let peak = main.points.map(\.value).max() else { return "\(title): no data" }
        var s = "\(title), latest \(unit.format(last.value)), peak \(unit.format(peak))"
        if let capacity { s += ", capacity \(unit.format(capacity))" }
        if let req = series.first(where: { $0.style == .requests })?.points.last { s += ", requests \(unit.format(req.value))" }
        return s
    }

    public var body: some View {
        Chart {
            ForEach(series) { s in
                ForEach(s.points, id: \.time) { p in
                    switch s.style {
                    case .area:
                        AreaMark(x: .value("Time", p.time), y: .value(s.name, p.value), series: .value("Series", s.id))
                            .foregroundStyle(LinearGradient(colors: [s.color.opacity(0.35), s.color.opacity(0.03)], startPoint: .top, endPoint: .bottom))
                        LineMark(x: .value("Time", p.time), y: .value(s.name, p.value), series: .value("Series", s.id))
                            .foregroundStyle(s.color).lineStyle(StrokeStyle(lineWidth: 2))
                    case .line:
                        LineMark(x: .value("Time", p.time), y: .value(s.name, p.value), series: .value("Series", s.id))
                            .foregroundStyle(s.color).lineStyle(StrokeStyle(lineWidth: 1.5))
                    case .requests:
                        LineMark(x: .value("Time", p.time), y: .value(s.name, p.value), series: .value("Series", s.id))
                            .foregroundStyle(s.color).lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                    }
                }
            }
            if let capacity {
                RuleMark(y: .value("Capacity", capacity)).foregroundStyle(Palette.chartCapacity).lineStyle(StrokeStyle(lineWidth: 1))
            }
            if let selection {
                RuleMark(x: .value("Selected", selection)).foregroundStyle(Color.secondary.opacity(0.5))
                    .annotation(position: .top, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) { tooltip(at: selection) }
            }
        }
        .chartXSelection(value: $selection)
        .chartYScale(domain: .automatic(includesZero: true))
        .chartYAxis { AxisMarks(position: .trailing) { v in
            AxisGridLine().foregroundStyle(Palette.chartCapacity.opacity(0.5))
            AxisValueLabel { if let d = v.as(Double.self) { Text(unit.format(d)).font(.caption2) } }
        } }
        .chartXAxis { AxisMarks(values: .automatic(desiredCount: 4)) { _ in AxisValueLabel(format: .dateTime.hour().minute()).font(.caption2) } }
        .frame(height: height)
        .transaction { if reduceMotion { $0.animation = nil } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary)
    }

    private func tooltip(at date: Date) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(date, format: .dateTime.hour().minute()).font(.caption2).foregroundStyle(.secondary)
            ForEach(series) { s in
                if let p = s.points.min(by: { abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date)) }) {
                    HStack(spacing: 4) { Circle().fill(s.color).frame(width: 6, height: 6); Text("\(s.name) \(unit.format(p.value))").font(.caption2.monospacedDigit()) }
                }
            }
        }
        .padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - HeatGrid

public struct HeatTile: Identifiable, Hashable {
    public var id: String
    public var label: String
    /// 0...1
    public var value: Double
    public var isNotReady: Bool
    public init(id: String, label: String, value: Double, isNotReady: Bool = false) {
        self.id = id
        self.label = label
        self.value = value
        self.isNotReady = isNotReady
    }
}

/// Node tiles: teal intensity below 80 %, orange at 80 % and above, red outline when NotReady.
/// More than 30 tiles collapse to 8 pt dots; AX text sizes switch to a list. Hatch pattern when "Differentiate Without Color" is on.
public struct HeatGrid: View {
    private let tiles: [HeatTile]
    private let onSelect: ((HeatTile) -> Void)?
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityDifferentiateWithoutColor) private var differentiate

    public init(tiles: [HeatTile], onSelect: ((HeatTile) -> Void)? = nil) {
        self.tiles = tiles
        self.onSelect = onSelect
    }

    public var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) { ForEach(tiles) { t in
                HStack { Text(t.label).font(.subheadline); Spacer(); Text(label(t)).font(.subheadline.monospacedDigit()) }.accessibilityElement(children: .combine)
            } }
        } else if tiles.count > 30 {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 8, maximum: 8), spacing: 4)], spacing: 4) {
                ForEach(tiles) { t in RoundedRectangle(cornerRadius: 2).fill(fill(t)).frame(width: 8, height: 8).overlay { if t.isNotReady { RoundedRectangle(cornerRadius: 2).stroke(Palette.critical, lineWidth: 1.5) } }
                    .accessibilityElement().accessibilityLabel(a11y(t)) }
            }
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 6)], spacing: 6) {
                ForEach(tiles) { t in
                    Button { onSelect?(t) } label: {
                        VStack(spacing: 1) {
                            Text(t.label).font(.system(size: 10, weight: .medium, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(t.isNotReady ? "NotReady" : Format.percent(t.value)).font(.caption.weight(.semibold).monospacedDigit())
                        }
                        .foregroundStyle(t.value >= 0.8 && !t.isNotReady ? Color.black.opacity(0.85) : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 44)
                        .background(fill(t), in: RoundedRectangle(cornerRadius: Radius.small, style: .continuous))
                        .overlay { if differentiate && t.value >= 0.8 { Hatch().clipShape(RoundedRectangle(cornerRadius: Radius.small, style: .continuous)) } }
                        .overlay { if t.isNotReady { RoundedRectangle(cornerRadius: Radius.small, style: .continuous).stroke(Palette.critical, lineWidth: 2) } }
                    }
                    .buttonStyle(.plain)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(a11y(t))
                }
            }
        }
    }

    private func fill(_ t: HeatTile) -> Color {
        if t.isNotReady { return Palette.critical.opacity(0.15) }
        if t.value >= 0.8 { return Palette.warning }
        return Palette.tint.opacity(0.15 + 0.55 * t.value)
    }
    private func label(_ t: HeatTile) -> String { t.isNotReady ? "NotReady" : Format.percent(t.value) }
    private func a11y(_ t: HeatTile) -> String { t.isNotReady ? "\(t.label), NotReady" : "\(t.label), CPU \(Format.percent(t.value))\(t.value >= 0.8 ? ", above 80 percent" : "")" }

    private struct Hatch: View {
        var body: some View {
            Canvas { ctx, size in
                var x: CGFloat = -size.height
                while x < size.width {
                    var p = Path(); p.move(to: CGPoint(x: x, y: size.height)); p.addLine(to: CGPoint(x: x + size.height, y: 0))
                    ctx.stroke(p, with: .color(.black.opacity(0.35)), lineWidth: 1)
                    x += 6
                }
            }
        }
    }
}
