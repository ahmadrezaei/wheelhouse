import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// A probe with fixed answers (a real EPERM can't be made outside a sandbox).
private struct FixedProbe: FileAccessProbing {
    var answers: [String: FileAccessResult]
    func probe(_ path: String) -> FileAccessResult { answers[path] ?? .readable }
}

/// The sandboxed edition's import: files a kubeconfig refers to are asked for by folder, and an exec plugin says why it can't be used.
@Suite("Import in the sandboxed edition")
struct ImportSandboxTests {
    private let home = URL(fileURLWithPath: "/private/tmp/claude-501/import-home", isDirectory: true)
    private var kubeconfig: String {
        """
        apiVersion: v1
        kind: Config
        clusters:
        - name: c
          cluster:
            server: https://c.example.test:6443
            certificate-authority: \(home.path)/.minikube/ca.crt
        users:
        - name: u
          user:
            client-certificate: \(home.path)/.minikube/profiles/t/client.crt
            client-key: "\(home.path)/.minikube/profiles/t/client.key"
            tokenFile: relative-token # a comment
        contexts:
        - name: c
          context: {cluster: c, user: u}
        """
    }

    @Test func everyReferencedFileIsListed() {
        let files = KubeconfigFileInliner().referencedFiles(kubeconfig, baseDirectory: home.appending(path: ".kube"))
        #expect(files.map(\.path) == [
            home.appending(path: ".minikube/ca.crt").path, home.appending(path: ".minikube/profiles/t/client.crt").path,
            home.appending(path: ".minikube/profiles/t/client.key").path, home.appending(path: ".kube/relative-token").path,
        ])
    }

    @Test func theDeniedFilesAskForTheirCommonFolderBelowHome() {
        let probe = FixedProbe(answers: [
            home.appending(path: ".minikube/ca.crt").path: .needsAccess,
            home.appending(path: ".minikube/profiles/t/client.crt").path: .needsAccess,
            home.appending(path: ".minikube/profiles/t/client.key").path: .denied,
        ])
        let inliner = KubeconfigFileInliner(probe: probe, isSandboxed: true)
        let folders = inliner.foldersNeedingAccess(kubeconfig, baseDirectory: home.appending(path: ".kube"), accountHome: home)
        #expect(folders.count == 1)
        #expect(folders[0].hasSuffix("/.minikube"))
    }

    @Test func outsideTheSandboxNothingIsAskedFor() {
        let probe = FixedProbe(answers: [home.appending(path: ".minikube/ca.crt").path: .needsAccess])
        let inliner = KubeconfigFileInliner(probe: probe, isSandboxed: false)
        #expect(inliner.foldersNeedingAccess(kubeconfig, baseDirectory: home.appending(path: ".kube"), accountHome: home).isEmpty)
    }

    @Test func inliningARefusedFileNamesTheFolderInsteadOfSayingItCantBeRead() throws {
        let probe = FixedProbe(answers: [home.appending(path: ".minikube/ca.crt").path: .needsAccess])
        let inliner = KubeconfigFileInliner(probe: probe, isSandboxed: true)
        let error = #expect(throws: KubeconfigFileInliner.Failure.self) { try inliner.inline(kubeconfig, baseDirectory: home.appending(path: ".kube")) }
        guard case .needsAccess(let folder)? = error else { Issue.record("not needsAccess: \(String(describing: error))"); return }
        #expect(folder.hasSuffix("/.minikube"))
        #expect(error?.localizedDescription.contains("needs access") == true)
    }

    @Test func aMissingFileIsStillJustUnreadableAndInliningWorksOnceAccessIsThere() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "wh-inl-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "CA-DATA".write(to: dir.appending(path: "ca.crt"), atomically: true, encoding: .utf8)
        let text = "clusters:\n- name: c\n  cluster:\n    certificate-authority: ca.crt\n"
        let inliner = KubeconfigFileInliner(probe: FixedProbe(answers: [:]), isSandboxed: true)
        #expect(try inliner.inline(text, baseDirectory: dir).contains("certificate-authority-data: \(Data("CA-DATA".utf8).base64EncodedString())"))
        let missing = "clusters:\n- name: c\n  cluster:\n    certificate-authority: nope.crt\n"
        #expect(throws: KubeconfigFileInliner.Failure.unreadable("nope.crt")) { try inliner.inline(missing, baseDirectory: dir) }
    }

    @Test func anExecContextSaysWhyInTheSandboxAndKeepsTheOldTextElsewhere() throws {
        let text = "apiVersion: v1\nkind: Config\nclusters:\n- name: e\n  cluster:\n    server: https://e.example.test:6443\n"
            + "users:\n- name: u\n  user:\n    exec:\n      apiVersion: client.authentication.k8s.io/v1\n      command: aws\n      args: [eks, get-token]\n"
            + "contexts:\n- name: e\n  context: {cluster: e, user: u}\n"
        let sandboxed = try MacImportPolicy(isSandboxed: true).parse(text).contexts
        #expect(sandboxed.first?.unsupportedReason == EditionNotice.execPlugin(command: "aws"))
        let open = try MacImportPolicy(isSandboxed: false).parse(text).contexts
        #expect(open.first?.unsupportedReason?.hasPrefix("Uses a credential plugin. Wheelhouse can reference this file in place") == true)
    }
}

