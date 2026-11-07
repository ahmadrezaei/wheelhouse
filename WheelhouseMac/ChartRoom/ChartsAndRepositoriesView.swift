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

    init(services: ChartRoomServices) { self.services = services }

    func load() async {
        let paths = services.helmPaths, cache = services.indexCache
        snapshot = await HelmRepositorySnapshot.load(paths: paths, indexCache: cache)
        phase = .loaded
    }

    var results: [HelmChartSummary] { HelmRepositories.search(search, in: snapshot.charts) }
}

// MARK: - Charts

struct ChartsView: View {
    @Bindable var model: RepositoriesModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Search charts", text: $model.search).textFieldStyle(.roundedBorder).frame(maxWidth: 320)
                Spacer()
                Text("\(model.snapshot.charts.count) charts from \(model.snapshot.indexes.count) repositories").font(.footnote).foregroundStyle(.secondary)
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Divider()
            content
        }
        .task(priority: .utility) { await model.load() }
        .accessibilityIdentifier("chartroom-charts")
    }

    @ViewBuilder private var content: some View {
        if model.phase == .loading {
            EmptyState(.loading)
        } else if let error = model.snapshot.configError {
            EmptyState(.error(message: error))
        } else if model.snapshot.repositories.isEmpty {
            EmptyState(.empty(title: "No Helm Repositories", systemImage: "books.vertical",
                              hint: "Charts come from the repositories in your Helm configuration. Add one with `helm repo add`; adding from here arrives with the write path (M6b).")) {
                Button("Add Repository…") {}.disabled(true)
            }
        } else if model.snapshot.charts.isEmpty {
            EmptyState(.empty(title: "No Chart Indexes Yet", systemImage: "arrow.down.circle",
                              hint: "None of your repositories has been updated. Run `helm repo update`, or update from the Repositories section once the write path arrives (M6b)."))
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
                    ChartDetail(chart: chart, services: model.services).id(id).frame(minWidth: 320, idealWidth: 400)
                }
            }
        }
    }
}

private struct ChartDetail: View {
    let chart: HelmChartSummary
    let services: ChartRoomServices
    @State private var archive: HelmChartArchive?
    @State private var version: String

    init(chart: HelmChartSummary, services: ChartRoomServices) {
        self.chart = chart
        self.services = services
        _version = State(initialValue: chart.latest.version)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                HStack {
                    Text(chart.name).font(.title2.weight(.semibold))
                    Spacer()
                    Button("Install…") {}.disabled(true).help("Installing arrives with the write path (M6b)")
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
                    Label("README and default values are read from the chart archive once it is in Helm's cache. Wheelhouse pulls charts when you install (M6b).",
                          systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(Spacing.l)
        }
        .task(id: version) { archive = await Self.readCachedArchive(chart: chart.name, version: version, cache: services.helmPaths.repositoryCache) }
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button("Add…") {}.disabled(true)
                Button("Update All") {}.disabled(true)
                Text("Adding, updating and removing arrive with the write path (M6b). Until then, use `helm repo` in a terminal; this list follows it.")
                    .font(.footnote).foregroundStyle(.secondary)
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
                Table(model.snapshot.repositories) {
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
        .accessibilityIdentifier("chartroom-repositories")
    }
}
