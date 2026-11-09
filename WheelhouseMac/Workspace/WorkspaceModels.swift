import Foundation
import WheelhouseKit

// The persisted workspace model (ARCHITECTURE-MAC section 12.2). Only destinations and contexts are stored, never data or
// credentials. Decoding is lossy per pane (and per tab, window and Station): whatever cannot be decoded keeps its raw JSON in a
// placeholder and is written back unchanged until the user closes it.

// MARK: Identifiers

struct WorkspaceWindowID: Codable, Hashable, Sendable, RawRepresentable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func new() -> WorkspaceWindowID { WorkspaceWindowID(rawValue: UUID().uuidString) }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

struct TabID: Codable, Hashable, Sendable, RawRepresentable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func new() -> TabID { TabID(rawValue: UUID().uuidString) }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

struct PaneID: Codable, Hashable, Sendable, RawRepresentable {
    var rawValue: String
    init(rawValue: String) { self.rawValue = rawValue }
    static func new() -> PaneID { PaneID(rawValue: UUID().uuidString) }
    init(from decoder: Decoder) throws { rawValue = try decoder.singleValueContainer().decode(String.self) }
    func encode(to encoder: Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(rawValue) }
}

// MARK: Pane

/// The scope of one pane (DESIGN-MAC section 3.2): a cluster and a namespace (nil = All).
struct PaneContext: Codable, Hashable, Sendable {
    var clusterID: ClusterID?
    var namespace: String?
}

/// How a linked pane shows the selection of its source: the same detail route, or the pod's logs.
enum LinkedView: String, Codable, Hashable, Sendable { case detail, logs }

struct PaneState: Codable, Hashable, Sendable {
    var id: PaneID
    var context: PaneContext
    /// Root plus pushed destinations. Empty is an empty pane (a fresh linked pane before its first selection).
    var stack: [WorkspaceDestination]
    /// The pane whose selection this pane follows (same tab).
    var link: PaneID?
    var linkedView: LinkedView?
    /// Set when the pane could not be decoded: the JSON exactly as it was read. A pane with `raw` is a placeholder
    /// ("This pane couldn't be restored") and encodes as that JSON, unchanged.
    var raw: JSONValue?

    init(id: PaneID = .new(), context: PaneContext = PaneContext(), stack: [WorkspaceDestination] = [], link: PaneID? = nil, linkedView: LinkedView? = nil) {
        self.id = id
        self.context = context
        self.stack = stack
        self.link = link
        self.linkedView = linkedView
    }

    /// A pane showing one destination, in the cluster that destination belongs to (or `context`).
    init(showing destination: WorkspaceDestination, context: PaneContext? = nil) {
        self.init(context: context ?? PaneContext(clusterID: destination.clusterID), stack: [destination])
    }

    static func placeholder(raw: JSONValue) -> PaneState {
        var pane = PaneState()
        if case .object(let o) = raw, let id = o["id"]?.stringValue { pane.id = PaneID(rawValue: id) }
        pane.raw = raw
        return pane
    }

    var isPlaceholder: Bool { raw != nil }
    var root: WorkspaceDestination? { stack.first }
    var top: WorkspaceDestination? { stack.last }

    private enum CodingKeys: String, CodingKey { case id, context, stack, link, linkedView }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(PaneID.self, forKey: .id)
        context = try c.decodeIfPresent(PaneContext.self, forKey: .context) ?? PaneContext()
        stack = try c.decode([WorkspaceDestination].self, forKey: .stack)
        link = try c.decodeIfPresent(PaneID.self, forKey: .link)
        linkedView = try c.decodeIfPresent(LinkedView.self, forKey: .linkedView)
    }

    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(context, forKey: .context)
        try c.encode(stack, forKey: .stack)
        try c.encodeIfPresent(link, forKey: .link)
        try c.encodeIfPresent(linkedView, forKey: .linkedView)
    }
}

// MARK: Tree

enum SplitAxis: String, Codable, Hashable, Sendable {
    /// Panes side by side (a vertical divider).
    case horizontal
    /// Panes stacked (a horizontal divider).
    case vertical
}

enum MoveDirection: String, Codable, Hashable, Sendable, CaseIterable { case left, right, up, down }

/// Where a dragged pane lands on a target pane (DESIGN-MAC section 6.5).
enum DropZone: String, Hashable, Sendable, CaseIterable { case left, right, top, bottom, center }

