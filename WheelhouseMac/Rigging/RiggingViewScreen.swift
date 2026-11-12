import SwiftUI
import WheelhouseKit
import WheelhouseUI

extension RiggingPack.Tone {
    var statusTone: StatusTone {
        switch self {
        case .neutral: .unknown
        case .healthy: .healthy
        case .warning: .warning
        case .critical: .critical
        }
    }
}

/// One pack view (`riggingView(RiggingViewRef)`): the objects of a kind with the pack's columns and status tones. It reads through the
/// shared `unstructuredStore` of the cluster session and holds it only while the view is on screen in a visible window, so it adds no
/// watch of its own (ARCHITECTURE-MAC section 12.3).
struct RiggingViewScreen: View {
    let ref: RiggingViewRef
    @Environment(MacAppEnvironment.self) private var env
    @Environment(ClusterRegistry.self) private var registry
    @Environment(AppRouter.self) private var router: AppRouter?
    @State private var selection: String?
    @State private var search = ""
    @State private var kind: ResourceKind?
    @State private var discoveryDone = false

    private var rigging: RiggingRuntime { env.rigging }
    private var cluster: ClusterConfig? { (ref.clusterID).flatMap { registry.config(for: $0) } ?? registry.currentCluster }
    private var session: ClusterSession? { cluster.flatMap { registry.session(for: $0.id) } }
    private var resolved: (pack: RiggingPack, view: RiggingPack.ViewSpec)? { rigging.store.view(pack: ref.pack, id: ref.view) }

    private struct Row: Identifiable {
        var id: String
        var name: String
        var namespace: String?
        var tone: RiggingPack.Tone
        var label: String?
        var cells: [String]
        var raw: JSONValue
    }

    var body: some View {
        Group {
            if let (pack, view) = resolved, let cluster, let session {
                content(pack: pack, view: view, cluster: cluster, session: session)
            } else if resolved == nil {
                ContentUnavailableView("This pack view is not available", systemImage: "puzzlepiece.extension",
                                       description: Text("The pack “\(ref.pack)” is off, was removed, or has no view “\(ref.view)”. Check Settings ▸ Rigging."))
            } else {
                ContentUnavailableView("Choose a cluster", systemImage: "server.rack")
            }
        }
        .confirmSheet(Binding(get: { rigging.confirm.pending }, set: { rigging.confirm.pending = $0 }))
        .onAppear { rigging.confirm.hosts += 1 }
        .onDisappear { rigging.confirm.hosts -= 1 }
        .accessibilityIdentifier("rigging-view")
    }

