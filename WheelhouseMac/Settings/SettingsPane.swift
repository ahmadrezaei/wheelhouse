import SwiftUI
import WheelhouseDesktop

/// The Settings panes, in display order (DESIGN-MAC §12). Each pane's view lives in `Settings/Panes/<Name>Pane.swift`.
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case clusters
    case moorings
    case landfall
    case safetySecurity
    case terminal
    case editor
    case chartRoom
    case survey
    case tides
    case firstMate
    case beacon
    case notifications
    case iCloud
    case updates
    case rigging
    case advanced

    /// The panes this build shows: a pane that belongs to a feature not enabled in this build (Rigging in Distribution 1.0) is left out.
    static var visible: [SettingsPane] { allCases.filter { $0.isVisible() } }

    func isVisible(gateActive: Bool = DevSafety.isActive) -> Bool {
        switch self {
        case .rigging: FeatureRegistry.isEnabled(.rigging, gateActive: gateActive)
        default: true
        }
    }
    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .clusters: "Clusters"
        case .moorings: "Moorings"
        case .landfall: "Landfall"
        case .safetySecurity: "Safety & Security"
        case .terminal: "Terminal"
        case .editor: "Editor"
        case .chartRoom: "Chart Room"
        case .survey: "Survey"
        case .tides: "Tides"
        case .firstMate: "First Mate"
        case .beacon: "Beacon"
        case .notifications: "Notifications"
        case .iCloud: "iCloud"
        case .updates: "Updates"
        case .rigging: "Rigging"
        case .advanced: "Advanced"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .clusters: "server.rack"
        case .moorings: "anchor"
        case .landfall: "cloud"
        case .safetySecurity: "lock.shield"
        case .terminal: "terminal"
        case .editor: "doc.text"
        case .chartRoom: "shippingbox"
        case .survey: "binoculars"
        case .tides: "water.waves"
        case .firstMate: "sparkles"
        case .beacon: "antenna.radiowaves.left.and.right"
        case .notifications: "bell"
        case .iCloud: "icloud"
        case .updates: "arrow.down.circle"
        case .rigging: "puzzlepiece.extension"
        case .advanced: "slider.horizontal.3"
        }
    }

    @ViewBuilder var content: some View {
        switch self {
        case .general: GeneralPane()
        case .clusters: ClustersPane()
        case .moorings: MooringsPane()
        case .landfall: LandfallPane()
        case .safetySecurity: SafetySecurityPane()
        case .terminal: TerminalPane()
        case .editor: EditorPane()
        case .chartRoom: ChartRoomPane()
        case .survey: SurveyPane()
        case .tides: TidesPane()
        case .firstMate: FirstMatePane()
        case .beacon: BeaconPane()
        case .notifications: NotificationsPane()
        case .iCloud: ICloudPane()
        case .updates: UpdatesPane()
        case .rigging: RiggingPane()
        case .advanced: AdvancedPane()
        }
    }
}
