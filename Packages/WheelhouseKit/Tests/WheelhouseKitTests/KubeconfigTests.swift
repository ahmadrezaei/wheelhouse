import Foundation
import Testing
@testable import WheelhouseKit

@Suite struct KubeconfigTests {
    static let caB64 = "LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0tCk1JSUJhZ0F3PT0KLS0tLS1FTkQgQ0VSVElGSUNBVEUtLS0tLQo="  // PEM text

    static func config(cluster: String, user: String, contextName: String = "ctx", extra: String = "") -> String {
        """
        apiVersion: v1
        kind: Config
        current-context: \(contextName)
        clusters:
        - name: c1
          cluster:
        \(cluster)
        users:
        - name: u1
          user:
        \(user)
        contexts:
        - name: \(contextName)
          context:
            cluster: c1
            user: u1
        \(extra)
        """
    }

    @Test func kindStyleClientCert() throws {
        let yaml = Self.config(cluster: "    certificate-authority-data: \(Self.caB64)\n    server: https://127.0.0.1:54321",
                               user: "    client-certificate-data: \(Self.caB64)\n    client-key-data: \(Self.caB64)", contextName: "kind-dev")
        let kc = try KubeconfigParser.parse(yaml)
        #expect(kc.currentContext == "kind-dev")
        let ctx = try #require(kc.contexts.first)
        #expect(ctx.status == .local)  // 127.0.0.1 is not reachable from a phone
        guard case .clientCertificate(let cert, _) = ctx.auth else { Issue.record("expected client cert"); return }
        #expect(cert.contains("BEGIN CERTIFICATE"))
        #expect(ctx.caPEM?.contains("BEGIN CERTIFICATE") == true)
        #expect(ctx.suggestedEnvironment == .development)
    }

    @Test func minikubeFileReferencesAreMissingFiles() throws {
        let yaml = Self.config(cluster: "    certificate-authority: /Users/me/.minikube/ca.crt\n    server: https://192.168.49.2:8443",
                               user: "    client-certificate: /Users/me/.minikube/profiles/minikube/client.crt\n    client-key: /Users/me/.minikube/profiles/minikube/client.key", contextName: "minikube")
        let ctx = try #require(try KubeconfigParser.parse(yaml).contexts.first)
        #expect(ctx.status == .missingFile)
        #expect(ctx.unsupportedReason?.contains("flatten") == true)
        #expect(ctx.suggestedEnvironment == .personal)
    }

    @Test func k3sTokenReady() throws {
        let yaml = Self.config(cluster: "    certificate-authority-data: \(Self.caB64)\n    server: https://k3s.lan.example.com:6443", user: "    token: eyJhbGciOi.abc.def", contextName: "homelab-k3s")
        let ctx = try #require(try KubeconfigParser.parse(yaml).contexts.first)
        #expect(ctx.status == .ready)
        #expect(ctx.isImportable)
        let made = try #require(ctx.makeClusterConfig())
        #expect(made.config.authKind == .token)
        #expect(made.secrets.token == "eyJhbGciOi.abc.def")
        #expect(made.config.server.host() == "k3s.lan.example.com")
    }

    @Test func eksExec() throws {
        let yaml = Self.config(cluster: "    certificate-authority-data: \(Self.caB64)\n    server: https://ABCDEF.gr7.eu-west-1.eks.amazonaws.com",
                               user: "    exec:\n      apiVersion: client.authentication.k8s.io/v1beta1\n      command: aws\n      args:\n        - eks\n        - get-token\n        - --cluster-name\n        - prod", contextName: "arn:aws:eks:eu-west-1:1:cluster/prod")
        let ctx = try #require(try KubeconfigParser.parse(yaml).contexts.first)
        #expect(ctx.status == .exec)
        #expect(ctx.needsToken)
        #expect(ctx.unsupportedReason?.contains("AWS EKS") == true)
        #expect(ctx.suggestedEnvironment == .production)
        #expect(ctx.makeClusterConfig() == nil)
        guard case .exec(let command, let args) = ctx.auth else { Issue.record("expected exec"); return }
        #expect(command == "aws")
        #expect(args.first == "eks")
    }

