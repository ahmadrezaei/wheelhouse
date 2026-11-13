import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

// MARK: - Model

/// One column of the resource table.
struct KubeColumn: Equatable {
    var id: String
    var title: String
    var width: CGFloat
    var minWidth: CGFloat = 50
    var alignment: NSTextAlignment = .left
    var sort: ListSort?
    var monospaced = false
    var hiddenByDefault = false

    /// The columns of a kind (ARCHITECTURE-MAC section 1.6 row 10). Custom-resource printer columns follow `details`.
    static func columns(for kind: ResourceKind, showNamespace: Bool, extra: [String]) -> [KubeColumn] {
        var cols = [KubeColumn(id: "name", title: "Name", width: 260, minWidth: 120, sort: .name, monospaced: true)]
        if kind.namespaced, showNamespace { cols.append(KubeColumn(id: "namespace", title: "Namespace", width: 140, sort: nil)) }
        switch kind.kind {
        case "Pod" where kind.group.isEmpty:
            cols += [KubeColumn(id: "ready", title: "Ready", width: 60, alignment: .right),
                     KubeColumn(id: "status", title: "Status", width: 150, sort: .status),
                     KubeColumn(id: "restarts", title: "Restarts", width: 70, alignment: .right, sort: .restarts),
                     KubeColumn(id: "cpu", title: "CPU", width: 70, alignment: .right, sort: .cpu),
                     KubeColumn(id: "memory", title: "Memory", width: 80, alignment: .right, sort: .memory),
                     KubeColumn(id: "node", title: "Node", width: 150, hiddenByDefault: false)]
        case "Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job":
            cols += [KubeColumn(id: "ready", title: "Ready", width: 70, alignment: .right),
                     KubeColumn(id: "uptodate", title: "Up-to-date", width: 80, alignment: .right),
                     KubeColumn(id: "status", title: "Status", width: 150, sort: .status)]
        case "Node":
            // fix-N: the Nodes table (Lens-like). Roles, version, pods and taints come from the node itself or the pod watch.
            cols += [KubeColumn(id: "status", title: "Status", width: 170, sort: .status),
                     KubeColumn(id: "roles", title: "Roles", width: 130),
                     KubeColumn(id: "version", title: "Version", width: 110, monospaced: true),
                     KubeColumn(id: "cpu", title: "CPU", width: 70, alignment: .right, sort: .cpu),
                     KubeColumn(id: "memory", title: "Memory", width: 80, alignment: .right, sort: .memory),
                     KubeColumn(id: "pods", title: "Pods", width: 60, alignment: .right),
                     KubeColumn(id: "taints", title: "Taints", width: 60, alignment: .right)]
        default:
            cols += [KubeColumn(id: "status", title: "Status", width: 150, sort: .status),
                     KubeColumn(id: "details", title: "Details", width: 280)]
        }
        for (i, name) in extra.enumerated() { cols.append(KubeColumn(id: "extra\(i)", title: name, width: 120)) }
        cols.append(KubeColumn(id: "age", title: "Age", width: 60, alignment: .right, sort: .age))
        return cols
    }
}

/// What a row shows. Built on demand for visible rows only.
struct KubeTableRow {
    var id: String
    var name: String
    var namespace: String
    var status: String
    var tone: HealthStatus
    var ready: String
    var upToDate: String
    var restarts: String
    var node: String
    var cpu: String
    var memory: String
    var details: String
    var age: String
    var extra: [String]
    var accessibility: String
    /// Columns only some kinds have (the Nodes table: roles, version, pods, taints), by column id.
    var kindColumns: [String: String] = [:]

    func text(for column: String) -> String {
        switch column {
        case "name": name
        case "namespace": namespace
        case "status": status
        case "ready": ready
        case "uptodate": upToDate
        case "restarts": restarts
        case "node": node
        case "cpu": cpu
        case "memory": memory
        case "details": details
        case "age": age
        default:
            if let value = kindColumns[column] { value }
            else if column.hasPrefix("extra"), let i = Int(column.dropFirst(5)), extra.indices.contains(i) { extra[i] } else { "" }
        }
    }
}

