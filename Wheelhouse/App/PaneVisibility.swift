import SwiftUI
import WheelhouseUI

private struct PaneIsVisibleKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False while the screen's pane cannot be seen: its Mac window is miniaturised or covered, its tab is not the selected one, or it
    /// is parked behind a zoomed pane (ARCHITECTURE-MAC section 12.3.3). Screens stop drawing and stop periodic refreshes while it is
    /// false; streams keep filling their buffers. Nothing sets it on iOS, so there it is always true and nothing changes.
    var paneIsVisible: Bool {
        get { self[PaneIsVisibleKey.self] }
        set { self[PaneIsVisibleKey.self] = newValue }
    }
}

private struct PaneContributesToolbarKey: EnvironmentKey { static let defaultValue = true }

extension EnvironmentValues {
    /// False in a Mac workspace pane that is not the focused pane of the selected tab: its screen leaves the window toolbar and the
    /// search field to the focused pane. SwiftUI merges the toolbar items of every view in a window, so two lists side by side showed
    /// two sets of items, and two `.searchable` screens cannot share a window at all (AppKit raises on a second
    /// `com.apple.SwiftUI.search` toolbar item). Nothing sets it on iOS, so there it is always true and nothing changes.
    var paneContributesToolbar: Bool {
        get { self[PaneContributesToolbarKey.self] }
        set { self[PaneContributesToolbarKey.self] = newValue }
    }
}

extension View {
    /// `.toolbar` for a screen that can be a workspace pane: its items are there only while the pane contributes to the window
    /// toolbar (``EnvironmentValues/paneContributesToolbar``). Only the toolbar's content changes, never the view, so a pane that
    /// loses focus keeps its state. On iOS it is exactly `.toolbar`.
    func paneToolbar<Items: ToolbarContent>(@ToolbarContentBuilder _ items: () -> Items) -> some View {
        modifier(PaneToolbar(items: items()))
    }

    /// The search field of a screen that can be a workspace pane. iOS: exactly `.searchable(text:prompt:)`. macOS: a filter field in
    /// the window toolbar while the pane contributes to it, as a plain toolbar item (one `.searchable` per pane would put two search
    /// items in one toolbar). A pane that loses focus keeps its text and its filtering.
    /// `drawer`: iOS places the field in the navigation bar drawer (`whSearchable`) instead of the default placement.
    @ViewBuilder func paneSearchable(text: Binding<String>, prompt: LocalizedStringKey, drawer: Bool = false) -> some View {
        #if os(macOS)
        paneToolbar { ToolbarItem(placement: .automatic) { ToolbarSearchField(text: text, prompt: prompt, submit: nil) } }
        #else
        if drawer { whSearchable(text: text, prompt: prompt) } else { searchable(text: text, prompt: prompt) }
        #endif
    }

    /// `paneSearchable` with search scopes and a submit action. iOS: exactly `.searchable`, `.searchScopes` and
    /// `.onSubmit(of: .search)`. macOS: the filter field and a segmented scope picker in the window toolbar, while the pane
    /// contributes to it.
    @ViewBuilder func paneSearchable<Scope: Hashable>(text: Binding<String>, prompt: LocalizedStringKey, scope: Binding<Scope>,
                                                      scopes: [(title: LocalizedStringKey, value: Scope)], onSubmit submit: @escaping () -> Void) -> some View {
        #if os(macOS)
        paneToolbar {
            ToolbarItem(placement: .automatic) {
                Picker("Scope", selection: scope) { ForEach(scopes.indices, id: \.self) { Text(scopes[$0].title).tag(scopes[$0].value) } }
                    .pickerStyle(.segmented).fixedSize()
            }
            ToolbarItem(placement: .automatic) { ToolbarSearchField(text: text, prompt: prompt, submit: submit) }
        }
        #else
        searchable(text: text, prompt: prompt)
            .searchScopes(scope) { ForEach(scopes.indices, id: \.self) { Text(scopes[$0].title).tag(scopes[$0].value) } }
            .onSubmit(of: .search, submit)
        #endif
    }
}

private struct PaneToolbar<Items: ToolbarContent>: ViewModifier {
    @Environment(\.paneContributesToolbar) private var contributes
    let items: Items

    func body(content: Content) -> some View {
        content.toolbar { if contributes { items } }
    }
}

#if os(macOS)
/// The filter field a pane's screen puts in the window toolbar.
struct ToolbarSearchField: View {
    @Binding var text: String
    let prompt: LocalizedStringKey
    let submit: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(prompt, text: $text).textFieldStyle(.plain).onSubmit { submit?() }.accessibilityAddTraits(.isSearchField)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Clear Search")
            }
        }
        .padding(.horizontal, 6)
        .frame(minWidth: 160, idealWidth: 220, maxWidth: 260)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("pane.search")
    }
}
#endif
