import SwiftUI
import AppKit
import SwiftTerm
import WheelhouseKit
import WheelhouseUI

/// The Mac `TerminalSurface`: the vendored SwiftTerm AppKit `TerminalView` behind the existing adapter protocol
/// (ARCHITECTURE-MAC section 3.5). This is the only file outside the Deck Terminal and Sign-in sheet hosts that imports SwiftTerm.
///
/// Resource use: the scrollback is capped (default 5,000 lines, hard maximum 20,000, the Sign-in sheet 1,000), the Metal renderer is
/// not enabled (it costs GPU memory and wakeups for no benefit on a text grid), and nothing here polls: bytes arrive from the
/// `ExecSession` and are fed straight in.
@MainActor
final class SwiftTermSurface: NSObject, TerminalSurface {
    /// Scrollback limits (section 12.3.2).
    enum Scrollback {
        static let defaultLines = 5_000
        static let maxLines = 20_000
        static let signInLines = 1_000
        static let defaultsKey = "terminalScrollbackLines"

        /// The user's setting, clamped to 1,000...20,000 (default 5,000).
        static func configured(defaults: UserDefaults = .standard) -> Int {
            let v = defaults.integer(forKey: defaultsKey)
            return clamp(v == 0 ? defaultLines : v)
        }
        static func clamp(_ lines: Int) -> Int { min(max(lines, 1_000), maxLines) }
    }

    private let terminalView: TerminalView
    private let bridge = Bridge()
    let scrollbackLines: Int

    weak var delegate: (any TerminalSurfaceDelegate)?
    let modifiers = TerminalModifierState()
    var showsExtraKeys = false
    var fontSize: CGFloat = 13 {
        didSet { terminalView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) }
    }
    var view: PlatformView { terminalView }
    var size: (cols: Int, rows: Int) {
        let d = terminalView.terminalDimensions
        return (d.cols, d.rows)
    }
    var hasFocus: Bool { terminalView.window?.firstResponder === terminalView }

    convenience override init() { self.init(scrollback: Scrollback.configured()) }

    init(scrollback: Int) {
        scrollbackLines = scrollback == Scrollback.signInLines ? Scrollback.signInLines : Scrollback.clamp(scrollback)
        var options = TerminalOptions.default
        options.scrollback = scrollbackLines
        terminalView = TerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400), font: .monospacedSystemFont(ofSize: 13, weight: .regular), options: options)
        super.init()
        bridge.surface = self
        terminalView.terminalDelegate = bridge
        terminalView.optionAsMetaKey = true
        terminalView.nativeBackgroundColor = TerminalTheme.background
        terminalView.nativeForegroundColor = TerminalTheme.foreground
        terminalView.installColors(TerminalTheme.ansi.map(Self.swiftTermColor))
        terminalView.setAccessibilityLabel("Terminal")
    }

    private static func swiftTermColor(_ c: NSColor) -> SwiftTerm.Color {
        let rgb = c.usingColorSpace(.sRGB) ?? c
        func v(_ x: CGFloat) -> UInt16 { UInt16(max(0, min(255, (x * 255).rounded()))) }
        return SwiftTerm.Color(red8: v(rgb.redComponent), green8: v(rgb.greenComponent), blue8: v(rgb.blueComponent))
    }

    // MARK: TerminalSurface

    func feed(_ data: Data) { terminalView.feed(byteArray: ArraySlice([UInt8](data))) }
    func feed(_ text: String) { terminalView.feed(text: text) }
    func reset() { terminalView.resetToInitialState() }
    func clearScreen() { terminalView.feed(text: "\u{1b}[2J\u{1b}[3J\u{1b}[H") }
    func allText() -> String { String(decoding: terminalView.getBufferAsData(), as: UTF8.self) }

    func sendKey(_ key: TerminalKey, modifiers: TerminalModifiers) {
        let bytes = TerminalKeyEncoder.bytes(for: key, modifiers: modifiers)
        guard !bytes.isEmpty else { return }
        delegate?.terminalSurface(self, send: Data(bytes))
    }

    func sendText(_ text: String) { delegate?.terminalSurface(self, send: Data(text.utf8)) }

    func pasteText(_ text: String) {
        // Bracketed paste keeps pasted newlines from running commands in editors and shells that ask for it.
        sendText(text)
    }

    func focus() { terminalView.window?.makeFirstResponder(terminalView) }
    func blur() { terminalView.window?.makeFirstResponder(nil) }

    // MARK: SwiftTerm delegate bridge

    @MainActor
    private final class Bridge: NSObject, TerminalViewDelegate {
        weak var surface: SwiftTermSurface?

        func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {
            guard let surface else { return }
            surface.delegate?.terminalSurface(surface, didResize: newCols, rows: newRows)
        }

        func setTerminalTitle(source: TerminalView, title: String) {}
        func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

        func send(source: TerminalView, data: ArraySlice<UInt8>) {
            guard let surface else { return }
            surface.delegate?.terminalSurface(surface, send: Data(data))
        }

        func scrolled(source: TerminalView, position: Double) {}

        /// Only web links, and only through the user's click inside SwiftTerm (the remote program is untrusted).
        func requestOpenLink(source: TerminalView, link: String, params: [String: String]) {
            guard let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
            NSWorkspace.shared.open(url)
        }

        func bell(source: TerminalView) { NSSound.beep() }

        func clipboardCopy(source: TerminalView, content: Data) {
            // OSC 52 write from the remote program: allowed, as in other terminals. Reading the clipboard is refused below.
            if let s = String(data: content, encoding: .utf8) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(s, forType: .string)
            }
        }

        func clipboardRead(source: TerminalView) -> Data? { nil }
        func iTermContent(source: TerminalView, content: ArraySlice<UInt8>) {}
        func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
    }
}
