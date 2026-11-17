#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

// MARK: - Fakes

/// Bookmarks as table entries, so every outcome of resolve, stale refresh and access can be injected.
final class FakeScopedBackend: ScopedAccessBackend, @unchecked Sendable {
    struct Log: Equatable { var events: [String] = [] }
    private let lock = Mutex(State())
    private struct State {
        var table: [Data: Result<(URL, Bool), any Error>] = [:]
        var counter = 0
        var startResult: [String: Bool] = [:]
        var events: [String] = []
    }

    var events: [String] { lock.withLock { $0.events } }
    func setResolution(_ bookmark: Data, _ result: Result<(URL, Bool), any Error>) { lock.withLock { $0.table[bookmark] = result } }
    func setStart(_ path: String, _ ok: Bool) { lock.withLock { $0.startResult[path] = ok } }
    func bookmark(for url: URL, stale: Bool = false) -> Data {
        lock.withLock { s in
            s.counter += 1
            let data = Data("bm-\(s.counter)".utf8)
            s.table[data] = .success((url, stale))
            return data
        }
    }

    func resolve(_ bookmark: Data) throws -> (url: URL, stale: Bool) {
        let r = lock.withLock { s -> Result<(URL, Bool), any Error>? in s.events.append("resolve"); return s.table[bookmark] }
        switch r {
        case .success(let v)?: return (v.0, v.1)
        case .failure(let e)?: throw e
        case nil: throw CocoaError(.fileReadNoSuchFile)
        }
    }

    func makeBookmark(for url: URL) throws -> Data {
        let data = bookmark(for: url)
        lock.withLock { $0.events.append("make:\(url.path)") }
        return data
    }

    func start(_ url: URL) -> Bool {
        lock.withLock { s in s.events.append("start:\(url.path)"); return s.startResult[url.path] ?? true }
    }

    func stop(_ url: URL) { lock.withLock { $0.events.append("stop:\(url.path)") } }
}

final class FakeProbe: FileAccessProbing, @unchecked Sendable {
    private let results = Mutex<[String: FileAccessResult]>([:])
    func set(_ path: String, _ r: FileAccessResult) { results.withLock { $0[path] = r } }
    func probe(_ path: String) -> FileAccessResult { results.withLock { $0[path] } ?? .readable }
}

/// Counts how many times a credential plugin source was asked for.
final class PluginCountingClients: MooringsClientMaking, @unchecked Sendable {
    let sources = Mutex(0)
    func makeClient(config: ClusterConfig, secrets: ClusterSecrets) -> any KubeClientProtocol { DemoFleet.client(for: DemoFleet.configs[0]) }
    func tokenSource(for config: ClusterConfig, secrets: ClusterSecrets) -> BearerTokenSource? { sources.withLock { $0 += 1 }; return nil }
}

/// A sandboxed service over a scratch account home. `.kube` lives in the home; the gate is open unless given.
final class SandboxHarness: @unchecked Sendable {
    let scratch: Scratch
    let home: URL
    let state: MooringsState
    let backend = FakeScopedBackend()
    let probe = FakeProbe()
    let clients = PluginCountingClients()
    let changes = ChangeLog()
    var service: MooringsService!

    init(scratch: Scratch, gate: DevSafetyPolicy? = nil, sandboxed: Bool = true, firstRunCompleted: Bool = false, shell: String? = nil) throws {
        self.scratch = scratch
        home = try scratch.home()
        let gate = gate ?? openGate(home: home)
        state = MooringsState(overrides: DiscoveredClusterStore(fileURL: scratch.root.appending(path: "discovered-clusters.json")),
                              preferences: MooringsPreferencesStore(fileURL: scratch.root.appending(path: "moorings.json")), gate: gate)
        try state.preferences.update { $0.firstRunCompleted = firstRunCompleted }
        service = MooringsService(
            config: MooringsConfiguration(gate: gate, home: home, explicitTestKubeconfig: nil, shellKubeconfig: { shell },
                                          registry: PeriodicTaskRegistry(), isSandboxed: { sandboxed }, accountHome: home,
                                          accessBackend: backend, fileProbe: probe),
            state: state, clients: clients, authorizer: AllowAuthorizer(), onChange: { [changes] c in changes.append(c) })
    }

