import Foundation
import WheelhouseKit

/// The rules a `SelfSubjectRulesReview` returned (ARCHITECTURE-MAC section 12.5), reduced to what hiding a kind needs.
struct SidebarRuleSet: Equatable, Sendable {
    struct Rule: Equatable, Sendable { var verbs: [String]; var apiGroups: [String]; var resources: [String]; var resourceNames: [String] }
    var rules: [Rule]
    /// The server could not give a complete answer (it may evaluate only some authorizers): nothing is hidden then.
    var incomplete: Bool

    /// Parses `status` of a review response. Returns nil when the response has no usable status (treated as "hide nothing").
    static func parse(_ response: JSONValue) -> SidebarRuleSet? {
        guard let status = response.value(at: "status") else { return nil }
        let incomplete = status.value(at: "incomplete")?.boolValue ?? false
        let raw = status.value(at: "resourceRules")?.arrayValue ?? []
        func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
        let rules = raw.map { Rule(verbs: strings($0.value(at: "verbs")), apiGroups: strings($0.value(at: "apiGroups")),
                                  resources: strings($0.value(at: "resources")), resourceNames: strings($0.value(at: "resourceNames"))) }
        return SidebarRuleSet(rules: rules, incomplete: incomplete)
    }

    /// True when the rules let the user list `kind`. A rule limited to named objects does not grant listing. An incomplete
    /// ruleset allows everything (the tree is a display filter, never a security control).
    func allowsList(_ kind: ResourceKind) -> Bool {
        if incomplete { return true }
        return rules.contains { r in
            guard r.resourceNames.isEmpty else { return false }
            guard r.verbs.contains("list") || r.verbs.contains("*") else { return false }
            guard r.apiGroups.contains(kind.group) || r.apiGroups.contains("*") else { return false }
            return r.resources.contains("*") || r.resources.contains(kind.plural)
        }
    }
}

/// Everything the tree is built from. Pure data, so `SidebarModelTests` can drive it without a cluster.
struct SidebarBuildInput {
    var clusters: [ClusterConfig]
    var expandedClusters: Set<ClusterID>
    /// `"<clusterID>|<groupID or api group>"` of every group the user opened.
    var expandedGroups: Set<String>
    var filter: String
    var showsForbiddenKinds: Bool
    var discovery: [ClusterID: DiscoveryInfo]
    /// Clusters whose discovery read failed: the catalogue is shown unfiltered so the lists can still be opened.
    var discoveryFailed: Set<ClusterID> = []
    var rules: [ClusterID: SidebarRuleSet]
    /// "Is there at least one object of this kind", read from running stores only (ReplicationControllers).
    var anyExist: (ClusterID, ResourceKind) -> Bool = { _, _ in false }
    var features: [FeatureDescriptor] = []
    var isDemo = false
}

struct SidebarBuildOutput {
    var rows: [SidebarRow]
    /// Rows that must be open while a filter is active (the ancestors of every match). Cleared with the filter.
    var forcedOpen: Set<String>
}

enum SidebarTreeBuilder {
    /// API groups that another group already covers; Custom Resources does not repeat them.
    static func isCoveredElsewhere(group: String) -> Bool {
        group == "gateway.networking.k8s.io" || group == "argoproj.io" || group.hasSuffix(".argoproj.io")
            || group.hasSuffix(".toolkit.fluxcd.io") || group == "aquasecurity.github.io"
    }

    static func groupKey(_ cluster: ClusterID, _ part: String) -> String { "\(cluster)|\(part)" }

    static func build(_ input: SidebarBuildInput) -> SidebarBuildOutput {
        let q = input.filter.trimmingCharacters(in: .whitespaces).lowercased()
        var forced = Set<String>()
        var rows: [SidebarRow] = []

        if q.isEmpty {
            rows.append(top("top.search", "Search", "magnifyingglass", .search))
            rows.append(top("top.fleet", "Fleet", "wheelhouse.helm", .fleet))
            rows.append(top("top.alerts", "Alerts", "bell", .alerts))
            rows.append(top("top.sessions", "Sessions", "apple.terminal.on.rectangle", .sessions))
        }
        var clusterRows: [SidebarRow] = []
        for c in input.clusters {
            var row = SidebarRow(id: "cluster.\(c.id)", role: .cluster, level: 1, title: c.name, symbol: "server.rack", clusterID: c.id,
                                 destination: .clusterOverview(c.id), isExpandable: true)
            let nameMatches = !q.isEmpty && c.name.lowercased().contains(q)
            let expanded = input.expandedClusters.contains(c.id)
            if expanded || !q.isEmpty {
                // With a filter active, only clusters that have been expanded (so their discovery is known) are searched below.
                var children = expanded ? groups(for: c, input: input, filter: q, nameMatches: nameMatches, forced: &forced) : []
                if expanded && children.isEmpty && q.isEmpty { children = [] }
                row.children = children
            }
            if !q.isEmpty {
                if nameMatches || !row.children.isEmpty {
                    if !row.children.isEmpty { forced.insert(row.id) }
                    clusterRows.append(row)
                }
            } else {
                clusterRows.append(row)
            }
        }
        if !clusterRows.isEmpty {
            if q.isEmpty { rows.append(SidebarRow(id: "section.clusters", role: .section, level: 0, title: "Clusters", symbol: "")) }
            rows.append(contentsOf: clusterRows)
        }
        return SidebarBuildOutput(rows: rows, forcedOpen: forced)
    }