@Suite("Import in the sandboxed edition: the gate")
struct ImportSandboxGateTests {
    private final class SpyProbe: FileAccessProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.withLock { count } }
        func probe(_ path: String) -> FileAccessResult { lock.withLock { count += 1 }; return .needsAccess }
    }

    @Test func aReferenceUnderHomeKubeIsNeverProbedWhileTheGateIsActive() {
        let home = URL(fileURLWithPath: "/private/tmp/claude-501/gate-home", isDirectory: true)
        let spy = SpyProbe()
        let gate = DevSafetyPolicy(isActive: true, home: home)
        let inliner = KubeconfigFileInliner(gate: gate, probe: spy, isSandboxed: true)
        let text = "clusters:\n- name: c\n  cluster:\n    certificate-authority: \(home.path)/.kube/ca.crt\n"
        #expect(inliner.foldersNeedingAccess(text, baseDirectory: home, accountHome: home).isEmpty)
        #expect(spy.calls == 0)
    }
}

@Suite("Import in the sandboxed edition: the preflight read")
@MainActor
struct ImportPreflightReadTests {
    @Test func aGatedBuildReadsNothingForAKubeShapedUrlOrItsSymlinkOrHardLink() throws {
        let home = FileManager.default.temporaryDirectory.appending(path: "wh-pre-\(UUID().uuidString)", directoryHint: .isDirectory)
        let kube = home.appending(path: ".kube", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: kube, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let config = kube.appending(path: "config")
        try "clusters: []".write(to: config, atomically: true, encoding: .utf8)
        let link = home.appending(path: "link.yaml")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: config)
        let hard = home.appending(path: "hard.yaml")
        try FileManager.default.linkItem(at: config, to: hard)
        let gate = DevSafetyPolicy(isActive: true, home: home)
        var reads = 0
        for url in [config, link, hard] {
            #expect(MacImportCoordinator.preflightText(of: url, gate: gate) { _ in reads += 1; return "x" } == nil)
        }
        #expect(reads == 0)
        // An ordinary file is read once.
        let other = home.appending(path: "other.yaml")
        try "a: b".write(to: other, atomically: true, encoding: .utf8)
        #expect(MacImportCoordinator.preflightText(of: other, gate: gate) { _ in reads += 1; return "x" } == "x")
        #expect(reads == 1)
    }

    @Test func anOversizedFileIsNotReadBeforeThePolicySeesIt() throws {
        let f = FileManager.default.temporaryDirectory.appending(path: "wh-big-\(UUID().uuidString).yaml")
        try Data(count: MacImportPolicy.maxFileBytes + 1).write(to: f)
        defer { try? FileManager.default.removeItem(at: f) }
        var reads = 0
        #expect(MacImportCoordinator.preflightText(of: f, gate: DevSafetyPolicy(isActive: false)) { _ in reads += 1; return "x" } == nil)
        #expect(reads == 0)
    }
}