indirect enum PaneNode: Codable, Hashable, Sendable {
    case leaf(PaneState)
    case split(axis: SplitAxis, fraction: Double, first: PaneNode, second: PaneNode)

    private enum CodingKeys: String, CodingKey { case leaf, split }
    private enum SplitKeys: String, CodingKey { case axis, fraction, first, second }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if c.contains(.leaf) {
            let inner = try c.superDecoder(forKey: .leaf)
            if let pane = try? PaneState(from: inner) {
                self = .leaf(pane)
            } else {
                self = .leaf(.placeholder(raw: try JSONValue(from: inner)))
            }
        } else if c.contains(.split) {
            let s = try c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            self = .split(axis: try s.decode(SplitAxis.self, forKey: .axis), fraction: try s.decode(Double.self, forKey: .fraction),
                          first: try s.decode(PaneNode.self, forKey: .first), second: try s.decode(PaneNode.self, forKey: .second))
        } else {
            throw DecodingError.dataCorruptedError(forKey: .leaf, in: c, debugDescription: "Neither leaf nor split")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .leaf(let pane): try c.encode(pane, forKey: .leaf)
        case .split(let axis, let fraction, let first, let second):
            var s = c.nestedContainer(keyedBy: SplitKeys.self, forKey: .split)
            try s.encode(axis, forKey: .axis)
            try s.encode(fraction, forKey: .fraction)
            try s.encode(first, forKey: .first)
            try s.encode(second, forKey: .second)
        }
    }
}

extension PaneNode {
    static let minimumFraction = 0.1

    var leaves: [PaneState] {
        switch self {
        case .leaf(let p): [p]
        case .split(_, _, let a, let b): a.leaves + b.leaves
        }
    }

    var paneIDs: [PaneID] { leaves.map(\.id) }
    var firstPane: PaneState { leaves[0] }
    func pane(_ id: PaneID) -> PaneState? { leaves.first { $0.id == id } }

    /// Rewrites every leaf.
    func mapPanes(_ transform: (PaneState) -> PaneState) -> PaneNode {
        switch self {
        case .leaf(let p): .leaf(transform(p))
        case .split(let axis, let f, let a, let b): .split(axis: axis, fraction: f, first: a.mapPanes(transform), second: b.mapPanes(transform))
        }
    }

    func updating(pane id: PaneID, _ change: (inout PaneState) -> Void) -> PaneNode {
        mapPanes { p in
            guard p.id == id else { return p }
            var copy = p
            change(&copy)
            return copy
        }
    }

    /// The tree without `id` (its sibling takes the space), or nil when `id` was the only pane.
    func removing(pane id: PaneID) -> PaneNode? {
        switch self {
        case .leaf(let p): return p.id == id ? nil : self
        case .split(let axis, let f, let a, let b):
            let na = a.removing(pane: id), nb = b.removing(pane: id)
            switch (na, nb) {
            case (nil, nil): return nil
            case (nil, let only?), (let only?, nil): return only
            case (let x?, let y?): return .split(axis: axis, fraction: f, first: x, second: y)
            }
        }
    }

    /// `pane` placed next to `target` on the given side (`center` replaces the target).
    func inserting(_ pane: PaneState, at target: PaneID, zone: DropZone) -> PaneNode {
        switch self {
        case .leaf(let p):
            guard p.id == target else { return self }
            switch zone {
            case .center: return .leaf(pane)
            case .left: return .split(axis: .horizontal, fraction: 0.5, first: .leaf(pane), second: self)
            case .right: return .split(axis: .horizontal, fraction: 0.5, first: self, second: .leaf(pane))
            case .top: return .split(axis: .vertical, fraction: 0.5, first: .leaf(pane), second: self)
            case .bottom: return .split(axis: .vertical, fraction: 0.5, first: self, second: .leaf(pane))
            }
        case .split(let axis, let f, let a, let b):
            return .split(axis: axis, fraction: f, first: a.inserting(pane, at: target, zone: zone), second: b.inserting(pane, at: target, zone: zone))
        }
    }

    /// `pane` placed on the outer edge of the whole tree (Move ▸ Left/Right/Up/Down).
    func wrapping(_ pane: PaneState, direction: MoveDirection) -> PaneNode {
        switch direction {
        case .left: .split(axis: .horizontal, fraction: 0.33, first: .leaf(pane), second: self)
        case .right: .split(axis: .horizontal, fraction: 0.67, first: self, second: .leaf(pane))
        case .up: .split(axis: .vertical, fraction: 0.33, first: .leaf(pane), second: self)
        case .down: .split(axis: .vertical, fraction: 0.67, first: self, second: .leaf(pane))
        }
    }

