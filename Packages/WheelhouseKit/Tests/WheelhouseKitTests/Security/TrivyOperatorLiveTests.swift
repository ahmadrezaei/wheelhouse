import Testing
import Foundation
@testable import WheelhouseKit

// Live roll-up of the Trivy Operator fixtures on the isolated TEST cluster. Seed first:
//   scripts/testcluster-fixtures.sh --section m8b-trivy
// then, from Packages/WheelhouseKit:
//   WH_TEST_TOKEN=$(cat <repo>/.testcluster/admin.token) WH_TEST_SERVER=https://127.0.0.1:<port> swift test --filter TrivyOperatorLive
// Without WH_TEST_TOKEN these tests are skipped. Clean up with: scripts/testcluster-fixtures.sh --section m8b-trivy clean

private enum TrivyLiveEnv {
    static var token: String? { ProcessInfo.processInfo.environment["WH_TEST_TOKEN"].flatMap { $0.isEmpty ? nil : $0 } }
    static var server: URL? { ProcessInfo.processInfo.environment["WH_TEST_SERVER"].flatMap { URL(string: $0) } }
    static var enabled: Bool { token != nil && server != nil && (server?.host == "127.0.0.1" || server?.host == "localhost") }
    static func client() -> LiveKubeClient {
        let config = ClusterConfig(name: "wheelhouse-test", server: server!, authKind: .token, environment: .development, skipTLSVerify: true)
        return LiveKubeClient(config: config, secrets: ClusterSecrets(token: token))
    }
}

@Suite("Trivy Operator: live roll-up on the test cluster", .enabled(if: TrivyLiveEnv.enabled), .serialized)
struct TrivyOperatorLiveTests {
    @Test func discoveryFindsTheOperatorGroup() async throws {
        let detection = TrivyOperator.detect(try await TrivyLiveEnv.client().discovery())
        #expect(detection.hasVulnerabilityReports)
        #expect(detection.version == "v1alpha1")
    }

    @Test func theFixturesRollUpAsDocumented() async throws {
        let client = TrivyLiveEnv.client()
        let list = try await client.list(VulnerabilityReportSummary.self, kind: VulnerabilityReportSummary.resourceKind, namespace: "wh-m8b", options: ListOptions())
        #expect(list.skippedItems == 0)
        #expect(list.items.count == 5)
        let rollup = OperatorRollup.build(list.items)
        #expect(rollup.total.critical == 3 && rollup.total.high == 4 && rollup.total.medium == 5 && rollup.total.low == 2 && rollup.total.unknown == 1)
        #expect(rollup.total.total == 15)
        #expect(rollup.total.fixable == nil)
        #expect(rollup.byNamespace["wh-m8b"]?.total == 15)
        #expect(rollup.workloads.count == 3)
        let web = try #require(rollup.workloads.first { $0.workload.name == "web" })
        #expect(web.workload.kind == "Deployment" && web.containers.count == 2)
        #expect(web.counts.critical == 2 && web.counts.high == 4)
        #expect(rollup.workloads.first { $0.workload.name == "db" }?.workload.kind == "StatefulSet")
        #expect(rollup.workloads.first { $0.workload.name == "tool" }?.workload.kind == "Pod")
    }

    @Test func theFullCVEListIsFetchedLazilyForOneReport() async throws {
        let client = TrivyLiveEnv.client()
        let raw = try await client.getRaw(VulnerabilityReportSummary.resourceKind, name: "replicaset-web-7d9f8c6b5d-app", namespace: "wh-m8b")
        let vulns = TrivyOperator.vulnerabilities(in: raw)
        #expect(vulns.map(\.cveID) == ["CVE-2026-0001", "CVE-2026-0002"])
        #expect(vulns[0].isFixable && !vulns[1].isFixable)
    }
}
