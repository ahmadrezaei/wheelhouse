import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit

/// One row of the Compass list.
struct CompassResult: Identifiable, Equatable {
    enum Group: Int, CaseIterable, Comparable {
        case topHit, actions, resources, clusters, stations, settings, hints
        static func < (a: Group, b: Group) -> Bool { a.rawValue < b.rawValue }
        var title: String {
            switch self {
            case .topHit: "Top Hit"
            case .actions: "Actions"
            case .resources: "Resources"
            case .clusters: "Clusters & Kinds"
            case .stations: "Stations"
            case .settings: "Settings"
            case .hints: ""
            }
        }
    }

    enum Target: Equatable {
        case command(String)
        case object(CompassHit)
        case cluster(ClusterID)
        case kind(ClusterID, ResourceKind)
        case station(String)
        case settings(SettingsPane)
        case railItem(String)
        case hint
    }

    var id: String
    var group: Group
    var title: String
    var subtitle: String?
    var symbol: String
    var environment: ClusterEnvironment?
    var shortcut: String?
    var isProblem = false
    var score = 0
    var target: Target
    /// The query that produced it, for the bold characters.
    var highlight = ""
}

/// A secondary action of a result (→ or Tab).
struct CompassAction: Identifiable, Equatable {
    var id: String
    var title: String
    var symbol: String
}

/// The Compass panel's state (DESIGN-MAC sections 6.7 and 9). It only ever OPENS things: a screen, a tab, a split, a window, a Station,
/// a Settings pane, or a menu command the person chose. It never runs a mutation (a command that mutates opens its own confirmation
/// sheet), and `!` and `?` are not handled in this version: they show a hint and do nothing, so nothing is ever written to a terminal
/// from here.
@MainActor @Observable
final class CompassModel {
    static let rememberQueryFor: TimeInterval = 30

    private(set) var isOpen = false
    var query = "" { didSet { if query != oldValue { update() } } }
    private(set) var results: [CompassResult] = []
    var selection = 0
    private(set) var actions: [CompassAction] = []
    private(set) var actionsFor: CompassResult?
    private(set) var stats = CompassIndexStats()
    /// The scope shown in the footer.
    var footer: String {
        guard stats.objects > 0 else { return "No objects indexed yet. Opt clusters in under Settings ▸ General." }
        let age = stats.updated.map { RelativeDateTimeFormatter().localizedString(for: $0, relativeTo: now()) } ?? "never"
        return "Indexed \(stats.objects.formatted()) objects in \(stats.clusters) cluster\(stats.clusters == 1 ? "" : "s") · updated \(age)"
    }

    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let workspace: WorkspaceController
    @ObservationIgnored private let commands: @MainActor () -> [CompassCommand]
    @ObservationIgnored let index: CompassIndex
    @ObservationIgnored let frecency: FrecencyStore
    @ObservationIgnored private let rail: RailModel
    @ObservationIgnored private let isLocked: @MainActor () -> Bool
    @ObservationIgnored private let openSettings: @MainActor () -> Void
    @ObservationIgnored private let now: @Sendable () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var closedAt: Date?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(registry: ClusterRegistry, workspace: WorkspaceController, commands: @escaping @MainActor () -> [CompassCommand], index: CompassIndex,
         frecency: FrecencyStore, rail: RailModel, isLocked: @escaping @MainActor () -> Bool, openSettings: @escaping @MainActor () -> Void = {},
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.registry = registry
        self.workspace = workspace
        self.commands = commands
        self.index = index
        self.frecency = frecency
        self.rail = rail
        self.isLocked = isLocked
        self.openSettings = openSettings
        self.now = now
    }

    // MARK: Opening

    /// ⌘K. Reopening within 30 seconds of closing keeps the last query so it can be refined.
    func toggle() { isOpen ? close() : open() }

    func open(seed: String? = nil) {
        guard !isLocked() else { return }
        if let seed { query = seed }
        else if let closedAt, now().timeIntervalSince(closedAt) > Self.rememberQueryFor { query = "" }
        isOpen = true
        selection = 0
        actions = []
        actionsFor = nil
        update()
        Task { stats = await index.stats }
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        closedAt = now()
        searchTask?.cancel()
        frecency.flush()
    }

