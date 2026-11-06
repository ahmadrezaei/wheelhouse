import SwiftUI
import UIKit
import WheelhouseKit

/// Design tokens from DESIGN.md §8.1–8.3. This file is the single source of truth for colours;
/// the app's AccentColor asset only mirrors `Palette.tint` so system chrome picks it up.
public enum Palette {
    // Brand
    public static let tint = Color(light: 0x0E8F89, dark: 0x2DD4BF)
    public static let onTint = Color(light: 0xFFFFFF, dark: 0x032622)
    public static let tintText = Color(light: 0x0B7A75, dark: 0x2DD4BF)
    public static let navy = Color(hex: 0x0B2545)
    public static let seafoam = Color(light: 0x6EF0DC, dark: 0x7DF5E2)

    // Status fills and text
    public static let healthy = Color(light: 0x34C759, dark: 0x30D158)
    public static let healthyText = Color(light: 0x1B8136, dark: 0x30D158)
    public static let warning = Color(light: 0xFF9500, dark: 0xFF9F0A)
    public static let warningText = Color(light: 0xA85600, dark: 0xFFB340)
    public static let critical = Color(light: 0xFF3B30, dark: 0xFF453A)
    public static let criticalText = Color(light: 0xCC1F2B, dark: 0xFF6B63)
    public static let unknown = Color(light: 0x8E8E93, dark: 0x8E8E93)
    public static let unknownText = Color(light: 0x6C6C70, dark: 0xAEAEB2)
    public static let info = Color(light: 0x007AFF, dark: 0x0A84FF)
    public static let infoText = Color(light: 0x0060C7, dark: 0x409CFF)

    // Environments
    public static let envProduction = Color(light: 0xD3245A, dark: 0xFF4D7D)
    public static let envStaging = Color(light: 0x5856D6, dark: 0x5E5CE6)
    public static let envDevelopment = tint

    // Charts
    public static let chartCPU = tint
    public static let chartMemory = Color(light: 0xAF52DE, dark: 0xBF5AF2)
    public static let chartRequests = Color(light: 0x5856D6, dark: 0x5E5CE6)
    public static let chartCapacity = Color(uiColor: .separator)

    // Diff / log / terminal
    public static let diffAdd = Color(light: 0x34C759, dark: 0x30D158)
    public static let diffDelete = Color(light: 0xFF3B30, dark: 0xFF453A)
    public static let logHighlight = Color(light: 0xFFD60A, dark: 0xFFD60A)
    public static let logCurrent = Color(hex: 0xFF9500)
    public static let terminalBackground = Color(hex: 0x0A0E13)
    public static let terminalForeground = Color(hex: 0xD5DEE8)
    public static let terminalPrompt = Color(hex: 0x5EEAD4)

    // Surfaces (system semantic colours)
    public static let groupedBackground = Color(uiColor: .systemGroupedBackground)
    public static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    public static let fieldFill = Color(uiColor: .quaternarySystemFill)
}

public enum Spacing {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 20
    public static let xxl: CGFloat = 24
    public static let xxxl: CGFloat = 32
    public static let cardGap: CGFloat = 12
    public static let minHit: CGFloat = 44
}

public enum Radius {
    public static let card: CGFloat = 24
    public static let tile: CGFloat = 18
    public static let small: CGFloat = 10
    public static let field: CGFloat = 14
    public static let code: CGFloat = 12
}

public extension Font {
    /// Counters and percentages (`.title2.bold().monospacedDigit()`).
    static var whKPI: Font { .title2.bold().monospacedDigit() }
    /// YAML, logs, generated object names, IPs.
    static var whCode: Font { .system(.footnote, design: .monospaced) }
    static var whCodeSmall: Font { .system(.caption, design: .monospaced) }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

// MARK: - Status tones

/// Semantic tone for pills, dots and meters. Status is always colour + symbol + text.
public enum StatusTone: Hashable, Sendable {
    case healthy, warning, critical, unknown, info

    public init(_ status: HealthStatus) {
        switch status {
        case .healthy: self = .healthy
        case .warning: self = .warning
        case .critical: self = .critical
        case .unknown: self = .unknown
        }
    }

    /// Base colour for fills (dots, bars, chart marks).
    public var color: Color {
        switch self {
        case .healthy: Palette.healthy
        case .warning: Palette.warning
        case .critical: Palette.critical
        case .unknown: Palette.unknown
        case .info: Palette.info
        }
    }
    /// Contrast-safe colour for text (≥ 4.5:1).
    public var textColor: Color {
        switch self {
        case .healthy: Palette.healthyText
        case .warning: Palette.warningText
        case .critical: Palette.criticalText
        case .unknown: Palette.unknownText
        case .info: Palette.infoText
        }
    }
    public var symbol: String {
        switch self {
        case .healthy: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .critical: "xmark.octagon.fill"
        case .unknown: "questionmark.circle"
        case .info: "info.circle.fill"
        }
    }
}

public extension HealthStatus {
    var tone: StatusTone { StatusTone(self) }
    var color: Color { tone.color }
    var textColor: Color { tone.textColor }
}

public extension ClusterColor {
    var color: Color {
        switch self {
        case .teal: Palette.tint
        case .blue: Palette.info
        case .indigo: Palette.envStaging
        case .purple: Palette.chartMemory
        case .pink: Palette.envProduction
        case .orange: Palette.warning
        case .green: Palette.healthy
        case .gray: Palette.unknown
        }
    }
}

// MARK: - Formatting

public enum Format {
    /// Compact age such as `3d`, `5h`, `12m`, `40s`.
    public static func age(from date: Date?, now: Date = Date()) -> String {
        guard let date else { return "–" }
        return age(seconds: now.timeIntervalSince(date))
    }

    public static func age(seconds: TimeInterval) -> String {
        let s = max(0, Int(seconds))
        switch s {
        case ..<60: return "\(s)s"
        case ..<3600: return "\(s / 60)m"
        case ..<86_400: return s < 36_000 && s % 3600 >= 60 ? "\(s / 3600)h\((s % 3600) / 60)m" : "\(s / 3600)h"
        default: return "\(s / 86_400)d"
        }
    }

    public static func percent(_ fraction: Double) -> String { "\(Int((fraction * 100).rounded()))%" }
}
