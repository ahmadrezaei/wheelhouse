import AppKit
import Foundation
import Observation
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

/// The Deck Terminal shells that exist, held weakly, so a pack command can be inserted into the right one.
@MainActor
final class RiggingTerminals {
    private struct Weak { weak var model: LocalShellModel? }
    private var items: [Weak] = []

    func register(_ model: LocalShellModel) {
        items.removeAll { $0.model == nil }
        items.append(Weak(model: model))
    }

    /// The newest guarded shell on `cluster` that can take a paste right now (a Direct shell never receives pack text).
    func target(for cluster: ClusterID) -> LocalShellModel? {
        items.reversed().compactMap(\.model).first {
            $0.configuration.cluster.id == cluster && $0.configuration.mode == .guarded && $0.phase == .running && $0.bracketedPasteEnabled && $0.isAtPrompt
        }
    }

    func hasShell(for cluster: ClusterID) -> Bool {
        items.contains { $0.model?.configuration.cluster.id == cluster && $0.model?.configuration.mode == .guarded && $0.model?.phase == .running }
    }
}

/// Holds the confirmation a pack's port-forward is waiting on. The sheet itself is the app's ConfirmSheet with the `.rigging` origin.
/// Only one pack view presents a request: the first to claim it. Every other visible view leaves it alone.
@MainActor @Observable
final class RiggingConfirmCenter {
    var pending: ConfirmRequest? {
        didSet { if pending == nil { claimant = nil } }
    }
    /// How many pack views are on screen to show the sheet.
    @ObservationIgnored var hosts = 0
    /// The host that presents `pending`.
    @ObservationIgnored private(set) var claimant: UUID?

    /// True when `host` is the one that shows the pending request (it claims it when none has).
    func claim(_ host: UUID) -> Bool {
        guard pending != nil else { return false }
        if claimant == nil { claimant = host }
        return claimant == host
    }

    /// A host that goes away gives up its claim, so another visible view can take over.
    func release(_ host: UUID) {
        if claimant == host { claimant = nil }
    }
}

/// A command a pack offers for a kind, with the pack it came from.
struct RiggingCommandItem: Identifiable {
    var pack: RiggingPack
    var command: RiggingPack.Command
    var id: String { "\(pack.metadata.name)|\(command.id)" }
}

/// Runs what packs ask for, in the only two ways they can: text inserted into a guarded terminal (never run) and a port-forward behind a
/// ConfirmSheet. Also feeds the packs' health rules to Alerts and tells the sidebar how packs lay out Custom Resources.
@MainActor @Observable
final class RiggingRuntime {
    let store: RiggingStore
    @ObservationIgnored let terminals = RiggingTerminals()
    @ObservationIgnored let confirm = RiggingConfirmCenter()
    @ObservationIgnored private let registry: ClusterRegistry
    @ObservationIgnored private let workspace: WorkspaceController
    @ObservationIgnored private let activity: any ActivityLogging
    @ObservationIgnored private var healthCache: [ClusterID: (at: Date, revision: Int, items: [AttentionItem])] = [:]
    @ObservationIgnored static let healthCacheSeconds: TimeInterval = 300
    /// Shown when a command cannot be used (a value that is not safe, no terminal). Replaced by tests.
    @ObservationIgnored var notify: @MainActor (_ title: String, _ message: String) -> Void = { title, message in
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        if let window = NSApp.keyWindow { alert.beginSheetModal(for: window) } else { alert.runModal() }
    }

    @ObservationIgnored var isLocked: @MainActor () -> Bool = { false }
    /// Whether this build runs Rigging. Replaced by tests.
    @ObservationIgnored var isFeatureEnabled: () -> Bool = { RiggingFeature.isEnabled() }
    /// The most items one rule, and one pack, may put into Alerts; the rest are summarised in one item.
    static let itemsPerRule = 20
    static let itemsPerPack = 20
    /// One plain list of a kind across all namespaces (nothing is watched). Replaced by tests.
    @ObservationIgnored var listObjects: (ClusterSession, ResourceKind) async throws -> [JSONValue] = { session, kind in
        try await session.client.listRaw(kind, namespace: nil, options: ListOptions(limit: 500))["items"]?.arrayValue ?? []
    }
    @ObservationIgnored private var failedKinds: [ClusterID: [String: Date]] = [:]

