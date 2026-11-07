import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// Mac placeholder `TerminalSurface`, so the shared session code compiles and runs. M1b replaces its body with the SwiftTerm
/// `TerminalView` adapter (scrollback caps of ARCHITECTURE-MAC §12.3.2). Until then output is shown as plain text and typed
/// text is forwarded to the delegate.
@MainActor
final class SwiftTermSurface: NSObject, TerminalSurface {
    private let scroll = NSTextView.scrollableTextView()
    private var textView: NSTextView { scroll.documentView as! NSTextView }
    private var transcript = ""

    weak var delegate: (any TerminalSurfaceDelegate)?
    let modifiers = TerminalModifierState()
    var showsExtraKeys = false
    var fontSize: CGFloat = 13 { didSet { textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular) } }
    var view: PlatformView { scroll }
    var size: (cols: Int, rows: Int) { (0, 0) }
    var hasFocus: Bool { textView.window?.firstResponder === textView }

    override init() {
        super.init()
        textView.isEditable = false
        textView.backgroundColor = TerminalTheme.background
        textView.textColor = TerminalTheme.foreground
        textView.font = .monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }

    func feed(_ data: Data) { feed(String(decoding: data, as: UTF8.self)) }
    func feed(_ text: String) {
        transcript += text
        if transcript.count > 200_000 { transcript = String(transcript.suffix(150_000)) }
        textView.string = transcript
        textView.scrollToEndOfDocument(nil)
    }
    func reset() { transcript = ""; textView.string = "" }
    func clearScreen() { reset() }
    func allText() -> String { transcript }
    func sendKey(_ key: TerminalKey, modifiers: TerminalModifiers) {}
    func sendText(_ text: String) { delegate?.terminalSurface(self, send: Data(text.utf8)) }
    func pasteText(_ text: String) { sendText(text) }
    func focus() { textView.window?.makeFirstResponder(textView) }
    func blur() { textView.window?.makeFirstResponder(nil) }
}
