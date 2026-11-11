import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

@MainActor
@Suite("Chart Room write path")
struct HelmFlowTests {
    private func config(_ environment: ClusterEnvironment = .development, readOnly: Bool = false) -> ClusterConfig {
        ClusterConfig(id: "c1", name: "test", server: URL(string: "https://k.test:6443")!, environment: environment, readOnly: readOnly)
    }

    private func runner() -> HelmRunner {
        let paths = AppPaths(gateActive: true, bundleID: nil, home: FileManager.default.temporaryDirectory.appending(path: "wh-flow-\(UUID().uuidString)"))
        let provider = SnapshotClusterProvider { _ in throw UpstreamError.notReachable("unused") }
        let cli = HelmCLI(executable: URL(fileURLWithPath: "/usr/bin/true"), version: HelmVersion(3, 14), environment: EnvironmentBuilder(snapshot: nil, paths: paths, home: paths.home))
        return HelmRunner(cli: cli, gangway: GangwayService(paths: paths, clusters: provider))
    }

    private func release() throws -> HelmRelease {
        let json: [String: Any] = ["name": "web", "namespace": "shop", "version": 2, "info": ["status": "deployed"],
                                   "chart": ["metadata": ["name": "web", "version": "1.0.0"]],
                                   "manifest": "apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: web-config\n", "hooks": []]
        return try HelmReleaseCodec.decode(payload: JSONSerialization.data(withJSONObject: json))
    }

    private func model(_ kind: HelmFlowKind, _ cluster: ClusterConfig, current: HelmRelease? = nil) -> HelmFlowModel {
        let session = ClusterSession(config: cluster, client: DemoKubeClient(config: cluster))
        let made = runner()
        return HelmFlowModel(kind: kind, session: session, services: ChartRoomServices(), releaseName: "web", namespace: "shop", chart: "repo/web", current: current,
                             history: [], makeRunner: { made })
    }

    @Test func reviewNeedsAValidReleaseNameNamespaceAndChart() {
        let m = model(.install, config())
        #expect(m.blocker == nil)
        m.releaseName = "Web App"
        #expect(m.blocker?.contains("release name") == true)
        m.releaseName = "web"
        m.chart = ""
        #expect(m.blocker == "Choose a chart.")
        m.chart = "--post-renderer=evil"
        #expect(m.blocker == "That chart reference is not valid.")
        m.chart = "repo/web"
        m.namespace = ""
        #expect(m.blocker == "Choose a namespace.")
    }

    @Test func optionsMapToTheOperationAndTheApplyOptions() {
        let m = model(.install, config())
        m.createNamespace = true
        m.chartVersion = "1.2.3"
        #expect(m.operation == .install(release: "web", chart: "repo/web", version: "1.2.3", namespace: "shop", createNamespace: true))
        let up = model(.upgrade, config())
        up.resetThenReuse = true
        #expect(up.operation == .upgrade(release: "web", chart: "repo/web", version: nil, namespace: "shop", strategy: .resetThenReuse))
        up.wait = false
        up.skipCRDs = true
        #expect(up.applyOptions == HelmApplyOptions(wait: false, timeout: .seconds(300), rollbackOnFailure: false, skipCRDs: true))
        #expect(!model(.install, config(.development)).rollbackOnFailure)
        #expect(model(.install, config(.production)).rollbackOnFailure, "automatic rollback is on by default for Production")
    }

    @Test func nothingRunsBeforeReviewAndConfirmation() async throws {
        let m = model(.uninstall, config(), current: try release())
        await #expect(throws: HelmCLIError.self) { try await m.begin() }
        #expect(m.step == .configure)
        #expect(m.makeConfirmRequest() == nil)
    }

    @Test func anUninstallReviewListsTheObjectsAndBuildsATypedConfirmation() async throws {
        let m = model(.uninstall, config(.production), current: try release())
        await m.prepareReview()
        #expect(m.step == .review, Comment(rawValue: m.error ?? ""))
        let review = try #require(m.review)
        #expect(review.removed.map(\.name) == ["web-config"])
        #expect(review.plan.objects.contains(GrantedObject(resource: "configmaps", namespace: "shop", name: "web-config")))
        let request = try #require(m.makeConfirmRequest())
        #expect(request.confirmationText == "web" && request.origin == .chartRoom && request.isDestructive)
        #expect(request.requiresTyping(for: config(.production)), "Production requires typing the release name")
        #expect(request.requiresTyping(for: config(.development)), "an uninstall is typed on every cluster")
        #expect(request.facts.contains { $0.label == "Objects it may change" && $0.value == "3" })
        #expect(request.dryRun == nil)
    }

    @Test func theRunAppliesTheReviewedOperationAndNotTheFormAsItIsNow() async throws {
        let m = model(.uninstall, config(), current: try release())
        m.keepHistory = false
        m.valuesText = "reviewed: true\n"
        await m.prepareReview()
        #expect(m.step == .review)
        m.keepHistory = true                       // background tasks and edits after the review
        m.namespace = "elsewhere"
        m.valuesText = "changed: true\n"
        m.wait = false
        let run = try #require(m.reviewedRun)
        #expect(run.operation == .uninstall(release: "web", namespace: "shop", keepHistory: false))
        #expect(run.values == "reviewed: true\n")
        #expect(run.options.wait)
        let request = try #require(m.makeConfirmRequest())
        #expect(request.facts.contains { $0.label == "Namespace" && $0.value == "shop" })
    }

    @Test func aReadOnlyClusterRefusesTheConfirmationAndTheRun() async throws {
        let m = model(.uninstall, config(readOnly: true), current: try release())
        await m.prepareReview()
        let request = try #require(m.makeConfirmRequest())
        #expect(request.refusal(live: config(readOnly: true)) != nil)
        await #expect(throws: HelmCLIError.self) { try await m.begin() }
        #expect(m.step == .review, "a refused run does not start")
    }

    @Test func aFailedRenderReturnsToTheFormWithTheReason() async {
        let m = model(.install, config())              // /usr/bin/true prints nothing, so the dry run has no release to read
        await m.prepareReview()
        #expect(m.step == .configure)
        #expect(m.error != nil)
    }

    @Test func helmIsLocatedFromSettingsThenTheAppThenPath() {
        let defaults = UserDefaults(suiteName: "wh-helm-toolbox-\(UUID().uuidString)")!
        let locator = ExecutableLocator(searchPath: ["/usr/bin"], overrides: ["helm": "/usr/bin/true"])
        let bundled = URL(fileURLWithPath: "/App/Contents/Helpers/helm")
        #expect(HelmToolbox.locate(defaults: defaults, bundled: bundled, locator: locator) == .bundled(bundled))
        #expect(HelmToolbox.locate(defaults: defaults, bundled: nil, locator: locator) == .path(URL(fileURLWithPath: "/usr/bin/true")))
        defaults.set("custom", forKey: ChartRoomSettings.helmChoice)
        defaults.set("/usr/bin/false", forKey: ChartRoomSettings.helmPath)
        #expect(HelmToolbox.locate(defaults: defaults, bundled: bundled, locator: locator) == .custom(URL(fileURLWithPath: "/usr/bin/false")))
        defaults.set("/does/not/exist", forKey: ChartRoomSettings.helmPath)
        #expect(HelmToolbox.locate(defaults: defaults, bundled: bundled, locator: locator) == .bundled(bundled), "a path that is not an executable falls back")
    }
}
