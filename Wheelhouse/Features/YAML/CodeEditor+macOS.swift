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
    /// Opens the completion list at the caret (⎋ and F5 inside the editor do the same).
    func complete() { editor?.requestCompletion() }
    func foldAll() { editor?.foldAll() }
    func unfoldAll() { editor?.unfoldAll() }
    /// ⌘/: comments or uncomments the selected lines.
    func toggleComment() { editor?.toggleComment() }
    var caretLine: Int { editor?.currentLine ?? 1 }

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
    /// Manifest Editor extras (M7), all additive: schema findings drawn as squiggles, fold ranges, and the source of completions
    /// and hover text. Create-from-YAML and the plain viewer leave them at their defaults.
    var schemaDiagnostics: [ManifestDiagnostic] = []
    var folds: [ManifestFoldRange] = []
    var collapsedByDefault: [Int] = []
    var assist: (any EditorAssisting)?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> CodeEditorScrollView {
        let v = CodeEditorScrollView()
        v.textView.delegate = context.coordinator
        v.setText(text)
        v.setEditable(isEditable)
        v.setEnabled(context.environment.isEnabled)
        v.setWraps(wraps)
        v.assist = assist
        v.setDiagnostics(diagnostics)
        v.setSchemaDiagnostics(schemaDiagnostics)
        v.setFolds(folds, collapsed: collapsedByDefault)
        controller.editor = v
        return v
    }

    func updateNSView(_ v: CodeEditorScrollView, context: Context) {
        context.coordinator.parent = self
        controller.editor = v
        if v.textView.string != text { v.setText(text) }
        v.setEditable(isEditable)
        // `.disabled` (a hidden tab, the lock) reaches AppKit only through here: the text view stops editing and taking the keyboard.
        v.setEnabled(context.environment.isEnabled)
        v.setWraps(wraps)
        v.assist = assist
        v.setDiagnostics(diagnostics)
        v.setSchemaDiagnostics(schemaDiagnostics)
        v.setFolds(folds, collapsed: collapsedByDefault)
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

        /// The list the last `requestCompletion()` computed (native completion asks synchronously, so the answer is prepared first).
        func textView(_ textView: NSTextView, completions words: [String], forPartialWordRange charRange: NSRange,
                      indexOfSelectedItem index: UnsafeMutablePointer<Int>?) -> [String] {
            guard let pending = (textView as? YAMLNSTextView)?.editor?.pendingCompletion else { return [] }
            index?.pointee = 0
            // The system asks again on every keystroke and does not filter the answer: narrow by what is now in `charRange`, with the
            // rule and the ranking `ManifestAssist` uses (prefix matches first, else substring matches).
            let ns = textView.string as NSString
            let range = NSIntersectionRange(charRange, NSRange(location: 0, length: ns.length))
            return ManifestAssist.narrow(pending.items, typed: ns.substring(with: range)).map(\.insertText)
        }
    }
}

// MARK: - Text view

final class YAMLNSTextView: NSTextView {
    weak var editor: CodeEditorScrollView?
    private var tracking: NSTrackingArea?

    /// ⎋ and F5 reach here (`complete:`): the editor computes the list first, then the system list is shown. (⌃Space is macOS's
    /// input-source shortcut, so it is not used.)
    override func complete(_ sender: Any?) {
        guard let editor, editor.assist != nil else { super.complete(sender); return }
        editor.requestCompletion()
    }

    func showSystemCompletion() { super.complete(nil) }

    /// A disabled editor (`.disabled` in SwiftUI: a hidden tab, the lock) never takes the keyboard.
    override var acceptsFirstResponder: Bool { (editor?.isEnabled ?? true) && super.acceptsFirstResponder }

    /// `makeFirstResponder` does not consult `acceptsFirstResponder`: refuse here too while disabled.
    override func becomeFirstResponder() -> Bool { (editor?.isEnabled ?? true) && super.becomeFirstResponder() }

    /// From where the suggestions started to the caret, so typing while the list is open keeps narrowing the replaced word.
    override var rangeForUserCompletion: NSRange {
        guard let pending = editor?.pendingCompletion else { return super.rangeForUserCompletion }
        let caret = selectedRange().location
        return NSRange(location: pending.range.location, length: max(0, caret - pending.range.location))
    }

