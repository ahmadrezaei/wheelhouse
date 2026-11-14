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

    /// A click on the name: only this namespace.
    mutating func selectOnly(_ name: String) { selection = NamespaceSelection(name) }
    /// A click on the checkbox: add or remove this namespace.
    mutating func toggle(_ name: String) { selection = selection.toggling(name) }
    /// The All namespaces row.
    mutating func clear() { selection = .all }
}

/// Toolbar button for a list's namespace filter on the Mac: a popover with a search field, an "All namespaces" row, the pinned
/// namespaces and every namespace, each with a checkbox. Clicking a name selects only that namespace; the checkbox adds or removes it.
struct NamespacePickerButton: View {
    @Environment(ClusterRegistry.self) private var registry
    let session: ClusterSession
    @Binding var selection: NamespaceSelection
    @State private var isOpen = false
    @State private var query = ""
    @FocusState private var searchFocused: Bool

    var body: some View {
        let store = session.store(for: Namespace.self)
        Button { query = ""; isOpen = true } label: {
            Label(selection.label, systemImage: "folder")
        }
        .help(selection.detail)
        .accessibilityLabel("Namespace: \(selection.isAll ? "all" : selection.detail)")
        .accessibilityIdentifier("namespace.picker")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) { content }
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
                .onSubmit { if let only = singleMatch(shown) { apply({ $0.selectOnly(only) }, closes: true) } }
            Divider()
            if shown.isEmpty {
                Text("No namespaces match").foregroundStyle(.secondary).padding(16)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if shown.showsAllRow {
                            row(title: "All namespaces", symbol: "square.stack.3d.up", checked: selection.isAll, checkEnabled: !selection.isAll,
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
        .onAppear { searchFocused = true }
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
            name: { apply({ $0.selectOnly(name) }, closes: true) }, check: { apply({ $0.toggle(name) }, closes: false) })
    }

    private func row(title: String, symbol: String?, checked: Bool, checkEnabled: Bool,
                     name: @escaping () -> Void, check: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Button(action: check) {
                Image(systemName: checked ? "checkmark.square.fill" : "square").foregroundStyle(checked ? Palette.tint : .secondary)
            }
            .buttonStyle(.plain).disabled(!checkEnabled && !checked)
            .accessibilityLabel(checked ? "Deselect \(title)" : "Select \(title)")
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
    }
}
