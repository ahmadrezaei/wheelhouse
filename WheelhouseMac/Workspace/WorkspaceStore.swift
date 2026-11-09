import Foundation
import Observation
import WheelhouseKit

/// App-global workspace state, persisted to `Application Support/Wheelhouse/workspace.json` (ARCHITECTURE-MAC section 12.2):
/// every window with its tabs and pane tree, panes torn off into their own windows, Stations and the Rail (opaque until M4b).
///
/// Only destinations and contexts are stored, never data or credentials. The file is decoded node by node (``WorkspaceFile``), so
/// one pane that cannot be read becomes a placeholder and is written back unchanged; a file that cannot be read at all is moved
/// aside (`workspace.corrupt-<date>.json`) and the app starts with a fresh window. Saving is debounced (1 s), skipped when nothing
/// changed, and flushed on quit. With no `file` (performance scenarios, UI tests that reset state) nothing is read or written.
@MainActor @Observable
final class WorkspaceStore {
    static let saveDelay: Duration = .seconds(1)

    private(set) var windows: [WorkspaceWindowID: WorkspaceWindowState] = [:]
    /// Window order of the file (the order they were opened).
    private(set) var windowOrder: [WorkspaceWindowID] = []
    private(set) var detached: [PaneID: DetachedEntry] = [:]
    private(set) var stations: [Station] = []
    private(set) var rail: [JSONValue] = []
    /// True while the app terminates: window closes during quit must not delete state.
    var isTerminating = false

    /// Windows that exist right now (not persisted).
    @ObservationIgnored private(set) var liveWindows: Set<WorkspaceWindowID> = []
    @ObservationIgnored private(set) var liveDetached: Set<PaneID> = []
    /// Windows to reopen after launch: the first becomes the launch window, the rest open once it exists.
    @ObservationIgnored private var launchQueue: [WorkspaceWindowID] = []
    @ObservationIgnored private var detachedQueue: [PaneID] = []
    @ObservationIgnored private let file: URL?
    @ObservationIgnored private(set) var writesDisabled = false
    @ObservationIgnored private var lastWritten: Data?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let now: @Sendable () -> Date
    /// Set when a file could not be read: where it was moved (for the UI to mention).
    @ObservationIgnored private(set) var movedAsideCorruptFile: URL?
    @ObservationIgnored private(set) var writeCount = 0

    init(file: URL?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
        load()
    }

    // MARK: Loading

    private func load() {
        guard let file, let data = try? Data(contentsOf: file) else {
            installBuiltIns()
            return
        }
        do {
            let decoded = try JSONDecoder().decode(WorkspaceFile.self, from: data)
            // A file written by a newer build may hold fields this one does not know: it is read, never overwritten.
            writesDisabled = decoded.version > WorkspaceFile.currentVersion
            apply(decoded)
            lastWritten = nil
        } catch {
            let stamp = ISO8601DateFormatter().string(from: now()).replacingOccurrences(of: ":", with: "-")
            let aside = file.deletingLastPathComponent().appending(path: "workspace.corrupt-\(stamp).json")
            if (try? FileManager.default.moveItem(at: file, to: aside)) != nil { movedAsideCorruptFile = aside }
            installBuiltIns()
        }
    }

