import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The state and rules of the Mac namespace popover, kept free of views so they can be tested.
struct NamespacePickerModel: Equatable {
    var selection: NamespaceSelection
    /// Every namespace the picker can offer (cluster namespaces plus any selected one the cluster no longer lists).
    let names: [String]
    let pinned: [String]
    var query = ""

    init(selection: NamespaceSelection, clusterNamespaces: [String], pinned: [String]) {
        self.selection = selection
        let all = Set(clusterNamespaces).union(selection.names)
        self.names = all.sorted()
        self.pinned = pinned.filter { all.contains($0) }
    }

    private var needle: String { query.trimmingCharacters(in: .whitespaces).lowercased() }
    private func matches(_ name: String) -> Bool { needle.isEmpty || name.lowercased().contains(needle) }

    /// "All namespaces" stays visible unless the search is narrowing the list.
    var showsAllRow: Bool { needle.isEmpty }
    var pinnedRows: [String] { pinned.filter(matches) }
    var otherRows: [String] { names.filter { !pinned.contains($0) && matches($0) } }
    var isEmpty: Bool { !showsAllRow && pinnedRows.isEmpty && otherRows.isEmpty }
    var atLimit: Bool { selection.names.count >= NamespaceSelection.limit }

    /// One row of the list, in the order it is drawn: All namespaces, the pinned names, the others.
    enum Row: Equatable {
        case all
        case namespace(String)
    }

    var rows: [Row] { (showsAllRow ? [.all] : []) + pinnedRows.map(Row.namespace) + otherRows.map(Row.namespace) }

    /// The keyboard highlight after an arrow key: the first press lands on the first (↓) or last (↑) row; it stops at the ends.
    static func moved(_ index: Int?, by delta: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        guard let index else { return delta >= 0 ? 0 : count - 1 }
        return min(max(index + delta, 0), count - 1)
    }

    /// Return on the highlighted row: only that namespace (All namespaces clears the selection).
    mutating func selectOnly(_ row: Row) {
        switch row {
        case .all: clear()
        case .namespace(let name): selectOnly(name)
        }
    }

    /// Space on the highlighted row: add or remove it.
    mutating func toggle(_ row: Row) {
        switch row {
        case .all: clear()
        case .namespace(let name): toggle(name)
        }
    }

    /// A click on the name: only this namespace.
    mutating func selectOnly(_ name: String) { selection = NamespaceSelection(name) }
    /// A click on the checkbox: add or remove this namespace.
    mutating func toggle(_ name: String) { selection = selection.toggling(name) }
    /// The All namespaces row.
    mutating func clear() { selection = .all }
}

/// Toolbar button for a list's namespace filter on the Mac: a popover with a search field, an "All namespaces" row, the pinned
/// namespaces and every namespace, each with a checkbox. Clicking a name selects only that namespace; the checkbox adds or removes it.
extension Notification.Name {
    /// View > Namespace… (⌥⌘N): the object is the key window; the focused pane's picker opens.
    static let openNamespacePicker = Notification.Name("wheelhouse.openNamespacePicker")
}

struct NamespacePickerButton: View {
    @Environment(ClusterRegistry.self) private var registry
    let session: ClusterSession
    @Binding var selection: NamespaceSelection
    @State private var isOpen = false
    /// When the popover last closed: a click on the button while it is open first closes it (a click outside a transient popover),
    /// and the button's action must not open it again right away.
    @State private var closedAt = Date.distantPast
    @State private var query = ""
    @FocusState private var searchFocused: Bool
    /// The row the arrow keys are on (nil until the first arrow press).
    @State private var highlight: Int?
    @State private var window: NSWindow?

    var body: some View {
        let store = session.store(for: Namespace.self)
        Button {
            guard Date.now.timeIntervalSince(closedAt) > 0.3 else { return }
            query = ""; isOpen = true
        } label: {
            Label(selection.label, systemImage: "folder")
        }
        .help(selection.detail)
        .accessibilityLabel("Namespace: \(selection.isAll ? "all" : selection.detail)")
        .accessibilityIdentifier("namespace.picker")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { content }
        .background(PickerWindowProbe(window: $window))
        .onReceive(NotificationCenter.default.publisher(for: .openNamespacePicker)) { note in
            // Only the picker in the window the command was sent from (a window the probe has not reached yet answers too).
            guard window == nil || note.object as? NSWindow === window else { return }
            query = ""; highlight = nil; isOpen = true
        }
        .task { await store.run() }
    }

    /// Built on every render from the live namespace list, so an open popover fills in when the list finishes loading.
    private var model: NamespacePickerModel {
        let names = session.store(for: Namespace.self).items.map(\.metadata.name)
        // Until the list is known, pinned names stay offered (as the iOS menu does).
        return NamespacePickerModel(selection: selection, clusterNamespaces: names.isEmpty ? session.config.pinnedNamespaces : names,
                                    pinned: session.config.pinnedNamespaces)
    }

