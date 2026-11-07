import SwiftUI
import WheelhouseKit

/// Stub. M8a replaces the contents of this file (and only this folder).
enum SurveyFeature: WheelhouseFeature {
    static var id: FeatureID { .survey }
    static var title: String { "Survey" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .survey = destination { return true }
        if case .surveyFinding = destination { return true }
        return false
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
        FeaturePlaceholderView(title: "Survey", milestone: "M8a")
    }
}
