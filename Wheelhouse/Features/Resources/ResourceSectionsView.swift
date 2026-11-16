import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// S7: sections and kinds of one cluster with cheap counts, a namespace picker and discovered custom resources.
/// `clusterID == nil` means the current cluster.
struct ResourceSectionsView: View {
    @Environment(ClusterRegistry.self) private var registry
    var clusterID: ClusterID?

    private var resolvedID: ClusterID? { clusterID ?? registry.currentCluster?.id }

    var body: some View {
        if let id = resolvedID, let key = registry.screenKey(for: id), let session = registry.session(for: id) {
            SectionsList(session: session).id(key)
        } else {
            EmptyState(.empty(title: "No Cluster", systemImage: "server.rack"))
        }
    }
}

enum KindCount: Hashable {
    case exact(Int)
    case atLeast(Int)
    case locked
    case unavailable

    var text: String? {
        switch self { case .exact(let n): "\(n)"; case .atLeast(let n): "\(n)+"; default: nil }
    }

    /// Sums the counts one namespaced kind got in each selected namespace. A namespace the user may not list adds nothing and
    /// the kind is locked only when every namespace refused; an unreadable one makes the total open-ended.
    static func sum(_ parts: [KindCount]) -> KindCount {
        if parts.count == 1 { return parts[0] }
        let readable = parts.filter { $0 != .locked }
        guard !readable.isEmpty else { return .locked }
        if readable.allSatisfy({ $0 == .unavailable }) { return .unavailable }
        var total = 0
        var open = false
        for part in readable {
            switch part {
            case .exact(let n): total += n
            case .atLeast(let n): total += n; open = true
            default: open = true
            }
        }
        return open ? .atLeast(total) : .exact(total)
    }
}

@MainActor @Observable
final class CountsModel {
    var counts: [String: KindCount] = [:]
    var loadedFor: String?

    func load(session: ClusterSession, namespace: String?) async {
        await load(session: session, selection: NamespaceSelection(namespace))
    }

    /// Counts every built-in kind. A namespaced kind is listed once per selected namespace (All is one cluster-wide list) and the
    /// results are summed, so a user with namespace-scoped permissions is never asked for a cluster-wide list of the selection.
    func load(session: ClusterSession, selection: NamespaceSelection) async {
        let key = "\(session.id)|\(selection.encoded)"
        loadedFor = key
        let client = session.client
        let isDemo = session.config.isDemo
        let kinds = ResourceKind.builtIn
        let scopes: [String?] = selection.names.isEmpty ? [nil] : selection.names
        await withTaskGroup(of: (String, KindCount).self) { group in
            for kind in kinds {
                group.addTask {
                    // Secrets: never retain values just to count them (limit 1, redacted on arrival).
                    let source: any KubeClientProtocol = kind == .secret ? SecretStrippingClient(client) : client
                    let targets: [String?] = kind.namespaced ? scopes : [nil]
                    var parts: [KindCount] = []
                    for ns in targets { parts.append(await Self.count(kind, namespace: ns, source: source, isDemo: isDemo)) }
                    return (kind.id, KindCount.sum(parts))
                }
            }
            for await (id, count) in group {
                // A newer load (another selection) owns the counts now: a superseded one must not overwrite them.
                guard !Task.isCancelled, loadedFor == key else { continue }
                counts[id] = count
            }
        }
    }

    nonisolated static func count(_ kind: ResourceKind, namespace: String?, source: any KubeClientProtocol, isDemo: Bool) async -> KindCount {
        let limit = isDemo ? 500 : 1
        do {
            let raw = try await source.listRaw(kind, namespace: namespace, options: ListOptions(limit: limit))
            let items = raw["items"]?.arrayValue?.count ?? 0
            let remaining = raw.value(at: "metadata.remainingItemCount")?.intValue
            let more = !(raw.value(at: "metadata.continue")?.stringValue ?? "").isEmpty
            if let remaining { return .exact(items + remaining) }
            return more ? .atLeast(items) : .exact(items)
        } catch KubeError.forbidden { return .locked } catch { return .unavailable }
    }
}