    override func insertCompletion(_ word: String, forPartialWordRange charRange: NSRange, movement: Int, isFinal flag: Bool) {
        super.insertCompletion(word, forPartialWordRange: charRange, movement: movement, isFinal: flag)
        if flag { editor?.pendingCompletion = nil }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        editor?.pointerMoved(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        editor?.pointerLeft()
    }

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
final class CodeEditorScrollView: NSScrollView, @MainActor NSTextContentStorageDelegate {
    let textView = YAMLNSTextView(usingTextLayoutManager: true)
    private let gutter = GutterRulerView()
    private var diagnostics: [YAMLDiagnostic] = []
    private var schemaDiagnostics: [ManifestDiagnostic] = []
    /// Manifest Editor (M7): the completion list prepared for the system popup, the hover popover and the folds.
    weak var assist: (any EditorAssisting)?
    var pendingCompletion: ManifestCompletionResult?
    private var completionTask: Task<Void, Never>?
    private var hoverTask: Task<Void, Never>?
    private var hoverPopover: NSPopover?
    private var hoverRange: NSRange?
    private var folds: [ManifestFoldRange] = []
    /// Header lines of the folds that are closed.
    private(set) var collapsed: Set<Int> = []
    private var knownFoldHeaders: Set<Int> = []
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
        textView.textContentStorage?.delegate = self

        gutter.textView = textView
        gutter.editor = self
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
        completionTask?.cancel(); hoverTask?.cancel()
        hoverPopover?.close()
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
        guard requestedEditable != e else { return }
        requestedEditable = e
        textView.isEditable = e && isEnabled
        textView.isSelectable = true
        textView.undoManager?.removeAllActions()
    }

    /// Edit mode as the editor's owner asked for it; the text view is editable only while the editor is also enabled.
    private var requestedEditable: Bool?
    /// False while SwiftUI disables the editor: not editable, not first responder. Leaving and re-entering keeps the undo history.
    private(set) var isEnabled = true

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if requestedEditable == nil { requestedEditable = textView.isEditable }
        isEnabled = enabled
        textView.isEditable = enabled && (requestedEditable ?? false)
        if !enabled, let window = textView.window, window.firstResponder === textView { window.makeFirstResponder(nil) }
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
        updateGutterMarks()
        scheduleHighlight(immediate: true)
    }

    func setSchemaDiagnostics(_ d: [ManifestDiagnostic]) {
        guard d != schemaDiagnostics else { return }
        schemaDiagnostics = d
        updateGutterMarks()
        scheduleHighlight(immediate: true)
    }

    /// Errors win over warnings on the same line; syntax errors and schema findings share the gutter.
    private func updateGutterMarks() {
        var marks: [Int: YAMLDiagnostic.Severity] = [:]
        for d in schemaDiagnostics { marks[d.span.line] = (marks[d.span.line] == .error || d.severity == .error) ? .error : .warning }
        for d in diagnostics { marks[d.line] = (d.severity == .error || marks[d.line] == nil) ? d.severity : marks[d.line] }
        gutter.errorLines = marks
        gutter.needsDisplay = true
    }

    /// The UTF-16 range of a diagnostic span in the current text (at least one character wide).
    func nsRange(of span: YAMLSpan) -> NSRange {
        let total = (textView.string as NSString).length
        func offset(_ line: Int, _ column: Int) -> Int {
            let i = max(0, min(line - 1, lineStarts.count - 1))
            return min(lineStarts[i] + max(0, column), total)
        }
        let a = offset(span.line, span.column)
        let b = max(offset(span.endLine, span.endColumn), min(a + 1, total))
        return NSRange(location: a, length: max(0, b - a))
    }

    /// 1-based line of the caret.
    var currentLine: Int { lineIndex(forOffset: textView.selectedRange().location) + 1 }

    // MARK: Updates

    func textDidChange(editedAt offset: Int, immediate: Bool = false) {
        lastEditOffset = offset
        let previousLines = lineStarts.count
        lineStarts = Self.computeLineStarts(textView.string)
        // Closed folds are remembered by line number: a change in the number of lines moves them, so they open.
        if lineStarts.count != previousLines, !collapsed.isEmpty { unfoldAll() }
        if let pending = pendingCompletion, offset < pending.range.location { pendingCompletion = nil }
        gutter.lineCount = lineStarts.count
        gutter.updateThickness()
        gutter.needsDisplay = true
        scheduleHighlight(immediate: immediate)
    }

