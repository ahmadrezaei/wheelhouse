import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// What the sandboxed edition leaves out of Chart Room, Survey and Tides, with each flag set both ways (no sandbox is needed: the
/// capabilities are plain values the views and models take as input).
@MainActor @Suite("Edition capabilities", .serialized)
struct EditionCapabilityTests {
    private let cluster: ClusterID = "c1"
    private let readOnlyChartRoom = ChartRoomCapabilities(writes: false)
    private let fullChartRoom = ChartRoomCapabilities(writes: true)

    // MARK: Flags

    @Test func theHostedEditionTurnsEveryCapabilityOff() {
        // The MAS test host is sandboxed, so the real `current` values are the shipped ones.
        #expect(!ChartRoomCapabilities.current.writes)
        #expect(!SurveyCapabilities.current.localScans)
        #expect(!TidesCapabilities.current.fluxDiff)
    }

    @Test func theNotesPointAtTheEditionsPage() {
        #expect(EditionNotice.learnMore.absoluteString == "https://ahmadrezaei.github.io/wheelhouse/mac/editions.html")
        #expect(ChartRoomCapabilities.notice == "Helm changes need the open-source edition.")
    }

    // MARK: Chart Room

    @Test func chartRoomOffersNoHelmActionWhenReadOnly() {
        for action in ChartRoomAction.allCases {
            #expect(!readOnlyChartRoom.offers(action), "\(action) must not be offered")
            #expect(fullChartRoom.offers(action))
        }
    }

    @Test func chartRoomListsOnlyReleasesWhenReadOnly() {
        #expect(readOnlyChartRoom.sections == [.releases])
        #expect(fullChartRoom.sections == [.releases, .charts, .repositories])
        let titles = ChartRoomFeature.sidebarNodes(capabilities: readOnlyChartRoom).map(\.title)
        #expect(titles == ["Releases"])
        #expect(ChartRoomFeature.sidebarNodes(capabilities: fullChartRoom).map(\.title) == ["Releases", "Charts", "Repositories"])
        #expect(ChartRoomFeature.sidebarNodes(capabilities: readOnlyChartRoom).compactMap { $0.destination(cluster) } == [.chartRoom(cluster, .releases)])
    }

    @Test func aSavedPaneOnAHiddenSectionOpensReleases() {
        #expect(readOnlyChartRoom.resolve(.charts) == .releases)
        #expect(readOnlyChartRoom.resolve(.repositories) == .releases)
        #expect(readOnlyChartRoom.resolve(.releases) == .releases)
        #expect(fullChartRoom.resolve(.charts) == .charts)
        #expect(fullChartRoom.resolve(.repositories) == .repositories)
    }

    @Test func chartRoomHasNoCommandThatChangesAnything() {
        #expect(ChartRoomFeature.commands.isEmpty)
        // The sandboxed process still routes the destinations (a saved window may hold one), it just draws no install flow.
        #expect(ChartRoomFeature.handles(.helmInstall(ChartRef(repository: nil, name: "nginx", version: nil, ociReference: nil))))
    }

    // MARK: Survey

    @Test func surveyKeepsItsReadSurfaceAndNoScanCommand() {
        #expect(SurveyFeature.sidebarNodes.map(\.title) == ["Overview", "Vulnerabilities", "Access risks", "Workload risks"])
        #expect(SurveyFeature.commands.map(\.id) == ["survey.export"])
    }

    private func scratch() throws -> (root: URL, paths: AppPaths, marker: URL, script: URL) {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-mas-scan-\(UUID().uuidString)", directoryHint: .isDirectory).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root.appending(path: "home"), withIntermediateDirectories: true)
        let paths = AppPaths(gateActive: true, bundleID: nil, home: root.appending(path: "home"), temporaryDirectory: root)
        let marker = root.appending(path: "started")
        let script = root.appending(path: "trivy")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (root, paths, marker, script)
    }

    @Test func aCoordinatorWithoutLocalScansFindsNoTrivyAndStartsNothing() async throws {
        let env = try scratch()
        defer { try? FileManager.default.removeItem(at: env.root) }
        UserDefaults.standard.set(env.script.path, forKey: SurveyScanSettings.trivyPath)
        defer { UserDefaults.standard.removeObject(forKey: SurveyScanSettings.trivyPath) }
        let coordinator = ScanCoordinator(paths: env.paths, conditions: { ScanConditions() }, capabilities: SurveyCapabilities(localScans: false))
        await coordinator.prepare()                       // the database still opens: accepted risks live in it
        #expect(coordinator.store != nil)
        #expect(coordinator.source == .none)             // the configured trivy is ignored
        await coordinator.resolveSource()
        #expect(coordinator.source == .none)
        await coordinator.installManaged()
        await coordinator.scan(sessions: [], trigger: .manual)
        #expect(coordinator.message == SurveyCapabilities.notice)
        #expect(coordinator.progress.state == .idle && coordinator.progress.queued == 0)
        #expect(!FileManager.default.fileExists(atPath: env.marker.path))
    }

    @Test func aCoordinatorWithLocalScansStillFindsAConfiguredTrivy() async throws {
        let env = try scratch()
        defer { try? FileManager.default.removeItem(at: env.root) }
        UserDefaults.standard.set(env.script.path, forKey: SurveyScanSettings.trivyPath)
        defer { UserDefaults.standard.removeObject(forKey: SurveyScanSettings.trivyPath) }
        let coordinator = ScanCoordinator(paths: env.paths, conditions: { ScanConditions() }, capabilities: SurveyCapabilities(localScans: true))
        await coordinator.prepare()
        #expect(coordinator.source == .configured(env.script))
    }

    // MARK: Tides

    @Test func theFluxDiffTabIsDroppedFromKustomizationsOnly() {
        let on = TidesCapabilities(fluxDiff: true)
        let off = TidesCapabilities(fluxDiff: false)
        typealias Detail = TidesDetailView
        #expect(Detail.tabs(tool: .flux, flavor: .fluxKustomization, capabilities: on) == [.status, .inventory, .dependencies, .diff, .conditions, .manifest])
        #expect(Detail.tabs(tool: .flux, flavor: .fluxKustomization, capabilities: off) == [.status, .inventory, .dependencies, .conditions, .manifest])
        // Everything else is unchanged, Argo CD's diff included (it reads the API).
        #expect(Detail.tabs(tool: .argoCD, flavor: .argoApplication, capabilities: off) == [.resources, .diff, .history, .conditions, .manifest])
        #expect(Detail.tabs(tool: .flux, flavor: .fluxHelmRelease, capabilities: off) == Detail.tabs(tool: .flux, flavor: .fluxHelmRelease, capabilities: on))
    }

    @Test func tidesAddsNoFluxDiffCommandOrSidebarEntry() {
        #expect(TidesFeature.commands.isEmpty)
        let titles = TidesFeature.sidebarNodes.flatMap { [$0.title] + $0.children.map(\.title) }
        #expect(!titles.contains { $0.localizedCaseInsensitiveContains("diff") })
    }
}