    private func apply(_ f: WorkspaceFile) {
        windowOrder = f.windows.map(\.id)
        windows = Dictionary(f.windows.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
        windowOrder = windowOrder.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        detached = Dictionary(f.detached.map { ($0.pane.id, $0) }, uniquingKeysWith: { first, _ in first })
        stations = f.stations
        rail = f.rail
        launchQueue = windowOrder
        detachedQueue = f.detached.map(\.pane.id)
        detachedOrder = detachedQueue
        installBuiltIns()
    }

    /// The template Stations that ship with the app (DESIGN-MAC section 6.5). They are not stored in the file.
    private func installBuiltIns() {
        stations.removeAll { $0.isBuiltIn }
        stations.insert(contentsOf: BuiltInStations.all, at: 0)
    }

    // MARK: Saving

    var snapshot: WorkspaceFile {
        var f = WorkspaceFile()
        f.windows = windowOrder.compactMap { id in windows[id].map { WindowEntry(id: id, state: $0) } }
        f.detached = detachedOrder.compactMap { detached[$0] }
        f.stations = stations.filter { !$0.isBuiltIn }
        f.rail = rail
        return f
    }

    @ObservationIgnored private var detachedOrder: [PaneID] = []

    /// Schedules a save one second after the last structural change.
    func scheduleSave() {
        guard file != nil else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: Self.saveDelay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// Writes the file now (quit, tests). Nothing is written when the bytes are the same as the last write.
    func flush() {
        saveTask?.cancel(); saveTask = nil
        guard let file, !writesDisabled else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(snapshot), data != lastWritten else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? data.write(to: file, options: .atomic)) != nil {
            lastWritten = data
            writeCount += 1
        }
    }

    // MARK: Window lifecycle

    /// The window to open at launch (the SwiftUI `defaultValue`): the first saved window, else a new one. The answer is kept until
    /// that window appears, so SwiftUI asking twice never creates a second window.
    func launchWindowID() -> WorkspaceWindowID {
        if let pending = pendingLaunch, !liveWindows.contains(pending), windows[pending] != nil { return pending }
        let id: WorkspaceWindowID
        if !launchQueue.isEmpty { id = launchQueue.removeFirst() }
        else if let saved = windowOrder.first(where: { !liveWindows.contains($0) }) { id = saved }
        else { id = createWindow() }
        pendingLaunch = id
        return id
    }

    @ObservationIgnored private var pendingLaunch: WorkspaceWindowID?

    /// Windows saved by the last run that have not been opened yet; call once the first window exists.
    func takeRestorableWindows() -> (windows: [WorkspaceWindowID], panes: [PaneID]) {
        defer { launchQueue = []; detachedQueue = [] }
        return (launchQueue.filter { !liveWindows.contains($0) }, detachedQueue.filter { !liveDetached.contains($0) })
    }

    @discardableResult
    func createWindow(_ state: WorkspaceWindowState = .fresh()) -> WorkspaceWindowID {
        let id = WorkspaceWindowID.new()
        windows[id] = state
        windowOrder.append(id)
        scheduleSave()
        return id
    }

    /// The state of a window. A pure read: it never creates anything (a closed window whose view body runs once more must not come
    /// back). Unknown or closed identifiers read as a fresh, unsaved window.
    func state(for id: WorkspaceWindowID) -> WorkspaceWindowState { windows[id] ?? .fresh() }

    /// Makes sure a window the scenes ask for has a state (a restored identifier the file does not know), unless it was closed.
    func ensureWindow(_ id: WorkspaceWindowID) {
        guard windows[id] == nil, !closedWindows.contains(id) else { return }
        windows[id] = .fresh()
        windowOrder.append(id)
        scheduleSave()
    }

    func isClosed(_ id: WorkspaceWindowID) -> Bool { closedWindows.contains(id) }
    @ObservationIgnored private var closedWindows: Set<WorkspaceWindowID> = []

    func windowAppeared(_ id: WorkspaceWindowID) {
        guard !closedWindows.contains(id) else { return }
        liveWindows.insert(id)
        if pendingLaunch == id { pendingLaunch = nil }
    }

    /// A window closed. Its state is removed unless the app is quitting or it was the last workspace window (closing the last
    /// window quits the app, and the workspace must survive that).
    func windowClosed(_ id: WorkspaceWindowID) {
        let wasLast = liveWindows == [id] && liveDetached.isEmpty
        liveWindows.remove(id)
        guard !isTerminating, !wasLast else { return }
        closedWindows.insert(id)
        windows[id] = nil
        windowOrder.removeAll { $0 == id }
        scheduleSave()
    }

    func detachedAppeared(_ id: PaneID) { liveDetached.insert(id) }

    func detachedClosed(_ id: PaneID) {
        let wasLast = liveDetached == [id] && liveWindows.isEmpty
        liveDetached.remove(id)
        guard !isTerminating, !wasLast else { return }
        detached[id] = nil
        detachedOrder.removeAll { $0 == id }
        scheduleSave()
    }

    // MARK: Mutations

    /// Applies `change` to a window's state and schedules a save when something changed.
    @discardableResult
    func mutate<T>(_ id: WorkspaceWindowID, _ change: (inout WorkspaceWindowState) -> T) -> T {
        guard var state = windows[id] else { var scratch = WorkspaceWindowState.fresh(); return change(&scratch) }
        let result = change(&state)
        if windows[id] != state {
            windows[id] = state
            scheduleSave()
        }
        return result
    }

    func setFrame(_ frame: [Double], for id: WorkspaceWindowID) {
        guard windows[id]?.frame != frame else { return }
        windows[id]?.frame = frame
        scheduleSave()
    }

    // MARK: Detached panes

    func detach(_ pane: PaneState, frame: [Double]? = nil) {
        detached[pane.id] = DetachedEntry(pane: pane, frame: frame)
        detachedOrder.append(pane.id)
        scheduleSave()
    }

    func detachedPane(_ id: PaneID) -> PaneState? { detached[id]?.pane }

    func mutateDetachedFrame(_ id: PaneID, _ frame: [Double]) {
        guard detached[id] != nil, detached[id]?.frame != frame else { return }
        detached[id]?.frame = frame
        scheduleSave()
    }

    func mutateDetached(_ id: PaneID, _ change: (inout PaneState) -> Void) {
        guard var entry = detached[id] else { return }
        change(&entry.pane)
        detached[id] = entry
        scheduleSave()
    }

    /// Takes a detached pane back (re-attach): its window closes and its state is returned.
    func takeDetached(_ id: PaneID) -> PaneState? {
        guard let entry = detached.removeValue(forKey: id) else { return nil }
        detachedOrder.removeAll { $0 == id }
        scheduleSave()
        return entry.pane
    }

    // MARK: Stations

    /// Saves the tabs of a window as a Station. `bindToClusters` false makes a template: each distinct cluster becomes a placeholder.
    @discardableResult
    func saveStation(named name: String, from window: WorkspaceWindowState, bindToClusters: Bool) -> Station {
        var tabs = window.tabs.filter { $0.raw == nil }.map { tab -> TabState in
            var copy = tab
            copy.zoomedPane = nil
            return copy
        }
        if tabs.isEmpty { tabs = [TabState(showing: .route(.fleet))] }
        // A saved layout gets its own identifiers, so opening it never collides with the window it came from.
        tabs = tabs.map(Self.freshIdentifiers)
        var selected = tabs[0].id
        if let index = window.tabs.filter({ $0.raw == nil }).firstIndex(where: { $0.id == window.selectedTab }), tabs.indices.contains(index) { selected = tabs[index].id }
        if !bindToClusters {
            var order: [ClusterID] = []
            for tab in tabs { for id in tab.clusterIDs where !order.contains(id) { order.append(id) } }
            let map = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, Station.placeholder(at: $0.offset)) })
            tabs = tabs.map { $0.replacingClusters { map[$0] ?? $0 } }
        }
        let station = Station(name: name, isTemplate: !bindToClusters, tabs: tabs, selectedTab: selected)
        stations.append(station)
        scheduleSave()
        return station
    }

    func renameStation(_ id: StationID, to name: String) {
        guard let i = stations.firstIndex(where: { $0.id == id }), !stations[i].isBuiltIn else { return }
        stations[i].name = name
        scheduleSave()
    }

    func deleteStation(_ id: StationID) {
        guard stations.contains(where: { $0.id == id && !$0.isBuiltIn }) else { return }
        stations.removeAll { $0.id == id }
        scheduleSave()
    }

    @discardableResult
    func duplicateStation(_ id: StationID) -> Station? {
        guard let source = stations.first(where: { $0.id == id }), source.raw == nil else { return nil }
        var copy = source
        copy.id = StationID(rawValue: UUID().uuidString)
        copy.name = source.name + " Copy"
        copy.isBuiltIn = false
        copy.tabs = copy.tabs.map(Self.freshIdentifiers)
        copy.selectedTab = copy.tabs[0].id
        stations.append(copy)
        scheduleSave()
        return copy
    }

    /// The window state a Station opens as. `clusters` answers each placeholder of a template (placeholder → real cluster).
    func instantiate(_ station: Station, clusters: [ClusterID: ClusterID] = [:]) -> WorkspaceWindowState {
        var tabs = station.tabs.filter { $0.raw == nil }
        if tabs.isEmpty { tabs = [TabState(showing: .route(.fleet))] }
        let selectedIndex = station.tabs.filter { $0.raw == nil }.firstIndex { $0.id == station.selectedTab } ?? 0
        tabs = tabs.map { Self.freshIdentifiers($0.replacingClusters { clusters[$0] ?? $0 }) }
        return WorkspaceWindowState(tabs: tabs, selectedTab: tabs[min(selectedIndex, tabs.count - 1)].id)
    }

    /// Same layout with new tab and pane identifiers (links follow).
    static func freshIdentifiers(_ tab: TabState) -> TabState {
        var map: [PaneID: PaneID] = [:]
        for pane in tab.panes { map[pane.id] = .new() }
        var copy = tab
        copy.id = .new()
        copy.root = tab.root.mapPanes { pane in
            var p = pane
            p.id = map[pane.id] ?? pane.id
            p.link = pane.link.flatMap { map[$0] }
            return p
        }
        copy.focusedPane = map[tab.focusedPane] ?? copy.root.firstPane.id
        copy.zoomedPane = nil
        return copy
    }
}

