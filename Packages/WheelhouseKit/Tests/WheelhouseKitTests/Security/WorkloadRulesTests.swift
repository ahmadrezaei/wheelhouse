import Testing
import Foundation
@testable import WheelhouseKit

/// Positive and negative fixtures for every WH-W rule and the PSA evaluation (M8a exit criterion).
@Suite("Survey: workload rules WH-W01 to WH-W11")
struct WorkloadRulesTests {
    private func rules(_ w: SurveyWorkload) -> Set<String> {
        Set(WorkloadRules.findings(for: w, clusterID: SF.cluster).map(\.ruleID))
    }
    private func one(_ spec: JSONValue, _ rule: String) -> SecurityFinding? {
        WorkloadRules.findings(for: SF.deployment(spec: spec), clusterID: SF.cluster).first { $0.ruleID == rule }
    }
    private func hardenedPlus(_ extra: [String: JSONValue] = [:], security: JSONValue? = nil, container: JSONValue? = nil) -> JSONValue {
        SF.podSpec(containers: [container ?? SF.container(security: security ?? SF.hardenedSecurity)], extra: extra)
    }

    @Test func hardenedWorkloadHasNoFindings() {
        #expect(rules(SF.hardened()).isEmpty)
        #expect(PSAEvaluator.evaluate(SF.hardened()).failsRestricted == false)
    }

    @Test func w01Privileged() {
        var sec = SF.hardenedSecurity; sec["privileged"] = true
        let f = one(hardenedPlus(security: sec), "WH-W01")
        #expect(f?.severity == .critical)
        #expect(f?.containers == ["app"])
        var off = SF.hardenedSecurity; off["privileged"] = false
        #expect(one(hardenedPlus(security: off), "WH-W01") == nil)
    }

    @Test func w02HostPathSeverityDependsOnThePath() {
        func spec(_ path: String) -> JSONValue { hardenedPlus(["volumes": [["name": "v", "hostPath": ["path": .string(path)]]]]) }
        #expect(one(spec("/data/logs"), "WH-W02")?.severity == .high)
        for critical in ["/", "/var/run/docker.sock", "/var/run/containerd", "/var/run/containerd/containerd.sock", "/etc", "/etc/kubernetes", "/var/run", "/etc/"] {
            #expect(one(spec(critical), "WH-W02")?.severity == .critical, "\(critical)")
        }
        #expect(one(spec("/etcetera"), "WH-W02")?.severity == .high)
        #expect(one(hardenedPlus(["volumes": [["name": "v", "emptyDir": [:]]]]), "WH-W02") == nil)
    }

    @Test func w03HostNamespaces() {
        let f = one(hardenedPlus(["hostNetwork": true, "hostPID": true]), "WH-W03")
        #expect(f?.severity == .high)
        #expect(f?.evidence == ["hostNetwork: true", "hostPID: true"])
        #expect(one(hardenedPlus(["hostIPC": true]), "WH-W03")?.evidence == ["hostIPC: true"])
        #expect(one(hardenedPlus(["hostNetwork": false]), "WH-W03") == nil)
    }

    @Test func w04DangerousCapabilities() {
        for cap in ["SYS_ADMIN", "NET_ADMIN", "NET_RAW", "ALL", "CAP_SYS_ADMIN", "sys_admin"] {
            var sec = SF.hardenedSecurity; sec["capabilities"] = ["add": [.string(cap)], "drop": ["ALL"]]
            #expect(one(hardenedPlus(security: sec), "WH-W04")?.severity == .high, "\(cap)")
        }
        var ok = SF.hardenedSecurity; ok["capabilities"] = ["add": ["NET_BIND_SERVICE"], "drop": ["ALL"]]
        #expect(one(hardenedPlus(security: ok), "WH-W04") == nil)
    }

    @Test func w05PrivilegeEscalation() {
        var unset = SF.hardenedSecurity; unset["allowPrivilegeEscalation"] = nil
        #expect(one(hardenedPlus(security: unset), "WH-W05")?.severity == .medium)
        var explicit = SF.hardenedSecurity; explicit["allowPrivilegeEscalation"] = true
        #expect(one(hardenedPlus(security: explicit), "WH-W05") != nil)
        #expect(one(hardenedPlus(), "WH-W05") == nil)
    }

