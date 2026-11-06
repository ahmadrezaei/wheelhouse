import UIKit
import GameController
import WheelhouseKit

/// Fallback ``TerminalSurface``: renders a ``TerminalEmulator`` grid with Core Text and handles software + hardware keyboards.
/// Swapping to SwiftTerm later means writing another `TerminalSurface` adapter; nothing else changes.
@MainActor
final class BasicTerminalSurface: UIView, TerminalSurface, UIKeyInput, UITextInputTraits, @preconcurrency UIEditMenuInteractionDelegate, UIGestureRecognizerDelegate {
    // MARK: TerminalSurface
    var view: UIView { self }
    weak var delegate: (any TerminalSurfaceDelegate)?
    let modifiers = TerminalModifierState()
    var showsExtraKeys = true { didSet { if oldValue != showsExtraKeys { reloadInputViews() } } }
    var size: (cols: Int, rows: Int) { (emulator.cols, emulator.rows) }
    var hasFocus: Bool { isFirstResponder }

    var fontSize: CGFloat = 13 {
        didSet {
            fontSize = min(max(fontSize, 8), 26)
            guard fontSize != oldValue else { return }
            rebuildFonts()
            setNeedsLayout()
            setNeedsDisplay()
        }
    }

    // MARK: State
    let emulator = TerminalEmulator(cols: 80, rows: 24)
    private var regular = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    private var bold = UIFont.monospacedSystemFont(ofSize: 13, weight: .bold)
    private var italic = UIFont.italicSystemFont(ofSize: 13)
    private var cell = CGSize(width: 8, height: 16)
    private let inset: CGFloat = 6
    private var scrollOffset = 0
    private var panRemainder: CGFloat = 0
    private var reportedSize: (Int, Int) = (0, 0)
    private lazy var extraKeys: TerminalExtraKeysBar = {
        let bar = TerminalExtraKeysBar(state: modifiers)
        bar.onKey = { [weak self] key, mods in self?.sendKey(key, modifiers: mods) }
        bar.onText = { [weak self] text in self?.emit(Data(text.utf8)) }
        return bar
    }()
    private var editMenu: UIEditMenuInteraction?

    // UITextInputTraits: a terminal wants raw characters.
    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .asciiCapable
    var keyboardAppearance: UIKeyboardAppearance = .dark
    var returnKeyType: UIReturnKeyType = .default
    var enablesReturnKeyAutomatically = false
    var isSecureTextEntry = false
    var inlinePredictionType: UITextInlinePredictionType = .no

