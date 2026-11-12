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

private enum KindCount: Hashable {
    case exact(Int)
    case atLeast(Int)
    case locked
    case unavailable

    var text: String? {
        switch self { case .exact(let n): "\(n)"; case .atLeast(let n): "\(n)+"; default: nil }
    }
}

@MainActor @Observable
private final class CountsModel {
    var counts: [String: KindCount] = [:]
    var loadedFor: String?

    func load(session: ClusterSession, namespace: String?) async {
        let key = "\(session.id)|\(namespace ?? "*")"
        loadedFor = key
        let client = session.client
        let isDemo = session.config.isDemo
        let kinds = ResourceKind.builtIn
        await withTaskGroup(of: (String, KindCount).self) { group in
            for kind in kinds {
                group.addTask {
                    let ns = kind.namespaced ? namespace : nil
                    // Secrets: never retain values just to count them (limit 1, redacted on arrival).
                    let limit = isDemo ? 500 : 1
                    let source: any KubeClientProtocol = kind == .secret ? SecretStrippingClient(client) : client
                    do {
                        let raw = try await source.listRaw(kind, namespace: ns, options: ListOptions(limit: limit))
                        let items = raw["items"]?.arrayValue?.count ?? 0
                        let remaining = raw.value(at: "metadata.remainingItemCount")?.intValue
                        let more = !(raw.value(at: "metadata.continue")?.stringValue ?? "").isEmpty
                        if let remaining { return (kind.id, .exact(items + remaining)) }
                        return (kind.id, more ? .atLeast(items) : .exact(items))
                    } catch KubeError.forbidden { return (kind.id, .locked) }
                    catch { return (kind.id, .unavailable) }
                }
            }
            for await (id, count) in group {
                counts[id] = count
            }
        }
    }
}

private struct SectionsList: View {
    let session: ClusterSession
    @Environment(ClusterRegistry.self) private var registry
    @State private var model = CountsModel()
    @State private var namespace: String?
    @State private var customSearch = ""

    var body: some View {
        let ns = registry.namespace(for: session.id)
        List {
            Section {
                ContextLine(cluster: session.config, namespace: ns).listRowBackground(Color.clear)
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
            ToolbarItem(placement: .whTrailing) {
                NamespaceMenu(session: session, namespace: $namespace) { _ in Task { await model.load(session: session, namespace: registry.namespace(for: session.id)) } }
            }
        }
        .refreshable {
            await session.loadDiscovery(forceRefresh: true)
            await model.load(session: session, namespace: ns)
        }
        .task(id: "\(session.id)|\(ns ?? "*")") {
            namespace = ns
            async let discovery: Void = session.loadDiscovery()
            await model.load(session: session, namespace: ns)
            await discovery
        }
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