    @Test func w06RootOrRunAsNonRootMissing() {
        var none = SF.hardenedSecurity; none["runAsNonRoot"] = nil; none["runAsUser"] = nil
        #expect(one(hardenedPlus(security: none), "WH-W06")?.severity == .medium)
        var root = SF.hardenedSecurity; root["runAsNonRoot"] = nil; root["runAsUser"] = 0
        #expect(one(hardenedPlus(security: root), "WH-W06") != nil)
        // pod-level settings apply to containers that set nothing
        let podLevel = SF.podSpec(containers: [SF.container(security: ["allowPrivilegeEscalation": false])], extra: ["securityContext": ["runAsNonRoot": true]])
        #expect(one(podLevel, "WH-W06") == nil)
        // a non-zero user without runAsNonRoot does not run as root
        var uid = SF.hardenedSecurity; uid["runAsNonRoot"] = nil
        #expect(one(hardenedPlus(security: uid), "WH-W06") == nil)
    }

    @Test func w07WritableRootFilesystem() {
        var sec = SF.hardenedSecurity; sec["readOnlyRootFilesystem"] = false
        #expect(one(hardenedPlus(security: sec), "WH-W07")?.severity == .low)
        sec["readOnlyRootFilesystem"] = nil
        #expect(one(hardenedPlus(security: sec), "WH-W07") != nil)
        #expect(one(hardenedPlus(), "WH-W07") == nil)
    }

    @Test func w08MissingLimits() {
        #expect(one(hardenedPlus(container: SF.container(security: SF.hardenedSecurity, limits: false)), "WH-W08")?.severity == .low)
        let onlyMemory: JSONValue = ["name": "app", "image": "r/x@sha256:1", "securityContext": SF.hardenedSecurity, "resources": ["limits": ["memory": "1Gi"]]]
        #expect(one(hardenedPlus(container: onlyMemory), "WH-W08")?.evidence == ["container app: no cpu limit"])
        #expect(one(hardenedPlus(), "WH-W08") == nil)
    }

    @Test func w09MutableImageTags() {
        for image in ["nginx:latest", "nginx", "registry.example.com:5000/team/app:1.2.3"] {
            let f = one(hardenedPlus(container: SF.container(image: image, security: SF.hardenedSecurity)), "WH-W09")
            #expect(f?.severity == .low, "\(image)")
        }
        #expect(one(hardenedPlus(container: SF.container(image: "nginx", security: SF.hardenedSecurity)), "WH-W09")?.evidence == ["container app: image nginx (latest)"])
        #expect(one(hardenedPlus(container: SF.container(image: "nginx@sha256:aaaa", security: SF.hardenedSecurity)), "WH-W09") == nil)
        #expect(one(hardenedPlus(container: SF.container(image: "reg:5000/x/y:1@sha256:aaaa", security: SF.hardenedSecurity)), "WH-W09") == nil)
    }

    @Test func w10NamespacesWithoutPSALabels() {
        let w = SF.hardened(ns: "shop")
        let r = SF.run(SF.snapshot(namespaces: [SF.namespace("shop"), SF.namespace("labelled", labels: ["pod-security.kubernetes.io/warn": "restricted"]),
                                                SF.namespace("empty-ns"), SF.namespace("withpods2")],
                                   workloads: [w, SF.hardened(ns: "labelled"), SF.hardened(ns: "withpods2")]))
        let names = Set(r.findings.filter { $0.ruleID == "WH-W10" }.map(\.object.name))
        #expect(names == ["shop", "withpods2"])          // `empty-ns` has no workloads, `labelled` has a label
        #expect(r.findings.first { $0.ruleID == "WH-W10" }?.severity == .medium)
    }

    @Test func w11SeccompProfile() {
        var none = SF.hardenedSecurity; none["seccompProfile"] = nil
        #expect(one(hardenedPlus(security: none), "WH-W11")?.severity == .low)
        var unconfined = SF.hardenedSecurity; unconfined["seccompProfile"] = ["type": "Unconfined"]
        #expect(one(hardenedPlus(security: unconfined), "WH-W11") != nil)
        // Pod-level profile covers containers that set none
        let podLevel = SF.podSpec(containers: [SF.container(security: none)], extra: ["securityContext": ["seccompProfile": ["type": "RuntimeDefault"]]])
        #expect(one(podLevel, "WH-W11") == nil)
        #expect(one(hardenedPlus(), "WH-W11") == nil)
    }

