import SwiftUI
import AppKit
import WheelhouseKit
import WheelhouseUI

/// The Mac body of the resource list: the same `ListScreen` state, data and actions as iOS, hosted in a `KubeTable`
/// (ARCHITECTURE-MAC section 1.6 row 10) instead of a SwiftUI `List`.
extension ListScreen {
    @ViewBuilder func macList(_ store: ResourceStore<Unstructured>) -> some View {
        let showNamespace = effectiveNamespace == nil && kind.namespaced
        let extraNames = columns.prefix(3).map(\.name)
        let layout = KubeColumn.columns(for: kind, showNamespace: showNamespace, extra: extraNames)
        let rows = rows
        let usage = usage
        let kind = kind
        let keys = rows.map { KubeRowKey(id: $0.id, version: Self.version(of: $0, usage: usage, kind: kind)) }
        VStack(spacing: 0) {
            macHeader(store)
            Divider()
            KubeTable(
                kindID: kind.id, keys: keys, columns: layout, sort: sort, reversed: sortReversed,
                rowAt: { i in Self.tableRow(rows[i], kind: kind, usage: usage, columns: columns, showNamespace: showNamespace) },
                onSort: { s, reversed in sort = s; sortReversed = reversed },
                onOpen: { id in if let r = rows.first(where: { $0.id == id }) { open(r) } },
                actions: { id in rows.first { $0.id == id }.map(macActions) ?? [] }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay {
                if store.phase == .loaded, store.items.isEmpty { emptyState }
                else if !store.items.isEmpty, rows.isEmpty, hasFilters { filteredEmpty }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: Header

    private func macHeader(_ store: ResourceStore<Unstructured>) -> some View {
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
        .padding(.horizontal, Spacing.l).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.bar)
    }

    // MARK: Rows

    private static func version(of row: ListRowModel, usage: [String: PodUsageSample], kind: ResourceKind) -> String {
        let meta = row.object.metadata
        var v = meta.resourceVersion ?? ""
        switch kind.kind {
        case "Pod": if let u = usage["\(meta.namespace ?? "")/\(meta.name)"] { v += "|\(u.cpuCores)|\(u.memoryBytes)" }
        case "Node": if let u = usage[meta.name] { v += "|\(u.cpuCores)|\(u.memoryBytes)" }
        default: break
        }
        return v
    }

    private static func tableRow(_ row: ListRowModel, kind: ResourceKind, usage: [String: PodUsageSample], columns: [CRDColumn], showNamespace: Bool) -> KubeTableRow {
        let o = row.object, s = row.summary, meta = o.metadata
        let u: PodUsageSample? = kind.kind == "Pod" ? usage["\(meta.namespace ?? "")/\(meta.name)"] : (kind.kind == "Node" ? usage[meta.name] : nil)
        let ready: String
        switch kind.kind {
        case "Pod": ready = "\(s.ready ?? 0)/\(s.desired ?? 0)"
        default: ready = s.desired.map { "\(s.ready ?? 0)/\($0)" } ?? ""
        }
        let age = Format.age(from: meta.creationTimestamp)
        let extra = columns.prefix(3).map { col in JSONPathLite.display(JSONPathLite.evaluate(col.jsonPath, in: o.raw)) ?? "" }
        var sentence = "\(meta.name), \(kind.kind)"
        if showNamespace, let ns = meta.namespace { sentence += ", \(ns)" }
        sentence += ", \(s.statusText.isEmpty ? s.status.title : s.statusText)"
        if !ready.isEmpty { sentence += ", \(ready) ready" }
        return KubeTableRow(
            id: row.id, name: meta.name, namespace: meta.namespace ?? "", status: s.statusText.isEmpty ? s.status.title : s.statusText, tone: s.status,
            ready: ready, upToDate: s.upToDate.map(String.init) ?? "", restarts: kind.kind == "Pod" ? "\(s.restarts)" : "", node: s.nodeName ?? "",
            cpu: u.map { Quantity.formatCPU(cores: $0.cpuCores) } ?? "", memory: u.map { Quantity.formatBytes($0.memoryBytes) } ?? "",
            details: s.details.joined(separator: " · "), age: age, extra: extra, accessibility: sentence)
    }

    // MARK: Opening and menu

    private func ref(_ row: ListRowModel) -> ResourceRef {
        ResourceRef(clusterID: session.id, kind: kind, namespace: row.object.metadata.namespace, name: row.object.metadata.name)
    }

    private func open(_ row: ListRowModel) { router.push(.resourceDetail(ref(row)), from: column) }

    func macActions(_ row: ListRowModel) -> [KubeRowAction] {
        let t = target(row)
        let ref = ref(row)
        var out: [KubeRowAction] = [
            KubeRowAction(title: "Open", symbol: "arrow.up.right.square") { open(row) },
            KubeRowAction(title: "Copy Name", symbol: "doc.on.doc") { Pasteboard.copy(row.object.metadata.name) },
        ]
        if kind != .secret {
            out.append(KubeRowAction(title: "Copy YAML", symbol: "doc.on.clipboard") { Pasteboard.copy(ResourceExport.yaml(row.object.raw)) })
        }
        out.append(KubeRowAction(title: "View YAML", symbol: "curlybraces") { router.push(.yaml(ref), from: column) })
        if kind == .pod {
            out.append(KubeRowAction(title: "Logs", symbol: "text.alignleft") { router.push(.logs(ref, container: nil, previous: false), from: column) })
        }
        guard canMutate else { return out }
        out.append(.separator)
        switch kind.kind {
        case "Deployment", "StatefulSet", "DaemonSet":
            out.append(KubeRowAction(title: "Restart…", symbol: "arrow.triangle.2.circlepath") { host.restart(t) })
        default: break
        }
        switch kind.kind {
        case "Deployment", "StatefulSet", "ReplicaSet": out.append(KubeRowAction(title: "Scale…", symbol: "plusminus") { host.scale(t) })
        case "Node":
            out.append(KubeRowAction(title: t.isCordoned ? "Uncordon" : "Cordon", symbol: "nosign") { host.cordon(t) })
            out.append(KubeRowAction(title: "Drain…", symbol: "arrow.down.to.line") { host.drain(t) })
        case "CronJob":
            out.append(KubeRowAction(title: t.isSuspended ? "Resume" : "Suspend", symbol: "pause.circle") { host.suspend(t) })
            out.append(KubeRowAction(title: "Trigger Now", symbol: "play.fill") { host.trigger(t) })
        default: break
        }
        out.append(KubeRowAction(title: "Delete…", symbol: "trash", isDestructive: true) { host.delete(t) })
        return out
    }
}
