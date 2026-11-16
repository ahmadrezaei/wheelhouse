import Foundation
import Testing
import WheelhouseDesktop
import WheelhouseKit
import WheelhouseUI
@testable import WheelhouseMac

private let folderPack = """
apiVersion: rigging.wheelhouse.app/v1
kind: Pack
metadata: { name: sample-pack, version: 1.0.0, description: "A sample" }
sidebar:
  - { apiGroup: example.io, title: "Examples", kinds: [Widget, Gadget] }
views:
  - id: widgets
    match: { group: example.io, kind: Widget }
    columns: [ { name: Phase, path: ".status.phase" } ]
commands:
  - title: "Describe"
    for: { group: example.io, kind: Widget }
    terminal: "kubectl describe widget {{name}} -n {{namespace}}"
"""

@MainActor
private func tempPaths() -> (AppPaths, URL) {
    let home = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appending(path: "wh-rig-\(UUID().uuidString)", directoryHint: .isDirectory)
    try? FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    return (AppPaths(gateActive: true, bundleID: nil, home: home, temporaryDirectory: home), home)
}

private func makeFolder(_ text: String = folderPack, in dir: URL) throws -> URL {
    let folder = dir.appending(path: "pack-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try text.write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
    return folder
}

@Suite("Rigging store")
@MainActor
struct RiggingStoreTests {
    @Test func builtInPacksAreListedAndOffByDefault() {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let store = RiggingStore(paths: paths)
        #expect(Set(store.installed.map(\.entry.name)) == Set(BuiltInRiggingPacks.names))
        #expect(store.active.isEmpty, "built-in packs are opt-in")
        for name in BuiltInRiggingPacks.names { store.setEnabled(name, true) }
        #expect(store.active.count == 8)
        store.setEnabled("keda", false)
        #expect(store.active.count == 7 && !store.active.contains { $0.metadata.name == "keda" })
        // The choice is remembered.
        #expect(RiggingStore(paths: paths).active.count == 7)
        #expect(store.viewIndex["cert-manager.io/Certificate"]?.pack == "cert-manager")
    }

    @Test func aFolderPackIsOnlyStoredAfterApprovalAndIsPinnedToTheApprovedFile() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try makeFolder(in: home)
        let store = RiggingStore(paths: paths)
        let candidate = try store.candidate(folder: folder)
        #expect(candidate.sections.contains { $0.title.contains("Inserts these commands") })
        #expect(!store.installed.contains { $0.entry.name == "sample-pack" }, "nothing is stored before approval")
        store.approve(candidate)
        #expect(store.active.contains { $0.metadata.name == "sample-pack" })
        #expect(store.sidebarLayouts["example.io"]?.title == "Examples" && store.sidebarLayouts["example.io"]?.order == ["Widget", "Gadget"])
        // A new store (a relaunch) finds it approved.
        #expect(RiggingStore(paths: paths).active.contains { $0.metadata.name == "sample-pack" })
        // The file changes on disk: the pack switches off and cannot be switched on without a new approval.
        try (folderPack + "\n# edited").write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        store.rebuild()
        let changed = try #require(store.installedPack(named: "sample-pack"))
        #expect(changed.changedSinceApproval)
        #expect(!store.active.contains { $0.metadata.name == "sample-pack" })
        store.setEnabled("sample-pack", true)
        #expect(!store.active.contains { $0.metadata.name == "sample-pack" })
        store.approve(try store.candidate(folder: folder))
        #expect(store.active.contains { $0.metadata.name == "sample-pack" })
        store.remove("sample-pack")
        #expect(!store.installed.contains { $0.entry.name == "sample-pack" })
    }

    @Test func aChangedFolderPackIsNeverParsedAtLaunch() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try makeFolder(in: home)
        let store = RiggingStore(paths: paths)
        store.approve(try store.candidate(folder: folder))
        // Tampered with: nested 200,000 deep (it would overflow the stack if anything parsed it). The file is under the size limit.
        let deep = "x: " + String(repeating: "[", count: 200_000)
        try deep.write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        let relaunched = RiggingStore(paths: paths)
        let item = try #require(relaunched.installedPack(named: "sample-pack"))
        #expect(item.changedSinceApproval && item.loaded == nil && item.problem == nil)
        #expect(!relaunched.active.contains { $0.metadata.name == "sample-pack" })
        // Reviewing it is the person's request, so that is when it is read: a candidate they can approve again.
        try "x: 1\n".write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        #expect(throws: RiggingPackError.self) { try relaunched.candidateForReview("sample-pack") }
        try folderPack.replacingOccurrences(of: "version: 1.0.0", with: "version: 9.0.0").write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        let review = try relaunched.candidateForReview("sample-pack")
        #expect(review.loaded.pack.metadata.version == "9.0.0" && review.replacementNotice?.hasPrefix("Updates") == true)
        relaunched.approve(review)
        #expect(relaunched.active.contains { $0.metadata.name == "sample-pack" })
    }

    @Test func aSameNamePackFromAnotherSourceShowsAReplacementWarningAndAnUpdateShowsTheChanges() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let first = try makeFolder(in: home)
        let store = RiggingStore(paths: paths)
        store.approve(try store.candidate(folder: first))
        let other = try makeFolder(folderPack.replacingOccurrences(of: "version: 1.0.0", with: "version: 2.0.0"), in: home)
        let replacement = try store.candidate(folder: other)
        #expect(replacement.replacementNotice?.contains("Replaces the installed pack “sample-pack”") == true)
        #expect(replacement.changes.contains { $0.hasPrefix("+ ") && $0.contains("2.0.0") } && replacement.changes.contains { $0.hasPrefix("- ") && $0.contains("1.0.0") })
        try folderPack.replacingOccurrences(of: "version: 1.0.0", with: "version: 3.0.0").write(to: first.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        // The same folder again is an update, not a replacement from elsewhere.
        store.rebuild()
        let again = try store.candidate(folder: first)
        #expect(again.replacementNotice?.hasPrefix("Updates") == true)
        let fresh = try RiggingStore(paths: tempPaths().0).candidate(folder: first)
        #expect(fresh.replacementNotice == nil && fresh.changes.isEmpty)
    }

    @Test func aPackCannotTakeTheNameOfABuiltInPack() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try makeFolder(folderPack.replacingOccurrences(of: "sample-pack", with: "keda"), in: home)
        #expect(throws: RiggingStore.StoreError.self) { try RiggingStore(paths: paths).candidate(folder: folder) }
    }

    @Test func aFolderWithALinkOrABadFileIsRefused() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try makeFolder(in: home)
        try FileManager.default.createSymbolicLink(at: folder.appending(path: "x"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: RiggingPackError.self) { try RiggingStore(paths: paths).candidate(folder: folder) }
        let bad = try makeFolder(folderPack.replacingOccurrences(of: "{{name}}", with: "{{secret}}"), in: home)
        #expect(throws: RiggingPackError.self) { try RiggingStore(paths: paths).candidate(folder: bad) }
    }

    @Test func gitPacksAreFetchedIntoTheAppFolderAndPinned() async throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        // A local repository stands in for a remote (the fixture never touches the network).
        let work = home.appending(path: "work", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try folderPack.write(to: work.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        let env = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.com",
                   "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.com", "HOME": "/nonexistent"]
        func git(_ args: [String]) async throws -> String {
            let r = try await Subprocess.run(ProcessSpec(executable: URL(fileURLWithPath: "/usr/bin/git"), arguments: args, environment: env, currentDirectory: work, timeout: .seconds(30)))
            return r.stdoutString.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["init", "--quiet", "-b", "main"])
        _ = try await git(["add", "-A"])
        _ = try await git(["commit", "--quiet", "-m", "c"])
        let commit = try await git(["rev-parse", "HEAD"])
        let store = RiggingStore(paths: paths, allowLocalGit: true)
        let candidate = try await store.candidate(gitURL: work.path, ref: nil)
        #expect(candidate.source.kind == .git && candidate.source.commit == commit)
        store.approve(candidate)
        let folder = store.root.appending(path: "sample-pack@\(commit)")
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "rigging.yaml").path))
        #expect(store.active.contains { $0.metadata.name == "sample-pack" })
        store.remove("sample-pack")
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }
}

