import Foundation
import WheelhouseKit

/// Every place a pane can show (ARCHITECTURE-MAC §12.2). All cases AND their payload types are declared in M1a and frozen:
/// later milestones add optional payload fields only, never cases or renames (§15.3).
///
/// The encoding is explicit (`{"case": "<name>", "payload": …}`), not synthesized, so it does not depend on Swift's
/// `_0` conventions. An unknown case from a newer build fails to decode; `WorkspaceStore` (M4a) then keeps that pane's raw JSON
/// and shows a "couldn't be restored" placeholder.
enum WorkspaceDestination: Codable, Hashable, Sendable {
    case route(Route)                                   // every iOS route, unchanged
    case deckTerminal(TerminalSpec)
    case chartRoom(ClusterID, ChartRoomSection)
    case helmRelease(HelmReleaseRef)
    case helmInstall(ChartRef)
    case survey(SurveyScope)
    case surveyFinding(FindingID)
    case tides(TidesScope)
    case gitopsApp(ResourceRef)
    case landfall
    case firstMate(ConversationID)
    case moorings
    case activity
    case station(StationID)
    case riggingView(RiggingViewRef)

    /// The stable name of the case in JSON.
    var caseName: String {
        switch self {
        case .route: "route"
        case .deckTerminal: "deckTerminal"
        case .chartRoom: "chartRoom"
        case .helmRelease: "helmRelease"
        case .helmInstall: "helmInstall"
        case .survey: "survey"
        case .surveyFinding: "surveyFinding"
        case .tides: "tides"
        case .gitopsApp: "gitopsApp"
        case .landfall: "landfall"
        case .firstMate: "firstMate"
        case .moorings: "moorings"
        case .activity: "activity"
        case .station: "station"
        case .riggingView: "riggingView"
        }
    }

    /// Every case name, in declaration order (the golden test checks it matches the samples).
    static let allCaseNames = ["route", "deckTerminal", "chartRoom", "helmRelease", "helmInstall", "survey", "surveyFinding", "tides",
                               "gitopsApp", "landfall", "firstMate", "moorings", "activity", "station", "riggingView"]

    private enum CodingKeys: String, CodingKey { case `case`, payload }
    private struct ChartRoomPayload: Codable, Hashable { var clusterID: ClusterID; var section: ChartRoomSection }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decode(String.self, forKey: .case)
        switch name {
        case "route": self = .route(try c.decode(Route.self, forKey: .payload))
        case "deckTerminal": self = .deckTerminal(try c.decode(TerminalSpec.self, forKey: .payload))
        case "chartRoom":
            let p = try c.decode(ChartRoomPayload.self, forKey: .payload)
            self = .chartRoom(p.clusterID, p.section)
        case "helmRelease": self = .helmRelease(try c.decode(HelmReleaseRef.self, forKey: .payload))
        case "helmInstall": self = .helmInstall(try c.decode(ChartRef.self, forKey: .payload))
        case "survey": self = .survey(try c.decode(SurveyScope.self, forKey: .payload))
        case "surveyFinding": self = .surveyFinding(try c.decode(FindingID.self, forKey: .payload))
        case "tides": self = .tides(try c.decode(TidesScope.self, forKey: .payload))
        case "gitopsApp": self = .gitopsApp(try c.decode(ResourceRef.self, forKey: .payload))
        case "landfall": self = .landfall
        case "firstMate": self = .firstMate(try c.decode(ConversationID.self, forKey: .payload))
        case "moorings": self = .moorings
        case "activity": self = .activity
        case "station": self = .station(try c.decode(StationID.self, forKey: .payload))
        case "riggingView": self = .riggingView(try c.decode(RiggingViewRef.self, forKey: .payload))
        default:
            throw DecodingError.dataCorruptedError(forKey: .case, in: c, debugDescription: "Unknown destination \"\(name)\"")
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(caseName, forKey: .case)
        switch self {
        case .route(let v): try c.encode(v, forKey: .payload)
        case .deckTerminal(let v): try c.encode(v, forKey: .payload)
        case .chartRoom(let id, let section): try c.encode(ChartRoomPayload(clusterID: id, section: section), forKey: .payload)
        case .helmRelease(let v): try c.encode(v, forKey: .payload)
        case .helmInstall(let v): try c.encode(v, forKey: .payload)
        case .survey(let v): try c.encode(v, forKey: .payload)
        case .surveyFinding(let v): try c.encode(v, forKey: .payload)
        case .tides(let v): try c.encode(v, forKey: .payload)
        case .gitopsApp(let v): try c.encode(v, forKey: .payload)
        case .firstMate(let v): try c.encode(v, forKey: .payload)
        case .station(let v): try c.encode(v, forKey: .payload)
        case .riggingView(let v): try c.encode(v, forKey: .payload)
        case .landfall, .moorings, .activity: break
        }
    }
}