    var kube: URL { home.appending(path: ".kube", directoryHint: .isDirectory) }
    func writeKube(_ name: String, _ text: String) throws { try text.write(to: kube.appending(path: name), atomically: true, encoding: .utf8) }
}

private let execUser = "    exec:\n          apiVersion: client.authentication.k8s.io/v1\n          command: aws\n          args: [eks, get-token]"

// MARK: - Source and bookmark model

@Suite("Moorings sandbox: the source model")
struct MooringsSourceModelTests {
    @Test func aSourceFromBeforeBookmarksDecodesWithNilAndEncodesWithoutTheKey() throws {
        let old = Data(#"{"kind":"userFolder","path":"/x/y","recursive":false}"#.utf8)
        let source = try JSONDecoder().decode(MooringsSource.self, from: old)
        #expect(source.bookmark == nil)
        let encoded = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        #expect(!encoded.contains("bookmark"))
    }

    @Test func todaysPreferencesFileDecodesAndReencodesIdentically() throws {
        var prefs = MooringsPreferences()
        prefs.userSources = [MooringsSource(kind: .userFolder, path: "/x/y", recursive: true)]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let before = try encoder.encode(prefs)
        let again = try encoder.encode(try JSONDecoder().decode(MooringsPreferences.self, from: before))
        #expect(before == again)
        #expect(!String(decoding: before, as: UTF8.self).contains("bookmark"))
    }

    @Test func aBookmarkSurvivesARoundTrip() throws {
        let s = MooringsSource(kind: .kubeFolder, path: "/a", bookmark: Data([1, 2, 3]))
        #expect(try JSONDecoder().decode(MooringsSource.self, from: JSONEncoder().encode(s)).bookmark == Data([1, 2, 3]))
    }

    @Test func aRefreshedBookmarkIsTheSameSource() {
        let a = MooringsSource(kind: .userFolder, path: "/a", bookmark: Data([1]))
        let b = MooringsSource(kind: .userFolder, path: "/a", bookmark: Data([2]))
        #expect(a != b)
        #expect(MooringsService.sameSource(a, b))
        #expect(!MooringsService.sameSource(a, MooringsSource(kind: .userFolder, path: "/a", recursive: true)))
    }
}

// MARK: - SecurityScopedAccess

@Suite("Moorings sandbox: security-scoped access")
struct SecurityScopedAccessTests {
    private let folder = URL(fileURLWithPath: "/private/tmp/claude-501/grants/kube", isDirectory: true)

    @Test func aWorkingBookmarkIsResolvedAndHeld() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let source = MooringsSource(kind: .kubeFolder, path: SecurityScopedAccess.normalizedPath(folder), bookmark: b.bookmark(for: folder))
        let outcome = access.restore(source)
        #expect(outcome == .active(source: source, replacing: nil))
        #expect(access.isHolding(source.id))
        #expect(!b.events.contains { $0.hasPrefix("stop") })
    }

