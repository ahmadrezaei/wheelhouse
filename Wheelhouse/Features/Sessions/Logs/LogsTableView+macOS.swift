import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// View-based `NSTableView` log list for the Mac (ARCHITECTURE-MAC section 1.6 row 12, section 12.3.4).
///
/// - Virtualised: only visible rows have views; cells are reused; 20,000 lines cost the same as 20.
/// - Incremental: appends insert rows, a full ring dropping at the front removes and inserts rows; `reloadData()` is only used for the
///   first load and for changes that touch everything (settings, a different stream).
/// - Coalesced: at most 4 table updates per second (250 ms), and none while the window is hidden, minimised or occluded: the latest
///   state is applied when the view becomes visible again.
/// - Fixed row height with wrapping off; with wrapping on, the height comes from a character count per row (monospaced), cached per
///   line for the current width.
struct LogsTableView: NSViewRepresentable {
    let lines: [LogLine]
    let settings: LogsDisplaySettings
    let matcher: LogMatcher?
    let follow: Bool
    let scrollTarget: LogsModel.ScrollTarget?
    var onUserScrolledAway: () -> Void
    var onReachedBottom: () -> Void
    var onSelect: (LogLine) -> Void

    func makeNSView(context: Context) -> LogsScrollView {
        let v = LogsScrollView()
        v.onUserScrolledAway = onUserScrolledAway
        v.onReachedBottom = onReachedBottom
        v.onSelect = onSelect
        return v
    }

    func updateNSView(_ v: LogsScrollView, context: Context) {
        v.onUserScrolledAway = onUserScrolledAway
        v.onReachedBottom = onReachedBottom
        v.onSelect = onSelect
        v.apply(lines: lines, settings: settings, matcher: matcher, follow: follow, scrollTarget: scrollTarget)
    }

    static func dismantleNSView(_ v: LogsScrollView, coordinator: ()) { v.teardown() }
}