    @ViewBuilder private func content(pack: RiggingPack, view: RiggingPack.ViewSpec, cluster: ClusterConfig, session: ClusterSession) -> some View {
        let store = kind.map { session.unstructuredStore(kind: $0, namespace: ref.namespace) }
        VStack(spacing: 0) {
            if !discoveryDone {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let kind, let store {
                let rows = rows(store: store, view: view)
                if rows.isEmpty {
                    if store.isLoading { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
                    else if let error = store.error { ContentUnavailableView("Couldn’t load", systemImage: "exclamationmark.triangle", description: Text(error.localizedDescription)) }
                    else { ContentUnavailableView("No \(kind.displayName) here", systemImage: "tray") }
                } else {
                    table(rows: rows, view: view, pack: pack, kind: kind, cluster: cluster, session: session)
                }
            } else {
                ContentUnavailableView("\(view.match.kind) is not installed on \(cluster.name)", systemImage: "puzzlepiece.extension",
                                       description: Text("The cluster does not serve \(view.match.kind) (\(view.match.group.isEmpty ? "core" : view.match.group))."))
            }
        }
        .navigationTitle("\(view.title ?? view.match.kind) · \(cluster.name)")
        .paneSearchable(text: $search, prompt: "Filter")
        .paneToolbar {
            ToolbarItem {
                Button { if let kind { router?.push(.resourceList(session.id, kind, namespace: ref.namespace)) } } label: { Label("Plain List", systemImage: "list.bullet") }
                    .disabled(kind == nil).help("Open the standard list for this kind")
            }
        }
        .whileVisible(id: "\(session.id)|\(ref.pack)|\(ref.view)|\(ref.namespace ?? "-")") { await run(view: view, session: session) }
    }

    private func run(view: RiggingPack.ViewSpec, session: ClusterSession) async {
        if session.discovery == nil { await session.loadDiscovery() }
        guard !Task.isCancelled else { return }
        let k = rigging.resourceKind(view.match, in: session.discovery)
        kind = k
        discoveryDone = true
        guard let k else { return }
        let store = session.unstructuredStore(kind: k, namespace: ref.namespace)
        store.start()
        while !Task.isCancelled { try? await Task.sleep(for: .seconds(3600)) }
        store.stop()
    }

    private func rows(store: ResourceStore<Unstructured>, view: RiggingPack.ViewSpec) -> [Row] {
        let now = Date()
        let q = search.lowercased()
        return store.items.compactMap { object -> Row? in
            let name = object.metadata.name
            guard q.isEmpty || name.lowercased().contains(q) || (object.metadata.namespace ?? "").lowercased().contains(q) else { return nil }
            let (tone, label) = RiggingEngine.tone(for: view, object: object.raw, now: now)
            return Row(id: "\(object.metadata.namespace ?? "-")/\(name)", name: name, namespace: object.metadata.namespace, tone: tone, label: label,
                       cells: (view.columns ?? []).map { RiggingEngine.cell($0, object: object.raw, now: now) }, raw: object.raw)
        }.sorted { a, b in
            a.tone.rank != b.tone.rank ? a.tone.rank > b.tone.rank : (a.namespace ?? "", a.name) < (b.namespace ?? "", b.name)
        }
    }

    private static let cellWidth: CGFloat = 130

    private func table(rows: [Row], view: RiggingPack.ViewSpec, pack: RiggingPack, kind: ResourceKind, cluster: ClusterConfig, session: ClusterSession) -> some View {
        HSplitView {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(rows) { row in
                            rowView(row, view: view)
                                .background(selection == row.id ? Color.accentColor.opacity(0.18) : Color.clear)
                                .contentShape(Rectangle())
                                .onTapGesture(count: 2) { open(row, kind: kind, session: session) }
                                .onTapGesture { selection = row.id }
                                .contextMenu { menu(row, view: view, pack: pack, kind: kind, cluster: cluster, session: session) }
                                .accessibilityElement(children: .combine)
                        }
                    } header: { header(view: view, kind: kind) }
                }
            }
            if let id = selection, let row = rows.first(where: { $0.id == id }) {
                detail(row, view: view, kind: kind, cluster: cluster, session: session).frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
            }
        }
    }

    private func header(view: RiggingPack.ViewSpec, kind: ResourceKind) -> some View {
        HStack(spacing: 0) {
            Text("Name").frame(width: 200, alignment: .leading)
            if kind.namespaced { Text("Namespace").frame(width: Self.cellWidth, alignment: .leading) }
            Text("Status").frame(width: 110, alignment: .leading)
            ForEach(Array((view.columns ?? []).enumerated()), id: \.offset) { _, c in Text(c.name).frame(width: Self.cellWidth, alignment: .leading) }
        }
        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, Spacing.m).padding(.vertical, 4).background(.bar)
    }

    private func rowView(_ row: Row, view: RiggingPack.ViewSpec) -> some View {
        HStack(spacing: 0) {
            Text(row.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).frame(width: 200, alignment: .leading)
            if row.namespace != nil { Text(row.namespace ?? "").lineLimit(1).frame(width: Self.cellWidth, alignment: .leading) }
            Group {
                if row.tone == .neutral && row.label == nil { Text("") } else { StatusPill(tone: row.tone.statusTone, text: row.label ?? row.tone.rawValue.capitalized) }
            }.frame(width: 110, alignment: .leading)
            ForEach(Array(row.cells.enumerated()), id: \.offset) { _, cell in Text(cell).lineLimit(1).truncationMode(.tail).frame(width: Self.cellWidth, alignment: .leading) }
        }
        .padding(.horizontal, Spacing.m).padding(.vertical, 5)
    }

    @ViewBuilder private func menu(_ row: Row, view: RiggingPack.ViewSpec, pack: RiggingPack, kind: ResourceKind, cluster: ClusterConfig, session: ClusterSession) -> some View {
        Button("Open") { open(row, kind: kind, session: session) }
        let items = rigging.commands(for: view.match)
        if !items.isEmpty { Divider() }
        ForEach(items) { item in
            Button(item.command.title + (item.command.terminal != nil ? " (insert in terminal)" : "…")) {
                rigging.perform(item, subject: subject(row, kind: kind), cluster: cluster)
            }
        }
    }

    private func subject(_ row: Row, kind: ResourceKind) -> RiggingValues.Subject {
        RiggingValues.Subject(name: row.name, namespace: row.namespace, kind: kind.kind, raw: row.raw)
    }

    private func open(_ row: Row, kind: ResourceKind, session: ClusterSession) {
        router?.push(.resourceDetail(ResourceRef(clusterID: session.id, kind: kind, namespace: row.namespace, name: row.name)))
    }

    private func detail(_ row: Row, view: RiggingPack.ViewSpec, kind: ResourceKind, cluster: ClusterConfig, session: ClusterSession) -> some View {
        let related = RiggingEngine.related(of: row.raw, view: view)
        return ScrollView {
            VStack(alignment: .leading, spacing: Spacing.m) {
                Text(row.name).font(.headline)
                if let ns = row.namespace { Text(ns).foregroundStyle(.secondary) }
                ForEach(Array((view.columns ?? []).enumerated()), id: \.offset) { i, c in
                    if i < row.cells.count, !row.cells[i].isEmpty { LabeledContent(c.name) { Text(row.cells[i]).textSelection(.enabled) } }
                }
                if !related.isEmpty {
                    Divider()
                    Text("Related").font(.subheadline.weight(.semibold))
                    ForEach(related, id: \.self) { rel in
                        if let k = rigging.resourceKind(RiggingPack.KindMatch(group: rel.group, kind: rel.kind), in: session.discovery) {
                            Button { router?.push(.resourceDetail(ResourceRef(clusterID: session.id, kind: k, namespace: k.namespaced ? rel.namespace : nil, name: rel.name))) } label: {
                                Label("\(rel.label): \(rel.name)", systemImage: "arrow.turn.down.right")
                            }.buttonStyle(.link)
                        } else {
                            Text("\(rel.label): \(rel.name)").foregroundStyle(.secondary)
                        }
                    }
                }
            }.padding(Spacing.m).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension RiggingPack.Tone {
    var rank: Int {
        switch self {
        case .critical: 3
        case .warning: 2
        case .neutral: 1
        case .healthy: 0
        }
    }
}
