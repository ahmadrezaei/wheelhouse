import SwiftUI
import WheelhouseKit

/// Stub. M6a replaces the contents of this file (and only this folder).
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
        FeaturePlaceholderView(title: "Chart Room", milestone: "M6a")
    }
}