    @Test func aSourceWithoutABookmarkIsNotResolvedOrHeld() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let s = MooringsSource(kind: .userFolder, path: "/a")
        #expect(access.restore(s) == .active(source: s, replacing: nil))
        #expect(b.events.isEmpty)
    }

    @Test func aStaleBookmarkIsRemadeWhileAccessIsHeld() throws {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let old = b.bookmark(for: folder, stale: true)
        let source = MooringsSource(kind: .kubeFolder, path: SecurityScopedAccess.normalizedPath(folder), bookmark: old)
        guard case .active(let refreshed, let replacing) = access.restore(source) else { Issue.record("not active"); return }
        #expect(replacing == source.id)
        #expect(refreshed.bookmark != old)
        let path = SecurityScopedAccess.normalizedPath(folder)
        let events = b.events
        let start = try #require(events.firstIndex(of: "start:\(folder.path)"))
        let make = try #require(events.firstIndex(of: "make:\(folder.path)"))
        #expect(start < make)   // refreshed while accessing
        #expect(refreshed.path == path)
    }

    @Test func aMovedFolderGetsItsNewPathAndTheOldIdIsNotHeld() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let moved = URL(fileURLWithPath: "/private/tmp/claude-501/grants/moved", isDirectory: true)
        let source = MooringsSource(kind: .userFolder, path: "/private/tmp/claude-501/grants/kube", bookmark: b.bookmark(for: moved, stale: true))
        guard case .active(let refreshed, let replacing) = access.restore(source) else { Issue.record("not active"); return }
        #expect(refreshed.path == SecurityScopedAccess.normalizedPath(moved))
        #expect(replacing == source.id)
        #expect(access.isHolding(refreshed.id))
        #expect(!access.isHolding(source.id))
    }

    @Test func error4MeansTheFolderIsGone() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let bm = Data("gone".utf8)
        b.setResolution(bm, .failure(CocoaError(.fileReadNoSuchFile)))   // Cocoa error 4
        let source = MooringsSource(kind: .kubeFolder, path: "/x", bookmark: bm)
        #expect(access.restore(source) == .folderGone(source))
        #expect(!access.isHolding(source.id))
        #expect(!b.events.contains { $0.hasPrefix("start") })
    }

    @Test func aFolderInTheTrashIsGoneNotMoved() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let trashed = URL(fileURLWithPath: "/Users/x/.Trash/.kube", isDirectory: true)
        let source = MooringsSource(kind: .kubeFolder, path: "/Users/x/.kube", bookmark: b.bookmark(for: trashed, stale: true))
        #expect(access.restore(source) == .folderGone(source))
        #expect(!b.events.contains { $0.hasPrefix("start") })
    }

    @Test func aRefusedStartIsNeedsAccessAndStopIsNeverCalled() {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        b.setStart(folder.path, false)
        let source = MooringsSource(kind: .kubeFolder, path: SecurityScopedAccess.normalizedPath(folder), bookmark: b.bookmark(for: folder))
        #expect(access.restore(source) == .needsAccess(source))
        access.release(source.id)
        #expect(!b.events.contains { $0.hasPrefix("stop") })
    }

    @Test func aGrantBookmarksThenHoldsTheResolvedUrlAndReleaseStopsIt() throws {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        let s = try access.grant(folder, kind: .userFolder)
        #expect(s.bookmark != nil)
        #expect(access.isHolding(s.id))
        access.release(s.id)
        access.release(s.id)   // a second release is a no-op
        #expect(b.events.filter { $0.hasPrefix("stop") }.count == 1)
        #expect(!access.isHolding(s.id))
    }

    @Test func aRegrantStartsTheNewAccessBeforeStoppingTheOld() throws {
        let b = FakeScopedBackend()
        let access = SecurityScopedAccess(backend: b)
        _ = try access.grant(folder, kind: .userFolder)
        _ = try access.grant(folder, kind: .userFolder)
        let ev = b.events.filter { $0.hasPrefix("start") || $0.hasPrefix("stop") }
        #expect(ev == ["start:\(folder.path)", "start:\(folder.path)", "stop:\(folder.path)"])
    }

    @Test func aRefusedGrantThrows() {
        let b = FakeScopedBackend()
        b.setStart(folder.path, false)
        #expect(throws: GrantError.self) { _ = try SecurityScopedAccess(backend: b).grant(folder, kind: .kubeFolder) }
    }
}

// MARK: - Policy, planner, probe

@Suite("Moorings sandbox: grant rules")
struct FolderGrantPolicyTests {
    private let home = URL(fileURLWithPath: "/private/tmp/claude-501/fakehome", isDirectory: true)

    @Test func theHomeFolderAndItsAncestorsAreRefused() {
        #expect(throws: GrantError.isHomeFolder) { try FolderGrantPolicy.validateKubeFolder(home, home: home) }
        #expect(throws: GrantError.isHomeFolder) { try FolderGrantPolicy.validateKubeFolder(home.deletingLastPathComponent(), home: home) }
        #expect(throws: GrantError.isHomeFolder) { try FolderGrantPolicy.validateFolder(URL(fileURLWithPath: "/"), home: home) }
        #expect(throws: GrantError.isHomeFolder) { try FolderGrantPolicy.validateAccessGrant(home, needed: home.appending(path: ".minikube").path, home: home) }
    }

    @Test func theKubeFolderIsAccepted() throws {
        try FolderGrantPolicy.validateKubeFolder(home.appending(path: ".kube"), home: home)
        #expect(throws: GrantError.notKubeFolder) { try FolderGrantPolicy.validateKubeFolder(home.appending(path: "work"), home: home) }
    }