    /// Splits `target`: a new pane after it.
    func splitting(_ target: PaneID, axis: SplitAxis, inserting pane: PaneState) -> PaneNode {
        inserting(pane, at: target, zone: axis == .horizontal ? .right : .bottom)
    }

    /// Changes the fraction of the split at `path` (0 = first, 1 = second at each level).
    func settingFraction(_ fraction: Double, at path: [Int]) -> PaneNode {
        guard case .split(let axis, let f, let a, let b) = self else { return self }
        let clamped = min(max(fraction, Self.minimumFraction), 1 - Self.minimumFraction)
        guard let step = path.first else { return .split(axis: axis, fraction: clamped, first: a, second: b) }
        let rest = Array(path.dropFirst())
        return step == 0 ? .split(axis: axis, fraction: f, first: a.settingFraction(fraction, at: rest), second: b)
                         : .split(axis: axis, fraction: f, first: a, second: b.settingFraction(fraction, at: rest))
    }

    /// Unit-square rectangles of the leaves (x, y, width, height), for keyboard focus movement.
    func layout(in rect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [(id: PaneID, rect: CGRect)] {
        switch self {
        case .leaf(let p): return [(p.id, rect)]
        case .split(let axis, let f, let a, let b):
            if axis == .horizontal {
                let w = rect.width * f
                return a.layout(in: CGRect(x: rect.minX, y: rect.minY, width: w, height: rect.height)) + b.layout(in: CGRect(x: rect.minX + w, y: rect.minY, width: rect.width - w, height: rect.height))
            }
            let h = rect.height * f
            return a.layout(in: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: h)) + b.layout(in: CGRect(x: rect.minX, y: rect.minY + h, width: rect.width, height: rect.height - h))
        }
    }

    /// The pane next to `id` in `direction`, by geometry (the nearest whose span overlaps).
    func neighbour(of id: PaneID, _ direction: MoveDirection) -> PaneID? {
        let all = layout()
        guard let me = all.first(where: { $0.id == id })?.rect else { return nil }
        let candidates = all.filter { other in
            guard other.id != id else { return false }
            let r = other.rect
            switch direction {
            case .left: return r.maxX <= me.minX + 1e-9 && r.maxY > me.minY + 1e-9 && r.minY < me.maxY - 1e-9
            case .right: return r.minX >= me.maxX - 1e-9 && r.maxY > me.minY + 1e-9 && r.minY < me.maxY - 1e-9
            case .up: return r.maxY <= me.minY + 1e-9 && r.maxX > me.minX + 1e-9 && r.minX < me.maxX - 1e-9
            case .down: return r.minY >= me.maxY - 1e-9 && r.maxX > me.minX + 1e-9 && r.minX < me.maxX - 1e-9
            }
        }
        func distance(_ r: CGRect) -> CGFloat {
            switch direction {
            case .left: me.minX - r.maxX
            case .right: r.minX - me.maxX
            case .up: me.minY - r.maxY
            case .down: r.minY - me.maxY
            }
        }
        return candidates.min { distance($0.rect) < distance($1.rect) }?.id
    }
}

// MARK: Tabs and windows

struct TabState: Codable, Hashable, Sendable {
    var id: TabID
    var root: PaneNode
    var focusedPane: PaneID
    /// The pane zoomed to fill the tab (⇧⌘↩), if any. Not restored across launches.
    var zoomedPane: PaneID?
    /// Set when the whole tab could not be decoded: its JSON, written back unchanged until its placeholder pane is closed.
    var raw: JSONValue?

    init(id: TabID = .new(), root: PaneNode, focusedPane: PaneID? = nil) {
        self.id = id
        self.root = root
        self.focusedPane = focusedPane ?? root.firstPane.id
    }

    init(showing destination: WorkspaceDestination, context: PaneContext? = nil) {
        self.init(root: .leaf(PaneState(showing: destination, context: context)))
    }

    static func placeholder(raw: JSONValue) -> TabState {
        let pane = PaneState.placeholder(raw: raw)
        var tab = TabState(root: .leaf(pane), focusedPane: pane.id)
        if case .object(let o) = raw, let id = o["id"]?.stringValue { tab.id = TabID(rawValue: id) }
        tab.raw = raw
        return tab
    }