    @Test func gkeExec() throws {
        let yaml = Self.config(cluster: "    server: https://34.1.2.3\n    certificate-authority-data: \(Self.caB64)",
                               user: "    exec:\n      command: gke-gcloud-auth-plugin\n      installHint: install it\n      provideClusterInfo: true", contextName: "gke_proj_europe-west4_staging")
        let ctx = try #require(try KubeconfigParser.parse(yaml).contexts.first)
        #expect(ctx.status == .exec)
        #expect(ctx.unsupportedReason?.contains("GKE") == true)
        #expect(ctx.suggestedEnvironment == .staging)
    }

    @Test func aksExecAndLegacyAuthProvider() throws {
        let aks = Self.config(cluster: "    server: https://aks-dns.hcp.westeurope.azmk8s.io:443", user: "    exec:\n      command: kubelogin\n      args: [get-token, --login, azurecli]", contextName: "aks-dev")
        #expect(try KubeconfigParser.parse(aks).contexts.first?.status == .exec)
        let legacy = Self.config(cluster: "    server: https://aks.example.com", user: "    auth-provider:\n      name: azure\n      config:\n        apiserver-id: x", contextName: "legacy")
        let ctx = try #require(try KubeconfigParser.parse(legacy).contexts.first)
        #expect(ctx.status == .authProvider)
        let oidc = Self.config(cluster: "    server: https://oidc.example.com", user: "    auth-provider:\n      name: oidc", contextName: "oidc")
        #expect(try KubeconfigParser.parse(oidc).contexts.first?.unsupportedReason?.contains("ID token") == true)
    }

    @Test func basicAuthUnsupportedAndInsecureFlag() throws {
        let yaml = Self.config(cluster: "    server: https://old.example.com\n    insecure-skip-tls-verify: true", user: "    username: admin\n    password: secret", contextName: "old")
        let ctx = try #require(try KubeconfigParser.parse(yaml).contexts.first)
        #expect(ctx.status == .basicAuth)
        #expect(ctx.insecureSkipTLSVerify)
    }

    @Test func rejectsNonKubeconfig() {
        #expect(throws: KubeconfigError.self) { try KubeconfigParser.parse("hello: world") }
        #expect(throws: KubeconfigError.self) { try KubeconfigParser.parse(": : :\n\t- [") }
    }

    @Test func productionNeverImportsInsecure() throws {
        let yaml = Self.config(cluster: "    server: https://prod.example.com\n    insecure-skip-tls-verify: true", user: "    token: abc", contextName: "prod-main")
        let made = try #require(try KubeconfigParser.parse(yaml).contexts.first?.makeClusterConfig())
        #expect(made.config.environment == .production)
        #expect(!made.config.skipTLSVerify)
    }
}

@Suite struct PEMTests {
    @Test func decodeAndParseRSAHeaders() throws {
        let der = Data([0x30, 0x03, 0x02, 0x01, 0x00])
        let pem = PEM.encode(label: "RSA PRIVATE KEY", der: der)
        let blocks = PEM.decode(pem + pem)
        #expect(blocks.count == 2)
        #expect(blocks[0].der == der)
        #expect(try ParsedPrivateKey.parse(blocks[0]) == .rsa(pkcs1: der))
    }

    @Test func parsesSEC1ECKey() throws {
        // SEQ { INTEGER 1, OCTET STRING(32) priv, [1] { BIT STRING { 00 04 X(32) Y(32) } } }
        let priv = [UInt8](repeating: 0x11, count: 32)
        let point = [UInt8(0x04)] + [UInt8](repeating: 0x22, count: 64)
        let bitString: [UInt8] = [0x03, UInt8(point.count + 1), 0x00] + point
        let a1: [UInt8] = [0xA1, UInt8(bitString.count)] + bitString
        let body: [UInt8] = [0x02, 0x01, 0x01, 0x04, 0x20] + priv + a1
        let der = Data([0x30, UInt8(body.count)] + body)
        let parsed = try ParsedPrivateKey.parse(PEMBlock(label: "EC PRIVATE KEY", der: der))
        guard case .ec(let x963, let bits) = parsed else { Issue.record("expected EC"); return }
        #expect(bits == 256)
        #expect(x963.count == 65 + 32)
        #expect(x963.first == 0x04)
        #expect(x963.last == 0x11)
    }

    @Test func rejectsEncryptedKeys() {
        #expect(throws: ParsedPrivateKey.ParseError.self) { try ParsedPrivateKey.parse(PEMBlock(label: "ENCRYPTED PRIVATE KEY", der: Data())) }
    }
}