    @Test func anExtraFolderMayBeAnyFolderBelowHome() throws {
        try FolderGrantPolicy.validateFolder(home.appending(path: "work/kubes"), home: home)
    }

    @Test func anAccessGrantMustContainTheNeededFolder() throws {
        let needed = home.appending(path: ".minikube").path
        try FolderGrantPolicy.validateAccessGrant(home.appending(path: ".minikube"), needed: needed, home: home)
        let error = #expect(throws: GrantError.self) { try FolderGrantPolicy.validateAccessGrant(home.appending(path: ".other"), needed: needed, home: home) }
        #expect(error == .doesNotCover(needed: "~/.minikube"))
        #expect(error?.localizedDescription.contains("~/.minikube") == true)
    }

    @Test func theAccountKubeFolderIsRecognisedAndTildeUsesTheAccountHome() {
        #expect(FolderGrantPolicy.isAccountKubeFolder(home.appending(path: ".kube"), home: home))
        #expect(!FolderGrantPolicy.isAccountKubeFolder(home.appending(path: ".minikube"), home: home))
        #expect(FolderGrantPolicy.tildePath(home.appending(path: ".minikube/ca.crt").path, home: home) == "~/.minikube/ca.crt")
        #expect(FolderGrantPolicy.tildePath(home.path, home: home) == "~")
        #expect(FolderGrantPolicy.tildePath("/elsewhere/x", home: home) == "/elsewhere/x")
    }

    @Test func theKubeGrantIsOfferedOnlyWhenSandboxedUngatedAndWithoutAWorkingGrant() {
        #expect(FolderGrantPolicy.shouldOfferKubeGrant(sandboxed: true, gateActive: false, hasWorkingKubeFolder: false))
        #expect(!FolderGrantPolicy.shouldOfferKubeGrant(sandboxed: true, gateActive: true, hasWorkingKubeFolder: false))
        #expect(!FolderGrantPolicy.shouldOfferKubeGrant(sandboxed: false, gateActive: false, hasWorkingKubeFolder: false))
        #expect(!FolderGrantPolicy.shouldOfferKubeGrant(sandboxed: true, gateActive: false, hasWorkingKubeFolder: true))
    }

    @Test func plannerAsksForTheCommonParentBelowHome() {
        let files = [home.appending(path: ".minikube/ca.crt").path, home.appending(path: ".minikube/profiles/t/client.crt").path,
                     home.appending(path: ".minikube/profiles/t/client.key").path]
        #expect(AccessFolderPlanner.folders(forDenied: files, accountHome: home) == [home.appending(path: ".minikube").path])
        #expect(AccessFolderPlanner.folders(forDenied: [home.appending(path: ".config/foo/ca.crt").path], accountHome: home)
                == [home.appending(path: ".config/foo").path])
    }

    @Test func canonicalPathsAgreeForExistingAndMissingPartsAndNeverLoop() {
        #expect(PathCanonicalizer.canonical("/tmp/wh-none/a") == PathCanonicalizer.canonical("/private/tmp/wh-none/a"))
        #expect(PathCanonicalizer.canonical("") == "")
        #expect(PathCanonicalizer.canonical("relative/x") == "relative/x")
        #expect(PathCanonicalizer.canonical("/") == "/")
    }

    @Test func plannerNeverAsksForTheHomeFolderItself() {
        let files = [home.appending(path: ".a/ca.crt").path, home.appending(path: ".b/client.crt").path]
        // Common parent is the home folder: fall back to each file's own folder.
        #expect(AccessFolderPlanner.folders(forDenied: files, accountHome: home) == [home.appending(path: ".a").path, home.appending(path: ".b").path])
        #expect(AccessFolderPlanner.folders(forDenied: ["/opt/certs/ca.crt"], accountHome: home) == ["/opt/certs"])
        #expect(AccessFolderPlanner.folders(forDenied: [], accountHome: home).isEmpty)
    }
}

