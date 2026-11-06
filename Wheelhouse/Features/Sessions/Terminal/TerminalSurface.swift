import SwiftUI
import UIKit
import WheelhouseKit

/// Receives what the user types and the size the surface can display.
@MainActor
protocol TerminalSurfaceDelegate: AnyObject {
    func terminalSurface(_ surface: any TerminalSurface, send data: Data)
    func terminalSurface(_ surface: any TerminalSurface, didResize cols: Int, rows: Int)
}

/// Sticky modifier state shared between the extra-key row and the surface (Ctrl / Alt for the next key).
@MainActor
final class TerminalModifierState {
    var control = false { didSet { onChange?() } }
    var controlLocked = false { didSet { onChange?() } }
    var alt = false { didSet { onChange?() } }
    var onChange: (() -> Void)?

    /// Applies and clears sticky modifiers for the next typed key.
    func consume() -> TerminalModifiers {
        var m: TerminalModifiers = []
        if control { m.insert(.control) }
        if alt { m.insert(.alt) }
        if !controlLocked { control = false }
        alt = false
        return m
    }
}

/// The only thing the session code knows about terminal rendering. A SwiftTerm adapter later only needs to
/// implement this protocol (feed bytes in, emit typed bytes and size changes out).
@MainActor
protocol TerminalSurface: AnyObject {
    var view: UIView { get }
    var delegate: (any TerminalSurfaceDelegate)? { get set }
    /// Visible grid size, 0×0 until laid out.
    var size: (cols: Int, rows: Int) { get }
    var fontSize: CGFloat { get set }
    var modifiers: TerminalModifierState { get }
    /// Shows the iPhone extra-key row above the software keyboard.
    var showsExtraKeys: Bool { get set }

    func feed(_ data: Data)
    func feed(_ text: String)
    func reset()
    func clearScreen()
    func allText() -> String
    func sendKey(_ key: TerminalKey, modifiers: TerminalModifiers)
    func sendText(_ text: String)
    func pasteText(_ text: String)
    func focus()
    func blur()
    var hasFocus: Bool { get }
}

/// Embeds a surface's UIView in SwiftUI.
struct TerminalSurfaceHost: UIViewRepresentable {
    let surface: any TerminalSurface
    func makeUIView(context: Context) -> UIView { surface.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Theme

/// "Wheelhouse Dark" ANSI palette.
enum TerminalTheme {
    static let background = UIColor(red: 0x0A / 255, green: 0x0E / 255, blue: 0x13 / 255, alpha: 1)
    static let foreground = UIColor(red: 0xD5 / 255, green: 0xDE / 255, blue: 0xE8 / 255, alpha: 1)
    static let cursor = UIColor(red: 0x5E / 255, green: 0xEA / 255, blue: 0xD4 / 255, alpha: 1)

    private static func hex(_ v: UInt32) -> UIColor {
        UIColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255, blue: CGFloat(v & 0xFF) / 255, alpha: 1)
    }

    static let ansi: [UIColor] = [
        hex(0x1B2330), hex(0xFF6B63), hex(0x30D158), hex(0xFFD60A), hex(0x5EA2FF), hex(0xD28CF0), hex(0x5EEAD4), hex(0xD5DEE8),
        hex(0x5C6A7B), hex(0xFF8A84), hex(0x6EF08F), hex(0xFFE45E), hex(0x8DBBFF), hex(0xE3B0F7), hex(0x9CF5E6), hex(0xFFFFFF),
    ]

    /// xterm 256-colour palette (16 base colours from the theme, 6×6×6 cube, 24 greys).
    static let palette256: [UIColor] = {
        var colors = ansi
        let steps: [CGFloat] = [0, 95, 135, 175, 215, 255]
        for r in 0..<6 { for g in 0..<6 { for b in 0..<6 {
            colors.append(UIColor(red: steps[r] / 255, green: steps[g] / 255, blue: steps[b] / 255, alpha: 1))
        } } }
        for i in 0..<24 {
            let v = CGFloat(8 + i * 10) / 255
            colors.append(UIColor(red: v, green: v, blue: v, alpha: 1))
        }
        return colors
    }()

    static func color(_ c: TermColor, isForeground: Bool, bold: Bool = false) -> UIColor {
        switch c {
        case .default: return isForeground ? foreground : background
        case .indexed(let i):
            let idx = (bold && isForeground && i < 8) ? Int(i) + 8 : Int(i)
            return palette256[idx]
        case .rgb(let r, let g, let b): return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
    }
}