    init(store: RiggingStore, registry: ClusterRegistry, workspace: WorkspaceController, activity: any ActivityLogging) {
        self.store = store
        self.registry = registry
        self.workspace = workspace
        self.activity = activity
    }

    // MARK: Wiring

    /// Called once at start: health rules on every session, the sidebar layout, and a sidebar rebuild when packs change.
    func start() {
        guard isFeatureEnabled() else { return }
        store.sweep()
        registry.sessionHook = { [weak self] session in
            session.healthAugmenter = { [weak self] session in await self?.healthItems(for: session) ?? [] }
        }
        for session in registry.allSessions where session.healthAugmenter == nil {
            session.healthAugmenter = { [weak self] session in await self?.healthItems(for: session) ?? [] }
        }
        RiggingSidebarHook.layouts = { [weak self] in self?.store.sidebarLayouts ?? [:] }
        RiggingSidebarHook.views = { [weak self] in self?.store.viewIndex ?? [:] }
        store.onChange = { [weak self] in
            self?.healthCache = [:]
            self?.workspace.allModels.forEach { $0.sidebarIfCreated?.rebuild() }
        }
        store.onChange()   // the store loaded before this hook existed
        ResourceRowExtensions.provider = { [weak self] ref, raw in self?.menuActions(for: ref, raw: raw) ?? [] }
    }

    // MARK: Kinds

    func resourceKind(_ match: RiggingPack.KindMatch, in discovery: DiscoveryInfo?) -> ResourceKind? {
        if match.group.isEmpty, match.kind.lowercased() == "secret" { return nil }   // packs never read Secrets
        if let known = ResourceKind.builtIn.first(where: { $0.group == match.group && $0.kind == match.kind }) { return known }
        guard let r = discovery?.topLevel.first(where: { ($0.group ?? "") == match.group && $0.kind == match.kind && $0.verbs.contains("list") }), let version = r.version else { return nil }
        return .custom(group: match.group, version: version, kind: match.kind, plural: r.name, namespaced: r.namespaced)
    }

    static func match(for kind: ResourceKind) -> RiggingPack.KindMatch { RiggingPack.KindMatch(group: kind.group, kind: kind.kind) }

    // MARK: Commands

    func commands(for kind: RiggingPack.KindMatch) -> [RiggingCommandItem] {
        store.active.flatMap { pack in pack.commands(for: kind).map { RiggingCommandItem(pack: pack, command: $0) } }
    }

    var globalCommands: [RiggingCommandItem] {
        store.active.flatMap { pack in pack.globalCommands.map { RiggingCommandItem(pack: pack, command: $0) } }
    }

    /// Runs a command from a menu, the Rail or Compass. Terminal text is only inserted; a port-forward only shows its confirmation.
    func perform(_ item: RiggingCommandItem, subject: RiggingValues.Subject?, cluster: ClusterConfig) {
        guard isFeatureEnabled(), !isLocked() else { return }
        let plan: RiggingCommandPlan
        do { plan = try RiggingCommandPlanner.plan(item.command, in: item.pack, subject: subject, cluster: cluster.name) } catch {
            record(item, cluster: cluster, subject: subject, verb: "refused", result: "refused: \(error.localizedDescription)")
            notify("“\(item.command.title)” cannot be used here", error.localizedDescription)
            return
        }
        switch plan {
        case .insert(let text): Task { await insert(text, item: item, subject: subject, cluster: cluster) }
        case .portForward(let forward): requestPortForward(forward, item: item, cluster: cluster)
        }
    }

    /// The object's JSON from a store that already runs (never creates one), for commands that use a view's fields.
    private func liveObject(_ ref: ResourceRef) -> JSONValue? {
        guard let session = registry.session(for: ref.clusterID) else { return nil }
        for ns in [ref.namespace, nil] {
            if let store = session.existingUnstructuredStore(kind: ref.kind, namespace: ns), let found = store.items.first(where: { $0.metadata.name == ref.name && $0.metadata.namespace == ref.namespace }) {
                return found.raw
            }
        }
        return nil
    }

    // MARK: Terminal

