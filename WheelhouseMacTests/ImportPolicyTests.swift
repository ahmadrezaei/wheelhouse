import Testing
import Foundation
import WheelhouseDesktop
import WheelhouseKit
@testable import WheelhouseMac

/// ARCHITECTURE-MAC section 4.8: every import entry point goes through `MacImportPolicy`: read-only, no default environment, the
/// exec redirect and the dev-safety refusals.
@Suite("Import policy")
@MainActor
struct ImportPolicyTests {
    /// A scratch folder standing in for the home directory, with its own `.kube`.
    private struct Home {
        let root: URL
        var kube: URL { root.appending(path: ".kube", directoryHint: .isDirectory) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appending(path: "wh-home-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: root.appending(path: ".kube"), withIntermediateDirectories: true)
        }
        func write(_ text: String, to relative: String) throws -> URL {
            let url = root.appending(path: relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            return url
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func kubeconfig(contexts: [(name: String, server: String, user: String)], users: String) -> String {
        var s = "apiVersion: v1\nkind: Config\nclusters:\n"
        for c in contexts { s += "- name: \(c.name)\n  cluster:\n    server: \(c.server)\n    insecure-skip-tls-verify: true\n" }
        s += "contexts:\n"
        for c in contexts { s += "- name: \(c.name)\n  context:\n    cluster: \(c.name)\n    user: \(c.user)\n" }
        s += "users:\n" + users
        return s
    }

    private let tokenUser = "- name: tok\n  user:\n    token: abc123\n"
    private let execUser = "- name: ex\n  user:\n    exec:\n      apiVersion: client.authentication.k8s.io/v1\n      command: aws\n      args: [eks, get-token]\n"

    private func policy(home: Home, active: Bool = true, hosts: Set<String> = ["127.0.0.1"]) -> MacImportPolicy {
        MacImportPolicy(gate: DevSafetyPolicy(isActive: active, allowedHosts: hosts, home: home.root))
    }

    // MARK: Defaults

    @Test func everyRowStartsReadOnlyWithSyncOff() {
        let p = MacImportPolicy(gate: DevSafetyPolicy(isActive: false))
        #expect(p.defaultReadOnly)
        #expect(!p.defaultICloud)
    }

    @Test func theEnvironmentIsPrefilledOnlyFromTheSuggesterAndOtherwiseChosen() throws {
        let text = kubeconfig(contexts: [("prod-eu", "https://a.example", "tok"), ("staging-eu", "https://b.example", "tok"), ("mycluster", "https://c.example", "tok"),
                                         ("kind-dev", "https://d.example", "tok")], users: tokenUser)
        let kc = try MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).parse(text)
        let p = MacImportPolicy(gate: DevSafetyPolicy(isActive: false))
        let by = Dictionary(uniqueKeysWithValues: kc.contexts.map { ($0.name, p.suggestedEnvironment(for: $0)) })
        #expect(by["prod-eu"] == .production)
        #expect(by["staging-eu"] == .staging)
        #expect(by["kind-dev"] == .development)
        #expect(by["mycluster"].flatMap { $0 } == nil)            // no suggestion: the user must choose; there is no default
    }

    @Test func theIOSSubstringSuggestionIsNeverUsedOnTheMac() throws {
        // "preproduction" contains "production": the iOS suggestion says Production, the Mac token rules say Staging.
        let kc = try MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).parse(kubeconfig(contexts: [("preprod-eu", "https://a.example", "tok")], users: tokenUser))
        let ctx = kc.contexts[0]
        #expect(MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).suggestedEnvironment(for: ctx) == .staging)
    }

    @Test func allowingChangesOnProductionOrSuggestedProductionNeedsTheOwner() throws {
        let kc = try MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).parse(kubeconfig(contexts: [("prod-eu", "https://a.example", "tok"), ("lab", "https://b.example", "tok")], users: tokenUser))
        let p = MacImportPolicy(gate: DevSafetyPolicy(isActive: false))
        let prod = kc.contexts[0], lab = kc.contexts[1]
        #expect(p.requiresOwnerAuth(toAllowChangesOn: prod, environment: .staging))          // suggested Production, even if the user picked Staging
        #expect(p.requiresOwnerAuth(toAllowChangesOn: lab, environment: .production))
        #expect(!p.requiresOwnerAuth(toAllowChangesOn: lab, environment: .development))
    }

