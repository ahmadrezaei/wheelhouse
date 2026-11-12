import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// Keeps one `TidesClusterModel` per cluster alive across renders.
@MainActor
final class TidesModelCache {
    private var models: [ClusterID: TidesClusterModel] = [:]
    func model(for session: ClusterSession) -> TidesClusterModel {
        if let m = models[session.id], m.session === session { return m }
        let m = TidesClusterModel(session: session)
        models[session.id] = m
        return m
    }
}

extension GitOpsSyncStatus {
    var tone: StatusTone {
        switch self {
        case .synced: .healthy
        case .outOfSync: .warning
        case .unknown: .unknown
        }
    }
}

extension GitOpsHealth {
    var tone: StatusTone {
        switch self {
        case .healthy: .healthy
        case .progressing: .info
        case .degraded, .missing: .critical
        case .suspended: .unknown
        case .unknown: .unknown
        }
    }
}

struct SyncPill: View {
    let app: GitOpsApp
    var body: some View {
        if app.flavor.isSource { EmptyView() } else {
            StatusPill(tone: app.sync.tone, text: app.sync.rawValue == "OutOfSync" ? "Out of Sync" : app.sync.rawValue)
        }
    }
}

struct HealthPill: View {
    let app: GitOpsApp
    var body: some View { StatusPill(tone: app.health.tone, text: app.suspended ? "Suspended" : app.health.rawValue) }
}

struct ToolGlyph: View {
    let tool: GitOpsOwner.Tool
    var body: some View {
        Image(systemName: tool == .flux ? "water.waves" : "arrow.triangle.2.circlepath")
            .foregroundStyle(Palette.tintText)
            .help(tool == .flux ? "Flux" : "Argo CD")
            .accessibilityLabel(tool == .flux ? "Flux" : "Argo CD")
    }
}

/// `live`, or `live → target` while they differ.
struct RevisionText: View {
    let app: GitOpsApp
    var body: some View {
        let live = GitOpsRevision.short(app.liveRevision)
        let target = GitOpsRevision.short(app.targetRevision)
        if app.revisionDiffers, let live, let target {
            Text("\(live) → \(target)").font(.whCode).foregroundStyle(Palette.warningText)
        } else {
            Text(live ?? target ?? "-").font(.whCode)
        }
    }
}

// MARK: - Root

/// Tides: the Overview for a cluster or the whole fleet (DESIGN-MAC §6.10).
struct TidesRootView: View {
    let scope: TidesScope
    @Environment(ClusterRegistry.self) private var registry
    @State private var cache = TidesModelCache()
    @State private var selection: TidesRow.ID?
    @State private var opened: TidesRow?
    @State private var showsSources = false
    @State private var problemsOnly = false
    @State private var search = ""

    private var sessions: [ClusterSession] {
        if let id = scope.clusterID { return registry.session(for: id).map { [$0] } ?? [] }
        return registry.clusters.compactMap { registry.session(for: $0.id) }
    }
    private var models: [TidesClusterModel] { sessions.map(cache.model(for:)) }
    private var watchID: [String] { sessions.map(\.id) + [scope.tool.map { "\($0)" } ?? "all", showsSources ? "s" : "a"] }

