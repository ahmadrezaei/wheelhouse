import SwiftUI
import WheelhouseKit

/// Chart Room, read path (M6a): Releases, Charts and Repositories from the cluster's Helm records and helm's own caches.
/// Writes (install, upgrade, roll back, uninstall, repository changes) arrive in M6b.
enum ChartRoomFeature: WheelhouseFeature {
    static var id: FeatureID { .chartRoom }
    static var title: String { "Chart Room" }
    static func handles(_ destination: WorkspaceDestination) -> Bool {
        if case .chartRoom = destination { return true }
        if case .helmRelease = destination { return true }
        if case .helmInstall = destination { return true }
        return false
    }

    static var sidebarNodes: [SidebarNodeTemplate] {
        [
            SidebarNodeTemplate(id: "chartroom.releases", title: "Releases", symbol: "shippingbox") { .chartRoom($0, .releases) },
            SidebarNodeTemplate(id: "chartroom.charts", title: "Charts", symbol: "books.vertical") { .chartRoom($0, .charts) },
            SidebarNodeTemplate(id: "chartroom.repositories", title: "Repositories", symbol: "externaldrive.connected.to.line.below") { .chartRoom($0, .repositories) },
        ]
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        switch destination {
        case .chartRoom(let cluster, let section):
            ChartRoomView(clusterID: cluster, section: section).id("\(cluster)")
        case .helmRelease(let ref):
            ReleaseScreen(ref: ref)
        case .helmInstall:
            FeaturePlaceholderView(title: "Install a Chart", milestone: "M6b")
        default:
            EmptyView()
        }
    }
}