    @Test func initContainersAreJudgedAndNamed() {
        let spec: JSONValue = ["containers": [SF.container(security: SF.hardenedSecurity)],
                               "initContainers": [SF.container("init", security: ["privileged": true])]]
        #expect(one(spec, "WH-W01")?.containers == ["init"])
    }

    // MARK: building the workload list

    @Test func podsOfControllersAreSkippedAndBarePodsKept() {
        func pod(_ name: String, owner: String?) -> JSONValue {
            var meta: [String: JSONValue] = ["name": .string(name), "namespace": "shop"]
            if let owner { meta["ownerReferences"] = [["kind": .string(owner), "name": "x", "controller": true]] }
            return ["metadata": .object(meta), "spec": SF.podSpec(containers: [SF.container()])]
        }
        let deployment: JSONValue = ["metadata": ["name": "web", "namespace": "shop"], "spec": ["template": ["spec": SF.podSpec(containers: [SF.container()])]]]
        let cronOwnedJob: JSONValue = ["metadata": ["name": "nightly-1", "namespace": "shop", "ownerReferences": [["kind": "CronJob", "name": "nightly", "controller": true]]],
                                       "spec": ["template": ["spec": SF.podSpec(containers: [SF.container()])]]]
        let list = SurveySnapshot.workloads(controllers: ["Deployment": [deployment], "Job": [cronOwnedJob]],
                                            pods: [pod("web-abc-1", owner: "ReplicaSet"), pod("bare", owner: nil), pod("static", owner: "Node"), pod("job-pod", owner: "Job")])
        #expect(list.map(\.id) == ["Deployment/shop/web", "Pod/shop/bare", "Pod/shop/static"])
        // without the Deployment list, a ReplicaSet's Pod is judged itself
        let fallback = SurveySnapshot.workloads(controllers: [:], pods: [pod("web-abc-1", owner: "ReplicaSet")])
        #expect(fallback.map(\.id) == ["Pod/shop/web-abc-1"])
    }

    @Test func cronJobTemplatesAreRead() {
        let raw: JSONValue = ["metadata": ["name": "nightly", "namespace": "ops"],
                              "spec": ["jobTemplate": ["spec": ["template": ["spec": SF.podSpec(containers: [SF.container(security: ["privileged": true])])]]]]]
        let w = SurveyWorkload(raw: raw, kind: "CronJob")
        #expect(w != nil)
        #expect(WorkloadRules.findings(for: w!, clusterID: SF.cluster).contains { $0.ruleID == "WH-W01" })
    }

    @Test func managedByDetection() {
        #expect(SF.deployment(spec: SF.podSpec(containers: [SF.container()]), labels: ["app.kubernetes.io/managed-by": "Helm"]).managedBy == "Helm")
        #expect(SF.deployment(spec: SF.podSpec(containers: [SF.container()]), labels: ["kustomize.toolkit.fluxcd.io/name": "apps"]).managedBy == "Flux")
        #expect(SF.deployment(spec: SF.podSpec(containers: [SF.container()])).managedBy == nil)
    }

    // MARK: Pod Security Admission

    @Test func psaBaselineViolations() {
        func controls(_ spec: JSONValue) -> Set<String> {
            Set(PSAEvaluator.baselineViolations(SF.deployment(spec: spec).spec).map(\.control))
        }
        var priv = SF.hardenedSecurity; priv["privileged"] = true
        #expect(controls(hardenedPlus(security: priv)).contains("Privileged Containers"))
        #expect(controls(hardenedPlus(["hostNetwork": true])).contains("Host Namespaces"))
        #expect(controls(hardenedPlus(["volumes": [["name": "v", "hostPath": ["path": "/x"]]]])).contains("HostPath Volumes"))
        var caps = SF.hardenedSecurity; caps["capabilities"] = ["add": ["SYS_PTRACE"], "drop": ["ALL"]]
        #expect(controls(hardenedPlus(security: caps)).contains("Capabilities"))
        var allowed = SF.hardenedSecurity; allowed["capabilities"] = ["add": ["CHOWN"], "drop": ["ALL"]]
        #expect(!controls(hardenedPlus(security: allowed)).contains("Capabilities"))
        let hostPort: JSONValue = ["name": "a", "image": "x@sha256:1", "ports": [["containerPort": 80, "hostPort": 8080]], "securityContext": SF.hardenedSecurity]
        #expect(controls(hardenedPlus(container: hostPort)).contains("Host Ports"))
        var unconfined = SF.hardenedSecurity; unconfined["seccompProfile"] = ["type": "Unconfined"]
        #expect(controls(hardenedPlus(security: unconfined)).contains("Seccomp"))
        #expect(controls(hardenedPlus(["securityContext": ["sysctls": [["name": "kernel.msgmax", "value": "1"]]]])).contains("Sysctls"))
        #expect(!controls(hardenedPlus(["securityContext": ["sysctls": [["name": "net.ipv4.ip_unprivileged_port_start", "value": "0"]]]])).contains("Sysctls"))
        var selinux = SF.hardenedSecurity; selinux["seLinuxOptions"] = ["type": "spc_t"]
        #expect(controls(hardenedPlus(security: selinux)).contains("SELinux"))
        var proc = SF.hardenedSecurity; proc["procMount"] = "Unmasked"
        #expect(controls(hardenedPlus(security: proc)).contains("/proc Mount Type"))
        #expect(controls(hardenedPlus()).isEmpty)
    }

