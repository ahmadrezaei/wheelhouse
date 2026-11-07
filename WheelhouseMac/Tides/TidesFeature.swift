import SwiftUI
import WheelhouseKit

/// Stub. M9 replaces the contents of this file (and only this folder).
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
                SidebarNodeTemplate(id: "tides.argocd.applicationsets", title: "ApplicationSets", symbol: "square.stack.3d.down.right") { .tides(TidesScope(clusterID: $0, tool: .argoCD)) },
                SidebarNodeTemplate(id: "tides.argocd.projects", title: "Projects", symbol: "folder") { .tides(TidesScope(clusterID: $0, tool: .argoCD)) },
            ]) { .tides(TidesScope(clusterID: $0, tool: .argoCD)) },
            SidebarNodeTemplate(id: "tides.flux", title: "Flux", symbol: "water.waves", requiresAPIGroups: ["kustomize.toolkit.fluxcd.io", "helm.toolkit.fluxcd.io", "source.toolkit.fluxcd.io"], children: [
                SidebarNodeTemplate(id: "tides.flux.kustomizations", title: "Kustomizations", symbol: "square.stack.3d.up") { .tides(TidesScope(clusterID: $0, tool: .flux)) },
                SidebarNodeTemplate(id: "tides.flux.helmreleases", title: "HelmReleases", symbol: "shippingbox") { .tides(TidesScope(clusterID: $0, tool: .flux)) },
                SidebarNodeTemplate(id: "tides.flux.sources", title: "Sources", symbol: "arrow.down.circle") { .tides(TidesScope(clusterID: $0, tool: .flux)) },
            ]) { .tides(TidesScope(clusterID: $0, tool: .flux)) },
        ]
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        FeaturePlaceholderView(title: "Tides", milestone: "M9")
    }
}
