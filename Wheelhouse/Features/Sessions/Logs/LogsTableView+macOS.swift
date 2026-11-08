import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// View-based `NSTableView` log list for the Mac (ARCHITECTURE-MAC section 1.6 row 12, section 12.3.4).
///
/// - Virtualised: only visible rows have views; cells are reused; 20,000 lines cost the same as 20.
/// - Incremental: appends insert rows; a full ring dropping at the front only adds rows until a slack of old rows is used up, then
///   removes them in one go; `reloadData()` is only used for the first load and for changes that touch everything (settings, a
///   different stream).
/// - Coalesced: at most 4 table updates per second (250 ms), 2 while following a live tail (500 ms: each update of a following table
///   inserts rows, scrolls, re-tiles and re-tracks the visible rows, about 1 % CPU per update per second at 10 lines/s; performance
///   pass P1), and none while the window is hidden, minimised or occluded: the latest state is applied when the view becomes visible
///   again. A change the user makes (settings, follow, a scroll target) applies at once.
/// - Fixed row height with wrapping off; with wrapping on, the height comes from a character count per row (monospaced), cached per
///   line for the current width.
/// - Off the SwiftUI path: built with `source:`, the view follows `LogsModel.visible` itself (Observation), so a flush of new lines
///   updates the table without re-rendering any SwiftUI view. Every SwiftUI update of the window re-measures the whole window's minimum
///   size (`NSHostingView.minSize`), which was most of the cost of a followed log (performance pass P1). SwiftUI only passes the
///   display settings, which change when the user changes them.
struct LogsTableView: NSViewRepresentable {
    /// The lines, when given by value (tests); ignored when `source` is set.
    var lines: [LogLine] = []
    /// The model whose `visible` lines the table follows.
    var source: LogsModel?
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
        // Never read `source.visible` here: SwiftUI tracks what `updateNSView` reads, and that would put every flush back on its path.
        if let source { v.track(source) }
        v.apply(lines: source == nil ? lines : nil, settings: settings, matcher: matcher, follow: follow, scrollTarget: scrollTarget)
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
    /// `lines` nil: the source's lines, read when the request is applied. Holding a copy until then would share the model's array
    /// buffer, and every sync of the model in between would copy all its lines (copy on write).
    private struct Request { var lines: [LogLine]?; var settings: LogsDisplaySettings; var matcher: LogMatcher?; var follow: Bool }
    private var pending: Request?
    private var lastApplied = ContinuousClock.now - .seconds(1)
    private var flushTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private static let minInterval: Duration = .milliseconds(250)
    /// While following: new lines at the bottom twice a second are enough to read a live tail.
    private static let followInterval: Duration = .milliseconds(500)
    private var interval: Duration { follow && (pending?.follow ?? true) ? Self.followInterval : Self.minInterval }

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
        source = nil
        sourceGeneration += 1
        flushTask?.cancel(); flushTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pending = nil
    }

    // MARK: Visibility

    /// Tests drive the view without a window: when set, the view counts as visible.
    var assumeVisible = false
    /// How updates reached the table, for tests (`append`, `frontDrop`, `frontTrim` (the slack removed), `reload`).
    private(set) var applyCounts = (append: 0, frontDrop: 0, frontTrim: 0, reload: 0)
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

    // MARK: Following the model

    private weak var source: LogsModel?
    /// Bumped when the source changes or goes: an observation armed for an earlier source is ignored when it fires.
    private var sourceGeneration = 0
    /// The generation whose lines the table last took. The first lines of a new source are applied as a full reload: line ids count
    /// per stream, so two models' ids overlap and an incremental match across them would keep the other pod's rows.
    private var appliedGeneration = -1
    private var forceReload = false
    /// What SwiftUI passed last, re-used when only the lines change.
    private var lastSettings = LogsDisplaySettings()
    private var lastMatcher: LogMatcher?
    private var lastFollow = true
    private var lastScrollTarget: LogsModel.ScrollTarget?

    /// Follows `model.visible` until `teardown()` or another model. The first read happens on the next main-actor turn: `track` runs
    /// inside `updateNSView`, and a read there would become a SwiftUI dependency. Later changes arrive through Observation.
    func track(_ model: LogsModel) {
        guard source !== model else { return }
        source = model
        sourceGeneration += 1
        let generation = sourceGeneration
        Task { @MainActor [weak self] in self?.sourceChanged(generation) }
    }

    /// Re-arms the observation of the lines (it fires once, before the change; the update runs on the next main-actor turn). Only the
    /// count is touched here: the lines themselves are read when the update is applied.
    private func readSource(_ generation: Int) {
        guard let model = source else { return }
        withObservationTracking { _ = model.visible.count } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.sourceChanged(generation) }
        }
    }

    private func sourceChanged(_ generation: Int) {
        guard let model = source, generation == sourceGeneration else { return }
        if generation != appliedGeneration { appliedGeneration = generation; forceReload = true }
        readSource(generation)
        // Follow and the scroll target come from the model, not from the last SwiftUI update: a user scroll sets `model.follow` to false
        // before SwiftUI passes it on, and new lines applied with the old value would snap the table back to the bottom.
        apply(lines: nil, settings: lastSettings, matcher: lastMatcher, follow: model.follow, scrollTarget: model.scrollTarget)
    }

    // MARK: Apply (coalesced)

    func apply(lines new: [LogLine]?, settings newSettings: LogsDisplaySettings, matcher newMatcher: LogMatcher?, follow newFollow: Bool, scrollTarget: LogsModel.ScrollTarget?) {
        lastSettings = newSettings; lastMatcher = newMatcher; lastFollow = newFollow; lastScrollTarget = scrollTarget
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
        let interval = self.interval
        if !force, elapsed < interval {
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: interval - elapsed)
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
        var old = lines
        let new = r.lines ?? source?.visible ?? []
        lines = new
        settings = r.settings
        matcher = r.matcher
        follow = r.follow
        if fontChanged || charWidth <= 0 { remeasureFont() }
        if layoutChanged { rowCounts = [:] }

        let forced = forceReload
        forceReload = false
        let incremental = !settingsChanged && !forced
        let appendOnly = incremental && oldFirst == new.first?.id && new.count >= oldCount && oldCount > 0
        // A full ring drops lines at the front while new ones arrive at the back. `k` counts the table's rows whose lines the model
        // no longer holds (the rows kept as slack, see below, plus this update's drops).
        var frontDrop: Int?
        if !appendOnly, incremental, oldCount > 0, let first = new.first?.id, first != oldFirst,
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
            if new.count > oldCount {
                // Grow the table's own array instead of keeping the model's: a shared buffer makes the model copy all its lines on
                // its next sync, and that grows with the lines (performance pass P1).
                lines = []
                old.append(contentsOf: new[oldCount...])
                lines = old
                table.insertRows(at: IndexSet(oldCount..<new.count), withAnimation: [])
            } else if new.count == oldCount, settings.query != "" || matcher != nil { reloadVisible() }
        } else if let k = frontDrop {
            applyCounts.frontDrop += 1
            let appended = new.count - (oldCount - k)
            if k <= Self.frontSlack(rows: new.count) {
                // Keep the dropped lines' rows for now and only add rows at the end, as for a ring that is not full yet. Removing
                // rows at the front on every update moved every row view and rebuilt their layers: about 8 % CPU for a follow at
                // 10 lines/s once the ring was full (performance pass P1). The table shows up to `frontSlack` more old lines than
                // the ring holds, and a reader's scroll position does not move.
                lines = []
                old.append(contentsOf: new.suffix(appended))
                lines = old
                if appended > 0 { table.insertRows(at: IndexSet(oldCount..<(oldCount + appended)), withAnimation: []) }
            } else {
                applyCounts.frontTrim += 1
                table.beginUpdates()
                table.removeRows(at: IndexSet(0..<k), withAnimation: [])
                table.insertRows(at: IndexSet((oldCount - k)..<new.count), withAnimation: [])
                table.endUpdates()
                if !r.follow, let anchor { restore(anchor) }
            }
            pruneRowCounts()
        } else {
            applyCounts.reload += 1
            reloadAll()
            if !forced, !r.follow, !wasFollowing, let anchor { restore(anchor) }   // a new source's ids mean other lines
        }
        if settingsChanged && (appendOnly || frontDrop != nil) { reloadVisible() }
        if r.follow { scrollToBottom() }
    }

    /// Rows of lines the ring already dropped that the table may keep at its top before it removes them in one go: a tenth of the
    /// lines, at least 500 (at 10 lines/s and 20,000 lines, one removal every 200 s instead of four a second).
    static func frontSlack(rows: Int) -> Int { max(500, rows / 10) }

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
        // The anchor line was among the rows just removed (the slack): keep the reader at the oldest line instead of letting the
        // clip view stay put while the rows above it vanish.
        if let first = lines.first?.id, anchor.lineID < first {
            programmatic = true
            defer { programmatic = false }
            contentView.scroll(to: NSPoint(x: contentView.bounds.origin.x, y: 0))
            reflectScrolledClipView(contentView)
            return
        }
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
        // The waiting update must not undo the user's scroll before SwiftUI passes the new follow state on.
        if distanceFromBottom <= 24 { pending?.follow = true; onReachedBottom() } else { pending?.follow = false; onUserScrolledAway() }
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