extension Station {
    static func placeholder(at index: Int) -> ClusterID { index == 0 ? placeholderPrefix : "\(placeholderPrefix)\(index + 1)" }

    /// The placeholders a template needs answered, in order.
    var placeholders: [ClusterID] {
        var seen: [ClusterID] = []
        for tab in tabs { for id in tab.clusterIDs where id.hasPrefix(Station.placeholderPrefix) && !seen.contains(id) { seen.append(id) } }
        return seen
    }
}

/// Triage, Release and Node work (DESIGN-MAC section 6.5).
enum BuiltInStations {
    static let all: [Station] = [triage, release, nodeWork]

    private static let c = Station.placeholder(at: 0)

    private static func make(_ id: String, _ name: String, _ root: PaneNode) -> Station {
        let tab = TabState(root: root)
        return Station(id: StationID(rawValue: "builtin.\(id)"), name: name, isTemplate: true, tabs: [tab], isBuiltIn: true)
    }

    /// Pods table, logs linked to it, events, First Mate.
    static var triage: Station {
        let pods = PaneState(showing: .route(.resourceList(c, .pod, namespace: nil)))
        var logs = PaneState(context: PaneContext(clusterID: c), stack: [])
        logs.link = pods.id
        logs.linkedView = .logs
        let events = PaneState(showing: .route(.resourceList(c, .event, namespace: nil)))
        let mate = PaneState(showing: .firstMate("triage"), context: PaneContext(clusterID: c))
        let left = PaneNode.split(axis: .vertical, fraction: 0.5, first: .leaf(pods), second: .leaf(logs))
        let right = PaneNode.split(axis: .vertical, fraction: 0.5, first: .leaf(events), second: .leaf(mate))
        return make("triage", "Triage", .split(axis: .horizontal, fraction: 0.55, first: left, second: right))
    }