/// One entry of a row's context menu.
struct KubeRowAction {
    var title: String
    var symbol: String?
    var isDestructive = false
    var isSeparator = false
    var handler: @MainActor () -> Void = {}

    static let separator = KubeRowAction(title: "", isSeparator: true)
}

// MARK: - SwiftUI wrapper

/// The resource table: a view-based, virtualised `NSTableView` with incremental updates (ARCHITECTURE-MAC section 12.3.4).
struct KubeTable: NSViewRepresentable {
    let kindID: String
    let keys: [KubeRowKey]
    let columns: [KubeColumn]
    let sort: ListSort
    let reversed: Bool
    let rowAt: (Int) -> KubeTableRow
    var onSort: (ListSort, Bool) -> Void
    var onOpen: (String) -> Void
    /// fix-N: a plain single click on a row (no modifier) opens its detail, like Lens.
    var onSelect: (String) -> Void = { _ in }
    /// fix-N: the keyboard moved the selection to one row: a linked detail pane follows, nothing else changes.
    var onFollow: (String) -> Void = { _ in }
    var actions: (String) -> [KubeRowAction]

    func makeNSView(context: Context) -> KubeTableScrollView { KubeTableScrollView() }

    func updateNSView(_ v: KubeTableScrollView, context: Context) {
        v.onSort = onSort
        v.onOpen = onOpen
        v.onSelect = onSelect
        v.onFollow = onFollow
        v.actions = actions
        v.update(kindID: kindID, columns: columns, sort: sort, reversed: reversed, keys: keys, rowAt: rowAt)
    }

    static func dismantleNSView(_ v: KubeTableScrollView, coordinator: ()) { v.teardown() }
}

final class KubeNSTable: NSTableView {
    var openHandler: (() -> Void)?
    var copyHandler: (() -> Void)?
    /// Called after a left click finished selecting: the clicked row and the modifiers held.
    var clickHandler: ((Int, NSEvent.ModifierFlags) -> Void)?

    override func mouseDown(with event: NSEvent) {
        let row = self.row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)        // tracks the click until the button is released (a double click fires the double action)
        if event.clickCount == 1, row >= 0 { clickHandler?(row, event.modifierFlags) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { openHandler?(); return }     // Return, Enter
        super.keyDown(with: event)
    }

    /// Return reaches here when AppKit routes the key through the text-input system instead of `keyDown`.
    override func insertNewline(_ sender: Any?) { openHandler?() }

    @objc func copy(_ sender: Any?) { copyHandler?() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(copy(_:)) { return !selectedRowIndexes.isEmpty }
        return super.validateUserInterfaceItem(item)
    }
}

