import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

// MARK: - Controller

/// Lets SwiftUI drive the AppKit editor (toolbar buttons, jump-to-line, undo/redo). Same API as the iOS controller.
@MainActor @Observable
final class CodeEditorController {
    @ObservationIgnored fileprivate weak var editor: CodeEditorScrollView?
    private(set) var canUndo = false
    private(set) var canRedo = false

    func undo() { editor?.textView.undoManager?.undo(); refresh() }
    func redo() { editor?.textView.undoManager?.redo(); refresh() }
    func find() {
        guard let tv = editor?.textView else { return }
        tv.window?.makeFirstResponder(tv)
        let item = NSMenuItem()
        item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
        tv.performTextFinderAction(item)
    }
    func dismissKeyboard() { editor?.window?.makeFirstResponder(nil) }
    func focus() { if let tv = editor?.textView { tv.window?.makeFirstResponder(tv) } }
    func jump(toLine line: Int) { editor?.jump(toLine: line) }

    fileprivate func refresh() {
        let u = editor?.textView.undoManager?.canUndo ?? false
        let r = editor?.textView.undoManager?.canRedo ?? false
        if u != canUndo { canUndo = u }
        if r != canRedo { canRedo = r }
    }
}

// MARK: - SwiftUI wrapper

/// The basic Mac manifest editor (ARCHITECTURE-MAC section 1.6 row 24): TextKit 2 `NSTextView` in an `NSScrollView`, an `NSRulerView`
/// gutter with line numbers and error marks, YAML highlighting (the whole text for ordinary manifests, a window around the edit for
/// very large ones), the system find bar, and tab and newline handling that suits YAML. M7 grows it into the Manifest Editor.
struct YAMLCodeEditor: NSViewRepresentable {
    @Binding var text: String
    var isEditable: Bool
    var wraps: Bool
    var diagnostics: [YAMLDiagnostic] = []
    var controller: CodeEditorController

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeEditorScrollView {
        let v = CodeEditorScrollView()
        v.textView.delegate = context.coordinator
        v.setText(text)
        v.setEditable(isEditable)
        v.setWraps(wraps)
        v.setDiagnostics(diagnostics)
        controller.editor = v
        return v
    }

    func updateNSView(_ v: CodeEditorScrollView, context: Context) {
        context.coordinator.parent = self
        controller.editor = v
        if v.textView.string != text { v.setText(text) }
        v.setEditable(isEditable)
        v.setWraps(wraps)
        v.setDiagnostics(diagnostics)
    }

    static func dismantleNSView(_ v: CodeEditorScrollView, coordinator: Coordinator) { v.teardown() }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: YAMLCodeEditor
        init(_ parent: YAMLCodeEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? YAMLNSTextView else { return }
            parent.text = tv.string
            tv.editor?.textDidChange(editedAt: tv.selectedRange().location)
            parent.controller.refresh()
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? YAMLNSTextView else { return }
            tv.editor?.selectionDidChange()
        }
    }
}

// MARK: - Text view

final class YAMLNSTextView: NSTextView {
    weak var editor: CodeEditorScrollView?

    /// YAML forbids tab characters: Tab inserts two spaces.
    override func insertTab(_ sender: Any?) { insertText("  ", replacementRange: selectedRange()) }

    /// A new line keeps the indentation of the line above.
    override func insertNewline(_ sender: Any?) {
        let ns = string as NSString
        let caret = selectedRange().location
        let lineRange = ns.lineRange(for: NSRange(location: min(caret, ns.length), length: 0))
        var indent = ""
        var i = lineRange.location
        while i < min(caret, ns.length), ns.character(at: i) == 32 { indent += " "; i += 1 }
        insertText("\n" + indent, replacementRange: selectedRange())
    }
}

// MARK: - Container

@MainActor
final class CodeEditorScrollView: NSScrollView {
    let textView = YAMLNSTextView(usingTextLayoutManager: true)
    private let gutter = GutterRulerView()
    private var diagnostics: [YAMLDiagnostic] = []
    private var wraps = true
    private(set) var lineStarts: [Int] = [0]
    private var highlightTask: Task<Void, Never>?
    private var lastEditOffset = 0
    private static let fullHighlightLimit = 150_000     // UTF-16 units; beyond it only a window around the edit is tokenised

