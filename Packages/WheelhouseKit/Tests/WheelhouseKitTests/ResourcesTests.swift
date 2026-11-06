import Testing
import Foundation
@testable import WheelhouseKit

@Suite struct ResourcesTests {
    @Test func labelSelectorValidation() {
        #expect(LabelSelectorSyntax.validate("app=web,tier in (api,worker),!canary") == nil)
        #expect(LabelSelectorSyntax.validate("") == nil)
        #expect(LabelSelectorSyntax.validate("app=web,") != nil)
        #expect(LabelSelectorSyntax.validate("tier in (a,b") != nil)
        #expect(LabelSelectorSyntax.validate("bad key=1") != nil)
    }

    @Test func scalePolicy() {
        #expect(ScalePolicy.isDisruptive(from: 3, to: 0))
        #expect(ScalePolicy.isDisruptive(from: 4, to: 1))
        #expect(!ScalePolicy.isDisruptive(from: 4, to: 3))
        #expect(!ScalePolicy.isDisruptive(from: 0, to: 2))
    }

    @Test func cronTriggerJob() throws {
        let cj = Unstructured(raw: ["apiVersion": "batch/v1", "kind": "CronJob", "metadata": ["name": "report", "namespace": "batch", "uid": "u1"],
                                    "spec": ["jobTemplate": ["spec": ["template": ["spec": ["containers": [["name": "c", "image": "busybox"]]]]]]]])
        let job = try #require(CronJobTrigger.makeJob(cronJob: cj, now: Date(timeIntervalSince1970: 0)))
        #expect(job.value(at: "metadata.name")?.stringValue == "report-manual-700101000000")
        #expect(job.value(at: "metadata.annotations")?["cronjob.kubernetes.io/instantiate"]?.stringValue == "manual")
        #expect(job.value(at: "spec.template.spec.containers") != nil)
    }

    @Test func cronSchedule() throws {
        let s = try #require(CronSchedule("0 2 * * *"))
        #expect(s.describe() == "Every day at 02:00")
        let runs = s.nextRuns(after: Date(timeIntervalSince1970: 0), count: 2)
        #expect(runs.count == 2)
        #expect(runs[1].timeIntervalSince(runs[0]) == 86_400)
        #expect(CronSchedule("*/15 * * * *")?.describe() == "Every 15 minutes")
        #expect(CronSchedule("nonsense") == nil)
    }

    @Test func rollbackRevisions() throws {
        func rs(_ name: String, rev: String, image: String) -> Unstructured {
            Unstructured(raw: ["metadata": ["name": .string(name), "annotations": ["deployment.kubernetes.io/revision": .string(rev)], "ownerReferences": [["kind": "Deployment", "name": "web", "uid": "d1"]]],
                               "spec": ["template": ["metadata": ["labels": ["app": "web", "pod-template-hash": "x"]], "spec": ["containers": [["name": "web", "image": .string(image)]]]]]])
        }
        let dep = Unstructured(raw: ["metadata": ["name": "web", "uid": "d1", "annotations": ["deployment.kubernetes.io/revision": "2"]]])
        let revs = RolloutHistory.revisions(deployment: dep, replicaSets: [rs("web-a", rev: "1", image: "web:1"), rs("web-b", rev: "2", image: "web:2")])
        #expect(revs.map(\.revision) == [2, 1])
        #expect(revs[0].isCurrent && !revs[1].isCurrent)
        guard case .json(let ops)? = RolloutHistory.rollbackPatch(to: revs[1]) else { Issue.record("no patch"); return }
        #expect(ops[0]["path"]?.stringValue == "/spec/template")
        #expect(ops[0].value(at: "value.metadata.labels")?["pod-template-hash"] == nil)
    }

    @Test func drainPlanning() throws {
        func pod(_ name: String, owner: String?, ownerKind: String = "ReplicaSet", emptyDir: Bool = false, mirror: Bool = false) throws -> Pod {
            var raw: JSONValue = ["metadata": ["name": .string(name), "namespace": "shop", "labels": ["app": "web"]], "spec": ["nodeName": "n1", "containers": [["name": "c"]]]]
            if let owner { raw.setValue([["kind": .string(ownerKind), "name": .string(owner), "controller": true]], at: "metadata.ownerReferences") }
            if emptyDir { raw.setValue([["name": "tmp", "emptyDir": [:]]], at: "spec.volumes") }
            if mirror { raw.setValue(["kubernetes.io/config.mirror": "x"], at: "metadata.annotations") }
            return try raw.decode(Pod.self)
        }
        let budget = try JSONValue.object(["metadata": ["name": "pdb", "namespace": "shop"], "spec": ["selector": ["matchLabels": ["app": "web"]]], "status": ["disruptionsAllowed": 0]]).decode(PodDisruptionBudget.self)
        let pods = [try pod("a", owner: "rs"), try pod("ds", owner: "d", ownerKind: "DaemonSet"), try pod("bare", owner: nil), try pod("data", owner: "rs", emptyDir: true), try pod("static", owner: nil, mirror: true)]
        var opts = DrainOptions()
        var plan = DrainPlanner.plan(node: "n1", pods: pods, budgets: [budget], options: opts)
        #expect(plan.toEvict.map(\.name) == ["a"])
        #expect(Set(plan.skipped.map(\.name)) == ["ds", "static"])
        #expect(Set(plan.blockers.map(\.name)) == ["bare", "data"])
        #expect(plan.pdbWaiting.map(\.name) == ["a"])
        #expect(!plan.canProceed)
        opts.forceUnmanaged = true; opts.deleteEmptyDirData = true
        plan = DrainPlanner.plan(node: "n1", pods: pods, budgets: [], options: opts)
        #expect(plan.canProceed && plan.toEvict.count == 3)
    }

    @Test func summaries() {
        let dep = Unstructured(raw: ["metadata": ["name": "web"], "spec": ["replicas": 3], "status": ["readyReplicas": 3, "updatedReplicas": 3]])
        let s = ResourceSummarizer.summarize(kind: .deployment, object: dep)
        #expect(s.status == .healthy && s.ready == 3 && s.desired == 3)
        let node = Unstructured(raw: ["metadata": ["name": "n", "labels": ["node-role.kubernetes.io/control-plane": ""]], "spec": ["unschedulable": true],
                                      "status": ["conditions": [["type": "Ready", "status": "True"]]]])
        let n = ResourceSummarizer.summarize(kind: .node, object: node)
        #expect(n.isCordoned && n.roles == ["control-plane"] && n.status == .warning)
    }

    @Test func jsonPathAndSecrets() {
        let v: JSONValue = ["status": ["items": [["name": "a"]], "phase": "Ready"]]
        #expect(JSONPathLite.evaluate("{.status.items[0].name}", in: v)?.stringValue == "a")
        #expect(JSONPathLite.evaluate(".status.phase", in: v)?.stringValue == "Ready")
        #expect(SecretDecoder.text(fromBase64: "aGVsbG8=") == "hello")
    }
}
