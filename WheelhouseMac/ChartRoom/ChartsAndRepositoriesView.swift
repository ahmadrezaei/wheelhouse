import SwiftUI
import WheelhouseKit
import WheelhouseUI

@MainActor @Observable
final class RepositoriesModel {
    enum Phase: Equatable { case loading, loaded }
    let services: ChartRoomServices
    private(set) var phase: Phase = .loading
    private(set) var snapshot = HelmRepositorySnapshot()
    var search = ""
    var selectedChart: String?
    @ObservationIgnored var actions: RepositoryActions?

    init(services: ChartRoomServices) { self.services = services }

    func load() async {
        let paths = services.helmPaths, cache = services.indexCache
        snapshot = await HelmRepositorySnapshot.load(paths: paths, indexCache: cache)
        phase = .loaded
    }

    var results: [HelmChartSummary] { HelmRepositories.search(search, in: snapshot.charts) }

    /// The repository actions of this pane (created on first use, so a read-only visit builds nothing).
    func repositoryActions(_ env: MacAppEnvironment) -> RepositoryActions {
        if let actions { return actions }
        let made = RepositoryActions(makeCLI: { try await HelmToolbox.cli(paths: env.paths) })
        actions = made
        return made
    }
}

// MARK: - Charts

struct ChartsView: View {
    @Bindable var model: RepositoriesModel
    let session: ClusterSession
    @State private var adding = false
    @State private var hub = false
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search charts", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Text("\(model.snapshot.charts.count) charts from \(model.snapshot.indexes.count) repositories").font(.footnote).foregroundStyle(.secondary)
                if ChartRoomSettings.isArtifactHubOn { Button("Artifact Hub…") { hub = true } }
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Divider()
            content
        }
        .task(priority: .utility) { await model.load() }
        .sheet(isPresented: $adding) { AddRepositorySheet(actions: model.repositoryActions(env), onAdded: { Task { await model.load() } }) }
        .sheet(isPresented: $hub) { ArtifactHubSheet(actions: model.repositoryActions(env), onAdded: { Task { await model.load() } }) }
        .accessibilityIdentifier("chartroom-charts")
    }

    @ViewBuilder private var content: some View {
        if model.phase == .loading {
            EmptyState(.loading)
        } else if let error = model.snapshot.configError {
            EmptyState(.error(message: error))
        } else if model.snapshot.repositories.isEmpty {
            EmptyState(.empty(title: "No Helm Repositories", systemImage: "books.vertical",
                              hint: "Charts come from the repositories in your Helm configuration. Add one here, or with `helm repo add`.")) {
                Button("Add Repository…") { adding = true }
            }
        } else if model.snapshot.charts.isEmpty {
            EmptyState(.empty(title: "No Chart Indexes Yet", systemImage: "arrow.down.circle",
                              hint: "None of your repositories has been updated. Update them from the Repositories section, or run `helm repo update`.")) {
                Button("Update Repositories") { Task { _ = await model.repositoryActions(env).update(); await model.load() } }
            }
        } else if model.results.isEmpty {
            EmptyState(.filteredEmpty(filter: model.search))
        } else {
            HSplitView {
                Table(model.results, selection: $model.selectedChart) {
                    TableColumn("Chart") { c in
                        HStack(spacing: 6) {
                            Text(c.name).fontWeight(.medium)
                            if c.latest.deprecated { FlagBadge("deprecated", tone: .warning) }
                        }
                    }.width(min: 140, ideal: 200)
                    TableColumn("Repository") { c in Text(c.repository).foregroundStyle(.secondary) }.width(min: 90, ideal: 120)
                    TableColumn("Version") { c in Text(c.latest.version).monospacedDigit() }.width(min: 70, ideal: 90)
                    TableColumn("App version") { c in Text(c.latest.appVersion ?? "—").foregroundStyle(.secondary) }.width(min: 70, ideal: 90)
                    TableColumn("Description") { c in Text(c.description ?? "").foregroundStyle(.secondary).lineLimit(1) }.width(min: 160, ideal: 300)
                }
                .frame(minWidth: 520)
                if let id = model.selectedChart, let chart = model.results.first(where: { $0.id == id }) {
                    ChartDetail(chart: chart, services: model.services, session: session).id(id).frame(minWidth: 320, idealWidth: 400)
                }
            }
        }
    }
}

private struct ChartDetail: View {
    let chart: HelmChartSummary
    let services: ChartRoomServices
    let session: ClusterSession
    @State private var archive: HelmChartArchive?
    @State private var version: String
    @State private var flow: HelmFlowModel?
    @Environment(MacAppEnvironment.self) private var env