    private func rows() -> [TidesRow] {
        models.flatMap { m in
            (showsSources ? m.sources : m.apps).filter { app in
                (scope.tool == nil || (scope.tool == .flux) == (app.tool == .flux))
                    && (!problemsOnly || app.isProblem)
                    && (search.isEmpty || app.name.localizedCaseInsensitiveContains(search) || (app.namespace ?? "").localizedCaseInsensitiveContains(search)
                        || app.source.localizedCaseInsensitiveContains(search))
            }.map { TidesRow(cluster: m.id, clusterName: m.name, app: $0) }
        }.sorted { a, b in GitOpsApp.problemsFirst(a.app, b.app) }
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(scope.clusterID.flatMap { registry.config(for: $0)?.name }.map { "Tides: \($0)" } ?? "Tides")
                .navigationDestination(item: $opened) { row in
                    if let model = models.first(where: { $0.id == row.cluster }) {
                        TidesDetailView(model: model, appID: row.app.id)
                    }
                }
        }
        .whileVisible(id: watchID) { await run() }
        .accessibilityIdentifier("tides-root")
    }

    private func run() async {
        let list = models
        let sources = showsSources || scope.tool != .argoCD
        let loaders = list.map { m in Task { await m.loadDiscovery() } }
        for l in loaders { await l.value }
        guard !Task.isCancelled else { return }
        let held = list.map { ($0, $0.acquire(includeSources: sources)) }
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        for (m, stores) in held { m.release(stores) }
    }

    @ViewBuilder private var content: some View {
        let all = models
        let rows = rows()
        VStack(spacing: 0) {
            tiles(all.flatMap(\.apps))
            Divider()
            if all.isEmpty {
                ContentUnavailableView("No clusters", systemImage: "server.rack", description: Text("Add a cluster to see its Flux and Argo CD apps."))
            } else if all.allSatisfy({ $0.discoveryDone && !$0.detection.isPresent }) {
                ContentUnavailableView("No GitOps tools found", systemImage: "arrow.triangle.2.circlepath",
                                       description: Text("Flux (kustomize, helm and source controllers) and Argo CD are detected from the cluster's CRDs. None are installed here."))
            } else if rows.isEmpty {
                if all.contains(where: \.isLoading) {
                    ProgressView("Loading apps").frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = all.compactMap(\.storeError).first {
                    ContentUnavailableView("Couldn't load apps", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription))
                } else {
                    ContentUnavailableView(problemsOnly ? "No problems" : "Nothing here", systemImage: "checkmark.circle")
                }
            } else {
                table(rows)
            }
        }
        .paneSearchable(text: $search, prompt: "Filter apps")
        .paneToolbar {
            ToolbarItem {
                Picker("Show", selection: $showsSources) {
                    Text("Apps").tag(false)
                    Text("Sources").tag(true)
                }.pickerStyle(.segmented).help("Applications, or Flux sources")
            }
            ToolbarItem { Toggle(isOn: $problemsOnly) { Label("Problems only", systemImage: "exclamationmark.triangle") }.help("Show only apps that need attention") }
        }
    }

    private func tiles(_ apps: [GitOpsApp]) -> some View {
        let t = TidesTally(apps)
        return HStack(spacing: Spacing.m) {
            Tile(title: "Out of sync", count: t.outOfSync, tone: .warning)
            Tile(title: "Degraded", count: t.degraded, tone: .critical)
            Tile(title: "Suspended", count: t.suspended, tone: .unknown)
            Tile(title: "Failed reconcile", count: t.failedReconcile, tone: .critical)
            Spacer()
        }
        .padding(Spacing.m)
    }

    private func table(_ rows: [TidesRow]) -> some View {
        Table(rows, selection: $selection) {
            TableColumn("") { r in ToolGlyph(tool: r.app.tool) }.width(22)
            TableColumn("Name") { r in
                VStack(alignment: .leading, spacing: 0) {
                    Text(r.app.name).fontWeight(.medium)
                    if scope.clusterID == nil { Text(r.clusterName).font(.caption).foregroundStyle(.secondary) }
                }
            }.width(min: 120, ideal: 170)
            TableColumn("Kind") { r in Text(r.app.flavor.title).foregroundStyle(.secondary) }.width(min: 80, ideal: 100)
            TableColumn("Namespace / Project") { r in Text(r.app.project ?? r.app.namespace ?? "-") }.width(min: 90, ideal: 130)
            TableColumn("Source") { r in Text(r.app.source).lineLimit(1).truncationMode(.middle).help(r.app.source) }.width(min: 140, ideal: 220)
            TableColumn("Revision") { r in RevisionText(app: r.app) }.width(min: 90, ideal: 150)
            TableColumn("Sync") { r in SyncPill(app: r.app) }.width(min: 90, ideal: 110)
            TableColumn("Health") { r in HealthPill(app: r.app) }.width(min: 90, ideal: 110)
            TableColumn("Last") { r in
                if let d = r.app.lastActivity { Text(d, style: .relative).foregroundStyle(.secondary) } else { Text("-").foregroundStyle(.secondary) }
            }.width(min: 70, ideal: 90)
            TableColumn("Message") { r in Text(r.app.message ?? "").lineLimit(1).foregroundStyle(.secondary).help(r.app.message ?? "") }
        }
        .contextMenu(forSelectionType: TidesRow.ID.self) { _ in } primaryAction: { ids in
            if let id = ids.first, let row = rows.first(where: { $0.id == id }) { opened = row }
        }
        .accessibilityIdentifier("tides-table")
    }
}

private struct Tile: View {
    let title: String
    let count: Int
    let tone: StatusTone
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(count)").font(.title.weight(.semibold).monospacedDigit())
                .foregroundStyle(count == 0 ? Color.secondary : tone.textColor)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, Spacing.s)
        .frame(minWidth: 110, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}

/// `.gitopsApp(ResourceRef)`: one app, opened directly.
struct GitOpsAppDestinationView: View {
    let ref: ResourceRef
    @Environment(ClusterRegistry.self) private var registry
    @State private var cache = TidesModelCache()

    var body: some View {
        if let session = registry.session(for: ref.clusterID) {
            let model = cache.model(for: session)
            let id = GitOpsApp.identifier(kind: ref.kind, namespace: ref.namespace, name: ref.name)
            TidesDetailView(model: model, appID: id)
        } else {
            ContentUnavailableView("Cluster not found", systemImage: "server.rack")
        }
    }
}
