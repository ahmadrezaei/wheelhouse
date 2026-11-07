import Testing
import Foundation
@testable import WheelhouseKit

/// The redaction corpus (ARCHITECTURE-MAC section 9.3): positive cases that must lose their secret, and near-miss negative cases
/// that must come through byte for byte.
@Suite("Redactor corpus")
struct RedactorCorpusTests {
    let redactor = Redactor()

    // The literals below are fake and exist only in this file.
    static let rsaKey = """
    -----BEGIN RSA PRIVATE KEY-----
    MIIEowIBAAKCAQEAfakefakefakefakefakefakefakefakefakefake
    QWERTYUIOPASDFGHJKLZXCVBNMqwertyuiopasdfghjklzxcvbnm012345
    -----END RSA PRIVATE KEY-----
    """
    static let certificate = """
    -----BEGIN CERTIFICATE-----
    MIIDdzCCAl+gAwIBAgIEfakefakefakefakefakefakefakefakefakefake
    -----END CERTIFICATE-----
    """
    static let jwt = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U"
    static let ghp = "ghp_" + String(repeating: "a1B2c3", count: 6)                      // 36 characters
    static let googleKey = "AIza" + String(repeating: "Ab3_-", count: 7)                  // 35 characters
    static let kubeconfig = """
    apiVersion: v1
    kind: Config
    clusters:
    - cluster:
        server: https://203.0.113.9:6443
      name: prod
    users:
    - name: admin
      user:
        client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ==
    """

    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var input: String
        /// Substrings that must not survive.
        var secrets: [String]
        var label: String?
        var testDescription: String { name }
    }

    static let positives: [Case] = [
        Case(name: "RSA private key", input: "key:\n\(rsaKey)\nend", secrets: ["MIIEowIBAAKCAQEA", "QWERTYUIOP"], label: "private key"),
        Case(name: "EC private key", input: "-----BEGIN EC PRIVATE KEY-----\nMHcCAQEEIfake\n-----END EC PRIVATE KEY-----", secrets: ["MHcCAQEEIfake"], label: "private key"),
        Case(name: "PKCS8 private key", input: "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANfake\n-----END PRIVATE KEY-----", secrets: ["MIIEvQIBADANfake"], label: "private key"),
        Case(name: "encrypted private key", input: "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIFHDBOfake\n-----END ENCRYPTED PRIVATE KEY-----", secrets: ["MIIFHDBOfake"], label: "private key"),
        Case(name: "OpenSSH private key", input: "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAAfake\n-----END OPENSSH PRIVATE KEY-----", secrets: ["b3BlbnNzaC1rZXk"], label: "private key"),
        Case(name: "unterminated private key", input: "log: -----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCfakefake", secrets: ["MIIEowIBAAKCfakefake"], label: "private key"),
        Case(name: "certificate", input: certificate, secrets: ["MIIDdzCCAl"], label: "certificate"),
        Case(name: "JWT", input: "got token \(jwt) from issuer", secrets: [jwt], label: "jwt"),
        Case(name: "JWT in a key/value", input: "access_token=\(jwt)", secrets: [jwt], label: "jwt"),
        Case(name: "AWS access key", input: "AWS key AKIA" + "IOSFODNN7EXAMPLE used", secrets: ["AKIA" + "IOSFODNN7EXAMPLE"], label: "aws access key"),
        Case(name: "AWS session key", input: "ASIAY34FZKBOKMUTVV7A", secrets: ["ASIAY34FZKBOKMUTVV7A"], label: "aws access key"),
        Case(name: "AWS secret, equals", input: "aws_secret_access_key = wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", secrets: ["wJalrXUtnFEMI"], label: nil),
        Case(name: "AWS secret, env", input: "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", secrets: ["wJalrXUtnFEMI"], label: nil),
        Case(name: "GitHub PAT classic", input: "clone with \(ghp)", secrets: [ghp], label: "github token"),
        Case(name: "GitHub OAuth token", input: "gho_" + String(repeating: "Z9y8X7", count: 6), secrets: [String(repeating: "Z9y8X7", count: 6)], label: "github token"),
        Case(name: "GitHub fine-grained PAT", input: "github_" + "pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz0123456789", secrets: ["11ABCDEFG0abcdefghijkl"], label: "github token"),
        Case(name: "Slack bot token", input: "xo" + "xb-123456789012-1234567890123-abcdefghijklmnopqrstuvwx", secrets: ["123456789012-1234567890123"], label: "slack token"),
        Case(name: "Anthropic key", input: "ANTHROPIC key sk-" + "ant-api03-abcdefghijklmnopqrstuvwxyz0123456789", secrets: ["abcdefghijklmnopqrstuvwxyz0123456789"], label: "anthropic key"),
        Case(name: "Google API key", input: "key=\(googleKey)", secrets: [googleKey], label: "google api key"),
        Case(name: "Azure AccountKey", input: "DefaultEndpointsProtocol=https;AccountName=acct;AccountKey=abcDEF123+/ghiJKL456==;EndpointSuffix=core.windows.net", secrets: ["abcDEF123+/ghiJKL456=="], label: "azure key"),
        Case(name: "Azure SharedAccessSignature", input: "SharedAccessSignature=sv=2020-08-04&sig=abcDEF123456789xyz", secrets: ["abcDEF123456789xyz"], label: "azure sas"),
        Case(name: "SAS query signature", input: "https://acct.blob.core.windows.net/c/b?sv=2020&sig=abcDEF123%2Bxyz4567890QWERT", secrets: ["abcDEF123%2Bxyz4567890QWERT"], label: "azure sas"),
        Case(name: "Authorization Bearer header", input: "Authorization: Bearer abc123.def456.ghi789", secrets: ["abc123.def456.ghi789"], label: "bearer"),
        Case(name: "authorization in JSON", input: #"{"authorization": "Bearer s3cr3tT0kenValue99"}"#, secrets: ["s3cr3tT0kenValue99"], label: "bearer"),
        Case(name: "Authorization Basic", input: "Authorization: Basic dXNlcjpwYXNzd29yZA==", secrets: ["dXNlcjpwYXNzd29yZA=="], label: "bearer"),
        Case(name: "bare bearer credential", input: "sent header Bearer abcdefghijklmnopqrstuvwxyz012345", secrets: ["abcdefghijklmnopqrstuvwxyz012345"], label: "bearer"),
        Case(name: "password=", input: "connect password=hunter2 host=db", secrets: ["hunter2"], label: nil),
        Case(name: "password: in YAML", input: "db:\n  password: hunter2\n  user: app", secrets: ["hunter2"], label: nil),
        Case(name: "passwd:", input: "passwd: hunter2", secrets: ["hunter2"], label: nil),
        Case(name: "DB_PASSWORD env style", input: "DB_PASSWORD=hunter2", secrets: ["hunter2"], label: nil),
        Case(name: "JSON password", input: #"{"user":"app","password":"hunter2"}"#, secrets: ["hunter2"], label: nil),
        Case(name: "secret:", input: "secret: s3cr3tValue", secrets: ["s3cr3tValue"], label: nil),
        Case(name: "token=", input: "GET /v1/items?token=abc123xyz&page=2", secrets: ["abc123xyz"], label: nil),
        Case(name: "api_key quoted", input: "api_key: \"AbCdEf123456\"", secrets: ["AbCdEf123456"], label: nil),
        Case(name: "X-API-Key header", input: "x-api-key: AbCdEf123456", secrets: ["AbCdEf123456"], label: nil),
        Case(name: "client_secret", input: "client_secret=0a1b2c3d4e5f", secrets: ["0a1b2c3d4e5f"], label: nil),
        Case(name: "URL userinfo", input: "dsn postgres://admin:hunter2@db.internal:5432/app", secrets: ["hunter2"], label: "url credentials"),
        Case(name: "https userinfo", input: "pull https://deploy:t0psecret@git.example.com/org/repo.git", secrets: ["t0psecret"], label: "url credentials"),
        Case(name: "kubeconfig client-key-data", input: "    client-key-data: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQ==", secrets: ["LS0tLS1CRUdJTiBSU0Eg"], label: "kubeconfig credential"),
        Case(name: "kubeconfig client-certificate-data", input: "client-certificate-data: LS0tLS1CRUdJTiBDRVJUSUZJQ0FURS0tLS0t", secrets: ["LS0tLS1CRUdJTiBDRVJUSUZJ"], label: "kubeconfig credential"),
        Case(name: "kubeconfig token", input: "    token: 6f1e0a3c-fake-static-token", secrets: ["6f1e0a3c-fake-static-token"], label: nil),
        Case(name: "kubeconfig auth-provider tokens", input: "access-token: ya29.fakeaccesstoken\nrefresh-token: 1//fakerefreshtoken", secrets: ["ya29.fakeaccesstoken", "1//fakerefreshtoken"], label: "kubeconfig credential"),
        Case(name: "whole kubeconfig", input: kubeconfig, secrets: ["LS0tLS1CRUdJTiBSU0Eg", "203.0.113.9"], label: "kubeconfig"),
        Case(name: "PEM tail: END line without BEGIN", input: "MIIEowIBAAKCAQEAfakebodyline1\nQWERTYfakebodyline2\n-----END RSA PRIVATE KEY-----\nafter", secrets: ["MIIEowIBAAKCAQEAfakebody", "QWERTYfakebody"], label: "private key"),
        Case(name: "base64 PEM", input: "tls.key: LS0tLS1CRUdJTiBSU0EgUFJJVkFURSBLRVktLS0tLQpNSUlFb3dJQkFBS0NBUUVB", secrets: ["LS0tLS1CRUdJTiBSU0Eg"], label: nil),
        Case(name: "base64 key=value", input: "config: " + Data("db.host=db\ndb.password=hunter2\nport=5432\n".utf8).base64EncodedString(), secrets: ["ZGIuaG9zdD1kYg"], label: "base64 secret"),
        Case(name: "base64 JWT", input: "x " + Data(jwt.utf8).base64EncodedString(), secrets: [Data(jwt.utf8).base64EncodedString()], label: "base64 secret"),
        Case(name: "log line with two secrets", input: "2026-11-07T10:00:00Z ERROR auth failed password=hunter2 token=\(jwt)", secrets: ["hunter2", jwt], label: nil),
    ]

    @Test(arguments: positives)
    func removesTheSecret(_ c: Case) {
        let out = redactor.redact(c.input)
        for secret in c.secrets { #expect(!out.contains(secret), "\(c.name): \(secret) survived in \(out)") }
        #expect(out.contains(Redactor.placeholderPrefix), "\(c.name): no placeholder")
        if let label = c.label { #expect(out.contains("‹redacted: \(label)›"), "\(c.name): wrong label in \(out)") }
    }

    @Test(arguments: positives)
    func isIdempotent(_ c: Case) {
        let once = redactor.redact(c.input)
        #expect(redactor.redact(once) == once)
    }

    static let negatives: [String] = [
        "Reconciling deployment checkout: 3 replicas ready",
        "token_count=5 tokens: 12 max_tokens=1024",
        "secretName: db-credentials",
        "secretKeyRef:\n  name: db\n  key: password",
        "- name: DB_USER\n  value: app",
        "-----BEGIN PUBLIC KEY-----\nMFwwDQYJKoZIhvcNAQEBBQADSwAwSAJBAfake\n-----END PUBLIC KEY-----",
        "secretName: tls-cert\ntokenSecretRef:\n  name: gh\npasswordSecretSelector: x",
        "reference: ${SECRET_TOKEN} and {{ .Values.token }}",
        "http://example.com:8080/path?page=2",
        "contact user@example.com about it",
        "git clone git@github.com:org/repo.git",
        "ssh://git@github.com/org/repo",
        "image registry.example.com:5000/team/app:1.2.3",
        "eyJhbGciOiJIUzI1NiJ9 is only a header",
        "AKIA1234 is too short; ghp_short; skip-antivirus; sk-ant is a prefix",
        "bearer token required for this endpoint",
        "Authorization header missing",
        "password: ${DB_PASSWORD}",
        "password: {{ .Values.db.password }}",
        "password: <your-password>",
        "token: true",
        "pwd: /home/app",
        "Successfully pulled image \"nginx:1.25\" in 2.1s",
        "sha256:2c26b46b68ffc68ff99b453c1d30413413422d706483bfa0f98a5e886266e7ae",
        "monkey=banana",
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQC7fake user@host",
        "passwords must be rotated every 90 days",
        "Invalid password for user admin",
        "password:\n  nested: value",
        "tokenizer loaded in 12ms; secrets manager enabled",
        "request id 6f1e0a3c-1b2d-4c5e-8f90-a1b2c3d4e5f6 finished",
    ]

    @Test(arguments: negatives)
    func leavesNearMissesAlone(_ text: String) {
        #expect(redactor.redact(text) == text)
    }

    // MARK: Names

    @Test func sensitiveNames() {
        for name in ["DB_PASSWORD", "API_KEY", "GITHUB_TOKEN", "client-secret", "AWS_SECRET_ACCESS_KEY", "SENTRY_DSN", "AUTH_HEADER", "credentials_file", "passphrase"] {
            #expect(Redactor.isSensitiveName(name), "\(name)")
        }
        for name in ["LOG_LEVEL", "PORT", "REPLICAS", "DATABASE_HOST", "TZ", "HOSTNAME", "NODE_ENV"] {
            #expect(!Redactor.isSensitiveName(name), "\(name)")
        }
    }

    // MARK: Structure

    @Test func wrappedBase64PEMInLogsIsRemoved() {
        let pem = "-----BEGIN RSA PRIVATE KEY-----\n" + String(repeating: "MIIEowIBAAKCAQEAfakebody", count: 20) + "\n-----END RSA PRIVATE KEY-----\n"
        let b64 = Data(pem.utf8).base64EncodedString()
        var lines: [String] = []
        var rest = Substring(b64)
        while !rest.isEmpty { lines.append(String(rest.prefix(76))); rest = rest.dropFirst(76) }
        let log = (["tls.key: " + lines[0]] + lines.dropFirst() + ["next log line"]).joined(separator: "\n")
        let out = redactor.redact(log)
        for chunk in lines { #expect(!out.contains(chunk), "wrapped chunk survived") }
        #expect(out.contains("‹redacted: pem (base64)›"))
    }

    @Test func numbersUnderSecretKeysAreMasked() {
        let cr: JSONValue = ["kind": "Thing", "spec": ["pin": 1234, "adminPassword": 987654, "apiKey": 3.5, "replicas": 2, "tokenSecretRef": 7]]
        let out = redactor.resource(cr)
        #expect(out.value(at: "spec.adminPassword")?.stringValue == "‹redacted: field adminPassword›")
        #expect(out.value(at: "spec.apiKey")?.stringValue == "‹redacted: field apiKey›")
        #expect(out.value(at: "spec.replicas")?.intValue == 2)
        #expect(out.value(at: "spec.pin")?.intValue == 1234)
        #expect(out.value(at: "spec.tokenSecretRef")?.intValue == 7)
    }

    @Test func envPairsAreMaskedInHelmValuesAndProviderOutput() {
        let values: JSONValue = ["extraEnv": [["name": "DB_PASSWORD", "value": "HelmLeak1"], ["name": "LOG_LEVEL", "value": "debug"]]]
        let out = redactor.values(values)
        #expect(out.value(at: "extraEnv")?[0]?["value"]?.stringValue == "‹redacted: env value›")
        #expect(out.value(at: "extraEnv")?[1]?["value"]?.stringValue == "debug")
        let provider: JSONValue = ["items": [["name": "DB_PASSWORD", "value": "ProvLeak2"], ["name": "REGION", "value": "eu"]]]
        let scrubbed = redactor.scrubOutput(provider)
        #expect(scrubbed.value(at: "items")?[0]?["value"]?.stringValue == "‹redacted: env value›")
        #expect(scrubbed.value(at: "items")?[1]?["value"]?.stringValue == "eu")
        #expect(redactor.scrubOutput(scrubbed) == scrubbed)
    }

    @Test func podSpecSecretReferencesStayVisibleWhileValuesAreMasked() {
        let pod: JSONValue = ["kind": "Pod", "spec": [
            "imagePullSecrets": [["name": "regcred"]],
            "volumes": [["name": "certs", "secret": ["secretName": "tls-certs", "defaultMode": 420, "optional": false,
                                                      "items": [["key": "tls.crt", "path": "tls/tls.crt"]]]]],
            "containers": [["name": "app", "env": [
                ["name": "PASSWORD", "value": "PodLeak1"],
                ["name": "DB_USER", "valueFrom": ["secretKeyRef": ["name": "db", "key": "user"]]],
            ], "password": "PodLeak2"]],
        ]]
        let out = redactor.scrubOutput(pod)
        #expect(out.value(at: "spec.imagePullSecrets")?[0]?["name"]?.stringValue == "regcred")
        let secret = out.value(at: "spec.volumes")?[0]?["secret"]
        #expect(secret?["secretName"]?.stringValue == "tls-certs")
        #expect(secret?["defaultMode"]?.intValue == 420)
        #expect(secret?["optional"]?.boolValue == false)
        #expect(secret?["items"]?[0]?["key"]?.stringValue == "tls.crt")
        #expect(secret?["items"]?[0]?["path"]?.stringValue == "tls/tls.crt")
        let container = out.value(at: "spec.containers")?[0]
        #expect(container?["env"]?[0]?["value"]?.stringValue == "‹redacted: env value›")
        #expect(container?["env"]?[1]?["valueFrom"]?["secretKeyRef"]?["name"]?.stringValue == "db")
        #expect(container?["password"]?.stringValue == "‹redacted: field password›")
        #expect(!out.jsonString().contains("PodLeak"))
        // The same references inside a secret-named parent keep their metadata too.
        let nested: JSONValue = ["credentials": ["secret": ["secretName": "x", "defaultMode": 420, "items": [["key": "k"]]], "value": "NestLeak"]]
        let scrubbed = redactor.scrubOutput(nested)
        #expect(scrubbed.value(at: "credentials.secret.secretName")?.stringValue == "x")
        #expect(scrubbed.value(at: "credentials.secret.items")?[0]?["key"]?.stringValue == "k")
        #expect(scrubbed.value(at: "credentials.value")?.stringValue == "‹redacted: field value›")
        // Outside a reference, `key` under a secret field is still a value.
        #expect(redactor.scrubOutput(["password": ["key": "Leak3"]]).value(at: "password.key")?.stringValue == "‹redacted: field key›")
    }

    @Test func structuredFieldsWithSecretNamesAreMasked() {
        let cr: JSONValue = ["kind": "Database", "spec": [
            "password": "hunter2", "adminToken": "abc123", "apiKey": "k-123", "replicas": 3, "secretName": "db-creds",
            "tokenSecretRef": ["name": "gh", "key": "token"], "passwordSecretSelector": "x", "enabled": true,
        ]]
        let out = redactor.resource(cr)
        #expect(out.value(at: "spec.password")?.stringValue == "‹redacted: field password›")
        #expect(out.value(at: "spec.adminToken")?.stringValue == "‹redacted: field adminToken›")
        #expect(out.value(at: "spec.apiKey")?.stringValue == "‹redacted: field apiKey›")
        #expect(out.value(at: "spec.replicas")?.intValue == 3)
        #expect(out.value(at: "spec.secretName")?.stringValue == "db-creds")
        #expect(out.value(at: "spec.tokenSecretRef.name")?.stringValue == "gh")
        #expect(out.value(at: "spec.passwordSecretSelector")?.stringValue == "x")
        #expect(out.value(at: "spec.enabled")?.boolValue == true)
        #expect(redactor.resource(out) == out)
    }

    @Test func fluxSubstituteAndArgoParametersAreMasked() {
        let flux: JSONValue = ["kind": "Kustomization", "spec": ["postBuild": ["substitute": ["DB_PASSWORD": "hunter2", "REGION": "eu"]]]]
        let outFlux = redactor.resource(flux)
        #expect(outFlux.value(at: "spec.postBuild.substitute.DB_PASSWORD")?.stringValue == "‹redacted: field DB_PASSWORD›")
        #expect(outFlux.value(at: "spec.postBuild.substitute.REGION")?.stringValue == "eu")
        let argo: JSONValue = ["kind": "Application", "spec": ["source": ["helm": ["parameters": [
            ["name": "db.password", "value": "hunter2"], ["name": "image.tag", "value": "1.2"],
        ]]]]]
        let params = redactor.resource(argo).value(at: "spec.source.helm.parameters")?.arrayValue ?? []
        #expect(params[0]["value"]?.stringValue == "‹redacted: env value›")
        #expect(params[1]["value"]?.stringValue == "1.2")
        #expect(!redactor.resource(argo).jsonString().contains("hunter2"))
    }

    @Test func envLiteralsAreMaskedAndReferencesAreNeverResolved() {
        let deployment: JSONValue = ["kind": "Deployment", "spec": ["template": ["spec": ["containers": [[
            "name": "app",
            "env": [
                ["name": "LOG_LEVEL", "value": "debug"],
                ["name": "DB_PASSWORD", "value": "hunter2"],
                ["name": "API_TOKEN", "valueFrom": ["secretKeyRef": ["name": "api", "key": "token"]]],
                ["name": "SENTRY_DSN", "value": "https://abc@o1.ingest.sentry.io/1"],
            ],
        ]]]]]]
        let out = redactor.resource(deployment)
        let env = out.value(at: "spec.template.spec.containers")?[0]?["env"]?.arrayValue ?? []
        #expect(env[0]["value"]?.stringValue == "debug")
        #expect(env[1]["value"]?.stringValue == "‹redacted: env value›")
        #expect(env[2]["valueFrom"]?["secretKeyRef"]?["name"]?.stringValue == "api")
        #expect(env[2]["value"] == nil)
        #expect(env[3]["value"]?.stringValue == "‹redacted: env value›")
        #expect(!out.jsonString().contains("hunter2"))
    }

    @Test func secretBecomesTypeKeysAndSizes() {
        let secret: JSONValue = [
            "apiVersion": "v1", "kind": "Secret", "type": "kubernetes.io/tls",
            "metadata": ["name": "tls", "namespace": "apps", "managedFields": [["manager": "kubectl"]],
                         "annotations": ["kubectl.kubernetes.io/last-applied-configuration": #"{"data":{"tls.key":"U0VDUkVU"}}"#, "note": "ok"]],
            "data": ["tls.crt": "aGVsbG8gd29ybGQ=", "tls.key": "U0VDUkVUS0VZ"],
            "stringData": ["extra": "plaintext-secret"],
        ]
        let out = redactor.resource(secret)
        #expect(out["type"]?.stringValue == "kubernetes.io/tls")
        #expect(out["keys"]?.arrayValue?.compactMap(\.stringValue) == ["extra", "tls.crt", "tls.key"])
        #expect(out["sizes"]?["tls.crt"]?.intValue == 11)
        #expect(out["sizes"]?["tls.key"]?.intValue == 9)
        #expect(out["data"] == nil)
        #expect(out["stringData"] == nil)
        #expect(out.value(at: "metadata.managedFields") == nil)
        #expect(out["metadata"]?["annotations"]?["kubectl.kubernetes.io/last-applied-configuration"] == nil)
        let text = out.jsonString()
        for leaked in ["aGVsbG8gd29ybGQ=", "U0VDUkVUS0VZ", "plaintext-secret", "U0VDUkVU"] { #expect(!text.contains(leaked)) }
    }

    @Test func secretListsAreSummarisedItemByItemEvenWithoutAKindOnTheItems() {
        let list: JSONValue = ["items": [
            ["metadata": ["name": "a"], "type": "Opaque", "data": ["k": "dmFsdWU="]],
            ["metadata": ["name": "b"], "type": "Opaque", "data": ["k": "dmFsdWUy"]],
        ]]
        let out = redactor.resource(list, kind: .secret)
        let items = out["items"]?.arrayValue ?? []
        #expect(items.count == 2)
        #expect(items.allSatisfy { $0["data"] == nil && $0["keys"] != nil })
        #expect(!out.jsonString().contains("dmFsdWU"))
    }

    @Test func configMapValuesAreMaskedByKeyNameAndContent() {
        let cm: JSONValue = ["kind": "ConfigMap", "metadata": ["name": "cfg"], "data": [
            "LOG_LEVEL": "info",
            "api-token": "plain-looking-value",
            "app.properties": "db.host=db\ndb.password=hunter2\n",
        ], "binaryData": ["blob": "aGVsbG8="]]
        let out = redactor.resource(cm)
        #expect(out["data"]?["LOG_LEVEL"]?.stringValue == "info")
        #expect(out["data"]?["api-token"]?.stringValue == "‹redacted: key name›")
        let props = out["data"]?["app.properties"]?.stringValue ?? ""
        #expect(props.contains("db.host=db"))
        #expect(!props.contains("hunter2"))
        #expect(out.value(at: "binaryData.blob")?.stringValue == "‹binary, 5 bytes›")
    }

    @Test func lastAppliedConfigurationIsScannedForOtherKinds() throws {
        let applied = #"{"kind":"Deployment","spec":{"template":{"spec":{"containers":[{"name":"a","env":[{"name":"DB_PASSWORD","value":"hunter2"}]}]}}}}"#
        let deployment: JSONValue = ["kind": "Deployment", "metadata": ["name": "web", "annotations": ["kubectl.kubernetes.io/last-applied-configuration": .string(applied)]]]
        let out = redactor.resource(deployment)
        let text = try #require(out["metadata"]?["annotations"]?["kubectl.kubernetes.io/last-applied-configuration"]?.stringValue)
        #expect(!text.contains("hunter2"))
        #expect(text.contains("DB_PASSWORD"))
    }

    @Test func managedFieldsAreDropped() {
        let pod: JSONValue = ["kind": "Pod", "metadata": ["name": "p", "managedFields": [["manager": "kubelet"]], "labels": ["a": "b"]]]
        let out = redactor.resource(pod)
        #expect(out.value(at: "metadata.managedFields") == nil)
        #expect(out.value(at: "metadata.labels.a")?.stringValue == "b")
    }

    @Test func aKubeconfigObjectNeverLeaves() {
        let config: JSONValue = ["kind": "Config", "users": [["name": "u", "user": ["token": "abc"]]], "clusters": []]
        #expect(redactor.resource(config) == .string("‹redacted: kubeconfig›"))
        let nested: JSONValue = ["kind": "ConfigMap", "data": ["kubeconfig": .string(Self.kubeconfig)], "metadata": ["name": "x"]]
        #expect(redactor.resource(nested).value(at: "data.kubeconfig")?.stringValue == "‹redacted: kubeconfig›")
    }

    @Test func helmValuesAreMaskedByKeyAndContent() {
        let values: JSONValue = [
            "replicaCount": 3, "image": ["tag": "1.2.3"],
            "auth": ["enabled": true, "password": "hunter2", "port": 5432],
            "adminToken": "abc", "notes": "see https://u:pw@example.com/x",
            "env": [["name": "A_KEY", "value": "k"]],
        ]
        let out = redactor.values(values)
        #expect(out["replicaCount"]?.intValue == 3)
        #expect(out.value(at: "image.tag")?.stringValue == "1.2.3")
        #expect(out.value(at: "auth.enabled")?.boolValue == true)
        #expect(out.value(at: "auth.password")?.stringValue == "‹redacted: key name›")
        #expect(out["adminToken"]?.stringValue == "‹redacted: key name›")
        #expect(!out.jsonString().contains("u:pw@"))
        #expect(!out.jsonString().contains("hunter2"))
    }

    @Test func userPatternsApplyAndInvalidOnesAreSkipped() {
        let r = Redactor(userPatterns: ["ACME-[0-9]{6}", "(unclosed"])
        #expect(r.invalidUserPatterns == ["(unclosed"])
        #expect(r.redact("ticket ACME-123456 filed") == "ticket ‹redacted: custom› filed")
        #expect(r.redact("plain text") == "plain text")
    }

    @Test func isDeterministic() {
        let text = Self.positives.map(\.input).joined(separator: "\n")
        #expect(redactor.redact(text) == Redactor().redact(text))
    }

    @Test func logsAreRedactedAcrossLines() {
        let lines = ["start", "-----BEGIN RSA PRIVATE KEY-----", "MIIEfakefake", "-----END RSA PRIVATE KEY-----", "password=hunter2", "done"]
        let out = redactor.redactLog(lines)
        let joined = out.joined(separator: "\n")
        #expect(!joined.contains("MIIEfakefake"))
        #expect(!joined.contains("hunter2"))
        #expect(out.first == "start")
        #expect(out.last == "done")
    }
}