    init(chart: HelmChartSummary, services: ChartRoomServices, session: ClusterSession) {
        self.chart = chart
        self.services = services
        self.session = session
        _version = State(initialValue: chart.latest.version)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(chart.name).font(.title2.weight(.semibold))
                    Spacer()
                    Button("Install…") { install() }.help("Install this chart version into \(session.config.name)")
                }
                if let description = chart.description { Text(description).foregroundStyle(.secondary) }
                LabeledContent("Repository", value: chart.repository)
                if !chart.keywords.isEmpty { LabeledContent("Keywords", value: chart.keywords.joined(separator: ", ")) }
                if !chart.maintainers.isEmpty { LabeledContent("Maintainers", value: chart.maintainers.joined(separator: ", ")) }
                if let home = chart.home, let url = URL(string: home) { LabeledContent("Home") { Link(home, destination: url) } }
                Picker("Version", selection: $version) {
                    ForEach(chart.versions.prefix(200), id: \.version) { v in
                        Text(v.version + (v.appVersion.map { "  (app \($0))" } ?? "") + (v.deprecated ? "  deprecated" : "")).tag(v.version)
                    }
                }
                Divider()
                if let archive {
                    if let readme = archive.readme { Text("README").font(.headline); Text(readme).font(.callout).textSelection(.enabled) }
                    if let values = archive.values { Text("Default values").font(.headline); CodeView(values, language: .yaml).frame(minHeight: 160, maxHeight: 320) }
                    Label(archive.schema == nil ? "No values.schema.json" : "Has values.schema.json", systemImage: "checklist").font(.footnote).foregroundStyle(.secondary)
                } else {
                    Label("README and default values are read from the chart archive once it is in Helm's cache. Wheelhouse pulls the chart when you start an install.",
                          systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.l)
        }
        .task(id: version) { archive = await Self.readCachedArchive(chart: chart.name, version: version, cache: services.helmPaths.repositoryCache) }
        .sheet(item: $flow) { HelmFlowSheet(model: $0) }
    }

    private func install() {
        let reference = "\(chart.repository)/\(chart.name)"
        let flow = HelmFlowModel(kind: .install, session: session, services: services, releaseName: chart.name, namespace: "default", chart: reference,
                                 chartVersion: version, makeRunner: HelmToolbox.liveRunner(env))
        self.flow = flow
        Task { await flow.loadChartDefaults(env: env) }
    }

    @concurrent private static func readCachedArchive(chart: String, version: String, cache: URL) async -> HelmChartArchive? {
        guard let url = HelmChartArchive.cachedArchive(chart: chart, version: version, cache: cache),
              let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return nil }
        return try? HelmChartArchive.read(tgz: data)
    }
}

// MARK: - Repositories

struct RepositoriesView: View {
    @Bindable var model: RepositoriesModel
    @State private var adding = false
    @State private var selection: String?
    @State private var removing: String?
    @Environment(MacAppEnvironment.self) private var env

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add…") { adding = true }
                Button("Update All") { Task { _ = await model.repositoryActions(env).update(); await model.load() } }
                    .disabled(model.snapshot.repositories.isEmpty)
                Button("Update") { if let selection { Task { _ = await model.repositoryActions(env).update(names: [selection]); await model.load() } } }
                    .disabled(selection == nil)
                Button("Remove…", role: .destructive) { removing = selection }.disabled(selection == nil)
                if let actions = model.actions {
                    if actions.busy { ProgressView().controlSize(.small) }
                    if let message = actions.message { Text(message).font(.footnote).foregroundStyle(actions.failed ? Palette.criticalText : .secondary).lineLimit(2).textSelection(.enabled) }
                }
                Spacer()
                Button { Task { await model.load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.keyboardShortcut("r", modifiers: .command)
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Divider()
            if model.phase == .loading {
                EmptyState(.loading)
            } else if let error = model.snapshot.configError {
                EmptyState(.error(message: error)) { Button("Retry") { Task { await model.load() } } }
            } else if model.snapshot.repositories.isEmpty {
                EmptyState(.empty(title: "No Helm Repositories", systemImage: "externaldrive.connected.to.line.below",
                                  hint: model.snapshot.configExists ? "Your Helm configuration lists no repositories." : "Helm has not been set up on this Mac yet (no repositories.yaml)."))
            } else {
                Table(model.snapshot.repositories, selection: $selection) {
                    TableColumn("Name") { r in
                        HStack(spacing: 6) {
                            Text(r.name).fontWeight(.medium)
                            if r.isOCI { FlagBadge("OCI", tone: .info) }
                            if r.hasCredentials { Image(systemName: "key.fill").imageScale(.small).foregroundStyle(.secondary).help("Uses stored credentials") }
                        }
                    }.width(min: 120, ideal: 160)
                    TableColumn("URL") { r in Text(r.url).foregroundStyle(.secondary).textSelection(.enabled) }.width(min: 200, ideal: 300)
                    TableColumn("Last updated") { r in
                        if let date = model.snapshot.lastUpdated[r.name] { Text(date.formatted(.relative(presentation: .numeric))).foregroundStyle(.secondary) }
                        else { Text(r.isOCI ? "n/a" : "never").foregroundStyle(.tertiary) }
                    }.width(min: 100, ideal: 120)
                    TableColumn("Charts") { r in
                        if let error = model.snapshot.errors[r.name] {
                            HStack {
                                Label("Index failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(Palette.warningText).help(error)
                                Button("Retry") { Task { await model.load() } }.buttonStyle(.link)
                            }
                        } else if let index = model.snapshot.indexes[r.name] { Text("\(index.charts.count)").monospacedDigit() }
                        else { Text("—").foregroundStyle(.tertiary) }
                    }.width(min: 120, ideal: 160)
                }
            }
        }
        .task(priority: .utility) { await model.load() }
        .sheet(isPresented: $adding) { AddRepositorySheet(actions: model.repositoryActions(env), onAdded: { Task { await model.load() } }) }
        .confirmationDialog("Remove \(removing ?? "")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Remove Repository", role: .destructive) {
                if let name = removing { Task { _ = await model.repositoryActions(env).remove(name: name); await model.load() } }
                removing = nil
            }
        } message: { Text("It is removed from your helm configuration. Releases installed from it are not touched.") }
        .accessibilityIdentifier("chartroom-repositories")
    }
}
