import SwiftUI
import UIKit
import WheelhouseKit
import WheelhouseUI

// MARK: - Controller

/// Lets SwiftUI drive the UIKit editor (toolbar buttons, jump-to-line, undo/redo).
@MainActor @Observable
final class CodeEditorController {
    @ObservationIgnored fileprivate weak var container: CodeEditorContainer?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() { container?.textView.undoManager?.undo(); refresh() }
    func redo() { container?.textView.undoManager?.redo(); refresh() }
    func find() { container?.textView.presentFind() }
    func dismissKeyboard() { container?.textView.resignFirstResponder() }
    func jump(toLine line: Int) { container?.jump(toLine: line) }
    func focus() { container?.textView.becomeFirstResponder() }

    fileprivate func refresh() {
        let u = container?.textView.undoManager?.canUndo ?? false
        let r = container?.textView.undoManager?.canRedo ?? false
        if u != canUndo { canUndo = u }
        if r != canRedo { canRedo = r }
    }
}

// MARK: - SwiftUI wrapper

struct YAMLCodeEditor: UIViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wraps: Bool
    var diagnostics: [YAMLDiagnostic] = []
    var controller: CodeEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> CodeEditorContainer {
        let v = CodeEditorContainer()
        v.textView.delegate = context.coordinator
        v.setText(text)
        v.setEditable(isEditable)
        v.setWraps(wraps)
        v.setDiagnostics(diagnostics)
        controller.container = v
        return v
    }

    func updateUIView(_ v: CodeEditorContainer, context: Context) {
        context.coordinator.parent = self
        controller.container = v
        if v.textView.text != text { v.setText(text) }
        v.setEditable(isEditable)
        v.setWraps(wraps)
        v.setDiagnostics(diagnostics)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: YAMLCodeEditor
        init(_ parent: YAMLCodeEditor) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            guard let tv = textView as? YAMLTextView else { return }
            parent.text = tv.text
            tv.container?.textDidChange()
            parent.controller.refresh()
        }
        func textViewDidChangeSelection(_ textView: UITextView) {
            (textView as? YAMLTextView)?.container?.selectionDidChange()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView as? YAMLTextView)?.container?.contentDidScroll()
        }
    }
}

// MARK: - Container (gutter + text view)

@MainActor
final class CodeEditorContainer: UIView {
    let textView = YAMLTextView(usingTextLayoutManager: true)
    private let gutter = GutterView()
    private let lineHighlight = UIView()
    private var diagnostics: [YAMLDiagnostic] = []
    private var wraps = true
    private var lineStarts: [Int] = [0]
    private var highlightWork: Task<Void, Never>?

    var errorLines: [Int: YAMLDiagnostic.Severity] { gutter.errorLines }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .secondarySystemGroupedBackground
        textView.container = self
        textView.backgroundColor = .clear
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.spellCheckingType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.keyboardType = .asciiCapable
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.isFindInteractionEnabled = true
        textView.textContainer.lineFragmentPadding = 4
        textView.accessibilityLabel = "YAML editor"
        textView.accessibilityIdentifier = "yaml.editor"
        textView.inputAccessoryView = AccessoryBar.make(for: textView)

        lineHighlight.backgroundColor = UIColor(Palette.tint).withAlphaComponent(0.09)
        lineHighlight.isUserInteractionEnabled = false
        gutter.textView = textView
        gutter.isOpaque = true
        gutter.isAccessibilityElement = false