    /// App Lock: the panel closes and forgets what was typed.
    func lockEngaged() {
        isOpen = false
        query = ""
        results = []
        actions = []
    }

    // MARK: Searching

    private var focusedCluster: ClusterID? { workspace.activeModel?.focusedPane?.context.clusterID ?? registry.currentClusterID }

    private func name(of cluster: ClusterID) -> String { registry.config(for: cluster)?.name ?? cluster }

    func update() {
        generation += 1
        let myGeneration = generation
        searchTask?.cancel()
        let parsed = CompassQuery.parse(query)
        var rows = immediateResults(parsed)
        rows = Self.arranged(rows)
        results = rows
        selection = min(selection, max(0, rows.count - 1))
        actions = []
        actionsFor = nil
        guard parsed.mode == .all, !parsed.isEmpty else { return }
        let names = Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.id, $0.name) })
        let problems = problemKeys()
        let pinned = Set(rail.items.compactMap(\.resource).map { CompassHit.key(cluster: $0.clusterID, kindID: $0.kind.id, namespace: $0.namespace, name: $0.name) })
        let frecency = self.frecency
        let index = self.index
        let environments = Dictionary(uniqueKeysWithValues: registry.clusters.map { ($0.id, $0.environment) })
        searchTask = Task { [weak self] in
            let hits = await index.search(parsed, limit: 30, clusters: names, problems: problems, pinned: pinned, frecency: { frecency.boost($0) })
            let stats = await index.stats
            guard !Task.isCancelled, let self, self.generation == myGeneration else { return }
            self.stats = stats
            let objectRows = hits.map { hit in
                CompassResult(id: "obj|" + hit.id, group: .resources, title: hit.name, subtitle: "\(hit.kind.kind) · \(self.name(of: hit.cluster))" + (hit.namespace.map { " · \($0)" } ?? ""),
                              symbol: hit.kind.symbol, environment: environments[hit.cluster], isProblem: hit.isProblem, score: hit.score, target: .object(hit),
                              highlight: parsed.tokens.last ?? "")
            }
            self.results = Self.arranged(self.immediateResults(parsed) + objectRows)
            self.selection = min(self.selection, max(0, self.results.count - 1))
        }
    }

    /// Failing objects of the checked clusters, for "problems first".
    private func problemKeys() -> Set<String> {
        var keys = Set<String>()
        for health in registry.allSessions.compactMap(\.health) {
            for item in health.items {
                if let r = item.resource { keys.insert(CompassHit.key(cluster: r.clusterID, kindID: r.kind.id, namespace: r.namespace, name: r.name)) }
            }
        }
        return keys
    }

    /// Orders by group, best first; the single best row of the lot becomes the Top Hit.
    static func arranged(_ rows: [CompassResult]) -> [CompassResult] {
        var rows = rows.sorted { $0.group != $1.group ? $0.group < $1.group : ($0.score != $1.score ? $0.score > $1.score : $0.title < $1.title) }
        let candidates = rows.indices.filter { rows[$0].group != .hints }
        if let best = candidates.max(by: { rows[$0].score < rows[$1].score }), rows[best].score >= CompassMatcher.wordPrefix {
            var top = rows.remove(at: best)
            top.group = .topHit
            rows.insert(top, at: 0)
        }
        return rows
    }

    private func immediateResults(_ q: CompassQuery) -> [CompassResult] {
        let tokens = q.tokens.map(CompassMatcher.fold)
        func match(_ text: String) -> Int? {
            if tokens.isEmpty { return 0 }
            let folded = CompassMatcher.fold(text)
            var total = 0
            for t in tokens { guard let s = CompassMatcher.score(t, in: folded) else { return nil }; total += s }
            return total
        }
        var rows: [CompassResult] = []
        switch q.mode {
        case .run, .ask:
            let what = q.mode == .run ? "Running text in a terminal" : "Asking First Mate"
            return [CompassResult(id: "hint", group: .hints, title: "\(what) is not available in Compass yet", subtitle: "Open a Deck Terminal or the First Mate inspector instead.",
                                  symbol: "info.circle", target: .hint)]
        case .cve:
            return [CompassResult(id: "hint", group: .hints, title: "Survey findings are not searchable yet", subtitle: nil, symbol: "info.circle", target: .hint)]
        default: break
        }
        if q.isEmpty { return emptyFieldResults() }
        if q.mode == .all || q.mode == .actions {
            for c in commands() where c.isEnabled() {
                let text = q.mode == .actions || !c.menuPath.isEmpty ? "\(c.title) \(c.menuPath)" : c.title
                guard let s = match(text) else { continue }
                rows.append(CompassResult(id: "cmd|" + c.id, group: .actions, title: c.title, subtitle: c.menuPath, symbol: c.symbol, shortcut: c.shortcut,
                                          score: s / max(1, tokens.count) + frecency.boost("cmd|" + c.id), target: .command(c.id), highlight: q.tokens.first ?? ""))
            }
        }
        if q.mode == .actions { return rows }
        if q.mode == .all || q.mode == .settings {
            for pane in SettingsPane.allCases {
                guard q.mode == .settings ? (match(pane.title) != nil) : (!tokens.isEmpty && match("settings \(pane.title)") != nil && match(pane.title) != nil) else { continue }
                rows.append(CompassResult(id: "set|" + pane.rawValue, group: .settings, title: pane.title, subtitle: "Settings", symbol: pane.symbol,
                                          score: (match(pane.title) ?? 0) / max(1, tokens.count), target: .settings(pane)))
            }
        }
        if q.mode == .all || q.mode == .station {
            for station in workspace.store.stations where station.raw == nil {
                guard let s = match(station.name) else { continue }
                rows.append(CompassResult(id: "sta|" + station.id.rawValue, group: .stations, title: station.name, subtitle: station.isTemplate ? "Station template" : "Station",
                                          symbol: "rectangle.split.2x2", score: s / max(1, tokens.count) + frecency.boost("sta|" + station.id.rawValue),
                                          target: .station(station.id.rawValue)))
            }
        }
        if q.mode == .all {
            for cluster in registry.clusters {
                guard !tokens.isEmpty, let s = match(cluster.name) else { continue }
                rows.append(CompassResult(id: "cl|" + cluster.id, group: .clusters, title: cluster.name, subtitle: "Cluster", symbol: "server.rack", environment: cluster.environment,
                                          score: s / max(1, tokens.count) + frecency.boost("cl|" + cluster.id), target: .cluster(cluster.id)))
            }
        }
        if q.mode == .goToKind || (q.mode == .all && tokens.count == 1), let cluster = focusedCluster {
            for kind in SidebarCatalog.allKinds {
                let terms = SidebarCatalog.filterTerms(for: kind)
                guard let s = terms.compactMap({ t in tokens.isEmpty ? 0 : CompassMatcher.score(Array(tokens.joined()), in: CompassMatcher.fold(t)) }).max() else { continue }
                rows.append(CompassResult(id: "kind|\(cluster)|\(kind.id)", group: .clusters, title: "Go to \(kind.displayName)", subtitle: name(of: cluster), symbol: kind.symbol,
                                          environment: registry.config(for: cluster)?.environment, score: s - (q.mode == .goToKind ? 0 : 50), target: .kind(cluster, kind)))
            }
        }
        return rows
    }

    /// An empty field: recent choices, then Rail items.
    private func emptyFieldResults() -> [CompassResult] {
        var rows: [CompassResult] = []
        for key in frecency.topKeys(prefix: "cmd|", limit: 3) {
            if let c = commands().first(where: { "cmd|" + $0.id == key }), c.isEnabled() {
                rows.append(CompassResult(id: key, group: .actions, title: c.title, subtitle: "Recent · " + c.menuPath, symbol: c.symbol, shortcut: c.shortcut, score: 1, target: .command(c.id)))
            }
        }
        for item in rail.items where rail.isAvailable(item) {
            rows.append(CompassResult(id: "rail|" + item.id, group: .clusters, title: rail.title(for: item), subtitle: "Rail", symbol: "bookmark",
                                      environment: item.clusterID.flatMap { registry.config(for: $0)?.environment }, score: 0, target: .railItem(item.id)))
        }
        return rows
    }

    // MARK: Acting

    /// Moves the selection by `delta`, wrapping.
    func move(_ delta: Int) {
        let count = showsActionList ? actions.count : results.count
        guard count > 0 else { return }
        selection = (selection + delta + count) % count
    }

    var showsActionList: Bool { actionsFor != nil }

    /// The result under the selection.
    var selected: CompassResult? { results.indices.contains(selection) ? results[selection] : nil }

    /// → or Tab: the secondary actions of the selected object.
    func showActions() {
        guard let r = selected, case .object(let hit) = r.target else { return }
        var list = [CompassAction(id: "open", title: "Open", symbol: "arrow.right.circle")]
        if hit.kind == .pod {
            list.append(CompassAction(id: "logs", title: "Logs", symbol: "text.alignleft"))
            list.append(CompassAction(id: "previousLogs", title: "Previous Logs", symbol: "clock.arrow.circlepath"))
        }
        if hit.kind != .namespace { list.append(CompassAction(id: "yaml", title: "Manifest", symbol: "doc.plaintext")) }
        list.append(CompassAction(id: "pin", title: "Pin to Rail", symbol: "pin"))
        list.append(CompassAction(id: "copy", title: "Copy Name", symbol: "doc.on.doc"))
        actions = list
        actionsFor = r
        selection = 0
    }

    func hideActions() { actions = []; actionsFor = nil; selection = 0 }

    /// ↩ (and ⌘↩, ⌥↩, ⇧↩ through `placement`) on the selected row, or on the chosen secondary action.
    func performSelected(placement: OpenPlacement = .here) {
        if let target = actionsFor, actions.indices.contains(selection) {
            perform(action: actions[selection].id, on: target, placement: placement)
            return
        }
        guard let r = selected else { return }
        perform(r, placement: placement)
    }

    func perform(_ r: CompassResult, placement: OpenPlacement) {
        guard !isLocked() else { return }
        let model = workspace.activeModel
        switch r.target {
        case .hint: return
        case .command(let id):
            close()
            frecency.record("cmd|" + id)
            if let c = commands().first(where: { $0.id == id }), c.isEnabled() { c.perform() }
            return
        case .object(let hit):
            frecency.record(hit.frecencyKey)
            let ref = ResourceRef(clusterID: hit.cluster, kind: hit.kind, namespace: hit.namespace, name: hit.name)
            model?.show(WorkspaceWindowModel.destination(for: ref), placement: placement)
        case .cluster(let id):
            frecency.record("cl|" + id)
            model?.activate(cluster: id, placement: placement)
        case .kind(let cluster, let kind):
            let namespace = model?.focusedPane?.context.namespace
            model?.show(.route(.resourceList(cluster, kind, namespace: kind.namespaced ? namespace : nil)), placement: placement)
        case .station(let id):
            frecency.record("sta|" + id)
            if let station = workspace.store.stations.first(where: { $0.id.rawValue == id }) { workspace.open(station: station) }
        case .settings(let pane):
            SettingsNavigation.shared.requested = pane
            openSettings()
        case .railItem(let id):
            if let item = rail.items.first(where: { $0.id == id }), let model { rail.activate(item, in: model, placement: placement, controller: workspace) }
        }
        close()
    }

    private func perform(action: String, on r: CompassResult, placement: OpenPlacement) {
        guard case .object(let hit) = r.target, !isLocked(), let model = workspace.activeModel else { return }
        let ref = ResourceRef(clusterID: hit.cluster, kind: hit.kind, namespace: hit.namespace, name: hit.name)
        frecency.record(hit.frecencyKey)
        switch action {
        case "logs": model.show(.route(.logs(ref, container: nil, previous: false)), placement: placement)
        case "previousLogs": model.show(.route(.logs(ref, container: nil, previous: true)), placement: placement)
        case "yaml": model.show(.route(.yaml(ref)), placement: placement)
        case "pin": rail.pin(.resource(ref))
        case "copy":
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(hit.name, forType: .string)
        default: model.show(WorkspaceWindowModel.destination(for: ref), placement: placement)
        }
        close()
    }
}

/// `settings:beacon` and Compass's Settings rows ask the Settings window to show a pane.
@MainActor @Observable
final class SettingsNavigation {
    static let shared = SettingsNavigation()
    var requested: SettingsPane?
}
