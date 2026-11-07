import Testing
import Foundation
@testable import WheelhouseKit

// Live run of the Survey rules against the isolated TEST cluster. Seed first:
//   scripts/testcluster-fixtures.sh --section m8a-survey
// then, from Packages/WheelhouseKit:
//   WH_TEST_TOKEN=$(cat <repo>/.testcluster/admin.token) WH_TEST_SERVER=https://127.0.0.1:<port> swift test --filter SurveyLive
// Without WH_TEST_TOKEN these tests are skipped. Clean up with: scripts/testcluster-fixtures.sh --section m8a-survey clean

private enum SurveyLiveEnv {
    static var token: String? { ProcessInfo.processInfo.environment["WH_TEST_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }
    static var server: URL? { ProcessInfo.processInfo.environment["WH_TEST_SERVER"].flatMap { URL(string: $0) } }
    static var enabled: Bool { token != nil && server != nil && (server?.host == "127.0.0.1" || server?.host == "localhost") }
    static func client() -> LiveKubeClient {
        let config = ClusterConfig(name: "wheelhouse-test", server: server!, authKind: .token, environment: .development, skipTLSVerify: true)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: token))
    }
}

@Suite("Survey: live run on the test cluster", .enabled(if: SurveyLiveEnv.enabled), .serialized)
struct SurveyLiveTests {
    /// "RULE|Kind|name" for every finding about a `wh-m8a` fixture (the list in scripts/testcluster-fixtures.d/m8a-survey.sh).
    static let expected: Set<String> = [
        "WH-A01|Role|wh-m8a-wild-role", "WH-A01|ClusterRole|wh-m8a-wild-verbs",
        "WH-A02|User|wh-m8a-admin-user",
        "WH-A03|User|wh-m8a-secrets-user",
        "WH-A04|User|wh-m8a-binder-user",
        "WH-A05|User|wh-m8a-kubesystem-user",
        "WH-A06|Group|system:unauthenticated",
        "WH-A07|ServiceAccount|default",
        "WH-A08|Deployment|wh-m8a-powerful",
        "WH-A09|User|wh-m8a-hooks-user",
        "WH-A10|User|wh-m8a-proxy-user", "WH-A10|User|wh-m8a-token-user",
        "WH-W01|Deployment|wh-m8a-w01",
        "WH-W02|Deployment|wh-m8a-w02", "WH-W02|Deployment|wh-m8a-w02b",
        "WH-W03|Deployment|wh-m8a-w03",
        "WH-W04|Deployment|wh-m8a-w04",
        "WH-W05|Deployment|wh-m8a-w05", "WH-W05|Deployment|wh-m8a-w01",
        "WH-W06|Deployment|wh-m8a-w06",
        "WH-W07|Deployment|wh-m8a-w07",
        "WH-W08|Deployment|wh-m8a-w08",
        "WH-W09|Deployment|wh-m8a-w09", "WH-W09|Deployment|wh-m8a-running", "WH-W09|Pod|wh-m8a-bare",
        "WH-W10|Namespace|wh-m8a-nopsa",
        "WH-W11|Deployment|wh-m8a-w11",
    ]

    static func isFixture(_ f: SecurityFinding) -> Bool {
        f.object.name.hasPrefix("wh-m8a") || (f.namespace ?? "").hasPrefix("wh-m8a") || f.related.contains { $0.name.hasPrefix("wh-m8a") }
    }

