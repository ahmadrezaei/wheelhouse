import SwiftUI
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI

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

    static var sidebarNodes: [SidebarNodeTemplate] { sidebarNodes(capabilities: .current) }

    /// Charts and Repositories exist only to install and to manage repositories, so a read-only edition lists Releases alone.
    static func sidebarNodes(capabilities: ChartRoomCapabilities) -> [SidebarNodeTemplate] {
        let all = [
            SidebarNodeTemplate(id: "chartroom.releases", title: "Releases", symbol: "shippingbox") { .chartRoom($0, .releases) },
            SidebarNodeTemplate(id: "chartroom.charts", title: "Charts", symbol: "books.vertical") { .chartRoom($0, .charts) },
            SidebarNodeTemplate(id: "chartroom.repositories", title: "Repositories", symbol: "externaldrive.connected.to.line.below") { .chartRoom($0, .repositories) },
        ]
        return capabilities.writes ? all : Array(all.prefix(1))
    }

    @MainActor @ViewBuilder static func makeView(for destination: WorkspaceDestination) -> some View {
        switch destination {
        case .chartRoom(let cluster, let section):
            ChartRoomView(clusterID: cluster, section: section).id("\(cluster)")
        case .helmRelease(let ref):
            ReleaseScreen(ref: ref)
        case .helmInstall:
            if ChartRoomCapabilities.current.writes {
                FeaturePlaceholderView(title: "Install a Chart", milestone: "M6b")
            } else {
                OpenSourceEditionNote(message: ChartRoomCapabilities.notice).padding(Spacing.xl)
            }
        default:
            EmptyView()
        }
    }
}

/// Everything in Chart Room that starts helm. A read-only edition offers none of these (the controls are left out, not disabled).
enum ChartRoomAction: CaseIterable, Sendable {
    case install, upgrade, rollBack, uninstall
    case addRepository, updateRepositories, removeRepository, artifactHub
    case openInTerminal
}

extension ChartRoomCapabilities {
    func offers(_ action: ChartRoomAction) -> Bool { writes }

    /// The sections a pane can show.
    var sections: [ChartRoomSection] { writes ? ChartRoomSection.allCases : [.releases] }

    /// A saved pane may name a section this edition doesn't have; it opens Releases instead.
    func resolve(_ section: ChartRoomSection) -> ChartRoomSection { sections.contains(section) ? section : .releases }
}