        addSubview(lineHighlight)
        addSubview(textView)
        addSubview(gutter)
        clipsToBounds = true
        layer.cornerRadius = Radius.code
        layer.cornerCurve = .continuous
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self, UITraitUserInterfaceStyle.self]) { (self: CodeEditorContainer, _) in
            self.applyFont()
            self.rehighlight()
        }
        applyFont()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: Configuration

    private var font: UIFont {
        UIFontMetrics(forTextStyle: .footnote).scaledFont(for: .monospacedSystemFont(ofSize: 13, weight: .regular))
    }

    private func applyFont() {
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
        updateInsets()
    }

    func setText(_ new: String) {
        guard textView.text != new else { return }
        let sel = textView.selectedRange
        textView.text = new
        let len = (new as NSString).length
        textView.selectedRange = NSRange(location: min(sel.location, len), length: 0)
        textDidChange()
    }

    func setEditable(_ e: Bool) {
        guard textView.isEditable != e else { return }
        textView.isEditable = e
        textView.isSelectable = true
        lineHighlight.isHidden = !e
        textView.inputAccessoryView?.isHidden = !e
        textView.undoManager?.removeAllActions()
        setNeedsLayout()
    }

    func setWraps(_ w: Bool) {
        guard wraps != w || textView.textContainer.size.width == 0 else { return }
        wraps = w
        updateContainerSize()
    }

    func setDiagnostics(_ d: [YAMLDiagnostic]) {
        guard d != diagnostics else { return }
        diagnostics = d
        gutter.errorLines = Dictionary(d.map { ($0.line, $0.severity) }, uniquingKeysWith: { a, _ in a })
        gutter.setNeedsDisplay()
        rehighlight()
    }

    private func updateContainerSize() {
        if wraps {
            textView.textContainer.widthTracksTextView = true
            textView.textContainer.size = CGSize(width: max(bounds.width - textView.textContainerInset.left - textView.textContainerInset.right, 0), height: CGFloat.greatestFiniteMagnitude)
            textView.alwaysBounceHorizontal = false
        } else {
            textView.textContainer.widthTracksTextView = false
            textView.textContainer.size = CGSize(width: 20_000, height: CGFloat.greatestFiniteMagnitude)
            textView.alwaysBounceHorizontal = true
        }
        textView.setNeedsLayout()
        gutter.setNeedsDisplay()
    }

    private var gutterWidth: CGFloat {
        let digits = max(3, String(lineStarts.count).count)
        let w = ("0" as NSString).size(withAttributes: [.font: gutter.numberFont]).width
        return ceil(w * CGFloat(digits)) + 22
    }

    private func updateInsets() {
        let g = gutterWidth
        let inset = UIEdgeInsets(top: 8, left: g + 4, bottom: 12, right: 8)
        if textView.textContainerInset != inset {
            textView.textContainerInset = inset
            updateContainerSize()
        }
        gutter.frame = CGRect(x: 0, y: 0, width: g, height: bounds.height)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        textView.frame = bounds
        updateInsets()
        if wraps { updateContainerSize() }
        updateLineHighlight()
        gutter.setNeedsDisplay()
    }

    // MARK: Updates

    func textDidChange() {
        lineStarts = Self.computeLineStarts(textView.text)
        updateInsets()
        rehighlight()
        updateLineHighlight()
        gutter.setNeedsDisplay()
    }

    func selectionDidChange() {
        updateLineHighlight()
        gutter.currentLine = currentLine
        gutter.setNeedsDisplay()
    }

    func contentDidScroll() {
        updateLineHighlight()
        gutter.setNeedsDisplay()
    }

    var currentLine: Int { lineIndex(forOffset: textView.selectedRange.location) + 1 }

    func lineIndex(forOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }
    var lineCount: Int { lineStarts.count }
    var endsWithNewline: Bool { textView.text.hasSuffix("\n") }

    static func computeLineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var i = 0
        for u in text.utf16 {
            i += 1
            if u == 10 { starts.append(i) }
        }
        return starts
    }

    private func updateLineHighlight() {
        guard textView.isEditable, textView.isFirstResponder || true, let range = textView.selectedTextRange else { lineHighlight.isHidden = true; return }
        let caret = textView.caretRect(for: range.start)
        guard caret.height > 0, caret.height < 200 else { return }
        lineHighlight.isHidden = false
        let y = caret.minY - textView.contentOffset.y
        lineHighlight.frame = CGRect(x: 0, y: y, width: bounds.width, height: caret.height)
    }

    func jump(toLine line: Int) {
        let idx = max(0, min(line - 1, lineStarts.count - 1))
        let range = NSRange(location: lineStarts[idx], length: 0)
        textView.selectedRange = range
        textView.scrollRangeToVisible(NSRange(location: lineStarts[idx], length: 1))
        if textView.isEditable { textView.becomeFirstResponder() }
    }

    // MARK: Syntax highlighting

    private func rehighlight() {
        guard textView.markedTextRange == nil else { return }
        let storage = textView.textStorage
        let text = textView.text ?? ""
        let font = self.font
        storage.beginEditing()
        let full = NSRange(location: 0, length: storage.length)
        storage.setAttributes([.font: font, .foregroundColor: UIColor.label], range: full)
        for t in YAMLTokenizer.tokens(in: text) where t.location + t.length <= full.length {
            storage.addAttribute(.foregroundColor, value: EditorColors.color(for: t.kind), range: t.nsRange)
        }
        for d in diagnostics where d.severity == .error && d.line >= 1 && d.line <= lineStarts.count {
            let start = lineStarts[d.line - 1]
            let end = d.line < lineStarts.count ? lineStarts[d.line] : full.length
            var r = NSRange(location: start, length: max(0, end - start))
            // Don't underline the trailing newline or leading indentation.
            let ns = text as NSString
            while r.length > 0, ns.character(at: r.location) == 32 { r.location += 1; r.length -= 1 }
            while r.length > 0, ns.character(at: r.location + r.length - 1) == 10 { r.length -= 1 }
            if r.length > 0 {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: EditorColors.error], range: r)
            }
        }
        storage.endEditing()
        textView.typingAttributes = [.font: font, .foregroundColor: UIColor.label]
    }
}