    private func insert(_ text: String, item: RiggingCommandItem, subject: RiggingValues.Subject?, cluster: ClusterConfig) async {
        var target = terminals.target(for: cluster.id)
        if target == nil {
            // No guarded shell is ready on that cluster: open one in a new tab, and wait (bounded) for its first prompt.
            workspace.activeModel?.openInNewTab(.deckTerminal(TerminalSpec(clusterID: cluster.id, title: item.pack.metadata.name)))
            for _ in 0..<80 where target == nil {
                try? await Task.sleep(for: .milliseconds(250))
                target = terminals.target(for: cluster.id)
            }
        }
        guard let target else {
            record(item, cluster: cluster, subject: subject, verb: "insert", result: "refused: no terminal ready")
            notify("No terminal is ready", "Open a Deck Terminal for \(cluster.name) and try again.")
            return
        }
        switch TerminalInserter.insert(text, forCluster: cluster, into: target) {
        case .inserted(let removed):
            revealTerminal(for: cluster.id)
            record(item, cluster: cluster, subject: subject, verb: "insert", result: removed == 0 ? "ok" : "ok (removed \(removed) hidden characters)", commandLine: text)
        case .refused(let why):
            record(item, cluster: cluster, subject: subject, verb: "insert", result: "refused: \(why)")
            notify("The command was not inserted", why)
        }
    }

    /// Brings the terminal pane the text went into to the front, so the person sees it and can review it before pressing Return.
    private func revealTerminal(for cluster: ClusterID) {
        guard let model = workspace.activeModel else { return }
        let pane = model.state.allPanes.first { pane in
            if case .deckTerminal(let spec)? = pane.top { return spec.clusterID == cluster }
            return false
        }
        if let pane { model.focus(pane: pane.id) }
    }

    // MARK: Port-forward

    func requestPortForward(_ plan: PortForwardPlan, item: RiggingCommandItem, cluster: ClusterConfig) {
        guard let session = registry.session(for: cluster.id) else { return }
        // The sheet is shown by a pack view. With none on screen and none to open, refuse rather than leave a request waiting.
        if confirm.hosts == 0, item.pack.allViews.isEmpty {
            notify("The port forward was not started", "The “\(item.pack.metadata.name)” pack has no view to show the confirmation in.")
            return
        }
        confirm.pending = RiggingConfirmations.portForward(plan: plan, pack: item.pack.metadata.name, title: item.command.title, cluster: cluster, session: session,
                                                           activity: activity)
        // A pack view shows the sheet. From Compass or the Rail one is opened for the pack when none is on screen.
        if confirm.hosts == 0, let view = item.pack.allViews.first {
            workspace.activeModel?.openInNewTab(.riggingView(RiggingViewRef(pack: item.pack.metadata.name, view: view.viewID, clusterID: cluster.id, namespace: nil)))
        }
    }

    private func record(_ item: RiggingCommandItem, cluster: ClusterConfig, subject: RiggingValues.Subject?, verb: String, result: String, commandLine: String? = nil) {
        let object = subject.flatMap { s in s.name.map { "\(s.kind?.lowercased() ?? "object")/\($0)" } } ?? item.command.title
        activity.record(ActivityEntry(cluster: cluster.id, origin: .rigging(pack: item.pack.metadata.name), verb: verb, object: object, result: result, commandLine: commandLine))
    }

    // MARK: Menus (resource rows, Rail, Compass)

    /// The pack commands for a resource row, as context-menu entries.
    func menuActions(for ref: ResourceRef, raw: JSONValue) -> [KubeRowAction] {
        guard isFeatureEnabled(), let cluster = registry.config(for: ref.clusterID) else { return [] }
        let items = commands(for: Self.match(for: ref.kind))
        guard !items.isEmpty else { return [] }
        let subject = RiggingValues.Subject(name: ref.name, namespace: ref.namespace, kind: ref.kind.kind, raw: raw)
        return [.separator] + items.map { item in
            KubeRowAction(title: item.command.title + (item.command.terminal != nil ? " (insert in terminal)" : "…"), symbol: "puzzlepiece.extension") { [weak self] in
                self?.perform(item, subject: subject, cluster: cluster)
            }
        }
    }

    struct RailAction { var id: String; var title: String; var perform: @MainActor () -> Void }