private let healthPack = """
apiVersion: rigging.wheelhouse.app/v1
kind: Pack
metadata: { name: noisy, version: 1.0.0 }
healthRules:
  - for: { group: "", kind: Pod }
    when: { path: ".metadata.name", exists: true }
    tone: critical
    message: "{{name}} is flagged"
"""

@Suite("Rigging runtime")
@MainActor
struct RiggingRuntimeTests {
    private func runtime(pack: String?, builtIn: Bool) throws -> (RiggingRuntime, ClusterSession, URL) {
        let (paths, home) = tempPaths()
        let store = RiggingStore(paths: paths, builtIns: [])
        if let pack {
            let folder = try makeFolder(pack, in: home)
            store.approve(try store.candidate(folder: folder))
        }
        _ = builtIn
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(), defaults: UserDefaults(suiteName: "wh.rigging.\(UUID().uuidString)")!)
        registry.enterDemoMode(persist: false)
        let session = try #require(registry.session(for: registry.clusters[0].id))
        let controller = WorkspaceController(store: WorkspaceStore(file: nil), registry: registry, sidebarFactory: { SidebarModel(provider: RegistrySidebarProvider(registry: registry)) })
        return (RiggingRuntime(store: store, registry: registry, workspace: controller, activity: NoopActivityLog()), session, home)
    }

    private func pods(_ count: Int) -> [JSONValue] {
        (0..<count).map { ["metadata": ["name": .string("pod-\($0)"), "namespace": "default"]] }
    }

    @Test func healthItemsAreCappedPerRuleCarryThePackNameAndAFolderPackIsOnlyAWarning() async throws {
        let (rigging, session, home) = try runtime(pack: healthPack, builtIn: false)
        defer { try? FileManager.default.removeItem(at: home) }
        rigging.listObjects = { [self] _, _ in pods(50) }
        let items = await rigging.healthItems(for: session)
        #expect(items.count == RiggingRuntime.itemsPerRule + 1, "20 items and one “and N more”")
        #expect(items.allSatisfy { $0.severity == .warning && $0.title.hasPrefix("noisy: ") })
        #expect(items.last?.title == "noisy: and 30 more")
    }

    @Test func aLongDiffEndsWithANoteAboutTheRest() throws {
        let (paths, home) = tempPaths()
        defer { try? FileManager.default.removeItem(at: home) }
        let folder = try makeFolder(in: home)
        let store = RiggingStore(paths: paths)
        store.approve(try store.candidate(folder: folder))
        let long = folderPack + "\n" + (0..<300).map { "# line \($0)" }.joined(separator: "\n")
        try long.write(to: folder.appending(path: "rigging.yaml"), atomically: true, encoding: .utf8)
        let candidate = try store.candidate(folder: folder)
        #expect(candidate.changes.count == 201 && candidate.changes.last == "… and 100 more lines")
    }

    @Test func aFailedKindIsNotListedAgainOnTheNextPass() async throws {
        let (rigging, session, home) = try runtime(pack: healthPack, builtIn: false)
        defer { try? FileManager.default.removeItem(at: home) }
        var calls = 0
        rigging.listObjects = { _, _ in calls += 1; throw KubeError.unsupported("forbidden") }
        _ = await rigging.healthItems(for: session)
        _ = await rigging.healthItems(for: session)
        #expect(calls == 1)
    }

    @Test func aBuildWithoutTheFeatureStartsAndOffersNothing() throws {
        let (rigging, session, home) = try runtime(pack: healthPack, builtIn: false)
        defer { try? FileManager.default.removeItem(at: home) }
        rigging.isFeatureEnabled = { false }
        rigging.start()
        #expect(RiggingSidebarHook.views().isEmpty && RiggingSidebarHook.layouts().isEmpty)
        #expect(session.healthAugmenter == nil)
        #expect(rigging.compassCommands().isEmpty)
        let ref = ResourceRef(clusterID: session.id, kind: .pod, namespace: "default", name: "p")
        #expect(rigging.menuActions(for: ref, raw: [:]).isEmpty)
        #expect(rigging.railActions(for: .resource(ref)).isEmpty && rigging.railActions(for: .cluster(session.id)).isEmpty)
        // The seam a Distribution build uses: Rigging is out of the release set.
        #expect(!RiggingFeature.isEnabled(gateActive: false))
        #expect(RiggingFeature.isEnabled(gateActive: true))
    }

    @Test func oneHostPresentsAPendingConfirmation() {
        let center = RiggingConfirmCenter()
        let a = UUID(), b = UUID()
        #expect(!center.claim(a), "nothing pending")
        center.pending = ConfirmRequest(title: "t", message: "m", verb: "Go", cluster: ClusterConfig(name: "c", server: URL(string: "https://127.0.0.1:1")!), namespace: nil, resource: "r", confirmationText: "r", action: {})
        #expect(center.claim(a) && !center.claim(b))
        center.release(a)
        #expect(center.claim(b) && !center.claim(a))
        center.pending = nil
        #expect(!center.claim(b))
    }

    @Test func rigginglessFleetGlyphNeverGoesRedForAPack() {
        let critical = AttentionItem(id: "r", clusterID: "c1", severity: .critical, kind: .riggingRule, title: "t", detail: "d")
        #expect(FleetSummary.make(attention: [critical], clusterCount: 1).level == .warning)
        let real = AttentionItem(id: "p", clusterID: "c1", severity: .critical, kind: .crashLoop, title: "t", detail: "d")
        #expect(FleetSummary.make(attention: [critical, real], clusterCount: 1).level == .critical)
    }
}