    @Test func liveFindingsMatchTheFixtures() async throws {
        let snapshot = await SurveyLoader.load(client: SurveyLiveEnv.client(), clusterID: "wheelhouse-test")
        #expect(snapshot.limitations.isEmpty, "\(snapshot.limitations)")
        #expect(snapshot.bindingCount > 10)
        let report = await SurveyEngine.run(snapshot)
        let fixture = report.findings.filter(Self.isFixture)
        let got = Set(fixture.map { "\($0.ruleID)|\($0.object.kind)|\($0.object.name)" })
        let missing = Self.expected.subtracting(got).sorted()
        let unexpected = got.subtracting(Self.expected).sorted()
        #expect(missing.isEmpty, "missing findings: \(missing)")
        #expect(unexpected.isEmpty, "unexpected findings: \(unexpected)")
        print("SURVEY live: \(snapshot.bindingCount) bindings, \(snapshot.workloads.count) workloads, \(report.findings.count) findings in \(String(format: "%.1f", report.durationMs)) ms; \(fixture.count) about fixtures")
        let counts = report.counts()
        print("SURVEY live severities:", Severity.allCases.map { "\($0.rawValue)=\(counts[$0] ?? 0)" }.joined(separator: " "))

        // The running Deployment is judged once through its template, never again through its Pod.
        #expect(!report.findings.contains { $0.object.kind == "Pod" && $0.object.name.hasPrefix("wh-m8a-running-") })
        // The PSA report knows about the fixture namespaces.
        let psa = report.psa.first { $0.namespace == "wh-m8a" }
        #expect(psa?.warn == .restricted)
        // The API server's own "would violate PodSecurity restricted" warnings at apply time named exactly these eight.
        #expect(Set(psa?.failingRestricted.map(\.workload.name) ?? []) == ["wh-m8a-w01", "wh-m8a-w02", "wh-m8a-w02b", "wh-m8a-w03", "wh-m8a-w04", "wh-m8a-w05", "wh-m8a-w06", "wh-m8a-w11"])
        #expect(psa?.failingBaseline.contains { $0.workload.name == "wh-m8a-w01" } == true)
        #expect(psa?.results.first { $0.workload.name == "wh-m8a-hardened" }?.failsRestricted == false)

        // Exports of the live report: SARIF validates, nothing from a Secret leaks (the fixtures hold none, the cluster may).
        for format in SurveyExportFormat.allCases {
            let data = SurveyExporter.export(report.findings, format: format, clusterNames: ["wheelhouse-test": "wheelhouse-test"])
            #expect(!data.isEmpty)
            if format == .sarif { #expect(SARIFSchemaCheck.validate(data).isEmpty, "\(SARIFSchemaCheck.validate(data))") }
        }
    }

    @Test func liveEffectivePermissionsAnswerLikeTheApiServer() async throws {
        let client = SurveyLiveEnv.client()
        let snapshot = await SurveyLoader.load(client: client, clusterID: "wheelhouse-test")
        let index = PermissionIndex(snapshot: snapshot)
        // Fixture grants, checked against the grants the fixtures create:
        #expect(index.can(.user("wh-m8a-secrets-user"), verb: "get", resource: "secrets", namespace: "anything"))
        #expect(!index.can(.user("wh-m8a-secrets-ns-user"), verb: "get", resource: "secrets", namespace: "anything"))
        #expect(index.can(.user("wh-m8a-secrets-ns-user"), verb: "get", resource: "secrets", namespace: "wh-m8a"))
        #expect(index.can(.user("wh-m8a-admin-user"), verb: "delete", resource: "nodes"))
        #expect(!index.can(.user("wh-m8a-dev-user"), verb: "create", resource: "pods/exec", namespace: "kube-system"))
        #expect(index.can(.user("wh-m8a-dev-user"), verb: "create", resource: "pods/exec", namespace: "wh-m8a"))
        // The live ClusterRoles include the server-populated aggregates (admin, edit, view).
        #expect(snapshot.clusterRoles.contains { $0.metadata.name == "admin" && !$0.rules.isEmpty })
    }

    @Test func rbacAnalysisWithoutPermissionsDegradesWithAnExplanation() async throws {
        // A client that can list nothing: the loader reports every kind as a limitation instead of failing.
        let config = ClusterConfig(name: "nobody", server: SurveyLiveEnv.server!, authKind: .token, environment: .development, skipTLSVerify: true)
        let client = LiveKubeClient(config: config, secrets: ClusterSecrets(token: "invalid-token"))
        let snapshot = await SurveyLoader.load(client: client, clusterID: "nobody")
        #expect(snapshot.limitations.count >= 6)
        #expect(SurveyEngine.runSync(snapshot).findings.isEmpty)
    }
}
