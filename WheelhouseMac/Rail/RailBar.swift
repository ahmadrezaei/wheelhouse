import AppKit
import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The Rail (DESIGN-MAC section 6.6): a 30 pt strip under the toolbar with pinned clusters, namespaces, objects and Stations. ⌘1 ... ⌘9
/// activate items 1 to 9 (through `MacCommands`). Click shows the item in the focused pane (a cluster keeps the current view), ⌘-click
/// opens a new tab, ⌥-click a split. Toggled with ⇧⌘B. It only reads the registry (no watch and no timer).
struct RailBar: View {
    let model: WorkspaceWindowModel
    @Environment(MacAppEnvironment.self) private var env
    @State private var renaming: RailItem?
    @State private var newName = ""

    private var rail: RailModel { env.rail }

    var body: some View {
        let items = rail.items
        HStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        RailChip(item: item, number: index < 9 ? index + 1 : nil)
                            .environment(env)
                            .onTapGesture { activate(item) }
                            .contextMenu { menu(for: item, index: index, count: items.count) }
                    }
                    if items.isEmpty {
                        Text("Pin clusters, namespaces and objects here with ⌥⌘B").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
            }
            if items.count > 9 {
                Menu {
                    ForEach(items.dropFirst(9)) { item in Button(rail.title(for: item)) { rail.activate(item, in: model, placement: .here, controller: env.workspace) } }
                } label: { Image(systemName: "chevron.right.2") }
                    .menuStyle(.borderlessButton).fixedSize().padding(.trailing, 8).help("More Rail items")
            }
        }
        .frame(height: 30)
        .background(.bar)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Rail")
        .alert("Rename Rail Item", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { if let r = renaming { rail.rename(r.id, to: newName) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func activate(_ item: RailItem) {
        let flags = NSEvent.modifierFlags
        let placement: OpenPlacement = flags.contains(.command) ? .newTab : (flags.contains(.option) ? .split : .here)
        rail.activate(item, in: model, placement: placement, controller: env.workspace)
    }

    @ViewBuilder private func menu(for item: RailItem, index: Int, count: Int) -> some View {
        Button("Open in New Tab") { rail.activate(item, in: model, placement: .newTab, controller: env.workspace) }
        Button("Open in Split") { rail.activate(item, in: model, placement: .split, controller: env.workspace) }
        Divider()
        Button("Rename…") { newName = rail.title(for: item); renaming = item }
        Button("Move Left") { if index > 0 { rail.move(item.id, before: rail.items[index - 1].id) } }.disabled(index == 0)
        Button("Move Right") { if index + 1 < count { rail.move(item.id, before: index + 2 < count ? rail.items[index + 2].id : nil) } }.disabled(index + 1 >= count)
        Button("Remove from Rail", role: .destructive) { rail.remove(item.id) }
    }
}

private struct RailChip: View {
    let item: RailItem
    let number: Int?
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        let rail = env.rail
        let available = rail.isAvailable(item)
        let config = item.clusterID.flatMap { env.registry.config(for: $0) }
        HStack(spacing: 4) {
            if item.kind == .cluster, let id = item.clusterID {
                Circle().fill(color(for: id)).frame(width: 7, height: 7)
            } else {
                Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
            }
            Text(rail.title(for: item)).font(.callout).lineLimit(1)
            if config?.environment == .production { Image(systemName: "shield.fill").font(.caption2).foregroundStyle(Palette.critical).accessibilityLabel("Production") }
            if let number { Text("⌘\(number)").font(.caption2).foregroundStyle(.tertiary) }
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
        .opacity(available ? 1 : 0.4)
        .contentShape(Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(rail.title(for: item))\(config.map { ", \($0.environment.title)" } ?? "")\(number.map { ", Rail item \($0)" } ?? "")")
        .accessibilityAddTraits(.isButton)
    }

    private var symbol: String {
        switch item.kind {
        case .cluster: "server.rack"
        case .namespace: "folder"
        case .resource: item.resource?.kind.symbol ?? "cube"
        case .station: "rectangle.split.2x2"
        }
    }

    /// The status dot reads the latest health snapshot only (never starts a check).
    private func color(for id: ClusterID) -> Color {
        switch env.registry.health(for: id)?.status {
        case .critical: .red
        case .warning: .orange
        case .healthy: .green
        default: .gray
        }
    }
}