@Suite("Moorings sandbox: the file probe")
struct FileAccessProbeTests {
    @Test func epermIsNeedsAccessButEaccesAndEnoentAreNot() {
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: EPERM) == .needsAccess)
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: EACCES) == .denied)
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: ENOENT) == .missing)
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: ENOTDIR) == .missing)
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: EIO) == .other)
        #expect(POSIXFileAccessProbe.classify(statErrno: nil, openErrno: nil) == .readable)
        #expect(POSIXFileAccessProbe.classify(statErrno: ENOENT, openErrno: nil) == .missing)
        #expect(POSIXFileAccessProbe.classify(statErrno: ENOTDIR, openErrno: nil) == .missing)
        #expect(POSIXFileAccessProbe.classify(statErrno: EIO, openErrno: nil) == .other)
    }

    @Test func cocoa257WithPosix1IsNeedsAccess() {
        let underlying = NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))
        let e = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSUnderlyingErrorKey: underlying])
        #expect(POSIXFileAccessProbe.classify(error: e) == .needsAccess)
        let eacces = NSError(domain: NSCocoaErrorDomain, code: 257, userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))])
        #expect(POSIXFileAccessProbe.classify(error: eacces) == .other)
        #expect(POSIXFileAccessProbe.classify(error: NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM))) == .needsAccess)
        #expect(POSIXFileAccessProbe.classify(error: CocoaError(.fileReadNoSuchFile)) == .missing)
        #expect(POSIXFileAccessProbe.classify(error: CocoaError(.fileReadCorruptFile)) == .other)
    }

    @Test func theRealProbeSeesReadableAndMissingFiles() throws {
        let s = try Scratch(); defer { s.cleanup() }
        let f = try s.write("a.txt", "x")
        #expect(POSIXFileAccessProbe().probe(f.path) == .readable)
        #expect(POSIXFileAccessProbe().probe(s.root.appending(path: "nope").path) == .missing)
    }
}

// MARK: - The service in the sandbox