    private static func top(_ id: String, _ title: String, _ symbol: String, _ dest: SidebarDestination) -> SidebarRow {
        SidebarRow(id: id, role: .top, level: 0, title: title, symbol: symbol, destination: dest)
    }

    // MARK: Groups of one cluster

    static func matches(_ kind: ResourceKind, query q: String) -> Bool {
        q.isEmpty || SidebarCatalog.filterTerms(for: kind).contains { $0.contains(q) } || kind.displayName.lowercased().contains(q)
    }

    private static func groups(for c: ClusterConfig, input: SidebarBuildInput, filter q: String, nameMatches: Bool, forced: inout Set<String>) -> [SidebarRow] {
        let discovery = input.discovery[c.id]
        let failed = input.discoveryFailed.contains(c.id)
        guard discovery != nil || failed else {
            return q.isEmpty ? [SidebarRow(id: "loading.\(c.id)", role: .kind, level: 2, title: "Loading…", symbol: "ellipsis", clusterID: c.id)] : []
        }
        let rules = input.rules[c.id]
        func served(_ kind: ResourceKind) -> Bool { failed || (discovery?.supports(kind) ?? true) }
        func visibleKind(_ kind: ResourceKind) -> (show: Bool, forbidden: Bool) {
            guard served(kind) else { return (false, false) }
            if let rules, !rules.allowsList(kind) { return (input.showsForbiddenKinds, true) }
            return (true, false)
        }

        var out: [SidebarRow] = []
        for group in SidebarCatalog.groups {
            if group.id == .customResources {
                if let row = customResources(for: c, discovery: discovery, input: input, filter: q, visible: visibleKind, forced: &forced) { out.append(row) }
                continue
            }
            if group.feature != nil {
                if let row = featureGroup(group, for: c, discovery: discovery, input: input, filter: q, forced: &forced) { out.append(row) }
                continue
            }
            if group.isLeaf {
                if group.id == .overview {
                    guard q.isEmpty || "overview".contains(q) || nameMatches else { continue }
                    out.append(SidebarRow(id: "group.\(c.id).overview", role: .group(.overview), level: 2, title: group.title, symbol: group.symbol,
                                          clusterID: c.id, destination: .clusterOverview(c.id)))
                } else if let entry = group.kinds.first {
                    let v = visibleKind(entry.kind)
                    guard v.show, q.isEmpty || matches(entry.kind, query: q) || group.title.lowercased().contains(q) else { continue }
                    out.append(SidebarRow(id: "group.\(c.id).\(group.id.rawValue)", role: .group(group.id), level: 2, title: group.title, symbol: group.symbol,
                                          clusterID: c.id, kind: entry.kind, destination: .kind(c.id, entry.kind), isForbidden: v.forbidden))
                }
                continue
            }
            var children: [SidebarRow] = []
            if group.hasSummaryRow, q.isEmpty || "overview".contains(q) {
                children.append(SidebarRow(id: "summary.\(c.id)", role: .kind, level: 3, title: "Overview", symbol: "gauge.with.dots.needle.33percent",
                                           clusterID: c.id, destination: .workloadSummary(c.id)))
            }
            for entry in group.kinds {
                if entry.onlyWhenAnyExist, !input.anyExist(c.id, entry.kind) { continue }
                let v = visibleKind(entry.kind)
                guard v.show, matches(entry.kind, query: q) || (!q.isEmpty && group.title.lowercased().contains(q)) else { continue }
                children.append(SidebarRow(id: "kind.\(c.id).\(entry.kind.id)", role: .kind, level: 3, title: entry.title, symbol: entry.kind.symbol, clusterID: c.id,
                                           kind: entry.kind, destination: .kind(c.id, entry.kind), isForbidden: v.forbidden))
            }
            for extra in group.extraRows where extra == .portForwards {
                if q.isEmpty || "port forwards".contains(q) {
                    children.append(SidebarRow(id: "extra.\(c.id).portforwards", role: .kind, level: 3, title: "Port Forwards", symbol: "arrow.left.arrow.right",
                                               clusterID: c.id, destination: .portForwards(c.id)))
                }
            }
            guard !children.isEmpty else { continue }       // a group with no served kinds is hidden
            var row = SidebarRow(id: "group.\(c.id).\(group.id.rawValue)", role: .group(group.id), level: 2, title: group.title, symbol: group.symbol,
                                 secondary: group.secondaryLabel, clusterID: c.id, isExpandable: true, children: children)
            if !q.isEmpty { forced.insert(row.id) }
            row.isForbidden = false
            out.append(row)
        }
        return out
    }

