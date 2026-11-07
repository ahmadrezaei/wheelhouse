import SwiftUI
import WheelhouseDesktop
import WheelhouseKit

/// Identifies a feature. One per `WheelhouseMac/<Feature>/` folder.
enum FeatureID: String, CaseIterable, Hashable, Sendable {
    case moorings, deckTerminal, chartRoom, survey, tides, landfall, firstMate, beacon, rigging
    case compass, rail, crowsNest, activity
}

/// A node a feature adds to the sidebar tree of every cluster (ARCHITECTURE-MAC §12.5). Feature groups (Chart Room, Tides,
/// Survey) supply theirs here, so M6a, M8a, M9 and M13 never edit the tree.
struct SidebarNodeTemplate: Identifiable, Sendable {
    var id: String
    var title: String
    var symbol: String
    /// API groups that must be served for the node to appear (empty = always). Tides sub-groups use their CRD groups.
    var requiresAPIGroups: [String] = []
    var children: [SidebarNodeTemplate] = []
    var destination: @Sendable (ClusterID) -> WorkspaceDestination?
}

/// The contract of one feature. Later milestones REPLACE the contents of their own `<Feature>Feature.swift`; nobody edits
/// `FeatureRegistry`, `WorkspaceDestination`, `project.yml` or `Package.swift` after M1a (ARCHITECTURE-MAC §15.3).
protocol WheelhouseFeature {
    associatedtype Content: View
    static var id: FeatureID { get }
    static var title: String { get }
    /// True for the destinations this feature renders.
    static func handles(_ destination: WorkspaceDestination) -> Bool
    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> Content
    static var commands: [WorkspaceCommand] { get }
    static var sidebarNodes: [SidebarNodeTemplate] { get }
}

extension WheelhouseFeature {
    static func handles(_ destination: WorkspaceDestination) -> Bool { false }
    static var commands: [WorkspaceCommand] { [] }
    static var sidebarNodes: [SidebarNodeTemplate] { [] }
}

/// The type-erased view of a feature, so the registry can list them all.
struct FeatureDescriptor: Sendable {
    let id: FeatureID
    let title: String
    let commands: [WorkspaceCommand]
    let sidebarNodes: [SidebarNodeTemplate]
    let handles: @Sendable (WorkspaceDestination) -> Bool
    let makeView: @MainActor @Sendable (WorkspaceDestination) -> AnyView

    init<F: WheelhouseFeature>(_ feature: F.Type) {
        id = F.id
        title = F.title
        commands = F.commands
        sidebarNodes = F.sidebarNodes
        handles = { F.handles($0) }
        makeView = { AnyView(F.makeView(for: $0)) }
    }
}

/// Every feature, by its static members. Nobody edits this after M1a.
enum FeatureRegistry {
    static let all: [FeatureDescriptor] = [
        FeatureDescriptor(MooringsFeature.self),
        FeatureDescriptor(DeckTerminalFeature.self),
        FeatureDescriptor(ChartRoomFeature.self),
        FeatureDescriptor(SurveyFeature.self),
        FeatureDescriptor(TidesFeature.self),
        FeatureDescriptor(LandfallFeature.self),
        FeatureDescriptor(FirstMateFeature.self),
        FeatureDescriptor(BeaconFeature.self),
        FeatureDescriptor(RiggingFeature.self),
        FeatureDescriptor(CompassFeature.self),
        FeatureDescriptor(RailFeature.self),
        FeatureDescriptor(CrowsNestFeature.self),
        FeatureDescriptor(ActivityFeature.self),
    ]

    /// Features whose milestone has passed its exit criteria and may ship in a Distribution build. Edited when a milestone
    /// is released (a one-line change in its own PR); empty in M1a.
    static let releaseEnabled: Set<FeatureID> = []

    /// Development builds (the safety gate is active: Debug, Profile and local Release) show every feature, so each milestone is
    /// built and measured behind its flag. Distribution shows only `releaseEnabled`.
    static func isEnabled(_ id: FeatureID, gateActive: Bool = DevSafety.isActive) -> Bool {
        gateActive || releaseEnabled.contains(id)
    }

    static var enabled: [FeatureDescriptor] { all.filter { isEnabled($0.id) } }

    /// The enabled feature that renders `destination`, if any.
    static func feature(for destination: WorkspaceDestination) -> FeatureDescriptor? {
        enabled.first { $0.handles(destination) }
    }

    @MainActor static func view(for destination: WorkspaceDestination) -> AnyView? {
        feature(for: destination)?.makeView(destination)
    }

    static var commands: [WorkspaceCommand] { enabled.flatMap(\.commands) }
}

/// What every feature stub shows until its milestone replaces it.
struct FeaturePlaceholderView: View {
    let title: String
    let milestone: String
    var body: some View {
        ContentUnavailableView(title, systemImage: "hammer", description: Text("Arrives in \(milestone)."))
    }
}
