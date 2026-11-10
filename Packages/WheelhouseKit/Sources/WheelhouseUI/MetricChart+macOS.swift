#if os(macOS)
import AppKit
import SwiftUI
import WheelhouseKit

/// The Mac rendering of ``MetricChart``: the same series, capacity rule, axes and hover readout, drawn with Core Graphics into one
/// chart-sized layer.
///
/// Swift Charts on the Mac allocates about 100 MB of GPU memory for a moment every time a chart updates (owned by the app, so it counts
/// in its physical footprint): measured in the M4a soak, one cluster overview with its CPU and memory charts turned a 120 MB app into a
/// 230 MB one for about a second at every 30-second refresh, and the soak's peak budget is 200 MB. Replacing the chart with a plain view
/// removed every spike; removing the gradient, the axes, the selection or the animations did not. A Core Graphics drawing costs one
/// bitmap of the chart's own size. iOS keeps Swift Charts.
struct MacMetricChart: NSViewRepresentable {
    let series: [ChartSeries]
    let unit: MetricUnit
    let capacity: Double?

    func makeNSView(context: Context) -> MetricChartView { MetricChartView() }

    func updateNSView(_ view: MetricChartView, context: Context) {
        let prepared = series.map { s in
            MetricChartLayout.Series(id: s.id, name: s.name, color: NSColor(s.color), style: s.style,
                                     points: s.points.downsampled().map { ($0.time.timeIntervalSinceReferenceDate, $0.value) })
        }
        view.update(MetricChartLayout(series: prepared, capacity: capacity), format: unit.format)
    }
}

/// The chart's geometry: value and time domains, axis ticks and the mapping from data to points. Pure, so it is tested without a view.
public struct MetricChartLayout {
    public struct Series {
        public var id: String
        public var name: String
        public var color: NSColor
        public var style: ChartSeries.Style
        /// Seconds since the reference date, value.
        public var points: [(t: TimeInterval, v: Double)]

        public init(id: String, name: String, color: NSColor, style: ChartSeries.Style, points: [(TimeInterval, Double)]) {
            self.id = id
            self.name = name
            self.color = color
            self.style = style
            self.points = points.map { (t: $0.0, v: $0.1) }
        }
    }

    public var series: [Series]
    public var capacity: Double?
    /// Lowest and highest time over every series (padded by a minute when there is a single instant).
    public let timeDomain: ClosedRange<TimeInterval>
    /// Zero to a rounded maximum above every value and the capacity.
    public let valueDomain: ClosedRange<Double>
    /// The values that get a grid line and a label (zero included).
    public let valueTicks: [Double]

    public init(series: [Series], capacity: Double?) {
        self.series = series
        self.capacity = capacity
        let times = series.flatMap { $0.points.map(\.t) }
        if let lo = times.min(), let hi = times.max() {
            timeDomain = lo < hi ? lo...hi : (lo - 60)...(hi + 60)
        } else {
            timeDomain = 0...1
        }
        let highest = max(series.flatMap { $0.points.map(\.v) }.max() ?? 0, capacity ?? 0)
        let step = Self.niceStep(for: highest > 0 ? highest : 1, ticks: 4)
        let top = max(step, (highest / step).rounded(.up) * step)
        valueDomain = 0...top
        valueTicks = stride(from: 0, through: top + step / 2, by: step).map { $0 }
    }

    /// A 1, 2, 2.5 or 5 times a power of ten step that splits `maximum` into about `ticks` intervals.
    public static func niceStep(for maximum: Double, ticks: Int) -> Double {
        let raw = maximum / Double(max(ticks, 1))
        let magnitude = pow(10, floor(log10(raw)))
        let fraction = raw / magnitude
        let nice: Double = fraction <= 1 ? 1 : (fraction <= 2 ? 2 : (fraction <= 2.5 ? 2.5 : (fraction <= 5 ? 5 : 10)))
        return nice * magnitude
    }