    /// Pack commands for a pinned Rail item: those for the pinned object's kind, or the commands that need no object for a cluster.
    func railActions(for item: RailItem) -> [RailAction] {
        guard isFeatureEnabled(), let clusterID = item.clusterID, let cluster = registry.config(for: clusterID) else { return [] }
        var out: [RailAction] = []
        func add(_ command: RiggingCommandItem, subject: RiggingValues.Subject?) {
            out.append(RailAction(id: command.id, title: command.command.title + (command.command.terminal != nil ? " (insert in terminal)" : "…")) { [weak self] in
                self?.perform(command, subject: subject, cluster: cluster)
            })
        }
        switch item.kind {
        case .resource:
            guard let ref = item.resource else { return [] }
            let raw = liveObject(ref)
            let subject = RiggingValues.Subject(name: ref.name, namespace: ref.namespace, kind: ref.kind.kind, raw: raw)
            commands(for: Self.match(for: ref.kind)).forEach { add($0, subject: subject) }
        case .cluster: globalCommands.forEach { add($0, subject: nil) }
        default: break
        }
        return out
    }

    /// Pack commands for the object the focused pane shows (Compass), plus the commands that need no object.
    func compassCommands() -> [CompassCommand] {
        guard isFeatureEnabled() else { return [] }
        let model = workspace.activeModel
        var destination: ResourceRef?
        if case .route(.resourceDetail(let ref))? = model?.focusedPane?.top { destination = ref }
        let clusterID = destination?.clusterID ?? model?.focusedPane?.top?.clusterID ?? registry.currentCluster?.id
        guard let clusterID, let cluster = registry.config(for: clusterID) else { return [] }
        var out: [CompassCommand] = []
        func add(_ item: RiggingCommandItem, subject: RiggingValues.Subject?) {
            out.append(CompassCommand(id: "rigging.\(item.id).\(clusterID)", title: item.command.title, menuPath: "Rigging ▸ \(item.pack.metadata.name)", shortcut: nil,
                                      symbol: "puzzlepiece.extension", isEnabled: { [weak self] in !(self?.isLocked() ?? false) }, perform: { [weak self] in self?.perform(item, subject: subject, cluster: cluster) }))
        }
        for item in globalCommands { add(item, subject: nil) }
        if let ref = destination {
            let raw = liveObject(ref)
            let subject = RiggingValues.Subject(name: ref.name, namespace: ref.namespace, kind: ref.kind.kind, raw: raw)
            for item in commands(for: Self.match(for: ref.kind)) { add(item, subject: subject) }
        }
        return out
    }

    // MARK: Health rules

    /// The attention items for the enabled packs' health rules on one cluster. Reads each kind once with a plain list (nothing is watched),
    /// at most every five minutes per cluster.
    func healthItems(for session: ClusterSession) async -> [AttentionItem] {
        let packs = store.active.filter { !$0.allHealthRules.isEmpty }
        guard !packs.isEmpty else { return [] }
        if let cached = healthCache[session.id], cached.revision == store.revision, Date().timeIntervalSince(cached.at) < Self.healthCacheSeconds { return cached.items }
        if session.discovery == nil { await session.loadDiscovery() }
        guard let discovery = session.discovery else { return [] }
        var lists: [String: [JSONValue]] = [:]
        var items: [AttentionItem] = []
        let revision = store.revision
        var complete = true
        let now = Date()
        // A kind that failed (a 403, a missing CRD) is not listed again until the cache window passes.
        failedKinds[session.id] = failedKinds[session.id]?.filter { now.timeIntervalSince($0.value) < Self.healthCacheSeconds }
        for pack in packs {
            // A pack that is not built in cannot make an item critical; its failure is a warning at most.
            let builtIn = store.installedPack(named: pack.metadata.name)?.entry.source.kind == .builtIn
            var packItems = 0
            var dropped = 0
            for rule in pack.allHealthRules {
                guard let kind = resourceKind(rule.for, in: discovery) else { continue }
                if lists[kind.id] == nil {
                    if failedKinds[session.id]?[kind.id] != nil {
                        lists[kind.id] = []
                    } else {
                        do {
                            lists[kind.id] = try await listObjects(session, kind)
                        } catch {
                            failedKinds[session.id, default: [:]][kind.id] = now
                            lists[kind.id] = []
                        }
                    }
                }
                var forRule = 0
                for f in RiggingEngine.findings(of: rule, pack: pack, objects: lists[kind.id] ?? [], cluster: session.config.name) {
                    guard forRule < Self.itemsPerRule, packItems < Self.itemsPerPack else { dropped += 1; continue }
                    forRule += 1
                    packItems += 1
                    items.append(AttentionItem(id: "rigging/\(pack.metadata.name)/\(session.id)/\(kind.id)/\(f.namespace ?? "-")/\(f.name)/\(rule.id)", clusterID: session.id,
                                               severity: f.tone == .critical && builtIn ? .critical : .warning, kind: .riggingRule, title: "\(pack.metadata.name): \(f.message)",
                                               detail: "\(pack.metadata.name) pack · \(f.kind) \(f.namespace.map { "\($0)/" } ?? "")\(f.name)",
                                               resource: ResourceRef(clusterID: session.id, kind: kind, namespace: f.namespace, name: f.name), since: f.since))
                }
            }
            if dropped > 0 {
                items.append(AttentionItem(id: "rigging/\(pack.metadata.name)/\(session.id)/more", clusterID: session.id, severity: .warning, kind: .riggingRule,
                                           title: "\(pack.metadata.name): and \(dropped) more", detail: "\(pack.metadata.name) pack · the first \(Self.itemsPerPack) are listed", resource: nil, since: nil))
            }
        }
        if complete, !Task.isCancelled, revision == store.revision { healthCache[session.id] = (Date(), revision, items) }
        return items
    }
}

