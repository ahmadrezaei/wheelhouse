import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The Compass overlay (DESIGN-MAC section 6.7): a 640 pt panel in the top third of the window. ↑ ↓ move, ↩ opens, ⌘↩ a new tab, ⌥↩ a
/// split, ⇧↩ a new window, → or Tab the actions of a result, Esc closes (or goes back from the actions).
struct CompassPanel: View {
    @Bindable var compass: CompassModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.18)
                .contentShape(Rectangle())
                .onTapGesture { compass.close() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search everything, or > for actions", text: $compass.query)
                        .textFieldStyle(.plain)
                        .font(.title3)
                        .focused($focused)
                        .onSubmit { compass.performSelected() }
                        .accessibilityLabel("Compass")
                        .accessibilityIdentifier("compass.field")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider()
                list
                Divider()
                Text(compass.footer).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
            }
            .frame(width: 640)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.separator))
            .shadow(radius: 24, y: 8)
            .padding(.top, 90)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Compass, \(compass.results.count) results")
        }
        .onAppear { focused = true }
        .onKeyPress(.upArrow) { compass.move(-1); return .handled }
        .onKeyPress(.downArrow) { compass.move(1); return .handled }
        .onKeyPress(.escape) { if compass.showsActionList { compass.hideActions() } else { compass.close() }; return .handled }
        .onKeyPress(.tab) { compass.showActions(); return .handled }
        .onKeyPress(.return, phases: .down) { press in
            if press.modifiers.contains(.command) { compass.performSelected(placement: .newTab) }
            else if press.modifiers.contains(.option) { compass.performSelected(placement: .split) }
            else if press.modifiers.contains(.shift) { compass.performSelected(placement: .newWindow) }
            else { compass.performSelected() }
            return .handled
        }
    }

    @ViewBuilder private var list: some View {
        if compass.showsActionList {
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(compass.actions.enumerated()), id: \.element.id) { i, action in
                        Label(action.title, systemImage: action.symbol)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.vertical, 6)
                            .background(i == compass.selection ? Palette.tint.opacity(0.2) : .clear)
                            .contentShape(Rectangle())
                            .onTapGesture { compass.selection = i; compass.performSelected() }
                    }
                }
            }
            .frame(maxHeight: 280)
        } else if compass.results.isEmpty {
            Text(compass.query.isEmpty ? "Type to search. > actions · @cluster · #namespace · go kind" : "No results")
                .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(20)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0, pinnedViews: []) {
                        ForEach(Array(compass.results.enumerated()), id: \.element.id) { i, result in
                            if i == 0 || compass.results[i - 1].group != result.group, !result.group.title.isEmpty {
                                Text(result.group.title).font(.caption).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 14).padding(.top, 8)
                            }
                            CompassRow(result: result, selected: i == compass.selection)
                                .id(i)
                                .onTapGesture { compass.selection = i; compass.performSelected() }
                        }
                    }
                }
                .frame(maxHeight: 380)
                .onChange(of: compass.selection) { _, i in proxy.scrollTo(i) }
            }
        }
    }
}

private struct CompassRow: View {
    let result: CompassResult
    let selected: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.symbol).frame(width: 20).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                highlighted
                if let subtitle = result.subtitle { Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 8)
            if let env = result.environment { EnvBadge(env) }
            if result.isProblem { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).accessibilityLabel("Failing") }
            if let shortcut = result.shortcut { Text(shortcut).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(.horizontal, 14).padding(.vertical, 5)
        .background(selected ? Palette.tint.opacity(0.2) : .clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel([result.title, result.subtitle, result.environment?.title, result.isProblem ? "failing" : nil].compactMap { $0 }.joined(separator: ", "))
    }

    private var highlighted: Text {
        let offsets = Set(CompassMatcher.matchedOffsets(query: result.highlight, in: result.title))
        guard !offsets.isEmpty else { return Text(result.title) }
        return result.title.enumerated().reduce(Text("")) { text, pair in
            text + (offsets.contains(pair.offset) ? Text(String(pair.element)).bold() : Text(String(pair.element)))
        }
    }
}