    // MARK: Exec contexts

    @Test func execContextsAreNeverImportedAsNoAuthAndOfferMooringsInstead() throws {
        let kc = try MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).parse(kubeconfig(contexts: [("eks", "https://e.example", "ex")], users: execUser))
        let ctx = kc.contexts[0]
        #expect(ctx.status == .exec)
        #expect(!ctx.isImportable)
        #expect(ctx.makeClusterConfig() == nil)                         // never becomes a cluster with authKind .none
        #expect(ctx.unsupportedReason?.contains("Moorings") == true)
        let p = MacImportPolicy(gate: DevSafetyPolicy(isActive: false))
        #expect(p.mooringsSource != nil && p.mooringsSource?.isAvailable == false)       // disabled until M3
    }

    @Test func addFileAsMooringsSourceIsUnavailableUntilM3() async {
        let p = MacImportPolicy(gate: DevSafetyPolicy(isActive: false))
        await #expect(throws: (any Error).self) { try await p.moorings.addFileSource(URL(fileURLWithPath: "/tmp/x")) }
    }

    @Test func localhostIsReadyOnTheMac() throws {
        let text = kubeconfig(contexts: [("minikube", "https://127.0.0.1:8443", "tok")], users: tokenUser)
        let ios = try KubeconfigParser.parse(text).contexts[0]
        #expect(ios.status == .local)                                     // iOS: unreachable from a phone
        let mac = try MacImportPolicy(gate: DevSafetyPolicy(isActive: false)).parse(text).contexts[0]
        #expect(mac.status == .ready && mac.unsupportedReason == nil)
    }

    // MARK: Dev safety

