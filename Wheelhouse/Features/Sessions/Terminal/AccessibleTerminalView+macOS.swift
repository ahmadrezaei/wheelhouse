import AppKit
import SwiftTerm

/// The terminal text VoiceOver reads: the live screen plus a capped slice of scrollback, one accessibility line per logical
/// line (soft-wrapped rows are joined). A plain value so the line arithmetic is testable without a view.
struct TerminalAccessibilityText: Equatable {
    /// The lines, oldest first. The last `liveRowCount` of them touch the live screen.
    let rows: [String]
    let liveRowCount: Int
    /// Index into `rows` of the line the cursor is on.
    let cursorLine: Int
    /// UTF-16 offset of the cursor inside its line.
    let cursorOffset: Int

    /// Lines joined with newlines; the last line carries none.
    let value: String
    /// UTF-16 range of each line inside `value`, newline excluded.
    let lineRanges: [NSRange]

    init(rows: [String], liveRowCount: Int, cursorLine: Int, cursorOffset: Int = 0) {
        self.rows = rows
        self.liveRowCount = min(max(liveRowCount, 0), rows.count)
        self.cursorLine = min(max(cursorLine, 0), max(rows.count - 1, 0))
        self.cursorOffset = max(cursorOffset, 0)
        value = rows.joined(separator: "\n")
        var ranges: [NSRange] = []
        var location = 0
        for row in rows {
            let length = (row as NSString).length
            ranges.append(NSRange(location: location, length: length))
            location += length + 1
        }
        lineRanges = ranges
    }

    var length: Int { (value as NSString).length }

    /// The live screen: what a sighted user sees unless they scrolled back.
    var visibleRange: NSRange {
        let first = rows.count - liveRowCount
        guard liveRowCount > 0, first >= 0, first < lineRanges.count else { return NSRange(location: 0, length: length) }
        let start = lineRanges[first].location
        return NSRange(location: start, length: length - start)
    }

    func line(for index: Int) -> Int {
        guard !lineRanges.isEmpty else { return 0 }
        let clamped = max(index, 0)
        return lineRanges.lastIndex { $0.location <= clamped } ?? 0
    }

    func range(forLine line: Int) -> NSRange {
        guard lineRanges.indices.contains(line) else { return NSRange(location: 0, length: 0) }
        let r = lineRanges[line]
        // Include the newline so a line range reads as a whole line.
        return NSRange(location: r.location, length: min(r.length + 1, length - r.location))
    }

    func string(for range: NSRange) -> String {
        let whole = NSRange(location: 0, length: length)
        let clamped = NSIntersectionRange(range, whole)
        return (value as NSString).substring(with: clamped)
    }

    /// Where VoiceOver puts the insertion point: the cursor's position inside its line.
    var insertionPoint: Int {
        guard lineRanges.indices.contains(cursorLine) else { return 0 }
        let r = lineRanges[cursorLine]
        return r.location + min(cursorOffset, r.length)
    }

    /// The last command's output. The text before the cursor on its line is the prompt; the output is whatever sits between the
    /// previous line that starts with the same prompt and the cursor line. The terminal carries no per-command marks to the host
    /// (the vendored SwiftTerm exposes none), so with no earlier prompt it falls back to the last block of non-blank lines.
    func lastOutput(maxLines: Int = 40) -> String {
        guard rows.indices.contains(cursorLine) else { return "" }
        let prompt = String(rows[cursorLine].prefix(cursorOffset)).trimmingCharacters(in: .whitespaces)
        if !prompt.isEmpty, let previous = rows[..<cursorLine].lastIndex(where: { $0.hasPrefix(prompt) }) {
            return rows[(previous + 1)..<cursorLine].suffix(maxLines).joined(separator: "\n")
        }
        var end = cursorLine - 1
        while end >= 0, rows[end].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
        guard end >= 0 else { return "" }
        var start = end
        while start > 0, end - start + 1 < maxLines, !rows[start - 1].trimmingCharacters(in: .whitespaces).isEmpty { start -= 1 }
        return rows[start...end].joined(separator: "\n")
    }
}

/// The SwiftTerm Mac view with a real accessibility surface: a read-only text area exposing the screen and recent scrollback
/// (SwiftTerm ships none). The text is rebuilt lazily and at most four times a second, and only when VoiceOver asks, so the
/// terminal costs nothing for everyone else. The pod shell and the Deck Terminal both use this view.
final class AccessibleTerminalView: TerminalView {
    /// Scrollback rows VoiceOver can read above the screen. Without VoiceOver nothing but the live screen is ever copied out.
    static let scrollbackRowsForAccessibility = 500
    static let changeInterval: TimeInterval = 0.25

    /// Swapped by tests.
    var voiceOverIsRunning: () -> Bool = { NSWorkspace.shared.isVoiceOverEnabled } {
        didSet { voiceOverCheckedAt = .distantPast }
    }
    /// How many times the text was rebuilt (tests).
    private(set) var buildCount = 0
    /// VoiceOver's state is read at most once a second, not on every chunk of output.
    private var voiceOverOn = false
    private var voiceOverCheckedAt = Date.distantPast
    static let voiceOverCheckInterval: TimeInterval = 1
    var postNotification: ((NSAccessibility.Notification) -> Void)?
    var announce: ((String) -> Void)?
    var now: () -> Date = Date.init