@MainActor
final class KubeTableScrollView: NSScrollView, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
    var onSort: (ListSort, Bool) -> Void = { _, _ in }
    var onOpen: (String) -> Void = { _ in }
    var onSelect: (String) -> Void = { _ in }
    var onFollow: (String) -> Void = { _ in }
    /// A click waits this long for a second click, so a double click opens once and never lands on the detail it just opened.
    var clickDelay: Duration = .milliseconds(250)
    /// Arrow keys settle for this long before a linked detail follows (holding an arrow must not restart a log stream per row).
    var followDelay: Duration = .milliseconds(150)
    private var pendingSelect: Task<Void, Never>?
    var actions: (String) -> [KubeRowAction] = { _ in [] }

    private let table = KubeNSTable()
    private var kindID = ""
    private var columns: [KubeColumn] = []
    private var keys: [KubeRowKey] = []
    private var rowAt: (Int) -> KubeTableRow = { _ in KubeTableRow(id: "", name: "", namespace: "", status: "", tone: .unknown, ready: "", upToDate: "", restarts: "", node: "", cpu: "", memory: "", details: "", age: "", extra: [], accessibility: "") }
    private var settingSort = false

    private struct Request { var keys: [KubeRowKey]; var rowAt: (Int) -> KubeTableRow }
    private var pending: Request?
    private var lastApplied = ContinuousClock.now - .seconds(1)
    private var flushTask: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private static let minInterval: Duration = .milliseconds(250)

    override init(frame: NSRect) {
        super.init(frame: frame)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        borderType = .noBorder
        drawsBackground = true
        backgroundColor = .textBackgroundColor

        table.dataSource = self
        table.delegate = self
        table.style = .fullWidth
        table.rowSizeStyle = .medium
        table.usesAlternatingRowBackgroundColors = true
        table.allowsMultipleSelection = true
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.allowsColumnSelection = false
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.doubleAction = #selector(doubleClicked)
        table.target = self
        table.usesAutomaticRowHeights = false
        table.rowHeight = 24
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.setAccessibilityLabel("Resources")
        table.openHandler = { [weak self] in self?.openSelected() }
        table.clickHandler = { [weak self] row, flags in self?.handleClick(row: row, modifiers: flags) }
        table.copyHandler = { [weak self] in self?.copyNames() }
        let menu = NSMenu()
        menu.delegate = self
        table.menu = menu
        let header = NSMenu()
        header.delegate = self
        table.headerView?.menu = header
        documentView = table
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func teardown() {
        pendingSelect?.cancel(); pendingSelect = nil
        flushTask?.cancel(); flushTask = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        pending = nil
    }

    // MARK: Visibility

    /// Tests drive the view without a window: when set, the view counts as visible.
    var assumeVisible = false
    private(set) var reloadCount = 0
    private(set) var deltaCount = 0
    var tableRowCount: Int { table.numberOfRows }

    private var isShown: Bool {
        if assumeVisible { return true }
        guard let window, window.isVisible, !window.isMiniaturized else { return false }
        return window.occlusionState.contains(.visible)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didDeminiaturizeNotification] {
            observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { if self?.isShown == true, self?.pending != nil { self?.flush(force: true) } }
            })
        }
        if pending != nil { flush(force: true) }
    }

    // MARK: Update (coalesced, incremental)

    func update(kindID newKind: String, columns newColumns: [KubeColumn], sort: ListSort, reversed: Bool, keys newKeys: [KubeRowKey], rowAt newRowAt: @escaping (Int) -> KubeTableRow) {
        var structural = false
        if newKind != kindID || newColumns != columns {
            kindID = newKind
            columns = newColumns
            rebuildColumns()
            structural = true
        }
        syncSortIndicator(sort: sort, reversed: reversed)
        pending = Request(keys: newKeys, rowAt: newRowAt)
        flush(force: structural || keys.isEmpty)
    }

    private func flush(force: Bool) {
        guard pending != nil, isShown || window == nil else { return }
        let elapsed = ContinuousClock.now - lastApplied
        if !force, elapsed < Self.minInterval {
            guard flushTask == nil else { return }
            flushTask = Task { [weak self] in
                try? await Task.sleep(for: Self.minInterval - elapsed)
                guard !Task.isCancelled else { return }
                self?.flushTask = nil
                self?.flush(force: true)
            }
            return
        }
        flushTask?.cancel(); flushTask = nil
        guard let r = pending else { return }
        pending = nil
        lastApplied = .now
        apply(r)
    }

    private func apply(_ r: Request) {
        let oldKeys = keys
        keys = r.keys
        rowAt = r.rowAt
        let delta = KubeTableDiffer.diff(old: oldKeys, new: r.keys)
        if delta.needsReload { reloadCount += 1 } else if !delta.isEmpty { deltaCount += 1 }
        if delta.needsReload {
            // First load, a re-sort or a filter change: reload, then restore the selection and the top row by id.
            let selected = Set(table.selectedRowIndexes.compactMap { oldKeys.indices.contains($0) ? oldKeys[$0].id : nil })
            let top = table.rows(in: table.visibleRect)
            let anchor = top.length > 0 && oldKeys.indices.contains(top.location) ? oldKeys[top.location] : nil
            let offset = anchor.flatMap { _ in oldKeys.isEmpty ? nil : contentView.bounds.origin.y - table.rect(ofRow: top.location).minY }
            table.reloadKeepingState(ids: r.keys.map(\.id), selectedIDs: selected, anchorID: anchor?.id, anchorOffset: offset ?? 0)
        } else {
            table.applyKubeDelta(delta)
        }
    }

    // MARK: Columns and sorting

    private func rebuildColumns() {
        for c in table.tableColumns { table.removeTableColumn(c) }
        table.autosaveName = nil
        for col in columns {
            let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(col.id))
            c.title = col.title
            c.width = col.width
            c.minWidth = col.minWidth
            c.maxWidth = 2_000
            c.headerCell.alignment = col.alignment
            c.isHidden = col.hiddenByDefault
            if col.sort != nil { c.sortDescriptorPrototype = NSSortDescriptor(key: col.id, ascending: true) }
            table.addTableColumn(c)
        }
        // Column widths, order and visibility persist per kind.
        table.autosaveName = "kubetable.\(kindID).\(columns.map(\.id).joined(separator: "-"))"
        table.autosaveTableColumns = true
    }

    private func syncSortIndicator(sort: ListSort, reversed: Bool) {
        guard let col = columns.first(where: { $0.sort == sort }) else { table.sortDescriptors = []; return }
        let wanted = [NSSortDescriptor(key: col.id, ascending: !reversed)]
        if table.sortDescriptors.first?.key == wanted[0].key, table.sortDescriptors.first?.ascending == wanted[0].ascending { return }
        settingSort = true
        table.sortDescriptors = wanted
        settingSort = false
    }

    func tableView(_ tableView: NSTableView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
        guard !settingSort, let d = tableView.sortDescriptors.first, let key = d.key, let col = columns.first(where: { $0.id == key }), let sort = col.sort else { return }
        onSort(sort, !d.ascending)
    }

    // MARK: Data source

    func numberOfRows(in tableView: NSTableView) -> Int { keys.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let id = NSUserInterfaceItemIdentifier("kubeRow")
        let v = (tableView.makeView(withIdentifier: id, owner: self) as? NSTableRowView) ?? { let r = NSTableRowView(); r.identifier = id; return r }()
        if row < keys.count { v.setAccessibilityLabel(rowAt(row).accessibility) }
        return v
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < keys.count, let def = columns.first(where: { $0.id == column.identifier.rawValue }) else { return nil }
        let id = NSUserInterfaceItemIdentifier("kubeCell")
        let cell = (tableView.makeView(withIdentifier: id, owner: self) as? KubeCellView) ?? { let c = KubeCellView(); c.identifier = id; return c }()
        let data = rowAt(row)
        cell.configure(text: data.text(for: def.id), column: def, tone: def.id == "status" ? data.tone : nil)
        return cell
    }

    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int) -> String? {
        row < keys.count ? rowAt(row).name : nil
    }

    // MARK: Open, copy, menus

    @objc private func doubleClicked() {
        let row = table.clickedRow
        guard row >= 0, row < keys.count else { return }
        pendingSelect?.cancel(); pendingSelect = nil
        onOpen(keys[row].id)
    }

    /// True for the modifiers that mean "select without opening" (command and shift extend the selection, control opens the menu).
    static func isSelectionOnly(_ modifiers: NSEvent.ModifierFlags) -> Bool {
        !modifiers.intersection([.command, .shift, .control]).isEmpty
    }

    /// A left click finished on `row`. A plain click that left exactly that row selected opens it after the double-click window.
    func handleClick(row: Int, modifiers: NSEvent.ModifierFlags) {
        guard !Self.isSelectionOnly(modifiers), keys.indices.contains(row), table.selectedRowIndexes == IndexSet(integer: row) else { return }
        schedule(keys[row].id, after: clickDelay, action: { [weak self] id in self?.onSelect(id) })
    }

    /// The selection changed. Only a keyboard move that leaves one row selected is followed; clicks are handled by `handleClick`.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard NSApp.currentEvent?.type == .keyDown else { return }
        selectionMovedByKeyboard()
    }

    func selectionMovedByKeyboard() {
        guard table.selectedRowIndexes.count == 1, let row = table.selectedRowIndexes.first, keys.indices.contains(row) else { return }
        schedule(keys[row].id, after: followDelay, action: { [weak self] id in self?.onFollow(id) })
    }

    private func schedule(_ id: String, after delay: Duration, action: @escaping @MainActor (String) -> Void) {
        pendingSelect?.cancel()
        pendingSelect = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.pendingSelect = nil
            action(id)
        }
    }

    /// Test seam: selects rows without a mouse.
    func selectRows(_ rows: IndexSet) { table.selectRowIndexes(rows, byExtendingSelection: false) }

    private func openSelected() {
        guard let row = table.selectedRowIndexes.first, row < keys.count else { return }
        onOpen(keys[row].id)
    }

    private func copyNames() {
        let names = table.selectedRowIndexes.filter { $0 < keys.count }.map { rowAt($0).name }
        guard !names.isEmpty else { return }
        Pasteboard.copy(names.joined(separator: "\n"))
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        if menu === table.headerView?.menu {
            // Column chooser.
            for c in table.tableColumns {
                let item = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = c
                item.state = c.isHidden ? .off : .on
                if c.identifier.rawValue == "name" { item.isEnabled = false }
                menu.addItem(item)
            }
            return
        }
        let row = table.clickedRow
        guard row >= 0, row < keys.count else { return }
        if !table.selectedRowIndexes.contains(row) { table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        if table.selectedRowIndexes.count > 1 {
            let item = NSMenuItem(title: "Copy \(table.selectedRowIndexes.count) Names", action: #selector(copyMenu), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            return
        }
        for a in actions(keys[row].id) {
            if a.isSeparator { menu.addItem(.separator()); continue }
            let item = NSMenuItem(title: a.title, action: #selector(runAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ActionBox(a.handler)
            if let s = a.symbol { item.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            menu.addItem(item)
        }
    }

    private final class ActionBox: NSObject {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
    }

    @objc private func runAction(_ item: NSMenuItem) { (item.representedObject as? ActionBox)?.handler() }
    @objc private func copyMenu() { copyNames() }
    @objc private func toggleColumn(_ item: NSMenuItem) {
        guard let c = item.representedObject as? NSTableColumn else { return }
        c.isHidden.toggle()
    }
}

// MARK: - Cell

private final class KubeCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        icon.imageScaling = .scaleProportionallyDown
        addSubview(icon)
        addSubview(label)
        textField = label
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        let iconWidth: CGFloat = icon.isHidden ? 0 : 16
        icon.frame = NSRect(x: 0, y: (bounds.height - 14) / 2, width: 14, height: 14)
        let x: CGFloat = iconWidth > 0 ? 20 : 0
        label.frame = NSRect(x: x, y: (bounds.height - label.intrinsicContentSize.height) / 2, width: max(0, bounds.width - x), height: label.intrinsicContentSize.height)
    }

    func configure(text: String, column: KubeColumn, tone: HealthStatus?) {
        label.stringValue = text
        label.alignment = column.alignment
        label.font = column.monospaced ? .monospacedSystemFont(ofSize: 12, weight: .medium) : .systemFont(ofSize: 12)
        label.textColor = .labelColor
        if let tone, !text.isEmpty {
            icon.isHidden = false
            icon.image = NSImage(systemSymbolName: tone.symbol, accessibilityDescription: tone.title)
            icon.contentTintColor = NSColor(tone.color)
            if tone != .healthy { label.textColor = NSColor(tone == .critical ? Palette.criticalText : tone == .warning ? Palette.warningText : Palette.unknownText) }
        } else {
            icon.isHidden = true
            if column.id == "namespace" || column.id == "age" || column.id == "node" || column.id == "details" { label.textColor = .secondaryLabelColor }
        }
        needsLayout = true
    }
}