@Suite("Rigging confirmations and sidebar")
@MainActor
struct RiggingConfirmationTests {
    @Test func aPackPortForwardAlwaysComesWithAHardenedConfirmSheetBadgedAsRigging() throws {
        let cluster = ClusterConfig(name: "prod-eu", server: URL(string: "https://127.0.0.1:6443")!, environment: .production)
        let session = ClusterSession(config: cluster, client: DemoKubeClient(config: DemoFleet.configs[0]))
        let plan = PortForwardPlan(target: PortForwardTarget(kind: .service, namespace: "monitoring", name: "grafana", remotePort: 3000), openTemplate: "http://127.0.0.1:{{localPort}}/")
        let request = RiggingConfirmations.portForward(plan: plan, pack: "demo", title: "Open Grafana", cluster: cluster, session: session, activity: NoopActivityLog())
        #expect(request.origin == .rigging(pack: "demo"))
        #expect(request.hasDefaultButton == false)
        #expect(request.inputDelay > 0)
        #expect(request.confirmationText == "grafana")
        #expect(request.facts.contains { $0.label == "Pack" && $0.value == "demo" })
        // Building the request starts nothing.
        #expect(SessionsHub.shared.forwards.isEmpty)
    }

    @Test func sidebarAppliesPackLayoutAndOpensPackViews() throws {
        let cluster = ClusterConfig(name: "dev", server: URL(string: "https://127.0.0.1:6443")!)
        func resource(_ name: String, _ kind: String) -> APIResource {
            let v: JSONValue = ["name": .string(name), "namespaced": true, "kind": .string(kind), "verbs": ["list", "get"], "group": "example.io", "version": "v1"]
            return try! v.decode(APIResource.self)
        }
        var input = SidebarBuildInput(clusters: [cluster], expandedClusters: [cluster.id], expandedGroups: ["\(cluster.id)|customResources", "\(cluster.id)|example.io"], filter: "", showsForbiddenKinds: true,
                                      discovery: [cluster.id: DiscoveryInfo(resources: [resource("alphas", "Alpha"), resource("gadgets", "Gadget"), resource("widgets", "Widget")])], rules: [:])
        input.riggingLayouts = ["example.io": (title: "Examples", order: ["Widget", "Gadget"])]
        input.riggingViews = ["example.io/Widget": (pack: "sample-pack", view: "widgets")]
        let out = SidebarTreeBuilder.build(input)
        func find(_ rows: [SidebarRow], _ test: (SidebarRow) -> Bool) -> SidebarRow? {
            for r in rows { if test(r) { return r }; if let f = find(r.children, test) { return f } }
            return nil
        }
        let group = try #require(find(out.rows) { $0.role == .apiGroup })
        #expect(group.title == "Examples")
        #expect(group.children.map(\.title) == ["Widget", "Gadget", "Alpha"])
        if case .feature(.riggingView(let ref))? = group.children.first?.destination { #expect(ref.pack == "sample-pack" && ref.view == "widgets" && ref.clusterID == cluster.id) }
        else { Issue.record("the covered kind should open its pack view") }
        if case .kind? = group.children.last?.destination {} else { Issue.record("an uncovered kind keeps the plain list") }
    }
}
