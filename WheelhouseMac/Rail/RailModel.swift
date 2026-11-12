import Foundation
import Observation
import WheelhouseKit

/// One pinned item of the Rail (DESIGN-MAC section 6.6). Local to this Mac (decision 22): stored in `workspace.json`, never synced.
struct RailItem: Codable, Hashable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case cluster, namespace, resource, station }
    var id: String
    var kind: Kind
    /// A name the person gave; nil shows the default.
    var title: String?
    var clusterID: ClusterID?
    var namespace: String?
    var resource: ResourceRef?
    var stationID: String?

    static func cluster(_ id: ClusterID) -> RailItem { RailItem(id: UUID().uuidString, kind: .cluster, clusterID: id) }
    static func namespace(_ namespace: String, in cluster: ClusterID) -> RailItem { RailItem(id: UUID().uuidString, kind: .namespace, clusterID: cluster, namespace: namespace) }
    static func resource(_ ref: ResourceRef) -> RailItem { RailItem(id: UUID().uuidString, kind: .resource, clusterID: ref.clusterID, resource: ref) }
    static func station(_ id: StationID) -> RailItem { RailItem(id: UUID().uuidString, kind: .station, stationID: id.rawValue) }

    /// The same thing pinned twice is one item.
    func samePin(as other: RailItem) -> Bool {
        kind == other.kind && clusterID == other.clusterID && namespace == other.namespace && resource == other.resource && stationID == other.stationID
    }
}

/// The Rail over `WorkspaceStore.rail`. An element this build cannot decode (an item kind from a newer build) stays in its place as
/// the JSON it was and is written back unchanged; it takes no ⌘ number and shows nowhere.
@MainActor @Observable
final class RailModel {
    private let store: WorkspaceStore
    private let registry: ClusterRegistry
    private let preferences: MacPreferences

    /// The stored array, decoded per element.
    enum Slot: Equatable { case item(RailItem), opaque(JSONValue) }

    init(store: WorkspaceStore, registry: ClusterRegistry, preferences: MacPreferences) {
        self.store = store
        self.registry = registry
        self.preferences = preferences
    }

    private var slots: [Slot] {
        store.rail.map { value in (try? value.decode(RailItem.self)).map(Slot.item) ?? .opaque(value) }
    }

    /// The items the Rail shows, in order. Items for a removed cluster stay (shown dimmed, disabled), so a cluster that comes back
    /// finds its pin.
    var items: [RailItem] { slots.compactMap { if case .item(let i) = $0 { i } else { nil } } }

    func isAvailable(_ item: RailItem) -> Bool {
        switch item.kind {
        case .station: store.stations.contains { $0.id.rawValue == item.stationID }
        default: item.clusterID.map { registry.config(for: $0) != nil } ?? false
        }
    }

    /// Clusters on the Rail: Crow's Nest checks them (DESIGN-MAC section 6.15).
    var clusterIDs: Set<ClusterID> { Set(items.compactMap(\.clusterID)) }

    func title(for item: RailItem) -> String {
        if let t = item.title, !t.isEmpty { return t }
        switch item.kind {
        case .cluster: return item.clusterID.flatMap { registry.config(for: $0)?.name } ?? "Removed cluster"
        case .namespace: return "\(item.namespace ?? "") @ \(item.clusterID.flatMap { registry.config(for: $0)?.name } ?? "?")"
        case .resource: return item.resource.map { "\($0.kind.kind.lowercased()) \($0.name)" } ?? "Resource"
        case .station: return store.stations.first { $0.id.rawValue == item.stationID }?.name ?? "Station"
        }
    }

    // MARK: Editing

    private func write(_ slots: [Slot]) {
        let encoder = JSONEncoder()
        let values: [JSONValue] = slots.compactMap { slot in
            switch slot {
            case .opaque(let v): return v
            case .item(let i): return (try? encoder.encode(i)).flatMap { try? JSONDecoder().decode(JSONValue.self, from: $0) }
            }
        }
        store.setRail(values)
    }

    /// Pins an item (at the end). Pinning what is already pinned does nothing; returns whether the Rail changed.
    @discardableResult
    func pin(_ item: RailItem) -> Bool {
        if items.contains(where: { $0.samePin(as: item) }) { return false }
        write(slots + [.item(item)])
        return true
    }

    func remove(_ id: String) {
        preferences.railCustomised = true
        write(slots.filter { if case .item(let i) = $0 { i.id != id } else { true } })
    }

    func rename(_ id: String, to title: String) {
        preferences.railCustomised = true
        write(slots.map { slot in
            guard case .item(var i) = slot, i.id == id else { return slot }
            i.title = title.trimmingCharacters(in: .whitespaces).isEmpty ? nil : title
            return .item(i)
        })
    }

    /// Moves the item `id` before the item `target` (nil = to the end), among the items; opaque elements keep their places.
    func move(_ id: String, before target: String?) {
        preferences.railCustomised = true
        var all = slots
        guard let from = all.firstIndex(where: { if case .item(let i) = $0 { i.id == id } else { false } }) else { return }
        let moving = all.remove(at: from)
        let to = target.flatMap { t in all.firstIndex { if case .item(let i) = $0 { i.id == t } else { false } } } ?? all.count
        all.insert(moving, at: to)
        write(all)
    }

    /// The first run with clusters pins the first nine, so ⌘1 ... ⌘9 keep reaching what they reached before the Rail existed
    /// (DESIGN-MAC section 6.6). Runs once and never refills a Rail the person emptied.
    func prefillOnce() {
        guard !preferences.railPrefilled, !registry.isDemoMode, !registry.clusters.isEmpty else { return }
        preferences.railPrefilled = true
        guard items.isEmpty else { return }
        write(registry.clusters.prefix(9).map { .item(.cluster($0.id)) })
    }

    /// A cluster added later joins the Rail while the Rail still holds fewer than five clusters and the person has not arranged it
    /// themselves (a new install fills up as the first clusters are added).
    func pinNewClusters() {
        guard preferences.railPrefilled, !preferences.railCustomised, !registry.isDemoMode else { return }
        var pinned = items.filter { $0.kind == .cluster }.count
        for cluster in registry.clusters where pinned < 5 && !items.contains(where: { $0.kind == .cluster && $0.clusterID == cluster.id }) {
            pin(.cluster(cluster.id))
            pinned += 1
        }
    }

    /// What ⌘1 ... ⌘9 reach: the Rail, or the first clusters while the Rail is empty (Demo mode, a Rail not filled yet), as before the Rail.
    var shortcutItems: [RailItem] {
        let list = items
        guard list.isEmpty else { return list }
        return registry.clusters.prefix(9).map { RailItem(id: "auto-\($0.id)", kind: .cluster, clusterID: $0.id) }
    }

    /// Rail item `number` (1-based) for ⌘1 ... ⌘9.
    func item(number: Int) -> RailItem? {
        let list = shortcutItems
        return list.indices.contains(number - 1) ? list[number - 1] : nil
    }
}