    /// The point of a data value in `plot` (a flipped rectangle: y grows downward).
    public func point(t: TimeInterval, v: Double, in plot: CGRect) -> CGPoint {
        let tx = (t - timeDomain.lowerBound) / max(timeDomain.upperBound - timeDomain.lowerBound, 1e-9)
        let vy = (v - valueDomain.lowerBound) / max(valueDomain.upperBound - valueDomain.lowerBound, 1e-9)
        return CGPoint(x: plot.minX + CGFloat(tx) * plot.width, y: plot.maxY - CGFloat(vy) * plot.height)
    }

    /// The time under a horizontal position in `plot`.
    public func time(atX x: CGFloat, in plot: CGRect) -> TimeInterval {
        let f = Double(min(max((x - plot.minX) / max(plot.width, 1), 0), 1))
        return timeDomain.lowerBound + f * (timeDomain.upperBound - timeDomain.lowerBound)
    }
}

/// Draws a ``MetricChartLayout``: grid and value labels on the right, four time labels below, filled areas, lines, the dashed
/// requests line, the capacity rule and, under the pointer, a rule with the values nearest in time.
final class MetricChartView: NSView {
    private var layout = MetricChartLayout(series: [], capacity: nil)
    private var format: (Double) -> String = { "\($0)" }
    private var hoverTime: TimeInterval?
    private var revision: [String] = []
    private static let labelFont = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize - 1)
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("jmm")
        return f
    }()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }

    /// `.onSetNeedsDisplay` does not redraw on a resize by itself: without this the old bitmap would be stretched until the next sample.
    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { needsDisplay = true }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    /// Redraws only when what is drawn changed (a SwiftUI update of the card with the same samples draws nothing).
    func update(_ new: MetricChartLayout, format: @escaping (Double) -> String) {
        let key = new.series.map { s in "\(s.id)|\(s.points.count)|\(s.points.first?.t ?? 0)|\(s.points.last?.t ?? 0)|\(s.points.last?.v ?? 0)|\(s.points.reduce(0) { $0 + $1.v })" }
            + ["cap \(new.capacity ?? -1)"]
        layout = new
        self.format = format
        guard key != revision else { return }
        revision = key
        needsDisplay = true
    }

    private var plotRect: CGRect {
        let labelWidth: CGFloat = 52, labelHeight: CGFloat = 16
        return CGRect(x: bounds.minX + 2, y: bounds.minY + 6, width: max(bounds.width - labelWidth - 4, 1), height: max(bounds.height - labelHeight - 8, 1))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let plot = plotRect
        let secondary = NSColor.secondaryLabelColor
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: secondary]

        // Grid and value labels.
        ctx.setLineWidth(1)
        NSColor.separatorColor.withAlphaComponent(0.5).setStroke()
        for tick in layout.valueTicks {
            let y = layout.point(t: layout.timeDomain.lowerBound, v: tick, in: plot).y.rounded() + 0.5
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y)); ctx.strokePath()
            let text = NSAttributedString(string: format(tick), attributes: attrs)
            text.draw(at: CGPoint(x: plot.maxX + 6, y: y - text.size().height / 2))
        }
        // Time labels.
        let span = layout.timeDomain.upperBound - layout.timeDomain.lowerBound
        for i in 0..<4 where !layout.series.allSatisfy({ $0.points.isEmpty }) {
            let t = layout.timeDomain.lowerBound + span * Double(i) / 3
            let text = NSAttributedString(string: Self.timeFormatter.string(from: Date(timeIntervalSinceReferenceDate: t)), attributes: attrs)
            let x = min(max(layout.point(t: t, v: 0, in: plot).x - text.size().width / 2, plot.minX), plot.maxX - text.size().width)
            text.draw(at: CGPoint(x: x, y: plot.maxY + 3))
        }
        // Series.
        ctx.saveGState()
        ctx.clip(to: plot.insetBy(dx: 0, dy: -2))
        for s in layout.series where s.points.count > 0 {
            let pts = s.points.map { layout.point(t: $0.t, v: $0.v, in: plot) }
            let line = CGMutablePath()
            line.addLines(between: pts)
            if s.style == .area, pts.count > 1, let first = pts.first, let last = pts.last {
                let area = CGMutablePath()
                area.move(to: CGPoint(x: first.x, y: plot.maxY))
                area.addLines(between: pts)
                area.addLine(to: CGPoint(x: last.x, y: plot.maxY))
                area.closeSubpath()
                let colors = [s.color.withAlphaComponent(0.35).cgColor, s.color.withAlphaComponent(0.03).cgColor] as CFArray
                if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                    ctx.saveGState()
                    ctx.addPath(area); ctx.clip()
                    ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: plot.minY), end: CGPoint(x: 0, y: plot.maxY), options: [])
                    ctx.restoreGState()
                }
            }
            ctx.setStrokeColor(s.color.cgColor)
            ctx.setLineWidth(s.style == .area ? 2 : 1.5)
            ctx.setLineJoin(.round); ctx.setLineCap(.round)
            ctx.setLineDash(phase: 0, lengths: s.style == .requests ? [4, 3] : [])
            ctx.addPath(line); ctx.strokePath()
        }
        ctx.setLineDash(phase: 0, lengths: [])
        if let capacity = layout.capacity {
            let y = layout.point(t: layout.timeDomain.lowerBound, v: capacity, in: plot).y
            NSColor.separatorColor.setStroke()
            ctx.setLineWidth(1)
            ctx.move(to: CGPoint(x: plot.minX, y: y)); ctx.addLine(to: CGPoint(x: plot.maxX, y: y)); ctx.strokePath()
        }
        ctx.restoreGState()
        if let hoverTime { drawReadout(at: hoverTime, plot: plot, ctx: ctx) }
    }

    /// The rule under the pointer and a box with the time and each series' nearest value.
    private func drawReadout(at t: TimeInterval, plot: CGRect, ctx: CGContext) {
        let x = layout.point(t: t, v: 0, in: plot).x
        NSColor.secondaryLabelColor.withAlphaComponent(0.5).setStroke()
        ctx.setLineWidth(1)
        ctx.move(to: CGPoint(x: x, y: plot.minY)); ctx.addLine(to: CGPoint(x: x, y: plot.maxY)); ctx.strokePath()
        var lines: [(String, NSColor?)] = [(Self.timeFormatter.string(from: Date(timeIntervalSinceReferenceDate: t)), nil)]
        for s in layout.series {
            guard let p = s.points.min(by: { abs($0.t - t) < abs($1.t - t) }) else { continue }
            lines.append(("\(s.name) \(format(p.v))", s.color))
        }
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.labelFont, .foregroundColor: NSColor.labelColor]
        let texts = lines.map { (NSAttributedString(string: $0.0, attributes: attrs), $0.1) }
        let width = (texts.map { $0.0.size().width + ($0.1 == nil ? 0 : 10) }.max() ?? 0) + 12
        let lineHeight = (texts.first?.0.size().height ?? 12) + 1
        var box = CGRect(x: x + 6, y: plot.minY, width: width, height: lineHeight * CGFloat(texts.count) + 8)
        if box.maxX > plot.maxX { box.origin.x = x - 6 - width }
        let path = NSBezierPath(roundedRect: box, xRadius: 6, yRadius: 6)
        NSColor.windowBackgroundColor.withAlphaComponent(0.95).setFill(); path.fill()
        NSColor.separatorColor.setStroke(); path.stroke()
        for (i, item) in texts.enumerated() {
            var origin = CGPoint(x: box.minX + 6, y: box.minY + 4 + lineHeight * CGFloat(i))
            if let color = item.1 {
                color.setFill()
                NSBezierPath(ovalIn: CGRect(x: origin.x, y: origin.y + lineHeight / 2 - 3, width: 6, height: 6)).fill()
                origin.x += 10
            }
            item.0.draw(at: origin)
        }
    }

    // MARK: Hover

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let plot = plotRect
        hoverTime = plot.contains(p) && !layout.series.allSatisfy({ $0.points.isEmpty }) ? layout.time(atX: p.x, in: plot) : nil
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        guard hoverTime != nil else { return }
        hoverTime = nil
        needsDisplay = true
    }
}
#endif
