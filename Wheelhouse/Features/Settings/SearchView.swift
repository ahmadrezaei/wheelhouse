import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// One searchable object.
struct SearchEntry: Identifiable, Hashable {
    var clusterID: ClusterID
    var clusterName: String
    var kind: ResourceKind
    var namespace: String?
    var name: String
    var images: [String]
    var id: String { "\(clusterID)|\(kind.id)|\(namespace ?? "")|\(name)" }
    var ref: ResourceRef { ResourceRef(clusterID: clusterID, kind: kind, namespace: namespace, name: name) }
}

struct SearchGroup: Identifiable {
    var kind: ResourceKind
    var hits: [SearchHit]
    var id: String { kind.id }
}
struct SearchHit: Identifiable { var entry: SearchEntry; var note: String?; var id: String { entry.id } }

/// Loads and caches name lists for the searchable kinds, then filters them locally on every (debounced) keystroke.
@MainActor @Observable
final class SearchModel {
    nonisolated static let kinds: [ResourceKind] = [.deployment, .statefulSet, .daemonSet, .pod, .cronJob, .job, .service, .ingress,
                                        .configMap, .persistentVolumeClaim, .namespace, .node]
    private(set) var entries: [ClusterID: [SearchEntry]] = [:]
    private(set) var errors: [ClusterID: String] = [:]
    private(set) var isLoading = false
    @ObservationIgnored private var loadedAt: [ClusterID: Date] = [:]

    func load(sessions: [ClusterSession], force: Bool = false) async {
        let stale = sessions.filter { force || (loadedAt[$0.id].map { Date().timeIntervalSince($0) > 20 } ?? true) }
        guard !stale.isEmpty else { return }
        for s in stale { loadedAt[s.id] = Date() }
        // Unstructured so a changing search term (which cancels the calling view task) never aborts the fetch half-way.
        await Task { @MainActor in await self.fetchAll(stale) }.value
    }

    private func fetchAll(_ stale: [ClusterSession]) async {
        isLoading = true; defer { isLoading = false }
        await withTaskGroup(of: (ClusterID, [SearchEntry], String?).self) { group in
            for session in stale {
                let client = session.client, id = session.id, name = session.config.name
                group.addTask { await Self.fetch(client: client, clusterID: id, clusterName: name) }
            }
            for await (id, list, error) in group { entries[id] = list; errors[id] = error }
        }
    }

    nonisolated private static func fetch(client: any KubeClientProtocol, clusterID: ClusterID, clusterName: String) async -> (ClusterID, [SearchEntry], String?) {
        var all: [SearchEntry] = []
        var firstError: String?
        var failures = 0
        await withTaskGroup(of: ([SearchEntry], KubeError?).self) { group in
            for kind in kinds {
                group.addTask {
                    do {
                        let raw = try await client.listRaw(kind, namespace: nil, options: ListOptions())
                        let items = raw["items"]?.arrayValue ?? []
                        return (items.compactMap { item -> SearchEntry? in
                            guard let name = item.value(at: "metadata.name")?.stringValue else { return nil }
                            var images = (item.value(at: "spec.containers")?.arrayValue ?? item.value(at: "spec.template.spec.containers")?.arrayValue ?? [])
                                .compactMap { $0["image"]?.stringValue }
                            if images.isEmpty { images = (item.value(at: "spec.jobTemplate.spec.template.spec.containers")?.arrayValue ?? []).compactMap { $0["image"]?.stringValue } }
                            return SearchEntry(clusterID: clusterID, clusterName: clusterName, kind: kind,
                                               namespace: kind.namespaced ? item.value(at: "metadata.namespace")?.stringValue : nil, name: name, images: images)
                        }, nil)
                    } catch let e as KubeError { return ([], e) } catch { return ([], .unreachable(cause: error.localizedDescription)) }
                }
            }
            for await (list, error) in group {
                all += list
                if let error { failures += 1; firstError = firstError ?? error.summary }
            }
        }
        return (clusterID, all, failures == kinds.count ? firstError : nil)
    }

    func search(_ query: String, in clusterIDs: [ClusterID]) -> [SearchGroup] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var scored: [(SearchHit, Int)] = []
        for id in clusterIDs {
            for e in entries[id] ?? [] {
                if let s = SearchRanking.score(name: e.name, query: q) { scored.append((SearchHit(entry: e, note: nil), s)) }
                else if let img = e.images.first(where: { $0.lowercased().contains(q.lowercased()) }) { scored.append((SearchHit(entry: e, note: "image \(img)"), 5)) }
            }
        }
        let order = Self.kinds.enumerated().reduce(into: [String: Int]()) { $0[$1.element.id] = $1.offset }
        var groups: [String: [(SearchHit, Int)]] = [:]
        for item in scored { groups[item.0.entry.kind.id, default: []].append(item) }
        return groups.values.compactMap { items -> SearchGroup? in
            guard let kind = items.first?.0.entry.kind else { return nil }
            let sorted = items.sorted { ($0.1, $0.0.entry.name, $0.0.entry.clusterName) < ($1.1, $1.0.entry.name, $1.0.entry.clusterName) }
            return SearchGroup(kind: kind, hits: sorted.prefix(25).map(\.0))
        }.sorted { (order[$0.kind.id] ?? 99) < (order[$1.kind.id] ?? 99) }
    }
}