// MARK: - Gutter

@MainActor
final class GutterView: UIView {
    weak var textView: YAMLTextView?
    var errorLines: [Int: YAMLDiagnostic.Severity] = [:]
    var currentLine = 1

    var numberFont: UIFont { UIFontMetrics(forTextStyle: .caption1).scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular)) }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .tertiarySystemGroupedBackground
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func draw(_ rect: CGRect) {
        guard let tv = textView, let container = tv.container, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        UIColor.opaqueSeparator.setFill()
        UIRectFill(CGRect(x: bounds.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height))

        let font = numberFont
        let startY = max(0, tv.bounds.minY - tv.textContainerInset.top)
        guard let first = tlm.textLayoutFragment(for: CGPoint(x: 0, y: startY)) else {
            drawNumber(1, y: tv.textContainerInset.top - tv.bounds.minY, height: font.lineHeight + 2, font: font)
            return
        }
        var lastDrawn = 0
        var lastMaxY: CGFloat = 0
        let endY = tv.bounds.maxY - tv.textContainerInset.top
        let docStart = tlm.documentRange.location
        tlm.enumerateTextLayoutFragments(from: first.rangeInElement.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            let offset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            let line = container.lineIndex(forOffset: offset) + 1
            let firstLine = fragment.textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: 0, height: font.lineHeight)
            let y = frame.minY + firstLine.minY + tv.textContainerInset.top - tv.bounds.minY
            if line > lastDrawn {
                self.drawNumber(line, y: y, height: firstLine.height, font: font)
                lastDrawn = line
            }
            lastMaxY = frame.maxY + tv.textContainerInset.top - tv.bounds.minY
            return frame.minY < endY
        }
        // Trailing empty line after a final newline has no layout fragment of its own.
        if container.endsWithNewline, lastDrawn == container.lineCount - 1 || lastDrawn == 0 {
            let caret = tv.caretRect(for: tv.endOfDocument)
            drawNumber(container.lineCount, y: caret.minY - tv.bounds.minY, height: caret.height, font: font)
        }
        _ = lastMaxY
    }

    private func drawNumber(_ line: Int, y: CGFloat, height: CGFloat, font: UIFont) {
        let severity = errorLines[line]
        let isCurrent = line == currentLine && (textView?.isEditable ?? false)
        let color: UIColor = severity == .error ? EditorColors.error : (isCurrent ? UIColor(Palette.tintText) : .tertiaryLabel)
        let weight = isCurrent ? UIFont.systemFont(ofSize: font.pointSize, weight: .bold) : font
        let attrs: [NSAttributedString.Key: Any] = [.font: isCurrent ? UIFont.monospacedDigitSystemFont(ofSize: font.pointSize, weight: .bold) : weight, .foregroundColor: color]
        let s = NSString(string: String(line))
        let size = s.size(withAttributes: attrs)
        s.draw(at: CGPoint(x: bounds.width - size.width - 8, y: y + (height - size.height) / 2), withAttributes: attrs)
        if severity != nil {
            let d: CGFloat = 6
            (severity == .error ? EditorColors.error : UIColor(Palette.warning)).setFill()
            UIBezierPath(ovalIn: CGRect(x: 5, y: y + (height - d) / 2, width: d, height: d)).fill()
        }
    }
}

// MARK: - Text view

@MainActor
final class YAMLTextView: UITextView {
    weak var container: CodeEditorContainer?

    // MARK: Smart indentation

    override func insertText(_ text: String) {
        if text == "\n", isEditable, markedTextRange == nil {
            super.insertText("\n" + indentForNewLine())
        } else {
            super.insertText(text)
        }
    }

    private func indentForNewLine() -> String {
        let ns = self.text as NSString
        let caret = selectedRange.location
        let lineRange = ns.lineRange(for: NSRange(location: caret, length: 0))
        let before = ns.substring(with: NSRange(location: lineRange.location, length: caret - lineRange.location))
        let leading = before.prefix { $0 == " " }.count
        var indent = leading
        var body = before.dropFirst(leading)
        let trimmedBody = String(body).trimmingCharacters(in: .whitespaces)
        if trimmedBody.hasPrefix("#") { return String(repeating: " ", count: indent) }
        var bulletPrefix = ""
        if body.hasPrefix("- ") || body == "-" {
            body = body.dropFirst(body.hasPrefix("- ") ? 2 : 1)
            let content = String(body).trimmingCharacters(in: .whitespaces)
            let looksLikeMapping = content.contains(": ") || content.hasSuffix(":")
            if looksLikeMapping || content.isEmpty { indent += 2 } else { bulletPrefix = "- " }
        }
        let tail = String(body).trimmingCharacters(in: .whitespaces)
        if tail.hasSuffix(":") || ["|", ">", "|-", "|+", ">-", ">+"].contains(where: { tail.hasSuffix(": " + $0) || tail == $0 }) { indent += 2 }
        return String(repeating: " ", count: indent) + bulletPrefix
    }

