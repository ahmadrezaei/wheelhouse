import SwiftUI
import WheelhouseKit

/// Survey: the security center (DESIGN-MAC §6.9). M8a ships the built-in access and workload rules (Overview, Access risks and
/// Workload risks), finding detail with fix guidance and suggested patches, accepted risks and exports. The vulnerability tab arrives
/// with M8b. Rules live in Kit (`WheelhouseKit/Security`); this folder is the UI and the per-cluster model.
enum SurveyFeature: WheelhouseFeature {
    static var id: FeatureID { .survey }
    static var title: String { "Survey" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .survey = destination { return true }
        if case .surveyFinding = destination { return true }
        return false
    }

    static var commands: [WorkspaceCommand] {
        [WorkspaceCommand(id: "survey.export", title: "Export Survey Findings…", symbol: "square.and.arrow.up", key: "E")]
    }

    static var sidebarNodes: [SidebarNodeTemplate] {
        [
            SidebarNodeTemplate(id: "survey.overview", title: "Overview", symbol: "binoculars") { .survey(SurveyScope(clusterID: $0, tab: .overview)) },
            SidebarNodeTemplate(id: "survey.vulnerabilities", title: "Vulnerabilities", symbol: "ladybug", requiresAPIGroups: ["aquasecurity.github.io"]) { .survey(SurveyScope(clusterID: $0, tab: .vulnerabilities)) },
            SidebarNodeTemplate(id: "survey.access", title: "Access risks", symbol: "lock.trianglebadge.exclamationmark") { .survey(SurveyScope(clusterID: $0, tab: .access)) },
            SidebarNodeTemplate(id: "survey.workload", title: "Workload risks", symbol: "exclamationmark.shield") { .survey(SurveyScope(clusterID: $0, tab: .workload)) },
        ]
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        switch destination {
        case .survey(let scope): SurveyRootView(scope: scope)
        case .surveyFinding(let id): SurveyFindingPane(findingID: id)
        default: EmptyView()
        }
    }
}