/// The sidebar's view of pack layouts (Custom Resources sub-groups): a closure the runtime fills at start, empty before and on iOS.
@MainActor
enum RiggingSidebarHook {
    static var layouts: () -> [String: (title: String?, order: [String])] = { [:] }
    static var views: () -> [String: (pack: String, view: String)] = { [:] }
}

/// The ConfirmSheet request of a pack's port-forward. The sheet carries the `.rigging(pack:)` origin, so it is badged, has no default
/// button, ignores input for a moment, and on Production needs the service name typed.
@MainActor
enum RiggingConfirmations {
    static func portForward(plan: PortForwardPlan, pack: String, title: String, cluster: ClusterConfig, session: ClusterSession, activity: any ActivityLogging) -> ConfirmRequest {
        let target = plan.target
        let preferred = target.remotePort
        let used = Set(SessionsHub.shared.forwards.filter { $0.state.isLive }.map(\.localPort))
        let local = LocalPort.suggest(preferred: preferred, excluding: used)
        var facts: [ConfirmRequest.Fact] = [.init("Pack", pack), .init("Local address", "127.0.0.1:\(local)")]
        if let url = plan.openURL(localPort: local) { facts.append(.init("Then opens", url.absoluteString)) }
        let object = target.title
        return ConfirmRequest(
            title: title, message: "The “\(pack)” pack asks to open a tunnel from this Mac to \(object) in \(target.namespace). Anything listening there becomes reachable at 127.0.0.1:\(local).",
            verb: "Start Forwarding", cluster: cluster, namespace: target.namespace, resource: object, confirmationText: target.name, facts: facts, isDisruptive: true,
            origin: .rigging(pack: pack),
            dryRun: {
                switch await SessionAccessCheck.canCreate(session.client, namespace: target.namespace, pod: target.kind == .pod ? target.name : nil, subresource: "portforward") {
                case .allowed: .passed("Access review: you can create pods/portforward here.")
                case .denied(let why): .failed(why)
                case .unknown(let why): .passed("Could not verify access (\(why)).")
                }
            },
            action: {
                do {
                    let info = try await SessionsHub.shared.startForward(session: session, target: target, localPort: local)
                    activity.record(ActivityEntry(cluster: cluster.id, origin: .rigging(pack: pack), verb: "port-forward", object: object, result: "ok"))
                    if let url = plan.openURL(localPort: info.localPort) { NSWorkspace.shared.open(url) }
                } catch {
                    activity.record(ActivityEntry(cluster: cluster.id, origin: .rigging(pack: pack), verb: "port-forward", object: object, result: "failed: \(error.localizedDescription)"))
                    throw error
                }
            })
    }
}