private struct SectionsList: View {
    let session: ClusterSession
    @Environment(ClusterRegistry.self) private var registry
    @State private var model = CountsModel()
    @State private var namespace: String?
    @State private var customSearch = ""

    var body: some View {
        let selection = registry.namespaceSelection(for: session.id)
        let ns = selection.single
        List {
            Section {
                ContextLine(cluster: session.config, namespace: selection.isAll ? nil : selection.label).listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            }
            ForEach(ResourceSection.allCases.filter { $0 != .custom }) { section in
                Section {
                    ForEach(ResourceKind.builtIn(in: section)) { kind in
                        kindRow(kind, namespace: ns)
                    }
                } header: {
                    Label(section.title, systemImage: section.symbol)
                }
            }
            customSection(namespace: ns)
        }
        .navigationTitle("Resources")
        .paneToolbar {
            ToolbarItem(placement: .whTrailing) { namespacePicker }
        }
        .refreshable {
            await session.loadDiscovery(forceRefresh: true)
            await model.load(session: session, selection: selection)
        }
        .task(id: "\(session.id)|\(selection.encoded)") {
            namespace = ns
            async let discovery: Void = session.loadDiscovery()
            await model.load(session: session, selection: selection)
            await discovery
        }
    }

    /// iOS keeps the single-select menu; the Mac has the same multi-select popover the lists use.
    @ViewBuilder private var namespacePicker: some View {
        #if os(macOS)
        NamespacePickerButton(session: session, selection: Binding(
            get: { registry.namespaceSelection(for: session.id) },
            set: { registry.setNamespaceSelection($0, for: session.id) }))
        #else
        NamespaceMenu(session: session, namespace: $namespace) { _ in Task { await model.load(session: session, namespace: registry.namespace(for: session.id)) } }
        #endif
    }

    private func kindRow(_ kind: ResourceKind, namespace ns: String?) -> some View {
        let count = model.counts[kind.id]
        return RouteLink(route: .resourceList(session.id, kind, namespace: ns)) {
            HStack {
                Label(kind.displayName, systemImage: kind.symbol)
                Spacer()
                if count == .locked {
                    Image(systemName: "lock.fill").foregroundStyle(.secondary).accessibilityLabel("No permission to list")
                } else if let t = count?.text {
                    Text(t).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .frame(minHeight: Spacing.minHit)
        }
        .accessibilityLabel("\(kind.displayName)\(count?.text.map { ", \($0)" } ?? "")\(count == .locked ? ", no permission" : "")")
    }

    @ViewBuilder private func customSection(namespace ns: String?) -> some View {
        let kinds = session.customKinds.sorted { ($0.group, $0.kind) < ($1.group, $1.kind) }
        if !kinds.isEmpty {
            let groups = Dictionary(grouping: kinds, by: \.group).sorted { $0.key < $1.key }
            ForEach(groups, id: \.key) { group, items in
                Section {
                    ForEach(items) { kind in
                        RouteLink(route: .resourceList(session.id, kind, namespace: ns)) {
                            HStack {
                                Label(kind.kind, systemImage: kind.symbol)
                                Spacer()
                                Text(kind.namespaced ? "Namespaced" : "Cluster").font(.caption).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: Spacing.minHit)
                        }
                    }
                } header: {
                    if group == groups.first?.key { Label("Custom Resources · \(group)", systemImage: ResourceSection.custom.symbol) } else { Text(group) }
                }
            }
        } else if session.discovery != nil {
            Section {
                Label("No custom resources discovered", systemImage: ResourceSection.custom.symbol).foregroundStyle(.secondary)
            } header: { Label("Custom Resources", systemImage: ResourceSection.custom.symbol) }
        }
    }
}