    @Test func aFileUnderHomeKubeIsRefusedWhileTheGateIsActive() throws {
        let home = try Home(); defer { home.remove() }
        let file = try home.write(kubeconfig(contexts: [("a", "https://127.0.0.1", "tok")], users: tokenUser), to: ".kube/config")
        let p = policy(home: home)
        #expect(throws: ImportPolicyError.self) { try p.loadFile(file) }
        // The same refusal through a symlink in an innocent folder.
        let link = home.root.appending(path: "Downloads/innocent.yaml")
        try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: ImportPolicyError.self) { try p.loadFile(link) }
        // And a hard link, caught by device and inode.
        let hard = home.root.appending(path: "Downloads/hard.yaml")
        try FileManager.default.linkItem(at: file, to: hard)
        #expect(throws: ImportPolicyError.self) { try p.loadFile(hard) }
    }

    @Test func aFileOutsideHomeKubeLoadsAndTheGateOffAllowsAnything() throws {
        let home = try Home(); defer { home.remove() }
        let ok = try home.write(kubeconfig(contexts: [("a", "https://127.0.0.1", "tok")], users: tokenUser), to: "work/test.yaml")
        #expect(throws: Never.self) { try policy(home: home).loadFile(ok) }
        let kube = try home.write(kubeconfig(contexts: [("a", "https://127.0.0.1", "tok")], users: tokenUser), to: ".kube/other")
        #expect(throws: Never.self) { try policy(home: home, active: false).loadFile(kube) }
    }

    @Test func contextsWhoseHostIsNotAnAllowedTestHostAreBlocked() throws {
        let home = try Home(); defer { home.remove() }
        let text = kubeconfig(contexts: [("test", "https://127.0.0.1:6443", "tok"), ("real", "https://api.prod.corp.example.com", "tok"), ("fixture", "https://x.test", "tok")], users: tokenUser)
        let p = policy(home: home)
        let kc = try p.parse(text)
        let by = Dictionary(uniqueKeysWithValues: kc.contexts.map { ($0.name, p.blockedReason(for: $0)) })
        #expect(by["test"].flatMap { $0 } == nil)
        #expect(by["fixture"].flatMap { $0 } == nil)                                                 // *.test never resolves
        #expect(by["real"].flatMap { $0 }?.hasPrefix("Blocked in development builds") == true)
        // With the gate off nothing is blocked.
        let off = policy(home: home, active: false)
        #expect(kc.contexts.allSatisfy { off.blockedReason(for: $0) == nil })
    }

    // MARK: File references (the test kubeconfig uses them)

    @Test func fileReferencesAreInlinedRelativeToTheKubeconfig() throws {
        let home = try Home(); defer { home.remove() }
        _ = try home.write("CA-PEM", to: "work/certs/ca.crt")
        _ = try home.write("CERT-PEM", to: "work/certs/client.crt")
        _ = try home.write("KEY-PEM", to: "work/certs/client.key")
        _ = try home.write("tok-from-file\n", to: "work/token")
        let text = """
        clusters:
        - cluster:
            certificate-authority: certs/ca.crt
            server: https://127.0.0.1:1
          name: t
        users:
        - name: t
          user:
            client-certificate: "certs/client.crt"
            client-key: certs/client.key
        - name: u
          user:
            tokenFile: token
        """
        let out = try KubeconfigFileInliner(gate: DevSafetyPolicy(isActive: true, home: home.root)).inline(text, baseDirectory: home.root.appending(path: "work"))
        #expect(out.contains("certificate-authority-data: \(Data("CA-PEM".utf8).base64EncodedString())"))
        #expect(out.contains("client-certificate-data: \(Data("CERT-PEM".utf8).base64EncodedString())"))
        #expect(out.contains("client-key-data: \(Data("KEY-PEM".utf8).base64EncodedString())"))
        #expect(out.contains("token: tok-from-file"))
        #expect(!out.contains("certs/ca.crt"))
        #expect(out.contains("server: https://127.0.0.1:1"))            // nothing else is touched
    }

    @Test func aReferencedFileUnderHomeKubeIsRefused() throws {
        let home = try Home(); defer { home.remove() }
        _ = try home.write("KEY", to: ".kube/client.key")
        let text = "users:\n- name: t\n  user:\n    client-key: \(home.kube.appending(path: "client.key").path)\n"
        #expect(throws: KubeconfigFileInliner.Failure.self) {
            try KubeconfigFileInliner(gate: DevSafetyPolicy(isActive: true, home: home.root)).inline(text, baseDirectory: home.root)
        }
        // Gate off: read as asked.
        #expect(throws: Never.self) {
            try KubeconfigFileInliner(gate: DevSafetyPolicy(isActive: false, home: home.root)).inline(text, baseDirectory: home.root)
        }
    }

    @Test func aMissingReferencedFileIsAClearError() throws {
        let home = try Home(); defer { home.remove() }
        let text = "clusters:\n- name: t\n  cluster:\n    certificate-authority: nope.crt\n"
        #expect(throws: KubeconfigFileInliner.Failure.unreadable("nope.crt")) {
            try KubeconfigFileInliner(gate: DevSafetyPolicy(isActive: true, home: home.root)).inline(text, baseDirectory: home.root)
        }
    }

    // MARK: Entry points

    @Test func everyEntryPointRecordsARequestAndNoneParsesAFile() {
        let c = MacImportCoordinator()
        let url = URL(fileURLWithPath: "/tmp/does-not-need-to-exist.yaml")
        c.import(url: url)                                   // Import File…, drag and drop, ⌘O and Finder Open With all end here
        #expect(c.presented?.url == url)
        c.dismiss()
        c.import(url: url, whileLocked: true)
        #expect(c.presented == nil)                          // held while locked
        c.presentDeferred()
        #expect(c.presented?.url == url)
    }

    @Test func importableFilesAreKubeconfigsAndYAML() {
        #expect(MacImportCoordinator.isImportable(URL(fileURLWithPath: "/a/b.kubeconfig")))
        #expect(MacImportCoordinator.isImportable(URL(fileURLWithPath: "/a/config")))
        #expect(MacImportCoordinator.isImportable(URL(fileURLWithPath: "/a/b.yaml")))
        #expect(!MacImportCoordinator.isImportable(URL(fileURLWithPath: "/a/b.png")))
        #expect(!MacImportCoordinator.isImportable(URL(string: "https://example.com/x.yaml")!))
    }
}