    /// Chart Room release, rollout status, Deck Terminal.
    static var release: Station {
        let chart = PaneState(showing: .chartRoom(c, .releases))
        let rollout = PaneState(showing: .route(.resourceList(c, .deployment, namespace: nil)))
        let terminal = PaneState(showing: .deckTerminal(TerminalSpec(clusterID: c)), context: PaneContext(clusterID: c))
        let top = PaneNode.split(axis: .horizontal, fraction: 0.5, first: .leaf(chart), second: .leaf(rollout))
        return make("release", "Release", .split(axis: .vertical, fraction: 0.6, first: top, second: .leaf(terminal)))
    }

    /// Nodes table, node detail linked, pods.
    static var nodeWork: Station {
        let nodes = PaneState(showing: .route(.resourceList(c, .node, namespace: nil)))
        var detail = PaneState(context: PaneContext(clusterID: c), stack: [])
        detail.link = nodes.id
        detail.linkedView = .detail
        let pods = PaneState(showing: .route(.resourceList(c, .pod, namespace: nil)))
        let left = PaneNode.split(axis: .vertical, fraction: 0.5, first: .leaf(nodes), second: .leaf(detail))
        return make("node-work", "Node work", .split(axis: .horizontal, fraction: 0.5, first: left, second: .leaf(pods)))
    }
}