    func selectionDidChange() {
        gutter.currentLine = lineIndex(forOffset: textView.selectedRange().location) + 1
        gutter.needsDisplay = true
        // A caret that lands inside a closed fold opens it.
        if let header = collapsed.first(where: { h in folds.first { $0.startLine == h }.map { gutter.currentLine > $0.startLine && gutter.currentLine <= $0.endLine } ?? false }) {
            toggleFold(atLine: header)
        }
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
        for d in schemaDiagnostics {
            let r = nsRange(of: d.span)
            guard r.length > 0, NSIntersectionRange(r, window).length > 0 else { continue }
            let colour = d.severity == .error ? EditorColors.error : EditorColors.warning
            storage.addAttributes([.underlineStyle: NSUnderlineStyle.single.rawValue | NSUnderlineStyle.patternDot.rawValue, .underlineColor: colour], range: r)
        }
        storage.endEditing()
        textView.typingAttributes = base
    }

    // MARK: Completion (M7)

    /// Computes the suggestions off the editing path, then opens the system completion list with them.
    func requestCompletion() {
        guard let assist, textView.isEditable, !textView.hasMarkedText() else { return }
        completionTask?.cancel()
        let text = textView.string
        let offset = textView.selectedRange().location
        completionTask = Task { [weak self] in
            let result = await assist.completions(text: text, offset: offset)
            guard !Task.isCancelled, let self, self.textView.string == text, self.textView.selectedRange().location == offset, !result.items.isEmpty else { return }
            self.pendingCompletion = result
            self.textView.showSystemCompletion()
        }
    }

    // MARK: Hover (M7)