    private enum CodingKeys: String, CodingKey { case id, root, focusedPane }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(TabID.self, forKey: .id)
        let tree = try c.decode(PaneNode.self, forKey: .root)
        root = tree
        let focused = try c.decodeIfPresent(PaneID.self, forKey: .focusedPane)
        // A focus that points at a pane that no longer exists falls back to the first pane.
        focusedPane = focused.flatMap { f in tree.pane(f) != nil ? f : nil } ?? tree.firstPane.id
    }

    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(root, forKey: .root)
        try c.encode(focusedPane, forKey: .focusedPane)
    }

    var panes: [PaneState] { root.leaves }
    var focused: PaneState? { root.pane(focusedPane) }
}

struct InspectorState: Codable, Hashable, Sendable {
    enum Segment: String, Codable, Hashable, Sendable { case details, events, firstMate }
    var isOpen = false
    var width: Double?
    var segment: Segment = .details
}

struct WorkspaceWindowState: Codable, Hashable, Sendable {
    var tabs: [TabState]
    var selectedTab: TabID
    var sidebarWidth: Double
    var inspector: InspectorState
    var sidebar: SidebarState
    /// Window frame (x, y, width, height) so a relaunch puts the window back.
    var frame: [Double]?
    var raw: JSONValue?

    init(tabs: [TabState], selectedTab: TabID? = nil, sidebarWidth: Double = 248, inspector: InspectorState = InspectorState(),
         sidebar: SidebarState = SidebarState(), frame: [Double]? = nil) {
        self.tabs = tabs
        self.selectedTab = selectedTab ?? tabs[0].id
        self.sidebarWidth = sidebarWidth
        self.inspector = inspector
        self.sidebar = sidebar
        self.frame = frame
    }

    /// A fresh window: one tab with the Fleet.
    static func fresh() -> WorkspaceWindowState { WorkspaceWindowState(tabs: [TabState(showing: .route(.fleet))]) }

    static func placeholder(raw: JSONValue) -> WorkspaceWindowState {
        var state = WorkspaceWindowState(tabs: [TabState.placeholder(raw: raw)])
        state.raw = raw
        return state
    }

    private enum CodingKeys: String, CodingKey { case tabs, selectedTab, sidebarWidth, inspector, sidebar, frame }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var tabs: [TabState] = []
        var list = try c.nestedUnkeyedContainer(forKey: .tabs)
        while !list.isAtEnd {
            let inner = try list.superDecoder()
            if let tab = try? TabState(from: inner) { tabs.append(tab) } else { tabs.append(.placeholder(raw: try JSONValue(from: inner))) }
        }
        guard !tabs.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .tabs, in: c, debugDescription: "A window needs a tab") }
        self.tabs = tabs
        let selected = try c.decodeIfPresent(TabID.self, forKey: .selectedTab)
        selectedTab = selected.flatMap { s in tabs.contains { $0.id == s } ? s : nil } ?? tabs[0].id
        sidebarWidth = try c.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 248
        inspector = (try? c.decode(InspectorState.self, forKey: .inspector)) ?? InspectorState()
        sidebar = (try? c.decode(SidebarState.self, forKey: .sidebar)) ?? SidebarState()
        frame = try? c.decodeIfPresent([Double].self, forKey: .frame)
    }

    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(selectedTab, forKey: .selectedTab)
        try c.encode(sidebarWidth, forKey: .sidebarWidth)
        try c.encode(inspector, forKey: .inspector)
        try c.encode(sidebar, forKey: .sidebar)
        try c.encodeIfPresent(frame, forKey: .frame)
    }
}

/// Per-window sidebar state (ARCHITECTURE-MAC section 12.5): disclosure per cluster, Keep Expanded and Show Forbidden Kinds.
struct SidebarState: Codable, Hashable, Sendable {
    var expandedClusters: [ClusterID] = []
    var keepExpanded: [ClusterID] = []
    var expandedGroups: [String] = []
    var showsForbiddenKinds = false
}

// MARK: Stations and the file

/// A saved layout (DESIGN-MAC section 6.5). A template keeps cluster placeholders instead of cluster IDs.
struct Station: Codable, Hashable, Sendable, Identifiable {
    /// The cluster placeholders of a template: `$cluster`, `$cluster2`, … (never a real cluster ID).
    static let placeholderPrefix = "$cluster"

    var id: StationID
    var name: String
    /// True for a template: opening it asks for a cluster for each placeholder.
    var isTemplate: Bool
    var tabs: [TabState]
    var selectedTab: TabID
    var isBuiltIn: Bool
    var raw: JSONValue?

