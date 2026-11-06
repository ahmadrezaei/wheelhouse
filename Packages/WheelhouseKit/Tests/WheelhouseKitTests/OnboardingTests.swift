import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct OnboardingTests {
    @Test func urlNormalisation() {
        #expect(ClusterDraft.normalizedURL("api.example.com:6443")?.absoluteString == "https://api.example.com:6443")
        #expect(ClusterDraft.normalizedURL(" https://x.io/ ")?.absoluteString == "https://x.io")
        #expect(ClusterDraft.normalizedURL("ftp://x.io") == nil)
        #expect(ClusterDraft.normalizedURL("") == nil)
    }

    @Test func draftValidationAndProductionTLS() throws {
        var d = ClusterDraft()
        #expect(d.problems.contains(.nameMissing))
        d.name = "prod"; d.serverText = "https://k.example.com"; d.token = "abc"
        #expect(d.isValid)
        d.environment = .production; d.skipTLSVerify = true
        let config = try #require(d.makeConfig())
        #expect(config.skipTLSVerify == false)
        d.environment = .development
        #expect(try #require(d.makeConfig()).skipTLSVerify)
        d.caPEM = "garbage"
        #expect(d.problems.contains(.caInvalid))
    }

    @Test func editKeepsExistingToken() throws {
        let cfg = ClusterConfig(name: "a", server: URL(string: "https://a.io")!)
        let d = ClusterDraft(editing: cfg, secrets: ClusterSecrets(token: "old"))
        #expect(d.isValid)
        #expect(d.makeSecrets(existing: ClusterSecrets(token: "old")).token == "old")
        var d2 = d; d2.token = "new"
        #expect(d2.makeSecrets(existing: ClusterSecrets(token: "old")).token == "new")
    }

    @Test func jwtExpiry() {
        // {"exp":1900000000}
        let payload = Data(#"{"exp":1900000000}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        #expect(JWTInfo.expiry(of: "aaa.\(payload).bbb") == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(JWTInfo.expiry(of: "not-a-jwt") == nil)
    }

    @Test func searchRanking() {
        #expect(SearchRanking.score(name: "payments-api", query: "payments-api") == 0)
        #expect(SearchRanking.score(name: "payments-api", query: "pay") == 1)
        #expect(SearchRanking.score(name: "payments-api", query: "api") == 2)
        #expect(SearchRanking.score(name: "payments-api", query: "ments") == 3)
        #expect(SearchRanking.score(name: "payments-api", query: "pmtapi") == 4)
        #expect(SearchRanking.score(name: "payments-api", query: "zzz") == nil)
    }

    /// Needs `TEST_RUNNER_WH_KUBECONFIG=<path to kubeconfig-embedded.yaml>` (the test host cannot read ~/Documents).
    static var testKubeconfig: String? {
        guard let path = ProcessInfo.processInfo.environment["WH_KUBECONFIG"] else { return nil }
        return try? String(contentsOfFile: path, encoding: .utf8)
    }

    @Test(.enabled(if: Self.testKubeconfig != nil)) func testClusterKubeconfigParses() throws {
        let text = try #require(Self.testKubeconfig)
        let kc = try KubeconfigParser.parse(text)
        let ctx = try #require(kc.contexts.first)
        guard case .clientCertificate = ctx.auth else { Issue.record("expected client cert auth"); return }
        #expect(ctx.status == .local)
        let made = try #require(ctx.makeClusterConfig())
        #expect(made.config.authKind == .clientCertificate)
    }

    /// Real connection with the client-certificate identity (ClientIdentityBuilder -> LiveKubeClient -> ConnectionTester).
    @Test(.enabled(if: Self.testKubeconfig != nil)) func clientCertificateConnectsToTestCluster() async throws {
        let text = try #require(Self.testKubeconfig)
        let ctx = try #require(try KubeconfigParser.parse(text).contexts.first)
        let made = try #require(ctx.makeClusterConfig())
        let client = LiveKubeClient(config: made.config, secrets: made.secrets)
        defer { ClientIdentityBuilder.remove(label: ClientIdentityBuilder.label(for: made.config.id)) }
        let result = await ConnectionTester.run(client: client)
        print("CLIENTCERT RESULT: version=\(result.version ?? "nil") error=\(String(describing: result.error)) nodes=\(String(describing: result.nodeCount)) caps=\(result.capabilities)")
        #expect(result.error == nil)
        #expect(result.version?.hasPrefix("v1") == true)
    }
}