    private func apply(_ change: (inout NamespacePickerModel) -> Void, closes: Bool) {
        var m = model
        change(&m)
        selection = m.selection
        registry.setNamespaceSelection(m.selection, for: session.id)
        if closes { isOpen = false }
    }

    private var content: some View {
        var shown = model
        shown.query = query
        let rows = (shown.showsAllRow ? 1 : 0) + shown.pinnedRows.count + shown.otherRows.count
        return VStack(spacing: 0) {
            TextField("Search namespaces", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(8)
                .onSubmit {
                    if let h = highlight, shown.rows.indices.contains(h) { let row = shown.rows[h]; apply({ $0.selectOnly(row) }, closes: true) }
                    else if let only = singleMatch(shown) { apply({ $0.selectOnly(only) }, closes: true) }
                }
                .onChange(of: query) { _, _ in highlight = nil }
            Divider()
            if shown.isEmpty {
                Text("No namespaces match").foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if shown.showsAllRow {
                            row(title: "All namespaces", symbol: "square.stack.3d.up", checked: selection.isAll, checkEnabled: !selection.isAll,
                                highlighted: highlight == 0,
                                name: { apply({ $0.clear() }, closes: true) }, check: { apply({ $0.clear() }, closes: false) })
                        }
                        if !shown.pinnedRows.isEmpty {
                            sectionTitle("Pinned")
                            ForEach(shown.pinnedRows, id: \.self) { item(shown, $0, symbol: "pin") }
                        }
                        if !shown.otherRows.isEmpty {
                            sectionTitle("Namespaces")
                            ForEach(shown.otherRows, id: \.self) { item(shown, $0, symbol: nil) }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(height: min(CGFloat(rows) * 26 + 40, 340))
            }
            if shown.atLimit {
                Divider()
                Text("Up to \(NamespaceSelection.limit) namespaces").font(.caption).foregroundStyle(.secondary).padding(6)
            }
        }
        .frame(width: 280)
        // ↑ ↓ move a highlight, Space adds or removes the highlighted namespace (while the search is empty: otherwise it is typed),
        // Return selects only the highlighted one.
        .onKeyPress(.downArrow) { highlight = NamespacePickerModel.moved(highlight, by: 1, count: shown.rows.count); return .handled }
        .onKeyPress(.upArrow) { highlight = NamespacePickerModel.moved(highlight, by: -1, count: shown.rows.count); return .handled }
        .onKeyPress(.space) {
            guard query.isEmpty, let h = highlight, shown.rows.indices.contains(h) else { return .ignored }
            let row = shown.rows[h]
            apply({ $0.toggle(row) }, closes: false)
            return .handled
        }
        // Focus once the popover's window exists: set during `onAppear` it is often dropped.
        .onAppear { DispatchQueue.main.async { searchFocused = true } }
        .onDisappear { closedAt = .now }
    }

    private func singleMatch(_ shown: NamespacePickerModel) -> String? {
        let all = shown.pinnedRows + shown.otherRows
        return all.count == 1 ? all[0] : nil
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 6).padding(.bottom, 2)
    }

    private func item(_ shown: NamespacePickerModel, _ name: String, symbol: String?) -> some View {
        row(title: name, symbol: symbol, checked: selection.contains(name), checkEnabled: selection.contains(name) || !shown.atLimit,
            highlighted: shown.rows.firstIndex(of: .namespace(name)) == highlight && highlight != nil,
            name: { apply({ $0.selectOnly(name) }, closes: true) }, check: { apply({ $0.toggle(name) }, closes: false) })
    }

    private func row(title: String, symbol: String?, checked: Bool, checkEnabled: Bool, highlighted: Bool = false,
                     name: @escaping () -> Void, check: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            // A real checkbox: VoiceOver says "checked", Full Keyboard Access reaches it, Space toggles it.
            Toggle(isOn: Binding(get: { checked }, set: { _ in check() })) { Text(title) }
                .toggleStyle(.checkbox).labelsHidden()
                .disabled(!checkEnabled && !checked)
                .accessibilityLabel(title)
            Button(action: name) {
                HStack(spacing: 6) {
                    if let symbol { Image(systemName: symbol).imageScale(.small).foregroundStyle(.secondary) }
                    Text(title).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12).frame(height: 26)
        .background(highlighted ? Palette.tint.opacity(0.18) : .clear)
    }
}

/// Reports the window a view is in, so a menu command reaches the picker of its own window.
private struct PickerWindowProbe: NSViewRepresentable {
    @Binding var window: NSWindow?

    final class Probe: NSView {
        var onWindow: ((NSWindow?) -> Void)?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            let window = window
            DispatchQueue.main.async { [onWindow] in onWindow?(window) }
        }
    }

    func makeNSView(context: Context) -> Probe {
        let probe = Probe()
        probe.onWindow = { window = $0 }
        return probe
    }

    func updateNSView(_ probe: Probe, context: Context) { probe.onWindow = { window = $0 } }
}