    func pointerMoved(to point: NSPoint) {
        guard assist != nil || !schemaDiagnostics.isEmpty || !diagnostics.isEmpty else { return }
        let offset = textView.characterIndexForInsertion(at: point)
        if let current = hoverRange, NSLocationInRange(offset, current) { return }
        hoverTask?.cancel()
        closeHover()
        let text = textView.string
        hoverTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self, self.textView.string == text else { return }
            if let (range, message) = self.diagnosticMessage(at: offset) {
                self.showHover(NSAttributedString(string: message, attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor]), range: range)
                return
            }
            guard let assist = self.assist, let hover = await assist.hover(text: text, offset: offset), !Task.isCancelled, self.textView.string == text else { return }
            self.showHover(Self.format(hover), range: hover.range)
        }
    }

    func pointerLeft() {
        hoverTask?.cancel()
        closeHover()
    }

    func diagnosticMessage(at offset: Int) -> (NSRange, String)? {
        let hits = schemaDiagnostics.filter { NSLocationInRange(offset, nsRange(of: $0.span)) }
        var messages = hits.map(\.message)
        var range = hits.first.map { nsRange(of: $0.span) }
        for d in diagnostics where d.line >= 1 && d.line <= lineStarts.count {
            let start = lineStarts[d.line - 1]
            let end = d.line < lineStarts.count ? lineStarts[d.line] : (textView.string as NSString).length
            if offset >= start, offset < end {
                messages.insert(d.message, at: 0)
                range = range ?? NSRange(location: start, length: max(1, end - start - 1))
            }
        }
        guard let range, !messages.isEmpty else { return nil }
        return (range, messages.joined(separator: "\n"))
    }

    static func format(_ h: ManifestHover) -> NSAttributedString {
        let out = NSMutableAttributedString()
        out.append(NSAttributedString(string: h.title, attributes: [.font: NSFont.monospacedSystemFont(ofSize: 12, weight: .semibold), .foregroundColor: NSColor.labelColor]))
        out.append(NSAttributedString(string: "  \(h.type)\(h.required ? " · required" : "")\n", attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        if let doc = h.documentation { out.append(NSAttributedString(string: doc + "\n", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor])) }
        if !h.choices.isEmpty {
            out.append(NSAttributedString(string: "One of: " + h.choices.prefix(10).joined(separator: ", "), attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]))
        }
        return out
    }

    private func showHover(_ text: NSAttributedString, range: NSRange) {
        guard let window = textView.window, range.length > 0 else { return }
        let screen = textView.firstRect(forCharacterRange: range, actualRange: nil)
        let inView = textView.convert(window.convertFromScreen(screen), from: nil)
        let label = NSTextField(labelWithAttributedString: text)
        label.preferredMaxLayoutWidth = 360
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.frame = NSRect(origin: NSPoint(x: 10, y: 8), size: label.sizeThatFits(NSSize(width: 360, height: 10_000)))
        let content = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + 20, height: label.frame.height + 16))
        content.addSubview(label)
        let controller = NSViewController()
        controller.view = content
        let popover = NSPopover()
        popover.contentViewController = controller
        popover.behavior = .semitransient
        popover.animates = false
        popover.show(relativeTo: inView, of: textView, preferredEdge: .maxY)
        hoverPopover = popover
        hoverRange = range
    }

    private func closeHover() {
        hoverPopover?.close()
        hoverPopover = nil
        hoverRange = nil
    }

    // MARK: Folding (M7)

    /// Lines hidden by the closed folds (everything after a header up to the fold's last line).
    private(set) var hiddenLines: [ClosedRange<Int>] = []

    /// New fold ranges from an analysis. Folds that disappeared close; headers seen for the first time that are in `initial` start closed.
    func setFolds(_ new: [ManifestFoldRange], collapsed initial: [Int]) {
        guard new != folds else { return }
        folds = new
        let headers = Set(new.map(\.startLine))
        var next = collapsed.intersection(headers)
        for h in initial where headers.contains(h) && !knownFoldHeaders.contains(h) { next.insert(h) }
        knownFoldHeaders.formUnion(headers)
        gutter.foldHeaders = Dictionary(uniqueKeysWithValues: headers.map { ($0, next.contains($0)) })
        gutter.updateThickness()
        applyCollapsed(next, force: true)
    }

    func toggleFold(atLine line: Int) {
        guard folds.contains(where: { $0.startLine == line }) else { return }
        var next = collapsed
        if next.contains(line) { next.remove(line) } else { next.insert(line) }
        gutter.foldHeaders[line] = next.contains(line)
        applyCollapsed(next)
    }

    func foldAll() {
        let all = Set(folds.map(\.startLine))
        for h in all { gutter.foldHeaders[h] = true }
        applyCollapsed(all)
    }

    func unfoldAll() {
        for h in collapsed { gutter.foldHeaders[h] = false }
        applyCollapsed([])
    }

    private func applyCollapsed(_ next: Set<Int>, force: Bool = false) {
        guard next != collapsed || force else { gutter.needsDisplay = true; return }
        collapsed = next
        let previousHidden = hiddenLines
        hiddenLines = Self.hiddenLines(folds: folds, collapsed: next)
        if hiddenLines != previousHidden, let layout = textView.textLayoutManager { layout.invalidateLayout(for: layout.documentRange) }
        textView.needsLayout = true
        textView.needsDisplay = true
        gutter.needsDisplay = true
    }

    static func hiddenLines(folds: [ManifestFoldRange], collapsed: Set<Int>) -> [ClosedRange<Int>] {
        folds.filter { collapsed.contains($0.startLine) && $0.endLine > $0.startLine }
            .map { ($0.startLine + 1)...$0.endLine }
            .sorted { $0.lowerBound < $1.lowerBound }
    }

    func isLineHidden(_ line: Int) -> Bool { hiddenLines.contains { $0.contains(line) } }

    /// TextKit 2 asks which paragraphs take part in layout: the ones inside a closed fold do not. The text itself is untouched, so
    /// undo, copy and the find bar keep seeing every line.
    func textContentManager(_ contentManager: NSTextContentManager, shouldEnumerate textElement: NSTextElement, options: NSTextContentManager.EnumerationOptions) -> Bool {
        guard !hiddenLines.isEmpty, let start = textElement.elementRange?.location else { return true }
        let offset = contentManager.offset(from: contentManager.documentRange.location, to: start)
        return !isLineHidden(lineIndex(forOffset: offset) + 1)
    }

    // MARK: Commands

    /// ⌘/: toggles `# ` on every selected line (all commented: remove, otherwise add at the shallowest indent).
    func toggleComment() {
        guard textView.isEditable else { return }
        let ns = textView.string as NSString
        let sel = textView.selectedRange()
        let endsOnNewline = sel.length > 0 && ns.character(at: NSMaxRange(sel) - 1) == 10
        let block = ns.lineRange(for: NSRange(location: sel.location, length: max(0, sel.length - (endsOnNewline ? 1 : 0))))
        let original = ns.substring(with: block)
        let result = Self.toggledComment(original)
        guard result != original, textView.shouldChangeText(in: block, replacementString: result) else { return }
        textView.replaceCharacters(in: block, with: result)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: block.location, length: (result as NSString).length - (result.hasSuffix("\n") ? 1 : 0)))
    }

    static func toggledComment(_ block: String) -> String {
        var lines = block.components(separatedBy: "\n")
        let trailingNewline = lines.last == ""
        if trailingNewline { lines.removeLast() }
        let content = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allCommented = !content.isEmpty && content.allSatisfy { $0.drop { $0 == " " }.hasPrefix("#") }
        let indent = content.map { $0.prefix { $0 == " " }.count }.min() ?? 0
        let out = lines.map { line -> String in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            if allCommented {
                let lead = line.prefix { $0 == " " }
                var rest = line.dropFirst(lead.count).dropFirst()     // the `#`
                if rest.hasPrefix(" ") { rest = rest.dropFirst() }
                return String(lead) + rest
            }
            return String(line.prefix(indent)) + "# " + line.dropFirst(indent)
        }
        return out.joined(separator: "\n") + (trailingNewline ? "\n" : "")
    }
}