    private var font: NSFont {
        let size = UserDefaults.standard.double(forKey: "editorFontSize")
        return .monospacedSystemFont(ofSize: size >= 9 ? size : 13, weight: .regular)
    }

    init() {
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor

        textView.editor = self
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.textContainer?.lineFragmentPadding = 4
        textView.drawsBackground = false
        textView.setAccessibilityLabel("YAML editor")
        textView.setAccessibilityIdentifier("yaml.editor")
        documentView = textView

        gutter.textView = textView
        gutter.clientView = textView
        verticalRulerView = gutter
        hasVerticalRuler = true
        rulersVisible = true

        contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: contentView)
        applyFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func teardown() {
        highlightTask?.cancel(); highlightTask = nil
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func scrolled() { gutter.needsDisplay = true }

    // MARK: Configuration

    private func applyFont() {
        textView.font = font
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        gutter.numberFont = .monospacedDigitSystemFont(ofSize: max(10, font.pointSize - 2), weight: .regular)
    }

    func setText(_ new: String) {
        guard textView.string != new else { return }
        let sel = textView.selectedRange()
        textView.string = new
        let len = (new as NSString).length
        textView.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        textView.undoManager?.removeAllActions()
        textDidChange(editedAt: min(sel.location, len), immediate: true)
    }

    func setEditable(_ e: Bool) {
        guard textView.isEditable != e else { return }
        textView.isEditable = e
        textView.isSelectable = true
        textView.undoManager?.removeAllActions()
    }

    func setWraps(_ w: Bool) {
        guard wraps != w || textView.textContainer?.widthTracksTextView != w else { return }
        wraps = w
        hasHorizontalScroller = !w
        textView.isHorizontallyResizable = !w
        textView.textContainer?.widthTracksTextView = w
        textView.textContainer?.size = NSSize(width: w ? contentSize.width : CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = w ? [.width] : []
        needsLayout = true
    }

    func setDiagnostics(_ d: [YAMLDiagnostic]) {
        guard d != diagnostics else { return }
        diagnostics = d
        gutter.errorLines = Dictionary(d.map { ($0.line, $0.severity) }, uniquingKeysWith: { a, _ in a })
        gutter.needsDisplay = true
        scheduleHighlight(immediate: true)
    }

    // MARK: Updates

    func textDidChange(editedAt offset: Int, immediate: Bool = false) {
        lastEditOffset = offset
        lineStarts = Self.computeLineStarts(textView.string)
        gutter.lineCount = lineStarts.count
        gutter.updateThickness()
        gutter.needsDisplay = true
        scheduleHighlight(immediate: immediate)
    }

    func selectionDidChange() {
        gutter.currentLine = lineIndex(forOffset: textView.selectedRange().location) + 1
        gutter.needsDisplay = true
    }

    func lineIndex(forOffset offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return lo
    }

    static func computeLineStarts(_ text: String) -> [Int] {
        var starts = [0]
        var i = 0
        for u in text.utf16 {
            i += 1
            if u == 10 { starts.append(i) }
        }
        return starts
    }

    func jump(toLine line: Int) {
        let idx = max(0, min(line - 1, lineStarts.count - 1))
        let range = NSRange(location: lineStarts[idx], length: 0)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(NSRange(location: lineStarts[idx], length: 1))
        if textView.isEditable { textView.window?.makeFirstResponder(textView) }
    }

    // MARK: Highlighting

    /// Typing is highlighted after a 60 ms pause (a burst of keystrokes costs one pass); setting new text or diagnostics is immediate.
    private func scheduleHighlight(immediate: Bool) {
        highlightTask?.cancel()
        if immediate { rehighlight(); return }
        highlightTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled else { return }
            self?.rehighlight()
        }
    }

    private func rehighlight() {
        guard !textView.hasMarkedText() else { return }
        let storage = textView.textStorage!
        let text = textView.string
        let ns = text as NSString
        let total = ns.length
        let base: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.textColor]

        // Which part to (re)colour: everything for ordinary manifests, a window of lines around the edit for huge ones.
        var window = NSRange(location: 0, length: total)
        var source = text
        var shift = 0
        if total > Self.fullHighlightLimit {
            let line = lineIndex(forOffset: min(lastEditOffset, total))
            let first = max(0, line - 200), last = min(lineStarts.count - 1, line + 200)
            let start = lineStarts[first]
            let end = last + 1 < lineStarts.count ? lineStarts[last + 1] : total
            window = NSRange(location: start, length: end - start)
            source = ns.substring(with: window)
            shift = start
        }
        storage.beginEditing()
        storage.setAttributes(base, range: window)
        for t in YAMLTokenizer.tokens(in: source) {
            let r = NSRange(location: t.location + shift, length: t.length)
            if NSMaxRange(r) <= total { storage.addAttribute(.foregroundColor, value: EditorColors.color(for: t.kind), range: r) }
        }
        for d in diagnostics where d.severity == .error && d.line >= 1 && d.line <= lineStarts.count {
            let start = lineStarts[d.line - 1]
            let end = d.line < lineStarts.count ? lineStarts[d.line] : total
            var r = NSRange(location: start, length: max(0, end - start))
            while r.length > 0, ns.character(at: r.location) == 32 { r.location += 1; r.length -= 1 }
            while r.length > 0, ns.character(at: r.location + r.length - 1) == 10 { r.length -= 1 }
            if r.length > 0, NSIntersectionRange(r, window).length > 0 {
                storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: EditorColors.error], range: r)
            }
        }
        storage.endEditing()
        textView.typingAttributes = base
    }
}