    init(id: StationID = StationID(rawValue: UUID().uuidString), name: String, isTemplate: Bool, tabs: [TabState], selectedTab: TabID? = nil, isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.isTemplate = isTemplate
        self.tabs = tabs
        self.selectedTab = selectedTab ?? tabs[0].id
        self.isBuiltIn = isBuiltIn
    }

    static func placeholder(raw: JSONValue) -> Station {
        var id = StationID(rawValue: UUID().uuidString)
        if case .object(let o) = raw, let s = o["id"]?.stringValue { id = StationID(rawValue: s) }
        var station = Station(id: id, name: "Station that couldn't be read", isTemplate: false, tabs: [TabState.placeholder(raw: raw)])
        station.raw = raw
        return station
    }

    private enum CodingKeys: String, CodingKey { case id, name, isTemplate, tabs, selectedTab }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(StationID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        isTemplate = try c.decodeIfPresent(Bool.self, forKey: .isTemplate) ?? false
        var tabs: [TabState] = []
        var list = try c.nestedUnkeyedContainer(forKey: .tabs)
        while !list.isAtEnd {
            let inner = try list.superDecoder()
            if let tab = try? TabState(from: inner) { tabs.append(tab) } else { tabs.append(.placeholder(raw: try JSONValue(from: inner))) }
        }
        guard !tabs.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .tabs, in: c, debugDescription: "A Station needs a tab") }
        self.tabs = tabs
        selectedTab = (try c.decodeIfPresent(TabID.self, forKey: .selectedTab)).flatMap { s in tabs.contains { $0.id == s } ? s : nil } ?? tabs[0].id
        isBuiltIn = false
    }

    func encode(to encoder: Encoder) throws {
        if let raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(isTemplate, forKey: .isTemplate)
        try c.encode(tabs, forKey: .tabs)
        try c.encode(selectedTab, forKey: .selectedTab)
    }
}

/// A window of the file: its identifier and state.
struct WindowEntry: Codable, Hashable, Sendable {
    var id: WorkspaceWindowID
    var state: WorkspaceWindowState
}

/// A pane torn off into its own window.
struct DetachedEntry: Codable, Hashable, Sendable {
    var pane: PaneState
    var frame: [Double]?

    init(pane: PaneState, frame: [Double]? = nil) {
        self.pane = pane
        self.frame = frame
    }

    private enum CodingKeys: String, CodingKey { case pane, frame }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pane = try c.decode(PaneState.self, forKey: .pane)
        frame = try c.decodeIfPresent([Double].self, forKey: .frame)
    }

    /// An entry that could not be read is written back as the JSON it was.
    func encode(to encoder: Encoder) throws {
        if let raw = pane.raw { try raw.encode(to: encoder); return }
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(pane, forKey: .pane)
        try c.encodeIfPresent(frame, forKey: .frame)
    }
}

/// `workspace.json`: versioned, decoded element by element so one bad window, tab, pane or Station never loses the rest.
struct WorkspaceFile: Codable, Equatable {
    static let currentVersion = 1

    var version = WorkspaceFile.currentVersion
    var windows: [WindowEntry] = []
    var detached: [DetachedEntry] = []
    var stations: [Station] = []
    /// The Rail (M4b) is stored as opaque JSON here so this file never drops items it does not understand.
    var rail: [JSONValue] = []

    init() {}

    private enum CodingKeys: String, CodingKey { case version, windows, detached, stations, rail }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? Self.currentVersion
        windows = try Self.lossy(c, .windows) { d in
            if let entry = try? WindowEntry(from: d) { return entry }
            let raw = try JSONValue(from: d)
            var id = WorkspaceWindowID.new()
            if case .object(let o) = raw, let s = o["id"]?.stringValue { id = WorkspaceWindowID(rawValue: s) }
            return WindowEntry(id: id, state: .placeholder(raw: raw))
        }
        detached = try Self.lossy(c, .detached) { d in
            if let entry = try? DetachedEntry(from: d) { return entry }
            return DetachedEntry(pane: .placeholder(raw: try JSONValue(from: d)))
        }
        stations = try Self.lossy(c, .stations) { d in
            if let station = try? Station(from: d) { return station }
            return Station.placeholder(raw: try JSONValue(from: d))
        }
        rail = (try? c.decodeIfPresent([JSONValue].self, forKey: .rail)) ?? []
    }

    private static func lossy<T>(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ make: (Decoder) throws -> T) throws -> [T] {
        guard c.contains(key) else { return [] }
        var list = try c.nestedUnkeyedContainer(forKey: key)
        var out: [T] = []
        while !list.isAtEnd { out.append(try make(try list.superDecoder())) }
        return out
    }
}