@Suite("Moorings sandbox: the service")
struct MooringsSandboxServiceTests {
    @Test func theKubeFolderGrantMakesConfigTheDefaultSetAndNoShellKubeconfigIsUsed() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let shellFile = try s.write("shell.yaml", kubeconfigText(context: "from-shell", server: "https://shell.example.test:6443"))
        let h = try SandboxHarness(scratch: s, shell: shellFile.path)
        try h.writeKube("config", kubeconfigText(context: "kube-config"))
        try h.writeKube("extra.yaml", kubeconfigText(context: "kube-extra", server: "https://x.example.test:6443"))
        #expect(await h.service.needsKubeGrant())
        await h.service.rescan()
        #expect(h.state.contexts.isEmpty)   // nothing is read before a grant, and the shell variable is ignored
        try await h.service.grantKubeFolder(h.kube)
        let names = Set(h.state.contexts.map(\.context.name))
        #expect(names == ["kube-config", "kube-extra"])
        #expect(!(await h.service.needsKubeGrant()))
        #expect(await h.service.grantedFolders().map(\.source.kind) == [.kubeFolder])
    }

    @Test func theHomeFolderIsRefusedAndNothingIsStored() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        await #expect(throws: GrantError.isHomeFolder) { try await h.service.grantKubeFolder(h.home) }
        #expect(h.state.preferences.value.userSources.isEmpty)
        #expect(h.backend.events.isEmpty)
    }

    @Test func aGatedBuildNeverOffersOrTakesTheKubeGrant() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let home = try s.home()
        let h = try SandboxHarness(scratch: s, gate: activeGate(home: home))
        #expect(!(await h.service.needsKubeGrant()))
        await #expect(throws: GrantError.notAvailable) { try await h.service.grantKubeFolder(h.kube) }
        #expect(h.backend.events.isEmpty)
    }

    @Test func grantsAreRestoredAtStartWithoutAskingAgain() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        try h.writeKube("config", kubeconfigText(context: "kube-config"))
        let bm = h.backend.bookmark(for: h.kube)
        try h.state.preferences.update { $0.userSources = [MooringsSource(kind: .kubeFolder, path: h.kube.path, bookmark: bm)] }
        await h.service.start()
        #expect(h.state.contexts.map(\.context.name) == ["kube-config"])
        #expect(!(await h.service.needsKubeGrant()))
        await h.service.stop()
    }

    @Test func aStaleBookmarkIsSavedBackAndAGoneFolderIsOfferedAgain() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let old = h.backend.bookmark(for: h.kube, stale: true)
        let gone = Data("gone".utf8)
        h.backend.setResolution(gone, .failure(CocoaError(.fileReadNoSuchFile)))
        let goneSource = MooringsSource(kind: .userFolder, path: "/private/tmp/claude-501/grants/gone", bookmark: gone)
        try h.state.preferences.update {
            $0.userSources = [MooringsSource(kind: .kubeFolder, path: h.kube.path, bookmark: old), goneSource]
        }
        await h.service.start()
        await h.service.stop()
        let stored = h.state.preferences.value.userSources
        #expect(stored.first { $0.kind == .kubeFolder }?.bookmark != old)
        let folders = await h.service.grantedFolders()
        #expect(folders.first { $0.source.kind == .userFolder }?.problem == .folderGone)
        #expect(folders.first { $0.source.kind == .kubeFolder }?.problem == nil)
        #expect(await h.service.grantProblems[goneSource.id] == .folderGone)
    }

    @Test func aMovedFolderReplacesItsOldEntryAndADuplicateIsDropped() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let target = try s.dir("kubes-new")
        let a = MooringsSource(kind: .userFolder, path: "/private/tmp/claude-501/grants/old", bookmark: h.backend.bookmark(for: target, stale: true))
        try h.state.preferences.update { $0.userSources = [a] }
        await h.service.start(); await h.service.stop()
        #expect(h.state.preferences.value.userSources.map(\.path) == [SecurityScopedAccess.normalizedPath(target)])
        // Now the old one moves onto a path that already has an entry.
        let existing = MooringsSource(kind: .userFolder, path: SecurityScopedAccess.normalizedPath(target), bookmark: h.backend.bookmark(for: target))
        let moved = MooringsSource(kind: .userFolder, path: "/private/tmp/claude-501/grants/old2", bookmark: h.backend.bookmark(for: target, stale: true))
        try h.state.preferences.update { $0.userSources = [existing, moved] }
        await h.service.start(); await h.service.stop()
        #expect(h.state.preferences.value.userSources.count == 1)
    }

    @Test func addFolderIsBookmarkedAndKeptUnderAPrivateTmpFixture() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let folder = try s.dir("more")
        try kubeconfigText(context: "more-ctx", server: "https://more.example.test:6443").write(to: folder.appending(path: "a.yaml"), atomically: true, encoding: .utf8)
        try await h.service.addFolderSource(folder)
        #expect(h.state.contexts.map(\.context.name) == ["more-ctx"])
        let granted = await h.service.grantedFolders()
        #expect(granted.count == 1 && granted[0].source.bookmark != nil)
        try await h.service.removeSource(granted[0].source)
        #expect(h.state.contexts.isEmpty)
        #expect(h.backend.events.contains("stop:\(folder.path)"))
        #expect(await h.service.grantedFolders().isEmpty)
    }

    @Test func fileSourcesAreNotOfferedInTheSandboxOnly() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        #expect(!(try SandboxHarness(scratch: s)).service.isAvailable)
        #expect(try SandboxHarness(scratch: s, sandboxed: false).service.isAvailable)
    }

    @Test func anExecContextIsShownButUnselectableAndNotAutoAdded() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s, firstRunCompleted: true)
        try h.writeKube("config", kubeconfigText(context: "eks", user: execUser))
        try await h.service.grantKubeFolder(h.kube)
        let ctx = try #require(h.state.contexts.first)
        #expect(ctx.authSummary == .exec(command: "aws"))
        let rows = await h.service.firstRunRows()
        #expect(rows.first?.selectable == false)
        #expect(rows.first?.unselectableReason == EditionNotice.execPlugin(command: "aws"))
        // Found after the first run: not auto-added.
        #expect(h.state.overrides.override(for: ctx.id) == nil)
        try await h.service.completeFirstRun(choices: [ctx.id: FirstRunChoice(selected: true, environment: .development, environmentPicked: true, allowChanges: false)])
        #expect(h.state.overrides.override(for: ctx.id)?.added != true)
    }

    @Test func aSandboxedExecCheckYieldsTheNewResultAndNeverAsksForAPlugin() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        try h.writeKube("config", kubeconfigText(context: "eks", user: execUser))
        try await h.service.grantKubeFolder(h.kube)
        let id = try #require(h.state.contexts.first?.id)
        let result = await h.service.check(id)
        #expect(result == .unavailableInEdition(command: "aws"))
        #expect(h.state.checkState(for: id) == .result(.unavailableInEdition(command: "aws")))
        #expect(h.clients.sources.withLock { $0 } == 0)
        if case .result(.unreachable) = h.state.checkState(for: id) { Issue.record("unreachable") }
    }

    @Test func theSameContextOutsideTheSandboxIsNotBlockedByTheEdition() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s, sandboxed: false, shell: nil)
        let f = try s.write("kc.yaml", kubeconfigText(context: "eks", user: execUser))
        try await h.service.addFileSource(f)
        let id = try #require(h.state.contexts.first?.id)
        let result = await h.service.check(id)
        #expect(result != .unavailableInEdition(command: "aws"))
        #expect(h.clients.sources.withLock { $0 } == 1)
    }

    @Test func adoptingAnExecContextIsRefusedInTheSandbox() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        try h.writeKube("config", kubeconfigText(context: "eks", user: execUser))
        try await h.service.grantKubeFolder(h.kube)
        let id = try #require(h.state.contexts.first?.id)
        await #expect(throws: MooringsError.unavailableInEdition(command: "aws")) { _ = try await h.service.prepareAdoption(id: id) }
    }

    private func certUser(_ h: SandboxHarness) -> String {
        "    client-certificate: \(h.home.path)/.minikube/profiles/t/client.crt\n    client-key: \(h.home.path)/.minikube/profiles/t/client.key"
    }

    @Test func referencedFilesOutsideAGrantAreNeedsAccessAndAGrantClearsItAndRebuildsTheClient() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let crt = h.home.appending(path: ".minikube/profiles/t/client.crt").path
        h.probe.set(crt, .needsAccess)
        h.probe.set(h.home.appending(path: ".minikube/profiles/t/client.key").path, .needsAccess)
        try h.writeKube("config", kubeconfigText(context: "mini", server: "https://127.0.0.1:8443", user: certUser(h)))
        try await h.service.grantKubeFolder(h.kube)
        let ctx = try #require(h.state.contexts.first)
        let minikube = PathCanonicalizer.canonical(h.home.appending(path: ".minikube/profiles/t"))
        #expect(ctx.accessFolders == [minikube])
        let id = ctx.id
        #expect(await h.service.check(id) == .needsAccess(folder: minikube))
        // The person grants the folder: same fingerprint, but the cluster is reported changed so its client is rebuilt.
        h.probe.set(crt, .readable)
        h.probe.set(h.home.appending(path: ".minikube/profiles/t/client.key").path, .readable)
        let before = h.changes.all.count
        let change = await h.service.rescan()
        #expect(change.changed == [id])
        #expect(h.changes.all.count == before + 1)
        #expect(h.state.context(for: id)?.accessFolders == [])
    }

    @Test func aGateRefusalIsNeverShownAsNeedsAccessAndEaccesIsNotEither() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        h.probe.set(h.home.appending(path: ".minikube/profiles/t/client.crt").path, .denied)
        h.probe.set(h.home.appending(path: ".minikube/profiles/t/client.key").path, .missing)
        try h.writeKube("config", kubeconfigText(context: "mini", server: "https://127.0.0.1:8443", user: certUser(h)))
        try await h.service.grantKubeFolder(h.kube)
        #expect(h.state.contexts.first?.accessFolders == [])
    }

    @Test func outsideTheSandboxNothingIsProbedAndAccessFoldersStayEmpty() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s, sandboxed: false)
        h.probe.set(h.home.appending(path: ".minikube/profiles/t/client.crt").path, .needsAccess)
        let f = try s.write("kc.yaml", kubeconfigText(context: "mini", server: "https://127.0.0.1:8443", user: certUser(h)))
        try await h.service.addFileSource(f)
        #expect(h.state.contexts.first?.accessFolders == [])
    }

    @Test func aSymlinkedConfigWhoseTargetIsOutsideTheGrantNamesTheTargetFolder() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let elsewhere = try s.write("work/kc.yaml", kubeconfigText(context: "linked"))
        try FileManager.default.createSymbolicLink(at: h.kube.appending(path: "config"), withDestinationURL: elsewhere)
        h.probe.set(elsewhere.path, .needsAccess)
        try await h.service.grantKubeFolder(h.kube)
        #expect(h.state.contexts.isEmpty)
        let needed = await h.service.accessNeeded
        #expect(needed.values.first == elsewhere.deletingLastPathComponent().path)
        #expect(await h.service.issues.values.first?.contains("Needs access to") == true)
    }

    @Test func grantingAFolderForReferencedFilesIsKeptAsAnAccessGrantAndNeverScanned() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        let mini = try h.home.appending(path: ".minikube", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: mini, withIntermediateDirectories: true)
        try kubeconfigText(context: "should-not-appear").write(to: mini.appending(path: "config.yaml"), atomically: true, encoding: .utf8)
        try await h.service.grantAccessFolder(mini, needed: mini.path)
        #expect((await h.service.grantedFolders()).map(\.source.kind) == [.accessGrant])
        #expect(h.state.contexts.isEmpty)
        await #expect(throws: GrantError.self) { try await h.service.grantAccessFolder(h.home.appending(path: ".other"), needed: mini.path) }
        // The account's own .kube goes to its own kind.
        try await h.service.grantAccessFolder(h.kube, needed: h.kube.path)
        #expect((await h.service.grantedFolders()).map(\.source.kind).contains(.kubeFolder))
    }

    @Test func aSecondKubeGrantReplacesTheFirstAndStopsItsAccess() async throws {
        let s = try Scratch(); defer { s.cleanup() }
        let h = try SandboxHarness(scratch: s)
        try await h.service.grantKubeFolder(h.kube)
        let other = h.home.appending(path: "dotfiles/.kube", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try await h.service.grantKubeFolder(other)
        let kinds = await h.service.grantedFolders()
        #expect(kinds.count == 1)
        #expect(h.backend.events.contains("stop:\(h.kube.path)"))
    }
}