    private var cachedText: TerminalAccessibilityText?
    private var isDirty = true
    private var lastBuild = Date.distantPast
    private var changePending = false

    /// Called after bytes were fed, the grid resized or the font changed. Marks the text stale and, while VoiceOver runs, schedules
    /// one trailing value-changed post so the last state is read once output stops. SwiftTerm itself posts value-changed after every
    /// frame, so the rebuild (not the post) is what is throttled.
    func contentDidChange() {
        isDirty = true
        guard !changePending, refreshVoiceOverState() else { return }
        changePending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.changeInterval) { [weak self] in
            guard let self else { return }
            changePending = false
            lastBuild = .distantPast
            if let postNotification { postNotification(.valueChanged) } else { NSAccessibility.post(element: self, notification: .valueChanged) }
        }
    }

    /// The cached VoiceOver state, refreshed when it is older than a second. A change of state makes the text stale.
    @discardableResult
    private func refreshVoiceOverState() -> Bool {
        let current = now()
        if current.timeIntervalSince(voiceOverCheckedAt) >= Self.voiceOverCheckInterval {
            let running = voiceOverIsRunning()
            if running != voiceOverOn { voiceOverOn = running; isDirty = true; cachedText = nil }
            voiceOverCheckedAt = current
        }
        return voiceOverOn
    }

    var accessibilityText: TerminalAccessibilityText {
        let withScrollback = refreshVoiceOverState()
        if let cachedText, !isDirty || now().timeIntervalSince(lastBuild) < Self.changeInterval { return cachedText }
        // The scrollback (anything that scrolled off, possibly secrets) is copied out only for a person using VoiceOver.
        let region: TerminalContentRegion = withScrollback ? .history(maximumScrollbackRows: Self.scrollbackRowsForAccessibility) : .history(maximumScrollbackRows: -1)
        let text = Self.makeText(from: terminalContentSnapshot(region: region))
        cachedText = text
        buildCount += 1
        isDirty = false
        lastBuild = now()
        return text
    }

    /// Soft-wrapped rows are joined into one logical line, so long log lines read and navigate as lines.
    static func makeText(from snapshot: TerminalContentSnapshot?) -> TerminalAccessibilityText {
        guard let snapshot else { return TerminalAccessibilityText(rows: [], liveRowCount: 0, cursorLine: 0) }
        var lines: [String] = []
        var lastRowOfLine: [Int] = []
        var cursorLine = 0
        var cursorOffset = 0
        for row in snapshot.rows {
            if row.isWrapped, !lines.isEmpty {
                lines[lines.count - 1] += row.text
                lastRowOfLine[lines.count - 1] = row.absoluteRow
            } else {
                lines.append(row.text)
                lastRowOfLine.append(row.absoluteRow)
            }
            if row.absoluteRow == snapshot.cursorRow {
                cursorLine = lines.count - 1
                let before = (lines[cursorLine] as NSString).length - (row.text as NSString).length
                let column = min(max(snapshot.cursorColumn, 0), row.cells.count)
                let inRow = row.cells.prefix(column).reduce(0) { $0 + ($1.text.isEmpty ? ($1.width == 0 ? 0 : 1) : ($1.text as NSString).length) }
                cursorOffset = before + min(inRow, (row.text as NSString).length)
            }
        }
        let live = lastRowOfLine.filter { $0 >= snapshot.liveTopRow }.count
        return TerminalAccessibilityText(rows: lines, liveRowCount: live, cursorLine: cursorLine, cursorOffset: cursorOffset)
    }

    func speak(_ text: String) {
        if let announce { announce(text); return }
        NSAccessibility.post(element: self, notification: .announcementRequested, userInfo: [
            .announcement: text,
            .priority: NSAccessibilityPriorityLevel.high.rawValue,
        ])
    }

    // MARK: NSAccessibility

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityValue() -> Any? { accessibilityText.value }
    override func accessibilityNumberOfCharacters() -> Int { accessibilityText.length }
    override func accessibilityVisibleCharacterRange() -> NSRange { accessibilityText.visibleRange }
    override func accessibilityLine(for index: Int) -> Int { accessibilityText.line(for: index) }
    override func accessibilityRange(forLine line: Int) -> NSRange { accessibilityText.range(forLine: line) }
    override func accessibilityString(for range: NSRange) -> String? { accessibilityText.string(for: range) }
    override func accessibilityInsertionPointLineNumber() -> Int { accessibilityText.cursorLine }

    override func accessibilitySelectedText() -> String? { selectionActive ? getSelection() ?? "" : "" }

    override func accessibilitySelectedTextRange() -> NSRange {
        let text = accessibilityText
        // A best guess: SwiftTerm keeps the selection's coordinates internal, so the selected text is searched for, the live screen first.
        if selectionActive, let selected = getSelection(), !selected.isEmpty {
            let value = text.value as NSString
            var found = value.range(of: selected, options: .backwards, range: text.visibleRange)
            if found.location == NSNotFound { found = value.range(of: selected, options: .backwards) }
            if found.location != NSNotFound { return found }
        }
        return NSRange(location: text.insertionPoint, length: 0)
    }

    override func accessibilityCustomActions() -> [NSAccessibilityCustomAction]? {
        [NSAccessibilityCustomAction(name: "Speak Last Output") { [weak self] in
            guard let self else { return false }
            let output = accessibilityText.lastOutput()
            speak(output.isEmpty ? "No output" : output)
            return true
        }]
    }
}
