#if os(macOS)
import Foundation
import Testing
import WheelhouseKit
@testable import WheelhouseDesktop

@MainActor
private func makeModel(_ rig: GangwayRig, mode: LocalShellModel.Mode = .guarded, cluster: ClusterConfig? = nil) throws -> LocalShellModel {
    let home = rig.scratch.root.appending(path: "home-\(UUID().uuidString.prefix(6))", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let config = LocalShellModel.Configuration(cluster: cluster ?? rig.provider.config(for: rig.clusterID)!, shell: URL(fileURLWithPath: "/bin/zsh"), mode: mode,
                                               baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": home.path, "LANG": "en_US.UTF-8"],
                                               userFiles: .init(zshDirectory: home, bashHome: home), home: home,
                                               kubeCacheDir: home.appending(path: "cache"), directRoot: rig.scratch.root.appending(path: "direct-root"),
                                               helper: try PTYHelper.url(), gate: DevSafetyPolicy(isActive: true, allowedHosts: ["127.0.0.1"], home: rig.scratch.root))
    return LocalShellModel(configuration: config)
}

@MainActor
private func mark(_ model: LocalShellModel, _ code: Int, _ payload: String, forged: Bool = false) {
    model.process(OSCSequence(code: code, payload: payload + ";wh=" + (forged ? String(repeating: "0", count: 32) : (model.verificationNonce ?? ""))))
}

@Suite("LocalShellModel", .serialized)
@MainActor
struct LocalShellModelTests {
    @Test func threeForgedMarksDropTheSessionToPerRequestAndClearTheCommand() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        try await model.start(gangway: rig.service)
        mark(model, 633, "E;kubectl rollout restart deploy/web")
        mark(model, 133, "C")
        #expect(model.gangwaySession?.reportedCommand?.line == "kubectl rollout restart deploy/web")
        for _ in 0..<2 { mark(model, 133, "D;0", forged: true) }
        #expect(model.banner != .perRequest(LocalShellModel.forgedMessage))
        model.process(OSCSequence(code: 633, payload: "E;kubectl delete ns x"))            // no nonce at all counts too
        #expect(model.forgedMarks == 3)
        #expect(model.banner == .perRequest(LocalShellModel.forgedMessage))
        #expect(model.gangwaySession?.reportedCommand == nil)
        #expect(!rig.service.grants.hasCommandGrant(session: try #require(model.gangwaySession)))
        // From now on a verified command line is never published.
        mark(model, 133, "A")
        mark(model, 633, "E;kubectl scale deploy/web --replicas=1")
        mark(model, 133, "C")
        #expect(model.gangwaySession?.reportedCommand == nil)
        await model.close()
    }

    @Test func marksDriveTheReportedCommandAndEachRunGetsItsOwnID() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        try await model.start(gangway: rig.service)
        let session = try #require(model.gangwaySession)
        mark(model, 133, "A")
        #expect(model.banner == .guarded && model.isAtPrompt)
        var ids: [String] = []
        for _ in 0..<2 {
            mark(model, 633, "E;kubectl apply -f x.yaml")
            mark(model, 133, "C")
            ids.append(try #require(session.reportedCommand).id)
            #expect(model.currentCommand == "kubectl apply -f x.yaml" && !model.isAtPrompt)
            mark(model, 133, "D;0")
            #expect(session.reportedCommand == nil && model.currentCommand == nil)
        }
        #expect(ids[0] != ids[1])
        // A C with no E (an alias, an unsaved line) publishes nothing.
        mark(model, 133, "C")
        #expect(session.reportedCommand == nil)
        await model.close()
    }

    @Test func aChangedKubeconfigOrABypassFlagTurnsTheBannerUnguardedAndItRecovers() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        try await model.start(gangway: rig.service)
        let own = try #require(model.sessionKubeconfig).path
        mark(model, 133, "A")
        mark(model, 633, "P;KubeConfig=\(own)")
        #expect(model.banner == .guarded)
        mark(model, 633, "P;KubeConfig=/Users/x/.kube/config")
        guard case .unguarded = model.banner else { Issue.record("expected unguarded"); return }
        #expect(model.canRestore)
        mark(model, 633, "P;KubeConfig=\(own)")
        #expect(model.banner == .guarded)
        mark(model, 633, "E;kubectl --kubeconfig /tmp/x get po")
        mark(model, 133, "C")
        guard case .unguarded = model.banner else { Issue.record("expected unguarded for the bypass"); return }
        mark(model, 133, "D;0")
        mark(model, 133, "A")
        #expect(model.banner == .guarded)
        mark(model, 633, "P;KubeConfigUnset=1")
        guard case .unguarded = model.banner else { Issue.record("an unset KUBECONFIG is unguarded"); return }
        await model.close()
    }

    @Test func aChangedSessionFileEndsTheSessionAndTurnsTheBannerUnguarded() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        try await model.start(gangway: rig.service)
        let file = try #require(model.sessionKubeconfig)
        chmod(file.path, 0o600)
        model.checkIntegrity()
        guard case .unguarded = model.banner else { Issue.record("expected unguarded"); return }
        #expect(model.gangwaySession?.isRevoked == true)
        #expect(model.restore() == .needsNewShell)
        await model.close()
    }

    @Test func closingTheShellRemovesTheSessionFolderAndRevokesTheToken() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        try await model.start(gangway: rig.service)
        let dir = try #require(model.sessionKubeconfig).deletingLastPathComponent()
        let session = try #require(model.gangwaySession)
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "zdotdir").path))
        await model.close()
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        #expect(session.isRevoked)
        #expect(model.phase != .running)
    }

    @Test func theShellStartsGuardedAndIsBoundToItsPTY() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        var received = Data()
        model.onOutput = { received.append($0) }
        try await model.start(gangway: rig.service)
        for _ in 0..<100 where model.banner != .guarded { try await Task.sleep(for: .milliseconds(100)) }
        #expect(model.banner == .guarded)
        #expect(model.kind == .zsh)
        #expect(!received.isEmpty)
        if case .pty = try #require(model.gangwaySession).binding {} else { Issue.record("the session must be bound to the PTY") }
        await model.close()
    }

    @Test func aTerminalClosedBeforeItsShellStartsSpawnsNothingAndLeavesNoSession() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        let model = try makeModel(rig)
        await model.close()
        await #expect(throws: CancellationError.self) { try await model.start(gangway: rig.service) }
        #expect(model.ptyProcessID == nil)
        #expect(rig.service.registry.sessions.allSatisfy { $0.isRevoked })
    }

    @Test func directModeIsRefusedForProductionClusters() async throws {
        let rig = try await GangwayRig()
        defer { rig.stop() }
        var prod = try #require(rig.provider.config(for: rig.clusterID))
        prod.environment = .production
        let model = try makeModel(rig, mode: .direct, cluster: prod)
        await #expect(throws: (any Error).self) { try await model.start(gangway: nil) }
        #expect(model.phase == .notStarted)
    }
}
#endif
