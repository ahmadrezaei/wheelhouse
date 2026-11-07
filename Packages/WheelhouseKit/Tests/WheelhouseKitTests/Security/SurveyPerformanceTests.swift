import Testing
import Foundation
@testable import WheelhouseKit

@Suite("Survey: performance", .serialized)
struct SurveyPerformanceTests {
    /// 5,000 bindings (3,000 RoleBindings and 2,000 ClusterRoleBindings, one to three subjects each) over 400 roles, with a few
    /// hundred workloads, as a large fleet cluster looks.
    static func bigSnapshot(bindings: Int = 5_000) -> SurveySnapshot {
        let safe = [SF.rule(resources: ["pods", "services", "configmaps"], verbs: ["get", "list", "watch"]), SF.rule(groups: ["apps"], resources: ["deployments"], verbs: ["get", "list"])]
        var clusterRoles: [ClusterRole] = []
        var roles: [Role] = []
        for i in 0..<200 {
            let rules: [JSONValue]
            // One role in ten is dangerous, far more than a real cluster has.
            switch i % 40 {
            case 0: rules = [SF.rule(resources: ["secrets"], verbs: ["get", "list"])]
            case 10: rules = [SF.rule(groups: ["rbac.authorization.k8s.io"], resources: ["roles"], verbs: ["bind"])]
            case 20: rules = [SF.rule(resources: ["pods/exec"], verbs: ["create"])]
            case 30: rules = [SF.rule(resources: ["*"], verbs: ["get"])]
            default: rules = safe
            }
            clusterRoles.append(SF.clusterRole("cr-\(i)", rules: rules))
        }
        for i in 0..<200 { roles.append(SF.role("role-\(i)", ns: "ns-\(i % 50)", rules: i % 25 == 0 ? [SF.rule(resources: ["secrets"], verbs: ["get"])] : safe)) }
        var rbs: [RoleBinding] = []
        var crbs: [ClusterRoleBinding] = []
        func subjects(_ i: Int) -> [JSONValue] {
            (0...(i % 3)).map { k in
                switch (i + k) % 3 {
                case 0: SF.subject("User", "user-\(i)-\(k)")
                case 1: SF.subject("Group", "group-\(i % 97)")
                default: SF.subject("ServiceAccount", i % 11 == 0 ? "default" : "sa-\(i)", ns: "ns-\(i % 50)")
                }
            }
        }
        for i in 0..<(bindings * 3 / 5) {
            let ns = "ns-\(i % 50)"
            rbs.append(i % 2 == 0 ? SF.binding("rb-\(i)", ns: ns, role: "cr-\(i % 200)", subjects: subjects(i))
                                  : SF.binding("rb-\(i)", ns: "ns-\(i % 50)", roleKind: "Role", role: "role-\((i % 200) / 50 * 50 + i % 50)", subjects: subjects(i)))
        }
        for i in 0..<(bindings * 2 / 5) { crbs.append(SF.clusterBinding("crb-\(i)", role: "cr-\(i % 200)", subjects: subjects(i))) }
        var workloads: [SurveyWorkload] = []
        for i in 0..<300 {
            var sec = SF.hardenedSecurity
            if i % 5 == 0 { sec["privileged"] = true }
            workloads.append(SF.deployment("w-\(i)", ns: "ns-\(i % 50)", spec: SF.podSpec(containers: [SF.container(security: sec)], extra: ["serviceAccountName": .string("sa-\(i)")])))
        }
        return SF.snapshot(roles: roles, clusterRoles: clusterRoles, roleBindings: rbs, clusterRoleBindings: crbs,
                           namespaces: (0..<50).map { SF.namespace("ns-\($0)") }, workloads: workloads)
    }

    @Test func fiveThousandBindingsRunUnderFiftyMilliseconds() {
        let snapshot = Self.bigSnapshot()
        #expect(snapshot.bindingCount == 5_000)
        _ = SF.run(snapshot)       // warm up
        var best = Double.infinity
        var report: SurveyReport?
        for _ in 0..<5 {
            let r = SurveyEngine.runSync(snapshot)
            if r.durationMs < best { best = r.durationMs }
            report = r
        }
        print("SURVEY perf: 5000 bindings, \(report?.findings.count ?? 0) findings, best \(String(format: "%.1f", best)) ms")
        #expect((report?.findings.count ?? 0) > 100)
        // The budget is for the shipped (optimised) build: about 8 ms there. An unoptimised test build is 5 to 10 times slower and runs
        // beside other builds, so it gets a wider bound.
        #if DEBUG
        #expect(best < 250, "rules took \(best) ms")
        #else
        #expect(best < 50, "rules took \(best) ms")
        #endif
    }

    /// `SurveyEngine.run` is `@concurrent`: awaited from the main actor it runs on the global executor, so the main actor keeps ticking.
    @MainActor @Test func theRunHappensOffTheMainActor() async {
        let snapshot = Self.bigSnapshot()
        var ticks = 0
        let ticker = Task { @MainActor in
            while !Task.isCancelled { ticks += 1; try? await Task.sleep(for: .milliseconds(1)) }
        }
        await Task.yield()
        var reports: [SurveyReport] = []
        for _ in 0..<4 { reports.append(await SurveyEngine.run(snapshot)) }
        ticker.cancel()
        #expect(reports.allSatisfy { $0.bindingCount == 5_000 })
        #expect(ticks > 5, "the main actor was blocked (\(ticks) ticks)")
    }

    @Test func exportOfALargeReportIsQuick() {
        let report = SF.run(Self.bigSnapshot())
        let start = ContinuousClock.now
        for f in SurveyExportFormat.allCases { _ = SurveyExporter.export(report.findings, format: f) }
        let ms = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
        #expect(ms < 2_000)
    }
}