/// Search tab root: names (and container images) across kinds in the current cluster or all clusters.
struct SearchView: View {
    var initialQuery: String?

    @Environment(ClusterRegistry.self) private var registry
    @State private var model = SearchModel()
    @State private var query = ""
    @State private var debounced = ""
    @State private var scope: Scope = .current
    @State private var recents = RecentSearches.load()

    enum Scope: Hashable { case current, all }

    private var sessions: [ClusterSession] {
        switch scope {
        case .current: registry.currentSession.map { [$0] } ?? []
        case .all: registry.allSessions
        }
    }

    var body: some View {
        let groups = model.search(debounced, in: sessions.map(\.id))
        content(groups)
            .navigationTitle("Search")
            .paneSearchable(text: $query, prompt: scope == .all ? "Search all clusters" : "Search \(registry.currentCluster?.name ?? "cluster")",
                            scope: $scope, scopes: [("This cluster", Scope.current), ("All clusters", Scope.all)]) {
                RecentSearches.add(query); recents = RecentSearches.load()
            }
            .task {
                var start = initialQuery
                #if DEBUG
                let args = ProcessInfo.processInfo.arguments  // `-WHSearch <query>` for screenshots
                if let i = args.firstIndex(of: "-WHSearch"), i + 1 < args.count { start = args[i + 1] }
                #endif
                if let start, query.isEmpty { query = start; debounced = start }
            }
            .task(id: query) {
                if query.isEmpty { debounced = ""; return }
                try? await Task.sleep(for: .milliseconds(250))
                if !Task.isCancelled { debounced = query }
            }
            .task(id: "\(scope)|\(sessions.map(\.id))|\(debounced.isEmpty)") {
                if !debounced.isEmpty { await model.load(sessions: sessions) }
            }
    }

    @ViewBuilder private func content(_ groups: [SearchGroup]) -> some View {
        if registry.clusters.isEmpty {
            EmptyState(.empty(title: "No Clusters", systemImage: "magnifyingglass", hint: "Add a cluster to search its resources."))
        } else if debounced.isEmpty {
            recentsList
        } else if groups.isEmpty {
            if model.isLoading { EmptyState(.loading) }
            else if let err = sessions.compactMap({ model.errors[$0.id] }).first, sessions.allSatisfy({ model.errors[$0.id] != nil }) { EmptyState(.error(message: err)) }
            else { EmptyState(.filteredEmpty(filter: debounced)) }
        } else {
            List {
                ForEach(groups) { group in
                    Section {
                        ForEach(group.hits) { hit in
                            RouteLink(route: .resourceDetail(hit.entry.ref)) {
                                ResourceRow(title: hit.entry.name,
                                            subtitle: subtitle(hit),
                                            lead: .symbol(group.kind.symbol, .init(.unknown)),
                                            monospacedTitle: true)
                            }
                            .simultaneousGesture(TapGesture().onEnded { RecentSearches.add(query); recents = RecentSearches.load() })
                        }
                    } header: { Label(group.kind.displayName, systemImage: group.kind.symbol) }
                }
                if model.isLoading { Section { HStack { ProgressView(); Text("Searching…").foregroundStyle(.secondary) } } }
                let failed = sessions.filter { model.errors[$0.id] != nil }
                if !failed.isEmpty {
                    Section { ForEach(failed) { Label("\($0.config.name): \(model.errors[$0.id] ?? "")", systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(Palette.warningText) } }
                }
                Section { } footer: { Text("Searches names and container images. Secrets and events are not searched.") }
            }
            .whGroupedListStyle()
        }
    }

    private func subtitle(_ hit: SearchHit) -> String {
        [scope == .all ? hit.entry.clusterName : nil, hit.entry.namespace, hit.note].compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var recentsList: some View {
        if recents.isEmpty {
            EmptyState(.empty(title: "Search \(scope == .all ? "All Clusters" : registry.currentCluster?.name ?? "Cluster")", systemImage: "magnifyingglass",
                              hint: "Find pods, deployments, services, nodes and more by name or container image."))
        } else {
            List {
                Section {
                    ForEach(recents, id: \.self) { r in
                        Button { query = r; debounced = r } label: { Label(r, systemImage: "clock.arrow.circlepath").foregroundStyle(.primary) }
                    }
                } header: {
                    HStack { Text("Recent"); Spacer(); Button("Clear") { RecentSearches.clear(); recents = [] }.font(.footnote) }
                }
            }
        }
    }
}