    // MARK: Custom Resources

    private static func customResources(for c: ClusterConfig, discovery: DiscoveryInfo?, input: SidebarBuildInput, filter q: String,
                                        visible: (ResourceKind) -> (show: Bool, forbidden: Bool), forced: inout Set<String>) -> SidebarRow? {
        var children: [SidebarRow] = []
        let crd = ResourceKind.customResourceDefinition
        let v = visible(crd)
        if v.show, q.isEmpty || matches(crd, query: q) || "definitions".contains(q) {
            children.append(SidebarRow(id: "kind.\(c.id).crds", role: .kind, level: 3, title: "Definitions", symbol: "square.stack.3d.up.badge.automatic",
                                       clusterID: c.id, kind: crd, destination: .kind(c.id, crd), isForbidden: v.forbidden))
        }
        let customs = (discovery?.customKinds ?? []).filter { !isCoveredElsewhere(group: $0.group) && !SidebarCatalog.allKinds.contains($0) }
        let byGroup = Dictionary(grouping: customs, by: \.group)
        for apiGroup in byGroup.keys.sorted() {
            var kids: [SidebarRow] = []
            for kind in (byGroup[apiGroup] ?? []).sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }) {
                let vk = visible(kind)
                guard vk.show, q.isEmpty || kind.displayName.lowercased().contains(q) || kind.plural.contains(q) || apiGroup.lowercased().contains(q) else { continue }
                kids.append(SidebarRow(id: "kind.\(c.id).\(kind.id)", role: .kind, level: 4, title: kind.displayName, symbol: "cube.transparent", clusterID: c.id,
                                       kind: kind, destination: .kind(c.id, kind), isForbidden: vk.forbidden))
            }
            guard !kids.isEmpty else { continue }
            let id = "api.\(c.id).\(apiGroup)"
            if !q.isEmpty { forced.insert(id) }
            children.append(SidebarRow(id: id, role: .apiGroup, level: 3, title: apiGroup, symbol: "", clusterID: c.id, isExpandable: true, children: kids))
        }
        guard !children.isEmpty else { return nil }
        let id = "group.\(c.id).customResources"
        if !q.isEmpty { forced.insert(id) }
        return SidebarRow(id: id, role: .group(.customResources), level: 2, title: "Custom Resources", symbol: "puzzlepiece.extension", clusterID: c.id,
                          isExpandable: true, children: children)
    }

    // MARK: Feature groups (Chart Room, Tides, Survey)

    private static func featureGroup(_ group: SidebarGroup, for c: ClusterConfig, discovery: DiscoveryInfo?, input: SidebarBuildInput, filter q: String,
                                     forced: inout Set<String>) -> SidebarRow? {
        guard let featureID = group.feature, let feature = input.features.first(where: { $0.id == featureID }) else { return nil }
        func served(_ t: SidebarNodeTemplate) -> Bool {
            guard !t.requiresAPIGroups.isEmpty else { return true }
            guard let discovery else { return false }
            return discovery.resources.contains { r in t.requiresAPIGroups.contains(r.group ?? "") }
        }
        func rows(_ templates: [SidebarNodeTemplate], level: Int) -> [SidebarRow] {
            templates.filter(served).compactMap { t in
                let kids = rows(t.children, level: level + 1)
                if !t.children.isEmpty, kids.isEmpty { return nil }
                guard q.isEmpty || t.title.lowercased().contains(q) || group.title.lowercased().contains(q) || !kids.isEmpty else { return nil }
                let dest = t.destination(c.id).map { SidebarDestination.feature($0) }
                return SidebarRow(id: "node.\(c.id).\(t.id)", role: .featureNode, level: level, title: t.title, symbol: t.symbol, clusterID: c.id,
                                  destination: dest, isExpandable: !kids.isEmpty, children: kids)
            }
        }
        let children = rows(feature.sidebarNodes, level: 3)
        guard !children.isEmpty else { return nil }
        let id = "group.\(c.id).\(group.id.rawValue)"
        if !q.isEmpty { forced.insert(id) }
        return SidebarRow(id: id, role: .group(group.id), level: 2, title: group.title, symbol: group.symbol, secondary: group.secondaryLabel, clusterID: c.id,
                          isExpandable: true, children: children)
    }
}
