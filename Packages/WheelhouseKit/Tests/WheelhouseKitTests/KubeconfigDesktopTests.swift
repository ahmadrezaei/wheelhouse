import Foundation
import Testing
@testable import WheelhouseKit

/// The desktop rules of `KubeconfigParser` (ARCHITECTURE-MAC §1.5, §4.2). iOS behaviour is pinned by `KubeconfigTests`.
@Suite("KubeconfigParser desktop environment")
struct KubeconfigDesktopTests {
    static let base = URL(fileURLWithPath: "/work/kube", isDirectory: true)

    static func yaml(server: String = "https://k.example.test:6443", cluster: String = "", user: String) -> String {
        """
        apiVersion: v1
        kind: Config
        current-context: ctx
        clusters:
        - name: c1
          cluster:
            server: \(server)
        \(cluster)
        users:
        - name: u1
          user:
        \(user)
        contexts:
        - name: ctx
          context:
            cluster: c1
            user: u1
            namespace: apps
        """
    }

    static func parse(_ text: String) throws -> KubeconfigContext {
        try #require(try KubeconfigParser.parse(text, environment: .desktop(baseDirectory: base)).contexts.first)
    }

    @Test func localServerIsReadyOnTheDesktopAndLocalOnMobile() throws {
        let text = Self.yaml(server: "https://127.0.0.1:60561", user: "    token: abc")
        #expect(try Self.parse(text).status == .ready)
        #expect(try #require(try KubeconfigParser.parse(text).contexts.first).status == .local)
    }

    @Test func relativeFileReferencesResolveAgainstTheKubeconfigFolder() throws {
        let text = Self.yaml(cluster: "    certificate-authority: certs/ca.crt", user: "    client-certificate: ../creds/c.crt\n    client-key: /abs/k.key")
        let ctx = try Self.parse(text)
        #expect(ctx.status == .ready)
        #expect(ctx.files?.certificateAuthority == "/work/kube/certs/ca.crt")
        #expect(ctx.files?.clientCertificate == "/work/creds/c.crt")
        #expect(ctx.files?.clientKey == "/abs/k.key")
    }

    @Test func tokenFileIsAReferenceNotAMissingFile() throws {
        let ctx = try Self.parse(Self.yaml(user: "    tokenFile: tok/sa-token"))
        #expect(ctx.status == .ready)
        #expect(ctx.files?.tokenFile == "/work/kube/tok/sa-token")
    }

    @Test func mobileStillReportsFileReferencesAsMissing() throws {
        let text = Self.yaml(cluster: "    certificate-authority: certs/ca.crt", user: "    tokenFile: tok")
        let ctx = try #require(try KubeconfigParser.parse(text).contexts.first)
        #expect(ctx.status == .missingFile)
        #expect(ctx.files == nil)
        #expect(ctx.exec == nil)
    }

    @Test func execIsReadyWithItsFullStanza() throws {
        let user = """
            exec:
              apiVersion: client.authentication.k8s.io/v1beta1
              command: aws
              args: ["eks", "get-token", "--cluster-name", "payments", "--profile", "prod"]
              env:
              - name: AWS_REGION
                value: eu-west-1
              installHint: brew install awscli
              provideClusterInfo: true
              interactiveMode: IfAvailable
        """
        let cluster = """
            extensions:
            - name: client.authentication.k8s.io/exec
              extension:
                audience: sts
        """
        let ctx = try Self.parse(Self.yaml(cluster: cluster, user: user))
        #expect(ctx.status == .ready)
        let exec = try #require(ctx.exec)
        #expect(exec.apiVersion == "client.authentication.k8s.io/v1beta1")
        #expect(exec.command == "aws")
        #expect(exec.args.prefix(2) == ["eks", "get-token"])
        #expect(exec.env == [.init(name: "AWS_REGION", value: "eu-west-1")])
        #expect(exec.installHint == "brew install awscli")
        #expect(exec.provideClusterInfo)
        #expect(exec.interactiveMode == "IfAvailable")
        #expect(exec.clusterConfig?.objectValue?["audience"]?.stringValue == "sts")
        #expect(exec.baseDirectory == "/work/kube")
    }

    @Test func execOnMobileKeepsItsUnsupportedStatus() throws {
        let ctx = try #require(try KubeconfigParser.parse(Self.yaml(user: "    exec:\n      command: aws\n      args: [eks]")).contexts.first)
        #expect(ctx.status == .exec)
        #expect(ctx.exec == nil)
    }

    @Test func proxyUrlStaysUnsupportedWithTheSameText() throws {
        let text = Self.yaml(cluster: "    proxy-url: http://proxy:3128", user: "    token: t")
        let desktop = try Self.parse(text)
        let mobile = try #require(try KubeconfigParser.parse(text).contexts.first)
        #expect(desktop.status == .invalid)
        #expect(desktop.unsupportedReason == mobile.unsupportedReason)
    }