    // MARK: Init

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = TerminalTheme.background
        isOpaque = true
        contentMode = .redraw
        isAccessibilityElement = true
        accessibilityLabel = "Terminal"
        accessibilityTraits = [.allowsDirectInteraction, .updatesFrequently]
        rebuildFonts()
        emulator.onResponse = { [weak self] bytes in self?.emit(Data(bytes)) }

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped))
        addGestureRecognizer(tap)
        let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        pan.maximumNumberOfTouches = 1
        addGestureRecognizer(pan)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        addGestureRecognizer(pinch)
        let press = UILongPressGestureRecognizer(target: self, action: #selector(longPressed(_:)))
        press.minimumPressDuration = 0.5
        addGestureRecognizer(press)
        let menu = UIEditMenuInteraction(delegate: self)
        addInteraction(menu)
        editMenu = menu
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Fonts & layout

    private func rebuildFonts() {
        regular = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        bold = UIFont.monospacedSystemFont(ofSize: fontSize, weight: .bold)
        if let d = regular.fontDescriptor.withSymbolicTraits(.traitItalic) { italic = UIFont(descriptor: d, size: fontSize) } else { italic = regular }
        let w = ("M" as NSString).size(withAttributes: [.font: regular]).width
        let scale = max(traitCollection.displayScale, 2)
        cell = CGSize(width: max(4, (w * scale).rounded(.up) / scale), height: ceil(regular.lineHeight))
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let cols = max(2, Int((bounds.width - inset * 2) / cell.width))
        let rows = max(2, Int((bounds.height - inset * 2) / cell.height))
        guard bounds.width > 20, bounds.height > 20 else { return }
        if cols != emulator.cols || rows != emulator.rows { emulator.resize(cols: cols, rows: rows) }
        if reportedSize != (cols, rows) {
            reportedSize = (cols, rows)
            delegate?.terminalSurface(self, didResize: cols, rows: rows)
        }
        setNeedsDisplay()
    }

    // MARK: Output

    func feed(_ data: Data) {
        emulator.feed(data)
        if scrollOffset > 0 { scrollOffset = min(scrollOffset, emulator.scrollback.count) }
        setNeedsDisplay()
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
    }

    func feed(_ text: String) { feed(Data(text.utf8)) }

    func reset() { emulator.reset(); scrollOffset = 0; setNeedsDisplay() }

    func clearScreen() {
        emulator.feed("\u{1B}[3J\u{1B}[H\u{1B}[2J")
        scrollOffset = 0
        setNeedsDisplay()
    }

    func allText() -> String { emulator.allText() }

    // MARK: Input

    private func emit(_ data: Data) {
        guard !data.isEmpty else { return }
        if scrollOffset != 0 { scrollOffset = 0; setNeedsDisplay() }
        delegate?.terminalSurface(self, send: data)
    }

    func sendKey(_ key: TerminalKey, modifiers mods: TerminalModifiers) {
        emit(Data(TerminalKeyEncoder.bytes(for: key, modifiers: mods, applicationCursor: emulator.applicationCursorKeys)))
    }

    func sendText(_ text: String) {
        let mods = modifiers.consume()
        emit(Data(TerminalKeyEncoder.bytes(forText: text, modifiers: mods)))
    }

    func pasteText(_ text: String) {
        emit(Data(TerminalKeyEncoder.paste(text, bracketed: emulator.bracketedPaste)))
    }

    func focus() { becomeFirstResponder() }
    func blur() { resignFirstResponder() }

    override var canBecomeFirstResponder: Bool { true }

    // UIKeyInput
    var hasText: Bool { true }

    func insertText(_ text: String) {
        if text == "\n" { sendKey(.enter, modifiers: modifiers.consume()); return }
        sendText(text)
    }

    func deleteBackward() { emit(Data([0x7F])) }

    private var hardwareKeyboardAttached: Bool { GCKeyboard.coalesced != nil }

    override var inputAccessoryView: UIView? { showsExtraKeys && !hardwareKeyboardAttached ? extraKeys : nil }

    // MARK: Hardware keyboard

    private static let arrowInputs: [(String, TerminalKey)] = [
        (UIKeyCommand.inputUpArrow, .up), (UIKeyCommand.inputDownArrow, .down),
        (UIKeyCommand.inputLeftArrow, .left), (UIKeyCommand.inputRightArrow, .right),
    ]

    private lazy var hardwareCommands: [UIKeyCommand] = Self.makeCommands()

    override var keyCommands: [UIKeyCommand]? { hardwareCommands }

    private static func makeCommands() -> [UIKeyCommand] {
        var list: [UIKeyCommand] = []
        func add(_ input: String, _ flags: UIKeyModifierFlags = []) {
            let c = UIKeyCommand(input: input, modifierFlags: flags, action: #selector(BasicTerminalSurface.handleKeyCommand(_:)))
            c.wantsPriorityOverSystemBehavior = true
            list.append(c)
        }
        for (input, _) in arrowInputs { for flags: UIKeyModifierFlags in [[], .shift, .alternate, .control] { add(input, flags) } }
        add(UIKeyCommand.inputEscape)
        add("\t"); add("\t", .shift)
        add(UIKeyCommand.inputHome); add(UIKeyCommand.inputEnd)
        add(UIKeyCommand.inputPageUp); add(UIKeyCommand.inputPageDown)
        add(UIKeyCommand.inputDelete)
        for scalar in "abcdefghijklmnopqrstuvwxyz" { add(String(scalar), .control); add(String(scalar), .alternate) }
        for ch in ["[", "\\", "]", "^", "_", "@", " ", "?"] { add(ch, .control) }
        let clear = UIKeyCommand(title: "Clear", action: #selector(BasicTerminalSurface.clearCommand), input: "k", modifierFlags: .command)
        list.append(clear)
        return list
    }

    @objc private func handleKeyCommand(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        var mods: TerminalModifiers = []
        if command.modifierFlags.contains(.shift) { mods.insert(.shift) }
        if command.modifierFlags.contains(.alternate) { mods.insert(.alt) }
        if command.modifierFlags.contains(.control) { mods.insert(.control) }
        switch input {
        case UIKeyCommand.inputUpArrow: sendKey(.up, modifiers: mods)
        case UIKeyCommand.inputDownArrow: sendKey(.down, modifiers: mods)
        case UIKeyCommand.inputLeftArrow: sendKey(.left, modifiers: mods)
        case UIKeyCommand.inputRightArrow: sendKey(.right, modifiers: mods)
        case UIKeyCommand.inputEscape: sendKey(.escape, modifiers: [])
        case "\t": sendKey(mods.contains(.shift) ? .backTab : .tab, modifiers: [])
        case UIKeyCommand.inputHome: sendKey(.home, modifiers: [])
        case UIKeyCommand.inputEnd: sendKey(.end, modifiers: [])
        case UIKeyCommand.inputPageUp: sendKey(.pageUp, modifiers: [])
        case UIKeyCommand.inputPageDown: sendKey(.pageDown, modifiers: [])
        case UIKeyCommand.inputDelete: sendKey(.delete, modifiers: [])
        default:
            emit(Data(TerminalKeyEncoder.bytes(forText: input, modifiers: mods.subtracting(.shift))))
        }
    }

    @objc private func clearCommand() {
        clearScreen()
        emit(Data([0x0C]))
    }

    // MARK: Clipboard

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        switch action {
        case #selector(paste(_:)): return UIPasteboard.general.hasStrings
        case #selector(copy(_:)): return true
        default: return super.canPerformAction(action, withSender: sender)
        }
    }

    override func paste(_ sender: Any?) {
        if let s = UIPasteboard.general.string { pasteText(s) }
    }

    override func copy(_ sender: Any?) {
        UIPasteboard.general.string = allText()
    }

    func editMenuInteraction(_ interaction: UIEditMenuInteraction, menuFor configuration: UIEditMenuConfiguration, suggestedActions: [UIMenuElement]) -> UIMenu? {
        UIMenu(children: [
            UIAction(title: "Paste", image: UIImage(systemName: "doc.on.clipboard")) { [weak self] _ in self?.paste(nil) },
            UIAction(title: "Copy All", image: UIImage(systemName: "doc.on.doc")) { [weak self] _ in self?.copy(nil) },
            UIAction(title: "Clear", image: UIImage(systemName: "trash")) { [weak self] _ in self?.clearCommand() },
        ])
    }

    // MARK: Gestures

    @objc private func tapped() {
        scrollOffset = 0
        setNeedsDisplay()
        if isFirstResponder { reloadInputViews() } else { becomeFirstResponder() }
    }

    @objc private func longPressed(_ g: UILongPressGestureRecognizer) {
        guard g.state == .began else { return }
        becomeFirstResponder()
        editMenu?.presentEditMenu(with: UIEditMenuConfiguration(identifier: nil, sourcePoint: g.location(in: self)))
    }

    @objc private func pinched(_ g: UIPinchGestureRecognizer) {
        guard g.state == .changed else { return }
        let scaled = fontSize * g.scale
        if abs(scaled - fontSize) >= 0.5 {
            fontSize = scaled.rounded()
            g.scale = 1
        }
    }

    @objc private func panned(_ g: UIPanGestureRecognizer) {
        let dy = g.translation(in: self).y
        g.setTranslation(.zero, in: self)
        if emulator.usingAlternateScreen {
            // Full-screen apps (less, vi): scroll with arrow keys.
            panRemainder += dy
            while abs(panRemainder) >= cell.height * 1.5 {
                sendKey(panRemainder > 0 ? .up : .down, modifiers: [])
                panRemainder += panRemainder > 0 ? -cell.height * 1.5 : cell.height * 1.5
            }
            return
        }
        panRemainder += dy
        let lines = Int(panRemainder / cell.height)
        if lines != 0 {
            panRemainder -= CGFloat(lines) * cell.height
            scrollOffset = min(max(0, scrollOffset + lines), emulator.scrollback.count)
            setNeedsDisplay()
        }
    }

    func gestureRecognizer(_ g: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { false }

    // MARK: Drawing

    override func draw(_ rect: CGRect) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        ctx.setFillColor(TerminalTheme.background.cgColor)
        ctx.fill(rect)

        let rows = emulator.rows, cols = emulator.cols
        let firstLine = emulator.totalLines - rows - scrollOffset
        for y in 0..<rows {
            let cy = inset + CGFloat(y) * cell.height
            if cy + cell.height < rect.minY || cy > rect.maxY { continue }
            let line = emulator.line(at: firstLine + y)
            drawLine(line, y: cy, cols: cols, in: ctx)
        }
        if scrollOffset == 0, emulator.cursorVisible {
            let x = inset + CGFloat(emulator.cursorX) * cell.width
            let y = inset + CGFloat(emulator.cursorY) * cell.height
            let r = CGRect(x: x, y: y, width: cell.width, height: cell.height)
            if isFirstResponder {
                ctx.setFillColor(TerminalTheme.cursor.withAlphaComponent(0.9).cgColor)
                ctx.fill(r)
                let c = emulator.grid[emulator.cursorY][emulator.cursorX]
                if c.char != " " {
                    (String(c.char) as NSString).draw(at: CGPoint(x: x, y: y), withAttributes: [.font: regular, .foregroundColor: TerminalTheme.background])
                }
            } else {
                ctx.setStrokeColor(TerminalTheme.cursor.cgColor)
                ctx.setLineWidth(1)
                ctx.stroke(r.insetBy(dx: 0.5, dy: 0.5))
            }
        }
        if scrollOffset > 0 {
            let label = "↓ \(scrollOffset) lines up — tap to return"
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 11, weight: .semibold), .foregroundColor: TerminalTheme.background]
            let size = (label as NSString).size(withAttributes: attrs)
            let pill = CGRect(x: bounds.maxX - size.width - 22, y: bounds.maxY - size.height - 14, width: size.width + 16, height: size.height + 6)
            ctx.setFillColor(TerminalTheme.cursor.cgColor)
            UIBezierPath(roundedRect: pill, cornerRadius: pill.height / 2).fill()
            (label as NSString).draw(at: CGPoint(x: pill.minX + 8, y: pill.minY + 3), withAttributes: attrs)
        }
    }

    private func drawLine(_ line: [TermCell], y: CGFloat, cols: Int, in ctx: CGContext) {
        // Backgrounds first, merged per run.
        var x = 0
        while x < min(cols, line.count) {
            let c = line[x]
            let bg = effectiveBackground(c.style)
            var end = x + 1
            while end < min(cols, line.count), effectiveBackground(line[end].style) == bg { end += 1 }
            if bg != TerminalTheme.background {
                ctx.setFillColor(bg.cgColor)
                ctx.fill(CGRect(x: inset + CGFloat(x) * cell.width, y: y, width: CGFloat(end - x) * cell.width, height: cell.height))
            }
            x = end
        }
        // Text runs of ASCII with identical style; other characters individually so wide glyphs keep their cell.
        var runStart = 0
        var run = ""
        var runStyle: TermStyle?
        func flush() {
            guard let style = runStyle, !run.isEmpty else { run = ""; runStyle = nil; return }
            let isBold = style.attrs.contains(.bold)
            var fg = effectiveForeground(style)
            if style.attrs.contains(.dim) { fg = fg.withAlphaComponent(0.6) }
            var attrs: [NSAttributedString.Key: Any] = [.font: isBold ? bold : (style.attrs.contains(.italic) ? italic : regular), .foregroundColor: fg]
            if style.attrs.contains(.underline) { attrs[.underlineStyle] = NSUnderlineStyle.single.rawValue }
            if style.attrs.contains(.strike) { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            (run as NSString).draw(at: CGPoint(x: inset + CGFloat(runStart) * cell.width, y: y), withAttributes: attrs)
            run = ""; runStyle = nil
        }
        for i in 0..<min(cols, line.count) {
            let c = line[i]
            if c.isContinuation { flush(); continue }
            let isASCII = c.char.isASCII
            if c.char == " " && !c.style.attrs.contains(.underline) { flush(); continue }
            if isASCII, c.style == runStyle {
                run.append(c.char)
            } else {
                flush()
                runStart = i
                run = String(c.char)
                runStyle = c.style
                if !isASCII { flush() }
            }
        }
        flush()
    }

    private func effectiveForeground(_ s: TermStyle) -> UIColor {
        s.attrs.contains(.inverse) ? TerminalTheme.color(s.bg, isForeground: false) : TerminalTheme.color(s.fg, isForeground: true, bold: s.attrs.contains(.bold))
    }

    private func effectiveBackground(_ s: TermStyle) -> UIColor {
        s.attrs.contains(.inverse) ? TerminalTheme.color(s.fg, isForeground: true) : TerminalTheme.color(s.bg, isForeground: false)
    }

    // MARK: Accessibility

    override var accessibilityValue: String? {
        get { emulator.screenText() }
        set {}
    }
}
