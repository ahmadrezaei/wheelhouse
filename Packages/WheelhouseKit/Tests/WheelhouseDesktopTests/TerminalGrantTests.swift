#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import WheelhouseDesktop
import WheelhouseKit

@Suite("Terminal grants and Direct files", .serialized)
struct TerminalGrantTests {
    private func request() throws -> GrantRequest {
        GrantRequest(kind: .mutation, shape: RequestClassifier.shape(of: try RequestClassifier.canonicalSegments(of: "/apis/apps/v1/namespaces/shop/deployments/web")), method: "PATCH")
    }

    @Test func aCommandGrantCoversOnlyTheProcessGroupThatWasApproved() throws {
        let foreground = Mutex<pid_t>(100)
        let registry = SessionRegistry(gate: { DevSafetyPolicy(isActive: false) })
        let cluster = ClusterConfig(id: "prod1", name: "prod-eu", server: URL(string: "https://prod.test:6443")!, environment: .production)
        let session = try registry.create(cluster: cluster, origin: .terminal(paneID: "p1"), binding: .pty(device: 1, session: 50, foreground: { foreground.withLock { $0 } })).session
        let grants = GrantStore()
        session.reportedCommand = ReportedCommand(id: "c1", line: "kubectl rollout restart deploy/web")
        #expect(grants.grantCommand(session: session, command: try #require(session.reportedCommand), group: 100))
        let approved = PeerProcess(pid: 101, session: 50, group: 100)
        #expect(grants.covers(try request(), session: session, peer: approved))
        // A background job takes the foreground during the approved command: it is the foreground job now, and still not covered.
        foreground.withLock { $0 = 200 }
        let intruder = PeerProcess(pid: 201, session: 50, group: 200)
        #expect(GrantStore.peerIsBound(intruder, to: session.binding))
        #expect(!grants.covers(try request(), session: session, peer: intruder))
        #expect(!grants.covers(try request(), session: session, peer: approved))
    }

    @Test func nothingIsApprovedWhileLockedAndNoGrantSurvivesTheUnlock() async throws {
        let holder = Mutex<GangwayService?>(nil)
        // The sheet answers "yes" only after the app locked: the answer must not create a batch approval or a grant.
        let late = ScriptedConfirmer { _ in
            holder.withLock { $0 }?.lock()
            return true
        }
        let rig = try await GangwayRig(environment: .production, confirmer: late)
        defer { rig.stop() }
        holder.withLock { $0 = rig.service }
        let (handle, token) = try await rig.open()
        let client = try await rig.client()
        try await client.send(rig.request("POST", "/api/v1/namespaces/a/configmaps", token: token, body: "{}"))
        let response = try #require(await client.readResponse(timeout: .seconds(8)))
        #expect(response.status == 403)
        rig.service.unlock()
        #expect(!rig.service.grants.hasCommandGrant(session: handle.session))
        // The approval the sheet gave while locked was never recorded.
        let hold = try #require(rig.service.grants.pendingBatchCount(session: handle.session))
        #expect(hold == 0)
    }

    private func context() throws -> KubeconfigContext {
        let yaml = "apiVersion: v1\nkind: Config\nclusters:\n- name: c\n  cluster: {server: \"https://127.0.0.1:6443\"}\nusers:\n- name: u\n  user: {token: t}\ncontexts:\n- name: d\n  context: {cluster: c, user: u}\ncurrent-context: d\n"
        return try #require(try KubeconfigParser.parse(yaml, environment: .desktop(baseDirectory: FileManager.default.temporaryDirectory)).contexts.first)
    }

    @Test func launchRemovesEveryDirectFolderAndAFailedWriteLeavesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wh-direct-clean-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let a = try DirectKubeconfig.write(try context(), root: root)
        let b = try DirectKubeconfig.write(try context(), root: root)
        #expect(FileManager.default.fileExists(atPath: a.file.path) && FileManager.default.fileExists(atPath: b.file.path))
        DirectKubeconfig.removeAll(root: root)
        #expect(!FileManager.default.fileExists(atPath: a.directory.path) && !FileManager.default.fileExists(atPath: b.directory.path))
        #expect(throws: (any Error).self) { try DirectKubeconfig.write(try context(), root: root, id: UUID(), failAfterOpen: true) }
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: "direct").path)) ?? []
        #expect(leftovers.isEmpty)
    }
}
#endif