    // MARK: Hardware keyboard

    override var keyCommands: [UIKeyCommand]? {
        guard isEditable else { return super.keyCommands }
        func cmd(_ input: String, _ mods: UIKeyModifierFlags, _ action: Selector, _ title: String) -> UIKeyCommand {
            let c = UIKeyCommand(title: title, action: action, input: input, modifierFlags: mods)
            c.wantsPriorityOverSystemBehavior = true
            return c
        }
        return (super.keyCommands ?? []) + [
            cmd("\t", [], #selector(indentSelection), "Indent"),
            cmd("\t", .shift, #selector(outdentSelection), "Outdent"),
            cmd("]", .command, #selector(indentSelection), "Indent"),
            cmd("[", .command, #selector(outdentSelection), "Outdent"),
        ]
    }

    @objc func indentSelection() {
        let sel = selectedRange
        let ns = text as NSString
        if sel.length == 0 || !ns.substring(with: sel).contains("\n") {
            if sel.length == 0 { insertText("  ") } else { replaceSelectedLines(indent: true) }
            return
        }
        replaceSelectedLines(indent: true)
    }

    @objc func outdentSelection() { replaceSelectedLines(indent: false) }

    private func replaceSelectedLines(indent: Bool) {
        let ns = text as NSString
        let sel = selectedRange
        let lineRange = ns.lineRange(for: sel)
        let block = ns.substring(with: lineRange)
        var lines = block.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let hadTrailing = block.hasSuffix("\n")
        if hadTrailing { lines.removeLast() }
        var firstDelta = 0, total = 0
        lines = lines.enumerated().map { i, line in
            if indent {
                if line.isEmpty { return line }
                total += 2; if i == 0 { firstDelta = 2 }
                return "  " + line
            }
            let n = min(2, line.prefix { $0 == " " }.count)
            total -= n; if i == 0 { firstDelta = -n }
            return String(line.dropFirst(n))
        }
        let replacement = lines.joined(separator: "\n") + (hadTrailing ? "\n" : "")
        guard let start = position(from: beginningOfDocument, offset: lineRange.location),
              let end = position(from: beginningOfDocument, offset: lineRange.location + lineRange.length),
              let range = textRange(from: start, to: end) else { return }
        replace(range, withText: replacement)
        let newStart = max(lineRange.location, sel.location + firstDelta)
        selectedRange = NSRange(location: newStart, length: max(0, sel.length + total - firstDelta))
        container?.textDidChange()
        delegate?.textViewDidChange?(self)
    }

    func presentFind() {
        findInteraction?.presentFindNavigator(showingReplace: isEditable)
    }
}

// MARK: - iPhone accessory bar

@MainActor
enum AccessoryBar {
    static func make(for tv: YAMLTextView) -> UIView {
        let bar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        bar.sizeToFit()
        bar.tintColor = UIColor(Palette.tint)

        func char(_ s: String, label: String) -> UIBarButtonItem {
            let item = UIBarButtonItem(title: s, image: nil, primaryAction: UIAction { [weak tv] _ in tv?.insertText(s) }, menu: nil)
            item.setTitleTextAttributes([.font: UIFont.monospacedSystemFont(ofSize: 18, weight: .medium)], for: .normal)
            item.accessibilityLabel = label
            return item
        }
        func symbol(_ name: String, label: String, _ handler: @escaping @MainActor (YAMLTextView) -> Void) -> UIBarButtonItem {
            let item = UIBarButtonItem(image: UIImage(systemName: name), primaryAction: UIAction { [weak tv] _ in if let tv { handler(tv) } })
            item.accessibilityLabel = label
            return item
        }
        let flex = { UIBarButtonItem.flexibleSpace() }
        bar.items = [
            symbol("arrow.right.to.line", label: "Indent") { $0.indentSelection() },
            symbol("arrow.left.to.line", label: "Outdent") { $0.outdentSelection() },
            flex(), char("-", label: "Dash"),
            flex(), char(":", label: "Colon"),
            flex(), char("\"", label: "Quote"),
            flex(), char("#", label: "Comment"),
            flex(), symbol("magnifyingglass", label: "Find") { $0.presentFind() },
            flex(), symbol("arrow.uturn.backward", label: "Undo") { $0.undoManager?.undo(); $0.container?.textDidChange(); $0.delegate?.textViewDidChange?($0) },
            symbol("arrow.uturn.forward", label: "Redo") { $0.undoManager?.redo(); $0.container?.textDidChange(); $0.delegate?.textViewDidChange?($0) },
            flex(), symbol("keyboard.chevron.compact.down", label: "Dismiss keyboard") { $0.resignFirstResponder() },
        ]
        return bar
    }
}
