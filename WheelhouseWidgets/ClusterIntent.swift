import AppIntents
import WidgetKit
import WheelhouseKit

/// A cluster choosable in widget configuration, sourced from the snapshot in the App Group (no credentials involved).
struct ClusterEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Cluster"
    static let defaultQuery = ClusterEntityQuery()
    var id: String
    var name: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct ClusterEntityQuery: EntityQuery, EntityStringQuery {
    private func all() -> [ClusterEntity] { (WidgetDataStore.read()?.clusters ?? []).map { ClusterEntity(id: $0.id, name: $0.name) } }
    func entities(for identifiers: [String]) async throws -> [ClusterEntity] { all().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [ClusterEntity] { all() }
    func entities(matching string: String) async throws -> [ClusterEntity] { all().filter { $0.name.localizedCaseInsensitiveContains(string) } }
    func defaultResult() async -> ClusterEntity? { all().first }
}

struct SelectClusterIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Select Cluster"
    static let description = IntentDescription("Choose which cluster this widget shows. Leave empty to show the cluster that needs the most attention.")
    @Parameter(title: "Cluster") var cluster: ClusterEntity?
}
