import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

@Suite("Chart Room")
struct ChartRoomTests {
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    @Test func isolatedBuildsNeverReadTheUsersHelmConfiguration() {
        let paths = AppPaths(gateActive: true, bundleID: nil, home: home)
        let hostile = ["HELM_REPOSITORY_CONFIG": "/Users/tester/Library/Preferences/helm/repositories.yaml",
                       "HELM_CONFIG_HOME": "/Users/tester/real", "XDG_CONFIG_HOME": "/Users/tester/.config", "XDG_CACHE_HOME": "/Users/tester/.cache"]
        let resolved = ChartRoomServices.defaultHelmPaths(paths: paths, environment: hostile)
        #expect(resolved.repositoryConfig.path.hasPrefix(paths.helmRoot.path))
        #expect(resolved.repositoryCache.path.hasPrefix(paths.helmRoot.path))
        #expect(paths.helmRoot.path.contains("Wheelhouse-Debug"))
    }

    @Test func unisolatedBuildsFollowHelmsOwnResolution() {
        let paths = AppPaths(gateActive: false, bundleID: AppPaths.releaseBundleID, home: home)
        #expect(ChartRoomServices.defaultHelmPaths(paths: paths, environment: [:]).repositoryConfig.path
                == "/Users/tester/Library/Preferences/helm/repositories.yaml")
        #expect(ChartRoomServices.defaultHelmPaths(paths: paths, environment: ["HELM_REPOSITORY_CONFIG": "/custom/r.yaml"]).repositoryConfig.path == "/custom/r.yaml")
    }

    @Test func statusesMapToTonesAndProblemsNeedAttention() {
        #expect(HelmReleaseStatus.deployed.tone == .healthy)
        #expect(HelmReleaseStatus.failed.tone == .critical)
        for pending in [HelmReleaseStatus.pendingInstall, .pendingUpgrade, .pendingRollback] {
            #expect(pending.tone == .warning && pending.needsAttention && pending.isPending)
        }
        #expect(HelmReleaseStatus.superseded.tone == .unknown && !HelmReleaseStatus.superseded.needsAttention)
        #expect(HelmReleaseStatus(label: "nonsense") == .unknown)
    }

    @Test func chartRoomHandlesItsDestinationsAndOffersThreeSections() throws {
        let feature = try #require(FeatureRegistry.all.first { $0.id == .chartRoom })
        let cluster: ClusterID = "c1"
        #expect(feature.handles(.chartRoom(cluster, .releases)))
        #expect(feature.handles(.helmRelease(HelmReleaseRef(clusterID: cluster, namespace: "ns", name: "r", revision: nil))))
        #expect(feature.sidebarNodes.map(\.title) == ["Releases", "Charts", "Repositories"])
        #expect(feature.sidebarNodes.compactMap { $0.destination(cluster) } == [.chartRoom(cluster, .releases), .chartRoom(cluster, .charts), .chartRoom(cluster, .repositories)])
    }

    @MainActor @Test func notesLinksAreClickable() {
        let text = NotesTab.linked("Visit https://example.com/docs for more.\nPlain line")
        #expect(text.runs.contains { $0.link?.absoluteString == "https://example.com/docs" })
    }
}
