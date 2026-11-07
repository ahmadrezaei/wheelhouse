import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// What a row shows besides its title: status, environment and flags (cluster rows), problem badge, hover count.
struct SidebarDecor: Equatable {
    var status: HealthStatus?
    var environment: ClusterEnvironment?
    var isReadOnly = false
    var syncs = false
    var badge: SidebarBadge?
    var count: Int?
}

/// One entry of a row's context menu.
struct SidebarMenuItem {
    var title: String
    var symbol: String?
    var isSeparator = false
    var handler: @MainActor () -> Void = {}
    static let separator = SidebarMenuItem(title: "", isSeparator: true)
}

/// The resource tree: a view-based `NSOutlineView` with real disclosure levels, type-to-select and node diffing that preserves
/// disclosure state (ARCHITECTURE-MAC section 12.5). It is fed by `SidebarModel`.
struct SidebarTree: NSViewRepresentable {
    let model: SidebarModel
    let selectedRowID: String?
    /// Changes when something the cells show (cluster status) changed, so `updateNSView` runs and refreshes the visible rows.
    let token: String
    let decor: (SidebarRow, Bool) -> SidebarDecor
    var onSelect: (SidebarRow) -> Void
    var menu: (SidebarRow) -> [SidebarMenuItem]

    func makeNSView(context: Context) -> SidebarScrollView {
        let v = SidebarScrollView(model: model)
        v.onSelect = onSelect
        v.menuProvider = menu
        v.decorProvider = decor
        return v
    }

    func updateNSView(_ v: SidebarScrollView, context: Context) {
        v.onSelect = onSelect
        v.menuProvider = menu
        v.decorProvider = decor
        // Reading these registers the observation: a structural change or a new badge set runs this method again.
        _ = model.structureRevision
        _ = model.badges
        _ = model.counts
        v.update(rows: model.rows, selected: selectedRowID)
    }

    static func dismantleNSView(_ v: SidebarScrollView, coordinator: ()) { v.teardown() }
}

final class SidebarOutlineItem: NSObject {
    let id: String
    var row: SidebarRow
    var children: [SidebarOutlineItem] = []
    init(_ row: SidebarRow) { self.id = row.id; self.row = row }
}

final class SidebarOutline: NSOutlineView {
    var menuProvider: ((SidebarOutlineItem) -> NSMenu?)?
    var openHandler: ((SidebarOutlineItem) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let r = row(at: convert(event.locationInWindow, from: nil))
        guard r >= 0, let item = item(atRow: r) as? SidebarOutlineItem else { return nil }
        if !selectedRowIndexes.contains(r) { selectRowIndexes(IndexSet(integer: r), byExtendingSelection: false) }
        return menuProvider?(item)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76, selectedRow >= 0, let item = item(atRow: selectedRow) as? SidebarOutlineItem { openHandler?(item); return }
        super.keyDown(with: event)
    }
}

@MainActor
final class SidebarScrollView: NSScrollView, NSOutlineViewDataSource, NSOutlineViewDelegate {
    var onSelect: (SidebarRow) -> Void = { _ in }
    var menuProvider: (SidebarRow) -> [SidebarMenuItem] = { _ in [] }
    var decorProvider: (SidebarRow, Bool) -> SidebarDecor = { _, _ in SidebarDecor() }

    private let model: SidebarModel
    private let outline = SidebarOutline()
    private var roots: [SidebarOutlineItem] = []
    private var itemsByID: [String: SidebarOutlineItem] = [:]
    private var syncing = false
    private var selectedID: String?
    private var lastDecor: [String: SidebarDecor] = [:]
    private var actionBoxes: [ActionBox] = []

    init(model: SidebarModel) {
        self.model = model
        super.init(frame: .zero)
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = true
        drawsBackground = false
        borderType = .noBorder

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("sidebar"))
        column.resizingMask = .autoresizingMask
        outline.addTableColumn(column)
        outline.outlineTableColumn = column
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowSizeStyle = .default
        outline.indentationPerLevel = 14
        outline.indentationMarkerFollowsCell = true
        outline.floatsGroupRows = false
        outline.autosaveExpandedItems = false
        outline.allowsMultipleSelection = false
        outline.allowsEmptySelection = true
        outline.dataSource = self
        outline.delegate = self
        outline.setAccessibilityLabel("Sidebar")
        outline.setAccessibilityRole(.outline)
        outline.menuProvider = { [weak self] item in self?.makeMenu(for: item.row) }
        outline.openHandler = { [weak self] item in self?.activate(item) }
        documentView = outline
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func teardown() {}

