import SwiftUI
import WheelhouseKit

/// Tides: GitOps with Flux and Argo CD (ARCHITECTURE-MAC §7, DESIGN-MAC §6.10).
///
/// Detection is by CRD discovery (the sidebar nodes appear only when a group is served). Reads go through the shared
/// `unstructuredStore`s, which run only while a Tides view is visible. Every action is a kube API patch behind ConfirmSheet
/// with a server dry-run first (`GitOpsPlanner` in WheelhouseKit).
enum TidesFeature: WheelhouseFeature {
    static var id: FeatureID { .tides }
    static var title: String { "Tides" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .tides = destination { return true }
        if case .gitopsApp = destination { return true }
        return false
    }

    static var sidebarNodes: [SidebarNodeTemplate] {
        [
            SidebarNodeTemplate(id: "tides.argocd", title: "Argo CD", symbol: "arrow.triangle.2.circlepath", requiresAPIGroups: ["argoproj.io"], children: [
                SidebarNodeTemplate(id: "tides.argocd.applications", title: "Applications", symbol: "app.badge") { .tides(TidesScope(clusterID: $0, tool: .argoCD)) },
            ]) { .tides(TidesScope(clusterID: $0, tool: .argoCD)) },
            SidebarNodeTemplate(id: "tides.flux", title: "Flux", symbol: "water.waves", requiresAPIGroups: ["kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io", "source.toolkit.fluxcd.io"], children: [
                SidebarNodeTemplate(id: "tides.flux.apps", title: "Kustomizations & HelmReleases", symbol: "square.stack.3d.up") { .tides(TidesScope(clusterID: $0, tool: .flux)) },
            ]) { .tides(TidesScope(clusterID: $0, tool: .flux)) },
        ]
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        switch destination {
        case .tides(let scope): TidesRootView(scope: scope)
        case .gitopsApp(let ref): GitOpsAppDestinationView(ref: ref)
        default: FeaturePlaceholderView(title: "Tides", milestone: "M9")
        }
    }
}