/// What the Manifest Editor supplies to the AppKit editor: suggestions and hover text for a position. Both run the schema engine
/// off the main actor.
@MainActor
protocol EditorAssisting: AnyObject {
    func completions(text: String, offset: Int) async -> ManifestCompletionResult
    func hover(text: String, offset: Int) async -> ManifestHover?
}

// MARK: - Gutter

/// Line numbers and error marks, drawn only for the lines in the viewport.
@MainActor
final class GutterRulerView: NSRulerView {
    weak var textView: NSTextView?
    weak var editor: CodeEditorScrollView?
    var errorLines: [Int: YAMLDiagnostic.Severity] = [:]
    /// Fold header lines (1-based) and whether each is closed. Empty when the editor has no folds (Create-from-YAML, the viewer).
    var foldHeaders: [Int: Bool] = [:]
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
        let t = ceil(w * CGFloat(digits)) + 22 + (foldHeaders.isEmpty ? 0 : 14)
        if abs(ruleThickness - t) > 0.5 { ruleThickness = t }
    }

    /// A click on a fold chevron opens or closes the fold.
    override func mouseDown(with event: NSEvent) {
        guard !foldHeaders.isEmpty, let tv = textView, let editor else { super.mouseDown(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        if local.x > bounds.maxX - 16 {
            let inText = tv.convert(event.locationInWindow, from: nil)
            let line = editor.lineIndex(forOffset: tv.characterIndexForInsertion(at: NSPoint(x: 0, y: inText.y))) + 1
            if foldHeaders[line] != nil { editor.toggleFold(atLine: line); return }
        }
        super.mouseDown(with: event)
    }

    override var requiredThickness: CGFloat { ruleThickness }

    static func mark(_ severity: YAMLDiagnostic.Severity?) -> NSColor { severity == .warning ? EditorColors.warning : EditorColors.error }

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
            if frame.height < 1 { return true }
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
                .foregroundColor: errorLines[line] != nil ? Self.mark(errorLines[line]) : (isCurrent ? NSColor.labelColor : NSColor.secondaryLabelColor),
            ]
            let numberInset: CGFloat = foldHeaders.isEmpty ? 10 : 24
            let size = label.size(withAttributes: attrs)
            let lineHeight = max(first.height, size.height)
            label.draw(at: NSPoint(x: bounds.maxX - size.width - numberInset, y: y + (lineHeight - size.height) / 2), withAttributes: attrs)
            if errorLines[line] != nil {
                Self.mark(errorLines[line]).setFill()
                NSBezierPath(ovalIn: NSRect(x: 5, y: y + (lineHeight - 6) / 2, width: 6, height: 6)).fill()
            }
            if let closed = foldHeaders[line] {
                let cx = bounds.maxX - 9, cy = y + lineHeight / 2
                let path = NSBezierPath()
                if closed {
                    path.move(to: NSPoint(x: cx - 2, y: cy - 4)); path.line(to: NSPoint(x: cx + 3, y: cy)); path.line(to: NSPoint(x: cx - 2, y: cy + 4))
                } else {
                    path.move(to: NSPoint(x: cx - 4, y: cy - 2)); path.line(to: NSPoint(x: cx, y: cy + 3)); path.line(to: NSPoint(x: cx + 4, y: cy - 2))
                }
                path.close()
                NSColor.secondaryLabelColor.setFill()
                path.fill()
            }
            return true
        }
    }
}