    // MARK: Update

    func update(rows: [SidebarRow], selected: String?) {
        reconcileRoots(rows)
        syncExpansion()
        applyDecor()
        select(selected)
    }

    /// Keeps `SidebarOutlineItem` identity for rows that survive (so disclosure state does too) and tells the outline view only what
    /// changed: removals, insertions, reloads of rows whose appearance changed.
    private func reconcileRoots(_ rows: [SidebarRow]) {
        syncing = true
        defer { syncing = false }
        outline.beginUpdates()
        reconcile(parent: nil, oldChildren: &roots, newRows: rows)
        outline.endUpdates()
        // Drop ids that no longer exist.
        var live = Set<String>()
        func collect(_ items: [SidebarOutlineItem]) { for i in items { live.insert(i.id); collect(i.children) } }
        collect(roots)
        itemsByID = itemsByID.filter { live.contains($0.key) }
        for (id, _) in lastDecor where !live.contains(id) { lastDecor[id] = nil }
    }

    private func reconcile(parent: SidebarOutlineItem?, oldChildren: inout [SidebarOutlineItem], newRows: [SidebarRow]) {
        let oldIDs = oldChildren.map(\.id)
        let newIDs = newRows.map(\.id)
        let oldSet = Set(oldIDs), newSet = Set(newIDs)
        let oldByID = Dictionary(oldChildren.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let parentExpanded = parent == nil || outline.isItemExpanded(parent)

        // Survivors keep their relative order? Then removals and insertions are enough.
        let survivorsOld = oldIDs.filter { newSet.contains($0) }
        let survivorsNew = newIDs.filter { oldSet.contains($0) }
        let orderStable = survivorsOld == survivorsNew

        var next: [SidebarOutlineItem] = []
        next.reserveCapacity(newRows.count)
        for row in newRows {
            if let existing = oldByID[row.id] { next.append(existing) } else { let i = SidebarOutlineItem(row); itemsByID[row.id] = i; next.append(i) }
        }

        let removed = IndexSet(oldIDs.enumerated().filter { !newSet.contains($0.element) }.map(\.offset))
        let inserted = IndexSet(newIDs.enumerated().filter { !oldSet.contains($0.element) }.map(\.offset))

        // Update the data first, then tell the outline view.
        var reloads: [SidebarOutlineItem] = []
        for (i, row) in newRows.enumerated() {
            let item = next[i]
            if !oldSet.contains(row.id) { item.row = row; continue }
            if !item.row.sameAppearance(as: row) { item.row = row; reloads.append(item) } else { item.row = row }
        }
        oldChildren = next

        if parentExpanded {
            if orderStable {
                if !removed.isEmpty { outline.removeItems(at: removed, inParent: parent, withAnimation: []) }
                if !inserted.isEmpty { outline.insertItems(at: inserted, inParent: parent, withAnimation: []) }
            } else {
                outline.reloadItem(parent, reloadChildren: true)
            }
        } else if let parent, !removed.isEmpty || !inserted.isEmpty {
            outline.reloadItem(parent, reloadChildren: false)
        }
        for item in reloads where outline.row(forItem: item) >= 0 || parent == nil { outline.reloadItem(item, reloadChildren: false) }

        // Recurse into survivors.
        for (i, row) in newRows.enumerated() {
            let item = next[i]
            reconcile(parent: item, oldChildren: &item.children, newRows: row.children)
        }
    }

    /// Opens and closes rows to match the model (the model owns disclosure state; a filter forces matches open).
    private func syncExpansion() {
        syncing = true
        defer { syncing = false }
        func visit(_ items: [SidebarOutlineItem]) {
            for item in items where item.row.isExpandable {
                let want = model.isExpanded(rowID: item.id)
                if want, !outline.isItemExpanded(item) { outline.expandItem(item) }
                else if !want, outline.isItemExpanded(item) { outline.collapseItem(item) }
                if outline.isItemExpanded(item) { visit(item.children) }
            }
        }
        visit(roots)
    }

    /// Reloads only the visible rows whose badge, count or status changed.
    private func applyDecor() {
        let visible = outline.rows(in: outline.visibleRect)
        guard visible.length > 0 else { return }
        var changed = IndexSet()
        for r in visible.location..<(visible.location + visible.length) {
            guard let item = outline.item(atRow: r) as? SidebarOutlineItem else { continue }
            let d = decorProvider(item.row, outline.isItemExpanded(item))
            if lastDecor[item.id] != d { lastDecor[item.id] = d; changed.insert(r) }
        }
        if !changed.isEmpty { outline.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0)) }
    }

    private func select(_ id: String?) {
        guard id != selectedID else { return }
        let previous = selectedID
        selectedID = id
        syncing = true
        defer { syncing = false }
        if let id, let item = itemsByID[id] {
            let row = outline.row(forItem: item)
            if row >= 0 { outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        } else {
            outline.deselectAll(nil)
        }
        // Rows show their count while selected.
        var reload = IndexSet()
        for case let key? in [previous, id] { if let item = itemsByID[key], outline.row(forItem: item) >= 0 { reload.insert(outline.row(forItem: item)) } }
        if !reload.isEmpty { outline.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0)) }
    }

    // MARK: Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        (item as? SidebarOutlineItem)?.children.count ?? roots.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if let item = item as? SidebarOutlineItem { return item.children[index] }
        return roots[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as? SidebarOutlineItem)?.row.isExpandable ?? false }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool { (item as? SidebarOutlineItem)?.row.role == .section }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool { (item as? SidebarOutlineItem)?.row.isSelectable ?? false }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        switch (item as? SidebarOutlineItem)?.row.role {
        case .cluster, .top, .section: 26
        case .group: 24
        default: 22
        }
    }

    func outlineView(_ outlineView: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? {
        (item as? SidebarOutlineItem)?.row.title
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let item = item as? SidebarOutlineItem else { return nil }
        let id = NSUserInterfaceItemIdentifier("sidebarCell")
        let cell = (outlineView.makeView(withIdentifier: id, owner: self) as? SidebarCellView) ?? { let c = SidebarCellView(); c.identifier = id; return c }()
        let expanded = outlineView.isItemExpanded(item)
        let decor = decorProvider(item.row, expanded)
        lastDecor[item.id] = decor
        cell.configure(item.row, decor: decor, isSelected: item.id == selectedID, expanded: expanded, parentTitle: parentTitle(of: item))
        return cell
    }

    private func parentTitle(of item: SidebarOutlineItem) -> String? {
        let r = outline.row(forItem: item)
        guard r >= 0, let p = outline.parent(forItem: item) as? SidebarOutlineItem else { return nil }
        return p.row.title
    }

    // MARK: Delegate

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !syncing, let item = outline.item(atRow: outline.selectedRow) as? SidebarOutlineItem else { return }
        selectedID = item.id
        onSelect(item.row)
    }

    func outlineViewItemWillExpand(_ notification: Notification) {
        guard !syncing, let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem else { return }
        // The model builds a cluster's children only when it is expanded: tell it first, then bring the items up to date so the
        // outline view finds children when it asks.
        model.setExpanded(true, rowID: item.id)
        if let fresh = model.find(item.id) {
            syncing = true
            reconcile(parent: item, oldChildren: &item.children, newRows: fresh.children)
            syncing = false
        }
    }

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !syncing, let item = notification.userInfo?["NSObject"] as? SidebarOutlineItem else { return }
        model.setExpanded(false, rowID: item.id)
    }

    private func activate(_ item: SidebarOutlineItem) {
        if item.row.isSelectable { selectedID = item.id; onSelect(item.row) }
        else if item.row.isExpandable { if outline.isItemExpanded(item) { outline.collapseItem(item) } else { outline.expandItem(item) } }
    }

    // MARK: Menu

    @MainActor private final class ActionBox: NSObject {
        let handler: @MainActor () -> Void
        init(_ handler: @escaping @MainActor () -> Void) { self.handler = handler }
        @objc func run() { handler() }
    }

    private func makeMenu(for row: SidebarRow) -> NSMenu? {
        let items = menuProvider(row)
        guard !items.isEmpty else { return nil }
        actionBoxes = []
        let menu = NSMenu()
        for i in items {
            if i.isSeparator { menu.addItem(.separator()); continue }
            let box = ActionBox(i.handler)
            actionBoxes.append(box)
            let mi = NSMenuItem(title: i.title, action: #selector(ActionBox.run), keyEquivalent: "")
            mi.target = box
            if let s = i.symbol { mi.image = NSImage(systemSymbolName: s, accessibilityDescription: nil) }
            menu.addItem(mi)
        }
        return menu
    }
}