// MARK: - Gutter

/// Line numbers and error marks, drawn only for the lines in the viewport.
@MainActor
final class GutterRulerView: NSRulerView {
    weak var textView: NSTextView?
    var errorLines: [Int: YAMLDiagnostic.Severity] = [:]
    var currentLine = 1
    var lineCount = 1
    var numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular) { didSet { updateThickness() } }

    init() {
        super.init(scrollView: nil, orientation: .verticalRuler)
        ruleThickness = 40
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func updateThickness() {
        let digits = max(3, String(lineCount).count)
        let w = ("0" as NSString).size(withAttributes: [.font: numberFont]).width
        let t = ceil(w * CGFloat(digits)) + 22
        if abs(ruleThickness - t) > 0.5 { ruleThickness = t }
    }

    override var requiredThickness: CGFloat { ruleThickness }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let tlm = tv.textLayoutManager, let tcm = tlm.textContentManager else { return }
        NSColor.windowBackgroundColor.withAlphaComponent(0.6).setFill()
        bounds.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: bounds.maxX - 0.5, y: rect.minY, width: 0.5, height: rect.height).fill()

        let visible = tv.visibleRect
        let inset = tv.textContainerOrigin
        let starts = (scrollView as? CodeEditorScrollView)?.lineStarts ?? [0]
        let docStart = tlm.documentRange.location
        guard let viewport = tlm.textViewportLayoutController.viewportRange ?? Optional(tlm.documentRange) else { return }
        tlm.enumerateTextLayoutFragments(from: viewport.location, options: [.ensuresLayout]) { fragment in
            let frame = fragment.layoutFragmentFrame
            if frame.minY + inset.y > visible.maxY { return false }
            let offset = tcm.offset(from: docStart, to: fragment.rangeInElement.location)
            var lo = 0, hi = starts.count - 1
            while lo < hi { let mid = (lo + hi + 1) / 2; if starts[mid] <= offset { lo = mid } else { hi = mid - 1 } }
            let line = lo + 1
            let isCurrent = line == currentLine
            let first = fragment.textLineFragments.first?.typographicBounds ?? CGRect(x: 0, y: 0, width: 0, height: frame.height)
            let y = self.convert(NSPoint(x: 0, y: frame.minY + inset.y), from: tv).y
            let label = "\(line)" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: isCurrent ? NSFont.monospacedDigitSystemFont(ofSize: numberFont.pointSize, weight: .semibold) : numberFont,
                .foregroundColor: errorLines[line] != nil ? EditorColors.error : (isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor),
            ]
            let size = label.size(withAttributes: attrs)
            let lineHeight = max(first.height, size.height)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - 10, y: y + (lineHeight - size.height) / 2), withAttributes: attrs)
            if errorLines[line] != nil {
                EditorColors.error.setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: y + (lineHeight - 6) / 2, width: 6, height: 6)).fill()
            }
            return true
        }
    }
}
