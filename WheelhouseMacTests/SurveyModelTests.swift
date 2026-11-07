import Testing
import Foundation
import WheelhouseKit
@testable import WheelhouseMac

@MainActor @Suite("Survey model", .serialized)
struct SurveyModelTests {
    private func demoSession() -> ClusterSession {
        let registry = ClusterRegistry(credentials: InMemoryCredentialStore(), metadata: InMemoryMetadataStore(),
                                       defaults: UserDefaults(suiteName: "wh.survey.tests") ?? .standard)
        registry.enterDemoMode(persist: false)
        return registry.session(for: registry.clusters[0].id)!
    }

    @Test func storesRunOnlyWhileSurveyIsVisible() async throws {
        let model = SurveyModel(session: demoSession())
        #expect(model.runningStoreCount == 0)
        #expect(!model.isWatching)
        model.retain()
        #expect(model.isWatching)
        #expect(model.runningStoreCount == 12)          // 6 RBAC and namespace stores, 5 controller stores, pods
        model.retain()                                   // a second pane of the same cluster shares them
        model.release()
        #expect(model.runningStoreCount == 12)
        model.release()
        #expect(model.runningStoreCount == 0)
        #expect(!model.isWatching)
    }

    @Test func demoClusterProducesAReportWhileWatched() async throws {
        let model = SurveyModel(session: demoSession())
        model.retain()
        defer { model.release() }
        for _ in 0..<100 where model.report == nil { try await Task.sleep(for: .milliseconds(100)) }
        let report = try #require(model.report)
        #expect(report.bindingCount >= 1)
        #expect(report.workloadCount > 0)
        #expect(report.workloadFindings.contains { $0.ruleID == "WH-W06" })
        #expect(report.findings.allSatisfy { $0.clusterID == model.clusterID })
    }

    @Test func acceptedRisksPersistAcrossHubInstances() throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "wh-survey-hub-\(UUID().uuidString)/risks.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let finding = SecurityFinding(ruleID: "WH-W07", severity: .low, clusterID: "c", namespace: "n", object: FindingObject(kind: "Deployment", namespace: "n", name: "d"),
                                      title: "t", evidence: [])
        let hub = SurveyHub(riskFile: url)
        hub.accept(finding, scope: .ruleInNamespace, reason: "tracked", days: 90)
        let again = SurveyHub(riskFile: url)
        #expect(again.risks.status(of: finding).isAccepted)
        again.removeRisk(again.risks.risks[0].id)
        #expect(SurveyHub(riskFile: url).risks.risks.isEmpty)
    }

    @Test func featureHandlesItsDestinationsAndShipsFourSidebarNodes() {
        #expect(SurveyFeature.handles(.survey(SurveyScope(clusterID: nil, tab: .overview))))
        #expect(SurveyFeature.handles(.surveyFinding("WH-A02|c||User/a|CRB:x")))
        #expect(SurveyFeature.sidebarNodes.count == 4)
    }

    @Test func filtersApplySeverityNamespaceAndAcceptedState() {
        func f(_ rule: String, _ sev: Severity, _ ns: String?) -> SecurityFinding {
            SecurityFinding(ruleID: rule, severity: sev, clusterID: "c", namespace: ns, object: FindingObject(kind: "Deployment", namespace: ns, name: "d-\(rule)"), title: "title \(rule)", evidence: [])
        }
        var book = AcceptedRiskBook()
        let findings = [f("WH-W01", .critical, "shop"), f("WH-W07", .low, "kube-system"), f("WH-W08", .low, "shop")]
        book.accept(findings[2], scope: .finding, reason: "r", days: 30)
        var report = SurveyEngine.runSync(SurveySnapshot(clusterID: "c"))
        report.findings = findings
        let rows = SurveyFilters.rows(from: [report], names: ["c": "Cluster"], category: .workload, book: book)
        #expect(rows.count == 3)
        #expect(SurveyFilters.apply(rows, severity: nil, search: "", hideSystemNamespaces: true, showAccepted: false, namespace: nil).map(\.finding.ruleID) == ["WH-W01"])
        #expect(SurveyFilters.apply(rows, severity: .low, search: "", hideSystemNamespaces: false, showAccepted: true, namespace: nil).count == 2)
        #expect(SurveyFilters.apply(rows, severity: nil, search: "w07", hideSystemNamespaces: false, showAccepted: true, namespace: "kube-system").count == 1)
    }
}
