import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S8: generic watch-backed list for any kind (built-in or custom) with kind-specific rows, search, sort, namespace and label filters,
/// swipe/context actions, and loading / empty / filtered-empty / forbidden / error states.
/// `clusterID == nil` means the current cluster; `namespace == nil` means All namespaces unless the registry selects one.
struct ResourceListView: View {
    @Environment(ClusterRegistry.self) private var registry
    let kind: ResourceKind
    var clusterID: ClusterID?
    var namespace: String?

    private var resolvedID: ClusterID? { clusterID ?? registry.currentCluster?.id }

    var body: some View {
        // Keyed on the cluster's config revision + session identity: a settings change rebuilds the screen and its ActionHost.
        if let id = resolvedID, let key = registry.screenKey(for: id), let session = registry.session(for: id) {
            ListScreen(session: session, baseKind: kind, initialNamespace: namespace ?? registry.namespace(for: session.id))
                .id(key)
        } else {
            EmptyState(.empty(title: "No Cluster", systemImage: "server.rack"))
        }
    }
}

private struct ListScreen: View {
    let session: ClusterSession
    let baseKind: ResourceKind
    @Environment(AppRouter.self) private var router
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.routeColumn) private var column

    @State private var kind: ResourceKind
    @State private var namespace: String?
    @State private var search = ""
    @State private var sort: ListSort = .status
    @State private var labelSelector = ""
    @State private var showLabelSheet = false
    @State private var rows: [ListRowModel] = []
    @State private var usage: [String: PodUsageSample] = [:]
    @State private var columns: [CRDColumn] = []
    @State private var cache = SummaryCache()
    @State private var host: ActionHost
    @State private var secretStores = SecretStoreCache()

    init(session: ClusterSession, baseKind: ResourceKind, initialNamespace: String?) {
        self.session = session
        self.baseKind = baseKind
        _kind = State(initialValue: baseKind)
        _namespace = State(initialValue: initialNamespace)
        _host = State(initialValue: ActionHost(session: session))
    }

    private var effectiveNamespace: String? { kind.namespaced ? namespace : nil }
    private var selector: String? { labelSelector.isEmpty ? nil : labelSelector }
    private var store: ResourceStore<Unstructured> {
        // Secret lists never hold values in memory (they are blanked on ingest); detail fetches the full object on demand.
        if kind == .secret { return secretStores.store(session: session, namespace: effectiveNamespace, labelSelector: selector) }
        return session.unstructuredStore(kind: kind, namespace: effectiveNamespace, labelSelector: selector)
    }
    /// Actions stay hidden on read-only clusters and while the cluster is unreachable (cached data only).
    private var canMutate: Bool { host.canMutate && store.error == nil }
    private var storeKey: String { "\(kind.id)|\(effectiveNamespace ?? "*")|\(labelSelector)" }
    private var siblings: [ResourceKind] { baseKind.section == .custom ? [] : ResourceKind.builtIn(in: baseKind.section) }
    private var hasFilters: Bool { !search.isEmpty || !labelSelector.isEmpty }

    private struct Token: Hashable { var key: String; var updated: Date?; var search: String; var sort: ListSort; var usageCount: Int; var columns: Int }
    private var token: Token { Token(key: storeKey, updated: store.lastUpdated, search: search, sort: sort, usageCount: usage.count, columns: columns.count) }

    var body: some View {
        let store = store
        Group {
            if store.isLoading { loading }
            else if let error = store.error, store.items.isEmpty { errorState(error) }
            else { list(store) }
        }
        .navigationTitle(kind.displayName)
        .whLargeNavigationTitle()
        .whSearchable(text: $search, prompt: "Search name, label, image")
        .toolbar { toolbar }
        .refreshable { await store.refresh() }
        .task(id: storeKey) { await store.run() }
        .task(id: storeKey) { await pollUsage() }
        .task(id: kind.id) { await loadColumns() }
        .onChange(of: token, initial: true) { rebuild() }
        .onChange(of: kind) { _, new in if !ListSort.available(for: new).contains(sort) { sort = .status } }
        .sheet(isPresented: $showLabelSheet) { LabelFilterSheet(applied: $labelSelector, suggestions: labelSuggestions(store)) }
        .actionHost(host)
    }

    // MARK: Content

    private func list(_ store: ResourceStore<Unstructured>) -> some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    ContextLine(cluster: session.config, namespace: effectiveNamespace, kind: kind.displayName, showsNamespace: kind.namespaced)
                    Text(summaryLine(store)).font(.footnote).foregroundStyle(.secondary)
                    if siblings.count > 1 { kindChips }
                    if !labelSelector.isEmpty { filterChip }
                    if let error = store.error, case .unreachable = error {
                        StateBanner(.cached(age: Format.age(from: store.lastUpdated)))
                    } else if let error = store.error, case .forbidden = error {
                        StateBanner(.partiallyForbidden(detail: error.summary))
                    }
                }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            Section {
                ForEach(rows) { row in
                    RouteLink(route: .resourceDetail(ResourceRef(clusterID: session.id, kind: kind, namespace: row.object.metadata.namespace, name: row.object.metadata.name))) {
                        ObjectRow(kind: kind, object: row.object, summary: row.summary, usage: usageSample(row), showNamespace: effectiveNamespace == nil && kind.namespaced, extraColumns: row.extra)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) { trailingSwipe(row) }
                    .swipeActions(edge: .leading, allowsFullSwipe: false) { leadingSwipe(row) }
                    .contextMenu { menu(row) }
                }
            }
        }
        .whGroupedListStyle()
        .animation(reduceMotion ? nil : .default, value: rows.map(\.id))
        .overlay {
            if store.phase == .loaded, store.items.isEmpty { emptyState }
            else if !store.items.isEmpty, rows.isEmpty, hasFilters { filteredEmpty }
        }
    }

    private var loading: some View {
        ScrollView { SkeletonList(rows: 8).padding(.top, Spacing.m) }.scrollDisabled(true)
    }

    private func errorState(_ error: KubeError) -> some View {
        EmptyState(EmptyStateKind(error: error, clusterName: session.config.name)) {
            VStack {
                if case .forbidden = error, namespace != nil, kind.namespaced {
                    Button("Show All Namespaces") { setNamespace(nil) }.buttonStyle(.bordered)
                }
                Button("Retry") { Task { await store.refresh() } }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var emptyState: some View {
        EmptyState(.empty(title: "No \(kind.displayName)\(effectiveNamespace.map { " in \($0)" } ?? "")", systemImage: kind.symbol,
                          hint: labelSelector.isEmpty ? "Nothing to show here yet." : "No objects match \(labelSelector).")) {
            VStack {
                if effectiveNamespace != nil { Button("Show All Namespaces") { setNamespace(nil) }.buttonStyle(.bordered) }
                if !labelSelector.isEmpty { Button("Clear Label Filter") { labelSelector = "" }.buttonStyle(.bordered) }
                if canMutate { Button("Create from YAML") { router.push(.createYAML(session.id, namespace: effectiveNamespace)) }.buttonStyle(.bordered) }
            }
        }
    }

    private var filteredEmpty: some View {
        EmptyState(.filteredEmpty(filter: search.isEmpty ? labelSelector : search)) {
            Button("Clear Filters") { search = ""; labelSelector = "" }.buttonStyle(.bordered)
        }
        .background(Palette.groupedBackground)
    }

    private func summaryLine(_ store: ResourceStore<Unstructured>) -> String {
        let count = rows.count == store.items.count ? "\(rows.count)" : "\(rows.count) of \(store.items.count)"
        return "\(count) \(kind.displayName.lowercased()) · sorted by \(sort.rawValue.lowercased())\(store.isRefreshing ? " · Updating…" : "")"
    }

    private var kindChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(siblings) { k in
                    Button { kind = k; rows = [] } label: {
                        Label(k.displayName, systemImage: k.symbol).font(.footnote.weight(.medium)).padding(.horizontal, 10).padding(.vertical, 6)
                            .background(k == kind ? Palette.tint.opacity(0.18) : Palette.fieldFill, in: Capsule())
                            .foregroundStyle(k == kind ? Palette.tintText : .primary)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(k == kind ? .isSelected : [])
                }
            }
        }
    }

    private var filterChip: some View {
        Button { labelSelector = "" } label: {
            HStack(spacing: 6) {
                Image(systemName: "tag").imageScale(.small)
                Text(labelSelector).font(.whCodeSmall).lineLimit(1)
                Image(systemName: "xmark.circle.fill").imageScale(.small).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6).background(Palette.tint.opacity(0.15), in: Capsule())
        }
        .buttonStyle(.plain).accessibilityLabel("Label filter \(labelSelector). Tap to clear.")
    }

    // MARK: Toolbar

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        if kind.namespaced {
            ToolbarItem(placement: .whTrailing) {
                NamespaceMenu(session: session, namespace: $namespace)
            }
        }
        ToolbarItem(placement: .whTrailing) {
            Menu {
                Section("Sort by") {
                    Picker("Sort", selection: $sort) {
                        ForEach(ListSort.available(for: kind)) { Label($0.rawValue, systemImage: $0.symbol).tag($0) }
                    }
                }
                Button { showLabelSheet = true } label: { Label(labelSelector.isEmpty ? "Filter by Labels…" : "Edit Label Filter…", systemImage: "tag") }
                if !labelSelector.isEmpty { Button(role: .destructive) { labelSelector = "" } label: { Label("Clear Label Filter", systemImage: "xmark") } }
                if canMutate {
                    Divider()
                    Button { router.push(.createYAML(session.id, namespace: effectiveNamespace)) } label: { Label("Create from YAML…", systemImage: "plus.square.on.square") }
                }
            } label: { Image(systemName: labelSelector.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill") }
            .accessibilityLabel("Sort and filter")
        }
    }

    // MARK: Actions

    private func target(_ row: ListRowModel) -> ResourceTarget { ResourceTarget(kind: kind, object: row.object) }

    @ViewBuilder private func trailingSwipe(_ row: ListRowModel) -> some View {
        if canMutate {
            let t = target(row)
            Button(role: .destructive) { host.delete(t) } label: { Label("Delete", systemImage: "trash") }
            switch kind.kind {
            case "Deployment", "StatefulSet", "DaemonSet":
                Button { host.restart(t) } label: { Label("Restart", systemImage: "arrow.triangle.2.circlepath") }.tint(Palette.info)
            default: EmptyView()
            }
            switch kind.kind {
            case "Deployment", "StatefulSet", "ReplicaSet":
                Button { host.scale(t) } label: { Label("Scale", systemImage: "plusminus") }.tint(Palette.warning)
            case "Node": Button { host.drain(t) } label: { Label("Drain", systemImage: "arrow.down.to.line") }.tint(Palette.warning)
            case "CronJob": Button { host.trigger(t) } label: { Label("Trigger", systemImage: "play.fill") }.tint(Palette.info)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func leadingSwipe(_ row: ListRowModel) -> some View {
        if canMutate {
            let t = target(row)
            switch kind.kind {
            case "Node":
                Button { host.cordon(t) } label: { Label(t.isCordoned ? "Uncordon" : "Cordon", systemImage: t.isCordoned ? "play.circle" : "nosign") }.tint(t.isCordoned ? Palette.healthy : Palette.warning)
            case "CronJob":
                Button { host.suspend(t) } label: { Label(t.isSuspended ? "Resume" : "Suspend", systemImage: t.isSuspended ? "play.circle" : "pause.circle") }.tint(Palette.warning)
            default: EmptyView()
            }
        }
    }

    @ViewBuilder private func menu(_ row: ListRowModel) -> some View {
        let t = target(row)
        let ref = ResourceRef(clusterID: session.id, kind: kind, namespace: row.object.metadata.namespace, name: row.object.metadata.name)
        Button { Pasteboard.copy(row.object.metadata.name) } label: { Label("Copy Name", systemImage: "doc.on.doc") }
        if kind != .secret {
            Button { Pasteboard.copy(ResourceExport.yaml(row.object.raw)) } label: { Label("Copy YAML", systemImage: "doc.on.clipboard") }
        }
        Button { router.push(.yaml(ref), from: column) } label: { Label("View YAML", systemImage: "curlybraces") }
        if kind == .pod {
            Button { router.push(.logs(ref, container: nil, previous: false), from: column) } label: { Label("Logs", systemImage: "text.alignleft") }
        }
        if canMutate {
            Divider()
            switch kind.kind {
            case "Deployment", "StatefulSet", "DaemonSet":
                Button { host.restart(t) } label: { Label("Restart", systemImage: "arrow.triangle.2.circlepath") }
            default: EmptyView()
            }
            switch kind.kind {
            case "Deployment", "StatefulSet", "ReplicaSet": Button { host.scale(t) } label: { Label("Scale…", systemImage: "plusminus") }
            case "Node":
                Button { host.cordon(t) } label: { Label(t.isCordoned ? "Uncordon" : "Cordon", systemImage: "nosign") }
                Button { host.drain(t) } label: { Label("Drain…", systemImage: "arrow.down.to.line") }
            case "CronJob":
                Button { host.suspend(t) } label: { Label(t.isSuspended ? "Resume" : "Suspend", systemImage: "pause.circle") }
                Button { host.trigger(t) } label: { Label("Trigger Now", systemImage: "play.fill") }
            default: EmptyView()
            }
            Button(role: .destructive) { host.delete(t) } label: { Label("Delete…", systemImage: "trash") }
        }
    }

    private func setNamespace(_ ns: String?) {
        namespace = ns
    }

    // MARK: Data

    private func rebuild() {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        var built: [ListRowModel] = store.items.compactMap { obj in
            let s = cache.summary(kind: kind, object: obj)
            if !q.isEmpty, !s.searchText.contains(q) { return nil }
            return ListRowModel(object: obj, summary: s, extra: extraColumns(for: obj))
        }
        built.sort(by: comparator())
        rows = built
    }

    private func comparator() -> (ListRowModel, ListRowModel) -> Bool {
        let u = usage
        func use(_ r: ListRowModel) -> PodUsageSample? { usageSample(r, in: u) }
        let byName: (ListRowModel, ListRowModel) -> Bool = { ($0.object.metadata.namespace ?? "", $0.object.metadata.name) < ($1.object.metadata.namespace ?? "", $1.object.metadata.name) }
        switch sort {
        case .name: return byName
        case .status: return { $0.summary.severityRank != $1.summary.severityRank ? $0.summary.severityRank < $1.summary.severityRank : byName($0, $1) }
        case .age: return { ($0.object.metadata.creationTimestamp ?? .distantPast) > ($1.object.metadata.creationTimestamp ?? .distantPast) }
        case .restarts: return { $0.summary.restarts != $1.summary.restarts ? $0.summary.restarts > $1.summary.restarts : byName($0, $1) }
        case .cpu: return { (use($0)?.cpuCores ?? -1) != (use($1)?.cpuCores ?? -1) ? (use($0)?.cpuCores ?? -1) > (use($1)?.cpuCores ?? -1) : byName($0, $1) }
        case .memory: return { (use($0)?.memoryBytes ?? -1) != (use($1)?.memoryBytes ?? -1) ? (use($0)?.memoryBytes ?? -1) > (use($1)?.memoryBytes ?? -1) : byName($0, $1) }
        }
    }

    private func usageSample(_ row: ListRowModel, in map: [String: PodUsageSample]? = nil) -> PodUsageSample? {
        let m = map ?? usage
        switch kind.kind {
        case "Pod": return m["\(row.object.metadata.namespace ?? "")/\(row.object.metadata.name)"]
        case "Node": return m[row.object.metadata.name]
        default: return nil
        }
    }

    private func extraColumns(for obj: Unstructured) -> [String] {
        columns.prefix(3).compactMap { col in
            JSONPathLite.display(JSONPathLite.evaluate(col.jsonPath, in: obj.raw)).flatMap { $0.isEmpty ? nil : "\(col.name): \($0)" }
        }
    }

    private func labelSuggestions(_ store: ResourceStore<Unstructured>) -> [String] {
        var counts: [String: Int] = [:]
        for o in store.items { for (k, v) in o.metadata.labels where !k.hasPrefix("pod-template-hash") { counts["\(k)=\(v)", default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(8).map(\.key)
    }

    /// metrics-server usage, refreshed every 30 s while the list is on screen.
    private func pollUsage() async {
        guard kind == .pod || kind == .node else { usage = [:]; return }
        let client = session.client, kind = kind, ns = effectiveNamespace
        var failures = 0
        while !Task.isCancelled {
            // Low Power Mode / hot device: keep what we have, stop sampling.
            if !EnergyPolicy.current.allowsLiveSampling, !usage.isEmpty {
                try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(30)))
                continue
            }
            do {
                var map: [String: PodUsageSample] = [:]
                if kind == .pod {
                    for m in try await client.podMetrics(namespace: ns) { map["\(m.metadata.namespace ?? "")/\(m.metadata.name)"] = PodUsageSample(cpuCores: m.cpuCores, memoryBytes: m.memoryBytes) }
                } else {
                    for m in try await client.nodeMetrics() { map[m.metadata.name] = PodUsageSample(cpuCores: m.cpuCores, memoryBytes: m.memoryBytes) }
                }
                usage = map
                failures = 0
            } catch {
                // metrics-server hiccups must not end polling for good: back off (30 s → 5 min) and keep trying.
                if Task.isCancelled { return }
                usage = [:]
                failures += 1
            }
            try? await Task.sleep(for: .seconds(EnergyPolicy.current.interval(failures == 0 ? 30 : min(30 * Double(1 << min(failures, 4)), 300))))
        }
    }

    /// Custom resources: columns from the CRD's `additionalPrinterColumns` (evaluated client-side with a JSONPath subset).
    private func loadColumns() async {
        columns = []
        guard kind.section == .custom else { return }
        guard let raw = try? await session.client.getRaw(.customResourceDefinition, name: "\(kind.plural).\(kind.group)", namespace: nil),
              let crd = try? raw.decode(CustomResourceDefinition.self) else { return }
        let version = crd.spec.versions.first { $0.name == kind.version } ?? crd.spec.versions.first
        columns = (version?.additionalPrinterColumns ?? []).filter { ($0.priority ?? 0) == 0 && $0.name != "Age" && $0.name != "Name" }.map { CRDColumn(name: $0.name, jsonPath: $0.jsonPath) }
    }
}

struct CRDColumn: Hashable { var name: String; var jsonPath: String }