    @Test func psaRestrictedAddsStricterControls() {
        func controls(_ spec: JSONValue) -> Set<String> {
            Set(PSAEvaluator.restrictedViolations(SF.deployment(spec: spec).spec).map(\.control))
        }
        #expect(controls(hardenedPlus()).isEmpty)
        #expect(controls(hardenedPlus(["volumes": [["name": "v", "nfs": ["server": "s", "path": "/p"]]]])).contains("Volume Types"))
        var sec = SF.hardenedSecurity
        sec["allowPrivilegeEscalation"] = nil
        #expect(controls(hardenedPlus(security: sec)).contains("Privilege Escalation"))
        sec = SF.hardenedSecurity; sec["runAsNonRoot"] = nil
        #expect(controls(hardenedPlus(security: sec)).contains("Running as Non-root"))
        sec = SF.hardenedSecurity; sec["runAsUser"] = 0
        #expect(controls(hardenedPlus(security: sec)).contains("Running as Non-root user"))
        sec = SF.hardenedSecurity; sec["seccompProfile"] = nil
        #expect(controls(hardenedPlus(security: sec)).contains("Seccomp"))
        sec = SF.hardenedSecurity; sec["capabilities"] = ["add": ["NET_BIND_SERVICE"]]
        #expect(controls(hardenedPlus(security: sec)).contains("Capabilities"))        // does not drop ALL
        sec = SF.hardenedSecurity; sec["capabilities"] = ["add": ["NET_BIND_SERVICE"], "drop": ["ALL"]]
        #expect(controls(hardenedPlus(security: sec)).isEmpty)
        // the Pod level can satisfy the non-root and seccomp controls for every container
        let podLevel = SF.podSpec(containers: [SF.container(security: ["allowPrivilegeEscalation": false, "capabilities": ["drop": ["ALL"]]])],
                                  extra: ["securityContext": ["runAsNonRoot": true, "seccompProfile": ["type": "RuntimeDefault"]]])
        #expect(controls(podLevel).isEmpty)
    }

    @Test func psaNamespaceReportCountsFailingWorkloads() {
        var priv = SF.hardenedSecurity; priv["privileged"] = true
        let bad = SF.deployment("bad", ns: "payments", spec: hardenedPlus(security: priv))
        let loose = SF.deployment("loose", ns: "payments", spec: SF.podSpec(containers: [SF.container()]))
        let r = PSAEvaluator.evaluate(snapshot: SF.snapshot(
            namespaces: [SF.namespace("payments", labels: ["pod-security.kubernetes.io/enforce": "baseline", "pod-security.kubernetes.io/warn": "restricted"]), SF.namespace("shop")],
            workloads: [bad, loose, SF.hardened()]))
        let payments = r.first { $0.namespace == "payments" }
        #expect(payments?.enforce == .baseline)
        #expect(payments?.warn == .restricted)
        #expect(payments?.failingBaseline.map(\.workload.name) == ["bad"])
        #expect(payments?.failingRestricted.count == 2)
        #expect(payments?.summary == "payments would fail restricted: 2 workloads")
        #expect(r.first { $0.namespace == "shop" }?.summary == "shop passes restricted")
    }
}
