import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// A sheet a window can show for the workspace commands.
enum WorkspaceSheet: Identifiable, Hashable {
    case saveStation
    case stations
    /// A template Station's cluster picker. `fromLink`: the Station was opened by a `wheelhouse://` link, so its terminals do not start.
    case pickClusters(StationID, fromLink: Bool = false)

    var id: String {
        switch self {
        case .saveStation: "save"
        case .stations: "stations"
        case .pickClusters(let id, let fromLink): "pick-\(id.rawValue)" + (fromLink ? "-link" : "")
        }
    }
}

/// Window ▸ Stations ▸ Save Current Window as Station…: a name and "Bind to these clusters" or "Ask for cluster when opening".
struct SaveStationSheet: View {
    @Environment(\.dismiss) private var dismiss
    let model: WorkspaceWindowModel
    @State private var name = ""
    @State private var bind = true

    var body: some View {
        Form {
            TextField("Name", text: $name).accessibilityIdentifier("station.name")
            Picker("Clusters", selection: $bind) {
                Text("Bind to these clusters").tag(true)
                Text("Ask for cluster when opening").tag(false)
            }
            .pickerStyle(.radioGroup)
            Text("A Station keeps the tabs, the pane layout, the routes and the contexts. It never keeps data or credentials.").font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    model.saveStation(named: name.trimmingCharacters(in: .whitespaces), bindToClusters: bind)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                .accessibilityIdentifier("station.save")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .padding(.bottom, 8)
    }
}

/// The Station manager and opener (⇧⌘O): built-in templates first, then the saved Stations. Open in a new window, rename,
/// duplicate, delete.
struct StationsView: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    @State private var renaming: StationID?
    @State private var newName = ""

    private var workspace: WorkspaceController { env.workspace }

    /// A template replaces this sheet with its cluster picker (so no dismiss: it would clear the picker too).
    private func open(_ station: Station) {
        workspace.open(station: station)
        if !station.isTemplate { dismiss() }
    }

    var body: some View {
        let stations = workspace.store.stations
        List {
            ForEach(stations) { station in
                HStack {
                    Image(systemName: station.isTemplate ? "rectangle.3.group.bubble" : "rectangle.3.group")
                    VStack(alignment: .leading) {
                        if renaming == station.id {
                            TextField("Name", text: $newName).onSubmit { workspace.store.renameStation(station.id, to: newName); renaming = nil }
                        } else {
                            Text(station.name)
                        }
                        Text(station.isTemplate ? "Asks for a cluster when opened" : "\(station.tabs.count) tab\(station.tabs.count == 1 ? "" : "s")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Open") { open(station) }.disabled(station.raw != nil).accessibilityIdentifier("station.open.\(station.name)")
                }
                .contextMenu {
                    Button("Open") { open(station) }.disabled(station.raw != nil)
                    Button("Rename") { newName = station.name; renaming = station.id }.disabled(station.isBuiltIn || station.raw != nil)
                    Button("Duplicate") { workspace.store.duplicateStation(station.id) }.disabled(station.raw != nil)
                    Divider()
                    Button("Delete", role: .destructive) { workspace.store.deleteStation(station.id) }.disabled(station.isBuiltIn)
                }
            }
        }
        .frame(minWidth: 420, minHeight: 320)
        .accessibilityIdentifier("stations.list")
    }
}

/// A template Station asks which cluster to use for each placeholder.
struct StationClusterPicker: View {
    @Environment(MacAppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss
    let station: Station
    /// Opened from a link: the Station opens without its terminals, like a link that needs no picker.
    var fromLink = false
    @State private var chosen: [ClusterID: ClusterID] = [:]

    var body: some View {
        let clusters = env.registry.clusters
        Form {
            Text("Open “\(station.name)” on:").font(.headline)
            ForEach(Array(station.placeholders.enumerated()), id: \.element) { index, placeholder in
                Picker(station.placeholders.count == 1 ? "Cluster" : "Cluster \(index + 1)", selection: Binding(get: { chosen[placeholder] ?? clusters.first?.id ?? "" }, set: { chosen[placeholder] = $0 })) {
                    ForEach(clusters, id: \.id) { Text($0.name).tag($0.id) }
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Open") {
                    env.workspace.open(station: station, picked: chosen, fromLink: fromLink)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction).disabled(clusters.isEmpty)
            }
        }
        .formStyle(.grouped).frame(width: 420)
    }
}
