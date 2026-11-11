import SwiftUI
import WheelhouseKit
import WheelhouseUI

/// The Chart Room pane: Releases, Charts and Repositories behind a segmented control in the header.
struct ChartRoomView: View {
    let clusterID: ClusterID
    @State var section: ChartRoomSection
    @Environment(ClusterRegistry.self) private var registry
    @Environment(\.chartRoomServices) private var services

    init(clusterID: ClusterID, section: ChartRoomSection) {
        self.clusterID = clusterID
        _section = State(initialValue: section)
    }

    var body: some View {
        if let session = registry.session(for: clusterID) {
            ChartRoomContent(session: session, services: services, section: $section)
        } else {
            ContentUnavailableView("Cluster Not Found", systemImage: "server.rack",
                                   description: Text("This pane refers to a cluster that is no longer configured."))
        }
    }
}

private struct ChartRoomContent: View {
    let session: ClusterSession
    @Binding var section: ChartRoomSection
    @State private var releases: ReleasesModel
    @State private var repositories: RepositoriesModel
    @Environment(AppLockController.self) private var lock: AppLockController?

    init(session: ClusterSession, services: ChartRoomServices, section: Binding<ChartRoomSection>) {
        self.session = session
        _section = section
        _releases = State(initialValue: ReleasesModel(session: session, services: services))
        _repositories = State(initialValue: RepositoriesModel(services: services))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: Spacing.m) {
                Label("Chart Room", systemImage: "shippingbox").font(.headline)
                EnvBadge(session.config.environment)
                Spacer()
                Picker("Section", selection: $section) {
                    Text("Releases").tag(ChartRoomSection.releases)
                    Text("Charts").tag(ChartRoomSection.charts)
                    Text("Repositories").tag(ChartRoomSection.repositories)
                }
                .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 320)
            }
            .padding(.horizontal, Spacing.l).padding(.vertical, Spacing.s)
            Divider()
            switch section {
            case .releases: ReleasesView(model: releases)
            case .charts: ChartsView(model: repositories, session: session)
            case .repositories: RepositoriesView(model: repositories)
            }
        }
        // Locking drops every decoded release and hides revealed values, whatever section is showing.
        .onChange(of: lock?.isLocked ?? false) { _, locked in if locked { ChartRoomMemory.scrub() } }
    }
}