// MARK: - Cell

private final class SidebarCellView: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let secondary = NSTextField(labelWithString: "")
    private let dot = NSView()
    private let envLabel = NSTextField(labelWithString: "")
    private let lock = NSImageView()
    private let badgeDot = NSView()
    private let badgeLabel = NSTextField(labelWithString: "")
    private let countLabel = NSTextField(labelWithString: "")
    private var tracking: NSTrackingArea?
    private var hovered = false { didSet { if hovered != oldValue { updateCount() } } }
    private var selected = false
    private var decor = SidebarDecor()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        icon.imageScaling = .scaleProportionallyDown
        title.lineBreakMode = .byTruncatingTail
        secondary.font = .systemFont(ofSize: 10)
        secondary.textColor = .secondaryLabelColor
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        envLabel.font = .systemFont(ofSize: 9, weight: .semibold)
        envLabel.wantsLayer = true
        envLabel.alignment = .center
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Read-only")
        lock.imageScaling = .scaleProportionallyDown
        lock.contentTintColor = .secondaryLabelColor
        badgeDot.wantsLayer = true
        badgeDot.layer?.cornerRadius = 3
        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        countLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .secondaryLabelColor
        [icon, title, secondary, dot, envLabel, lock, badgeDot, badgeLabel, countLabel].forEach(addSubview)
        textField = title
        imageView = icon
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(t)
        tracking = t
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    private func updateCount() {
        let show = (hovered || selected) && decor.count != nil
        countLabel.isHidden = !show
        countLabel.stringValue = decor.count.map(String.init) ?? ""
        needsLayout = true
    }

    func configure(_ row: SidebarRow, decor: SidebarDecor, isSelected: Bool, expanded: Bool, parentTitle: String?) {
        self.decor = decor
        selected = isSelected
        let isSection = row.role == .section
        title.stringValue = isSection ? row.title.uppercased() : row.title
        title.font = {
            switch row.role {
            case .section: .systemFont(ofSize: 10, weight: .semibold)
            case .cluster: .systemFont(ofSize: 13, weight: .medium)
            case .apiGroup: .monospacedSystemFont(ofSize: 11, weight: .regular)
            case .group: .systemFont(ofSize: 12, weight: .regular)
            default: .systemFont(ofSize: 12)
            }
        }()
        title.textColor = isSection ? .tertiaryLabelColor : (row.isForbidden ? .tertiaryLabelColor : .labelColor)
        secondary.stringValue = row.secondary ?? ""
        secondary.isHidden = row.secondary == nil

        icon.isHidden = row.symbol.isEmpty
        if !row.symbol.isEmpty {
            icon.image = row.symbol == "wheelhouse.helm" ? NSImage(named: "wheelhouse.helm") : NSImage(systemSymbolName: row.symbol, accessibilityDescription: nil)
            icon.contentTintColor = row.role == .kind || row.role == .featureNode ? .secondaryLabelColor : NSColor(Palette.tintText)
        }

        // Cluster-only decorations: status dot, environment badge, read-only lock, sync glyph.
        let isCluster = row.role == .cluster
        dot.isHidden = !isCluster || decor.status == nil
        if let s = decor.status { dot.layer?.backgroundColor = NSColor(s.color).cgColor }
        envLabel.isHidden = !(isCluster && decor.environment != nil)
        if let env = decor.environment {
            envLabel.stringValue = Self.short(env)
            envLabel.textColor = env == .production ? NSColor(Palette.criticalText) : .secondaryLabelColor
            envLabel.layer?.cornerRadius = 3
            envLabel.layer?.backgroundColor = (env == .production ? NSColor(Palette.critical).withAlphaComponent(0.14) : NSColor.quaternaryLabelColor.withAlphaComponent(0.2)).cgColor
        }
        lock.isHidden = !(isCluster && decor.isReadOnly)

        // Problem badge: a 6 pt dot and the count.
        if let b = decor.badge {
            badgeDot.isHidden = false
            badgeLabel.isHidden = false
            badgeDot.layer?.backgroundColor = NSColor(b.severity == .critical ? Palette.critical : Palette.warning).cgColor
            badgeLabel.stringValue = "\(b.count)"
            badgeLabel.textColor = NSColor(b.severity == .critical ? Palette.criticalText : Palette.warningText)
        } else {
            badgeDot.isHidden = true
            badgeLabel.isHidden = true
        }
        updateCount()

        // VoiceOver: "Pods, 3 problems, Workloads, prod-eu-west" / "prod-eu-west, Production cluster, critical, expanded".
        var parts = [row.title]
        if isCluster {
            if decor.environment == .production { parts.append("Production cluster") }
            if let s = decor.status { parts.append(s.title.lowercased()) }
            if decor.isReadOnly { parts.append("read-only") }
            parts.append(expanded ? "expanded" : "collapsed")
        } else {
            if let b = decor.badge { parts.append("\(b.count) problem\(b.count == 1 ? "" : "s")") }
            if row.isExpandable { parts.append(expanded ? "expanded" : "collapsed") }
            if row.isForbidden { parts.append("not permitted") }
            if let p = parentTitle { parts.append(p) }
        }
        setAccessibilityLabel(parts.joined(separator: ", "))
        setAccessibilityDisclosureLevel(max(row.level, 1))
        needsLayout = true
    }

    private static func short(_ env: ClusterEnvironment) -> String {
        switch env {
        case .production: "PROD"
        case .staging: "STG"
        case .development: "DEV"
        case .personal: "PERS"
        }
    }

    override func layout() {
        super.layout()
        let h = bounds.height
        var x: CGFloat = 0
        if !icon.isHidden { icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16); x = 22 }
        if !dot.isHidden { dot.frame = NSRect(x: x, y: (h - 8) / 2, width: 8, height: 8); x += 14 }

        // Trailing items, laid out right to left.
        var right = bounds.width - 2
        func place(_ v: NSView, width: CGFloat, height: CGFloat) {
            guard !v.isHidden else { return }
            v.frame = NSRect(x: right - width, y: (h - height) / 2, width: width, height: height)
            right -= width + 4
        }
        if !envLabel.isHidden { envLabel.sizeToFit(); place(envLabel, width: envLabel.frame.width + 8, height: 14) }
        if !lock.isHidden { place(lock, width: 11, height: 11) }
        if !badgeLabel.isHidden {
            badgeLabel.sizeToFit()
            place(badgeLabel, width: badgeLabel.frame.width, height: badgeLabel.frame.height)
            place(badgeDot, width: 6, height: 6)
        }
        if !countLabel.isHidden { countLabel.sizeToFit(); place(countLabel, width: countLabel.frame.width, height: countLabel.frame.height) }

        title.sizeToFit()
        var titleWidth = title.frame.width
        var secondaryWidth: CGFloat = 0
        if !secondary.isHidden { secondary.sizeToFit(); secondaryWidth = secondary.frame.width + 4 }
        titleWidth = min(titleWidth, max(20, right - x - secondaryWidth))
        title.frame = NSRect(x: x, y: (h - title.frame.height) / 2, width: titleWidth, height: title.frame.height)
        if !secondary.isHidden { secondary.frame = NSRect(x: x + titleWidth + 4, y: (h - secondary.frame.height) / 2, width: secondary.frame.width, height: secondary.frame.height) }
    }
}