/// The table itself: the first responder, so Copy, Select All and the keyboard work on rows.
final class LogsTable: NSTableView {
    var copyHandler: (() -> Void)?
    var jumpToLiveHandler: (() -> Void)?
    var userScrollHandler: (() -> Void)?

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.specialKey == .downArrow { jumpToLiveHandler?(); return }
        super.keyDown(with: event)
    }

    override func scrollWheel(with event: NSEvent) {
        super.scrollWheel(with: event)
        userScrollHandler?()
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class LogsScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onUserScrolledAway: () -> Void = {}
    var onReachedBottom: () -> Void = {}
    var onSelect: (LogLine) -> Void = { _ in }

    private let table = LogsTable()
    private var lines: [LogLine] = []
    private var settings = LogsDisplaySettings()
    private var matcher: LogMatcher?
    private var follow = true
    private var lastToken = 0
    private var charWidth: CGFloat = 7
    private var lineHeight: CGFloat = 15
    private var maxChars = 0
    private var programmatic = false
    private var applying = false
    private var wrapColumns = 0
    /// Rows a wrapped line needs at the current width, by line id.
    private var rowCounts: [Int: Int] = [:]

    // Coalescing: the newest requested state, applied at most every 250 ms and only while visible.
    private struct Request { var lines: [LogLine]; var settings: LogsDisplaySettings; var matcher: LogMatcher?; var follow: Bool }
    private var pending: Request?
    private var lastApplied = ContinuousClock.now - .seconds(1)
    private var flushTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private static let minInterval: Duration = .milliseconds(250)

    private let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("log"))

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder

        column.resizingMask = .autoresizingMask
        column.minWidth = 40
        column.width = 400
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.intercellSpacing = .zero
        table.usesAutomaticRowHeights = false
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.style = .plain
        table.gridStyleMask = []
        table.backgroundColor = .clear
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.doubleAction = #selector(rowDoubleClicked)
        table.target = self
        table.setAccessibilityLabel("Log lines")
        table.copyHandler = { [weak self] in self?.copySelection(withTimestamps: false) }
        table.jumpToLiveHandler = { [weak self] in self?.jumpToLive() }
        table.userScrollHandler = { [weak self] in self?.evaluateUserScroll() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        documentView = table
        contentView.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: contentView, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.boundsChanged() }
        })
        remeasureFont()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func teardown() {
        flushTask?.cancel(); flushTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pending = nil
    }

    // MARK: Visibility

    /// Tests drive the view without a window: when set, the view counts as visible.
    var assumeVisible = false
    /// How updates reached the table, for tests (`append`, `frontDrop`, `reload`).
    private(set) var applyCounts = (append: 0, frontDrop: 0, reload: 0)
    var displayedLineCount: Int { lines.count }
    var tableRowCount: Int { table.numberOfRows }
    var isAtBottom: Bool { distanceFromBottom <= 24 }

    private var isShown: Bool {
        if assumeVisible { return true }
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification]
        for name in names {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.becameVisibleMaybe() }
            })
        }
        becameVisibleMaybe()
    }

    private func becameVisibleMaybe() {
        if isShown, pending != nil { flushPending(force: true) }
    }

    // MARK: Apply (coalesced)

    func apply(lines new: [LogLine], settings newSettings: LogsDisplaySettings, matcher newMatcher: LogMatcher?, follow newFollow: Bool, scrollTarget: LogsModel.ScrollTarget?) {
        pending = Request(lines: new, settings: newSettings, matcher: newMatcher, follow: newFollow)
        let urgent = (scrollTarget?.token ?? 0) != lastToken || newSettings != settings || newFollow != follow
        if urgent { flushPending(force: true) } else { flushPending(force: false) }
        if let t = scrollTarget, t.token != lastToken, pending == nil {
            lastToken = t.token
            if t.lineID < 0 { scrollToBottom() } else { scrollTo(lineID: t.lineID) }
        }
    }

    private func flushPending(force: Bool) {
        guard pending != nil else { return }
        guard isShown else { return }                         // nothing is drawn while hidden: the next visible moment applies it
        let elapsed = ContinuousClock.now - lastApplied
        if !force, elapsed < Self.minInterval {
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.minInterval - elapsed)
                guard !Task.isCancelled else { return }
                self?.flushTask = nil
                self?.flushPending(force: true)
            }
            return
        }
        flushTask?.cancel(); flushTask = nil
        guard let r = pending else { return }
        pending = nil
        lastApplied = .now
        applyNow(r)
    }

    private func applyNow(_ r: Request) {
        applying = true
        defer { applying = false }
        let settingsChanged = r.settings != settings
        let oldFirst = lines.first?.id, oldCount = lines.count
        let wasFollowing = follow
        let anchor = captureAnchor()
        let fontChanged = r.settings.fontSize != settings.fontSize
        let layoutChanged = settingsChanged && (r.settings.wrap != settings.wrap || r.settings.timestamps != settings.timestamps || fontChanged)
        let old = lines
        lines = r.lines
        settings = r.settings
        matcher = r.matcher
        follow = r.follow
        if fontChanged || charWidth <= 0 { remeasureFont() }
        if layoutChanged { rowCounts = [:] }
        let new = r.lines

        let appendOnly = !settingsChanged && oldFirst == new.first?.id && new.count >= oldCount && oldCount > 0
        var frontDrop: Int?
        if !appendOnly, !settingsChanged, wasFollowing, r.follow, oldCount > 0, let first = new.first?.id, first != oldFirst,
           let k = old.firstIndex(where: { $0.id == first }), k > 0, oldCount - k <= new.count,
           old[oldCount - 1].id == new[oldCount - k - 1].id {
            frontDrop = k
        }
        if appendOnly || frontDrop != nil {
            if settings.wrap { maxChars = 0 } else {
                var m = maxChars
                for l in new[(frontDrop.map { oldCount - $0 } ?? oldCount)...] { m = max(m, min(l.message.utf8.count, 4000)) }
                maxChars = m
            }
        } else {
            recomputeWidth()
        }
        updateColumnWidth()

        if appendOnly {
            applyCounts.append += 1
            if new.count > oldCount { table.insertRows(at: IndexSet(oldCount..<new.count), withAnimation: []) }
            else if new.count == oldCount, settings.query != "" || matcher != nil { reloadVisible() }
        } else if let k = frontDrop {
            applyCounts.frontDrop += 1
            table.beginUpdates()
            table.removeRows(at: IndexSet(0..<k), withAnimation: [])
            table.insertRows(at: IndexSet(oldCount - k..<new.count), withAnimation: [])
            table.endUpdates()
            pruneRowCounts()
        } else {
            applyCounts.reload += 1
            reloadAll()
            if !r.follow, !wasFollowing, let anchor { restore(anchor) }
        }
        if settingsChanged && (appendOnly || frontDrop != nil) { reloadVisible() }
        if r.follow { scrollToBottom() }
    }

    private func reloadAll() { table.reloadData() }

    private func reloadVisible() {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0 else { return }
        table.reloadData(forRowIndexes: IndexSet(integersIn: rows.location..<(rows.location + rows.length)), columnIndexes: IndexSet(integer: 0))
    }

    private func pruneRowCounts() {
        if rowCounts.count > lines.count * 2 + 1000 {
            let live = Set(lines.map(\.id))
            rowCounts = rowCounts.filter { live.contains($0.key) }
        }
    }

    // MARK: Metrics

    private var font: NSFont { .monospacedSystemFont(ofSize: settings.fontSize, weight: .regular) }

    private func remeasureFont() {
        let f = font
        charWidth = ("M" as NSString).size(withAttributes: [.font: f]).width
        lineHeight = ceil(f.ascender - f.descender + f.leading)
        table.rowHeight = lineHeight + 4
        rowCounts = [:]
    }

    private func recomputeWidth() {
        guard !settings.wrap else { maxChars = 0; return }
        var m = 0
        for l in lines { m = max(m, l.message.utf8.count) }
        maxChars = min(m, 4000)
    }

    private var prefixChars: Int { settings.timestamps ? 14 : 5 }

    private func updateColumnWidth() {
        if settings.wrap {
            hasHorizontalScroller = false
            let width = max(contentSize.width, 100)
            if column.width != width { column.width = width }
            let cols = max(10, Int((width - 20) / charWidth))
            if cols != wrapColumns { wrapColumns = cols; rowCounts = [:] }
        } else {
            hasHorizontalScroller = true
            let width = max(contentSize.width, CGFloat(maxChars + prefixChars) * charWidth + 32)
            if column.width != width { column.width = width }
        }
    }

    override func layout() {
        super.layout()
        if settings.wrap, contentSize.width > 0 {
            let before = wrapColumns
            updateColumnWidth()
            if before != wrapColumns, !lines.isEmpty {
                // The width changed: heights change for every wrapped row. Re-measure only what is visible, the rest on demand.
                table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<lines.count))
                if follow { scrollToBottom() }
            }
        }
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { lines.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard settings.wrap, row < lines.count else { return lineHeight + 4 }
        let line = lines[row]
        if line.kind == .marker { return lineHeight + 8 }
        let rows: Int
        if let cached = rowCounts[line.id] { rows = cached } else {
            var chars = line.message.utf16.count + prefix(for: line)
            if chars == 0 { chars = 1 }
            rows = max(1, (chars + wrapColumns - 1) / max(wrapColumns, 1))
            rowCounts[line.id] = rows
        }
        return CGFloat(rows) * lineHeight + 4
    }

    private func prefix(for line: LogLine) -> Int {
        var n = 0
        if settings.timestamps, line.timestamp != nil { n += 13 }
        if line.level != .none { n += 4 }
        if let source = line.source { n += source.utf16.count + 3 }
        return n
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("logCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? LogCellView) ?? {
            let c = LogCellView(); c.identifier = id; return c
        }()
        guard row < lines.count else { return cell }
        let line = lines[row]
        cell.configure(line, settings: settings, matcher: matcher, isCurrent: line.id == settings.currentLineID)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? { nil }

    // MARK: Scrolling

    private var distanceFromBottom: CGFloat {
        let visibleBottom = contentView.bounds.maxY
        return table.frame.height - visibleBottom
    }

    private func scrollToBottom() {
        guard !lines.isEmpty else { return }
        programmatic = true
        defer { programmatic = false }
        table.scrollRowToVisible(lines.count - 1)
        let y = max(0, table.frame.height - contentView.bounds.height)
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
        reflectScrolledClipView(contentView)
    }

    private func jumpToLive() {
        scrollToBottom()
        onReachedBottom()
    }

    private func index(ofLineID id: Int) -> Int? {
        var lo = 0, hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].id == id { return mid }
            if lines[mid].id < id { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    private func scrollTo(lineID: Int) {
        guard let i = index(ofLineID: lineID) else { return }
        programmatic = true
        defer { programmatic = false }
        let rect = table.rect(ofRow: i)
        let y = max(0, rect.midY - contentView.bounds.height / 2)
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: y))
        reflectScrolledClipView(contentView)
    }

    private struct Anchor { var lineID: Int; var offset: CGFloat }

    private func captureAnchor() -> Anchor? {
        let rows = table.rows(in: table.visibleRect)
        guard rows.length > 0, rows.location < lines.count else { return nil }
        return Anchor(lineID: lines[rows.location].id, offset: contentView.bounds.origin.y - table.rect(ofRow: rows.location).minY)
    }

    private func restore(_ anchor: Anchor) {
        guard let i = index(ofLineID: anchor.lineID) else { return }
        programmatic = true
        defer { programmatic = false }
        contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: max(0, table.rect(ofRow: i).minY + anchor.offset)))
        reflectScrolledClipView(contentView)
    }

    private func boundsChanged() {
        guard !programmatic, !applying else { return }
        evaluateUserScroll()
    }

    private func evaluateUserScroll() {
        guard !programmatic, !applying, !lines.isEmpty else { return }
        if distanceFromBottom <= 24 { onReachedBottom() } else { onUserScrolledAway() }
    }

    // MARK: Selection, copy, menu

    @objc private func rowDoubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < lines.count else { return }
        onSelect(lines[row])
    }

    private func copySelection(withTimestamps: Bool) {
        let rows = table.selectedRowIndexes.filter { $0 < lines.count }
        guard !rows.isEmpty else { return }
        let text = rows.map { r -> String in
            let l = lines[r]
            return l.kind == .marker ? l.message : (withTimestamps ? l.text(timestamps: true) : l.message)
        }.joined(separator: "\n")
        Pasteboard.copy(text)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = table.clickedRow
        guard row >= 0, row < lines.count, lines[row].kind == .line else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        let many = table.selectedRowIndexes.count > 1
        let copy = NSMenuItem(title: many ? "Copy \(table.selectedRowIndexes.count) Lines" : "Copy Line", action: #selector(menuCopy), keyEquivalent: "")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        menu.addItem(copy)
        let ts = NSMenuItem(title: "Copy with Timestamp", action: #selector(menuCopyTimestamp), keyEquivalent: "")
        ts.target = self
        ts.image = NSImage(systemSymbolName: "clock", accessibilityDescription: nil)
        menu.addItem(ts)
    }

    @objc private func menuCopy() { copySelection(withTimestamps: false) }
    @objc private func menuCopyTimestamp() { copySelection(withTimestamps: true) }
}

// MARK: - Cell

private final class LogCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var tint: NSColor?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.isEditable = false
        label.isSelectable = false
        label.isBordered = false
        label.drawsBackground = false
        label.cell?.truncatesLastVisibleLine = false
        addSubview(label)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        label.frame = NSRect(x: 10, y: 2, width: max(0, bounds.width - 20), height: max(0, bounds.height - 4))
    }

    override func draw(_ dirtyRect: NSRect) {
        if let tint { tint.setFill(); dirtyRect.fill() }
        super.draw(dirtyRect)
    }

    private static func levelColor(_ l: LogLevel) -> NSColor {
        switch l {
        case .error: NSColor(Palette.criticalText)
        case .warn: NSColor(Palette.warningText)
        case .info: NSColor(Palette.infoText)
        case .debug: .tertiaryLabelColor
        case .none: .labelColor
        }
    }

    func configure(_ line: LogLine, settings: LogsDisplaySettings, matcher: LogMatcher?, isCurrent: Bool) {
        let size = settings.fontSize
        let mono = NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        label.maximumNumberOfLines = settings.wrap ? 0 : 1
        label.lineBreakMode = settings.wrap ? .byCharWrapping : .byClipping
        label.usesSingleLineMode = !settings.wrap

        if line.kind == .marker {
            tint = NSColor(Palette.info).withAlphaComponent(0.10)
            let p = NSMutableParagraphStyle(); p.alignment = .center
            label.attributedStringValue = NSAttributedString(string: "── \(line.message) ──", attributes: [
                .font: NSFont.systemFont(ofSize: size - 1, weight: .semibold), .foregroundColor: NSColor(Palette.infoText), .paragraphStyle: p,
            ])
            label.maximumNumberOfLines = 0
            needsDisplay = true
            return
        }

        let out = NSMutableAttributedString()
        if settings.timestamps, let ts = line.timestamp {
            let short = ts.count >= 23 ? String(ts.dropFirst(11).prefix(12)) : ts
            out.append(NSAttributedString(string: short + " ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor]))
        }
        if line.level != .none {
            let tag: String
            switch line.level { case .error: tag = "ERR"; case .warn: tag = "WRN"; case .info: tag = "INF"; case .debug: tag = "DBG"; case .none: tag = "" }
            out.append(NSAttributedString(string: tag + " ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .bold), .foregroundColor: Self.levelColor(line.level)]))
        }
        if let source = line.source {
            out.append(NSAttributedString(string: "[\(source)] ", attributes: [.font: NSFont.monospacedSystemFont(ofSize: size - 1, weight: .medium), .foregroundColor: NSColor(Palette.tintText)]))
        }
        let messageStart = out.length
        let messageColor: NSColor = line.level == .debug ? .secondaryLabelColor : .labelColor
        out.append(NSAttributedString(string: line.message, attributes: [.font: mono, .foregroundColor: messageColor]))
        if let matcher {
            var first = true
            for r in matcher.ranges(in: line.message) {
                let shifted = NSRange(location: r.location + messageStart, length: r.length)
                let color = (isCurrent && first) ? NSColor(Palette.logCurrent) : NSColor(Palette.logHighlight)
                out.addAttributes([.backgroundColor: color.withAlphaComponent(isCurrent && first ? 0.9 : 0.55), .foregroundColor: NSColor.black], range: shifted)
                first = false
            }
        }
        tint = line.level == .error ? NSColor(Palette.critical).withAlphaComponent(0.10)
            : (line.level == .warn ? NSColor(Palette.warning).withAlphaComponent(0.07) : nil)
        label.attributedStringValue = out
        setAccessibilityLabel((line.level == .none ? "" : "\(line.level.label). ") + line.message)
        needsDisplay = true
    }
}