@Suite("Moorings sandbox: the development dump")
struct MooringsDumpTests {
    @Test func theDumpHoldsNoSecret() throws {
        let token = ["tok", "en", "-", "secret", "-", "1234"].joined()
        let gate = DevSafetyPolicy(isActive: false)
        let ctx = try #require(try KubeconfigParser.parse(kubeconfigText(context: "c", server: "https://dump.example.test:6443",
                                                                         user: "    token: \(token)")).contexts.first)
        #expect(ctx.auth == .token(token))
        let discovered = DiscoveredContext.make(key: DiscoveredContextKey(definingFile: "/x/config", contextName: "c"), sourceID: "s", context: ctx,
                                                isCurrent: true, shadowedBy: nil, gate: gate)
        let granted = [GrantedFolder(source: MooringsSource(kind: .kubeFolder, path: "/x", bookmark: Data(token.utf8)), problem: .folderGone)]
        let dump = MooringsDump.make(sandboxed: true, contexts: [discovered], issues: ["/x/y": "bad"], accessNeeded: ["/x/y": "/x"], grants: granted)
        let text = String(decoding: try dump.json(), as: UTF8.self)
        #expect(!text.contains(token))
        #expect(text.contains("dump.example.test") && text.contains("folderGone"))
        #expect(try JSONDecoder().decode(MooringsDump.self, from: dump.json()) == dump)
    }
}

@Suite("Moorings sandbox: kubeconfig export")
struct KubeconfigExportModeTests {
    @Test func theSandboxUsesASavePanelAndRefusesTheHomeMerge() {
        #expect(KubeconfigWriter.exportMode(edition: Edition(isSandboxed: true)) == .savePanel)
        #expect(KubeconfigWriter.exportMode(edition: Edition(isSandboxed: false)) == .mergeIntoHomeConfig)
        #expect(throws: KubeconfigExportError.useSavePanel) { try KubeconfigWriter.assertMayMergeIntoHomeConfig(edition: Edition(isSandboxed: true)) }
        #expect(throws: Never.self) { try KubeconfigWriter.assertMayMergeIntoHomeConfig(edition: Edition(isSandboxed: false)) }
        #expect(KubeconfigExportError.useSavePanel.errorDescription?.contains("can't write to ~/.kube") == true)
    }
}
#endif