    @Test func inlineCertificateAndMixedHalves() throws {
        let b64 = Data("PEM".utf8).base64EncodedString()
        let both = try Self.parse(Self.yaml(user: "    client-certificate-data: \(b64)\n    client-key-data: \(b64)"))
        #expect(both.auth == .clientCertificate(certificatePEM: "PEM", keyPEM: "PEM"))
        let mixed = try Self.parse(Self.yaml(user: "    client-certificate-data: \(b64)\n    client-key: k.key"))
        #expect(mixed.files?.clientKey == "/work/kube/k.key")
        #expect(mixed.files?.inlineClientCertificatePEM == "PEM")
    }

    // MARK: Merging (client-go rules)

    static func document(_ text: String, dir: String) throws -> KubeconfigParser.Document {
        try KubeconfigParser.parseDocument(text, baseDirectory: URL(fileURLWithPath: dir, isDirectory: true))
    }

    static let fileA = """
    current-context: from-a
    clusters:
    - name: shared
      cluster: {server: "https://a.example.test"}
    contexts:
    - name: from-a
      context: {cluster: shared, user: shared-user}
    - name: dup
      context: {cluster: shared, user: shared-user}
    """
    static let fileB = """
    current-context: from-b
    clusters:
    - name: shared
      cluster: {server: "https://b.example.test"}
    - name: only-b
      cluster: {server: "https://only-b.example.test"}
    users:
    - name: shared-user
      user: {token: tok-b}
    contexts:
    - name: dup
      context: {cluster: only-b, user: shared-user}
    - name: from-b
      context: {cluster: only-b, user: shared-user}
    """

    @Test func firstFileThatDefinesANameWins() throws {
        let merged = KubeconfigParser.merge([try Self.document(Self.fileA, dir: "/a"), try Self.document(Self.fileB, dir: "/b")], desktop: true)
        let names = merged.contexts.map(\.context.name)
        #expect(names == ["from-a", "dup", "from-b"])
        // dup comes from A; its cluster is A's `shared`, not B's.
        let dup = try #require(merged.contexts.first { $0.context.name == "dup" })
        #expect(dup.fileIndex == 0)
        #expect(dup.context.server?.host() == "a.example.test")
        #expect(merged.shadowed == [.init(name: "dup", fileIndex: 1, shadowedByFileIndex: 0)])
        #expect(merged.currentContext == "from-a")
    }

    @Test func aContextUsesAUserDefinedInAnotherFile() throws {
        let merged = KubeconfigParser.merge([try Self.document(Self.fileA, dir: "/a"), try Self.document(Self.fileB, dir: "/b")], desktop: true)
        let ctx = try #require(merged.contexts.first { $0.context.name == "from-a" }?.context)
        #expect(ctx.auth == .token("tok-b"))
    }

    @Test func relativePathsResolveAgainstTheFileThatDefinesTheEntry() throws {
        let a = "clusters:\n- name: c\n  cluster: {server: \"https://x.example.test\", certificate-authority: ca.crt}\ncontexts:\n- name: x\n  context: {cluster: c, user: u}\n"
        let b = "users:\n- name: u\n  user: {tokenFile: sa/token}\n"
        let merged = KubeconfigParser.merge([try Self.document(a, dir: "/dirA"), try Self.document(b, dir: "/dirB")], desktop: true)
        let ctx = try #require(merged.contexts.first?.context)
        #expect(ctx.files?.certificateAuthority == "/dirA/ca.crt")
        #expect(ctx.files?.tokenFile == "/dirB/sa/token")
    }
}

@Suite("ClusterConfig.origin")
struct ClusterOriginTests {
    @Test func originIsNeverEncoded() throws {
        var c = ClusterConfig(name: "n", server: URL(string: "https://x.example.test")!)
        c.origin = .kubeconfig(path: "/p", context: "ctx", sourceID: "s")
        let data = try JSONEncoder().encode(c)
        let text = String(decoding: data, as: UTF8.self)
        #expect(!text.contains("origin"))
        #expect(!text.contains("/p"))
        let back = try JSONDecoder().decode(ClusterConfig.self, from: data)
        #expect(back.origin == nil)
    }

    @Test func discoveredClustersNeverReachTheMirrorOrTheFile() throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "origin-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mirror = InMemoryMetadataMirror()
        let store = ClusterMetadataStore(directory: dir, mirror: mirror)
        var keychain = ClusterConfig(id: "k1", name: "keychain", server: URL(string: "https://k.example.test")!, iCloudSync: true)
        keychain.modifiedAt = Date()
        var discovered = ClusterConfig(id: "kc-abc", name: "discovered", server: URL(string: "https://d.example.test")!, iCloudSync: true)
        discovered.origin = .kubeconfig(path: "/p", context: "c", sourceID: "s")
        try store.save([keychain, discovered])
        let mirrorText = String(decoding: try #require(try mirror.read()), as: UTF8.self)
        #expect(mirrorText.contains("keychain"))
        #expect(!mirrorText.contains("discovered"))
        #expect(!mirrorText.contains("kc-abc"))
        let file = String(decoding: try Data(contentsOf: dir.appending(path: "clusters.json")), as: UTF8.self)
        #expect(!file.contains("kc-abc"))
        #expect(store.load().map(\.id) == ["k1"])
    }
}
