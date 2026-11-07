import Testing
import Foundation
@testable import WheelhouseKit

/// Positive and negative fixtures for every WH-A rule (M8a exit criterion).
@Suite("Survey: access rules WH-A01 to WH-A10")
struct RBACRulesTests {
    private let bootstrap = ["kubernetes.io/bootstrapping": "rbac-defaults"]

    // MARK: WH-A01

    @Test func a01WildcardVerbsOrResourcesInClusterRoleAndRole() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("ns-wild", ns: "dev", rules: [SF.rule(resources: ["*"], verbs: ["get"])])],
            clusterRoles: [SF.clusterRole("verb-wild", rules: [SF.rule(resources: ["pods"], verbs: ["*"])])]))
        #expect(SF.has(r, "WH-A01", object: "ns-wild"))
        #expect(SF.has(r, "WH-A01", object: "verb-wild"))
        #expect(r.findings.first { $0.ruleID == "WH-A01" }?.severity == .high)
        #expect(r.findings.first { $0.object.name == "verb-wild" }?.evidence.first?.contains("verbs: [*]") == true)
    }

    @Test func a01NegativeExplicitRulesDefaultRolesAndAggregates() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("explicit", ns: "dev", rules: [SF.rule(resources: ["pods", "pods/log"], verbs: ["get", "list"])])],
            clusterRoles: [
                SF.clusterRole("cluster-admin", rules: [SF.rule(groups: ["*"], resources: ["*"], verbs: ["*"])], labels: bootstrap),
                SF.clusterRole("agg", rules: [SF.rule(resources: ["*"], verbs: ["*"])], aggregate: [["x": "y"]]),
                // a rule that only lists nonResourceURLs has no resources and is not a resource wildcard
                SF.clusterRole("urls", rules: [.object(["nonResourceURLs": ["/healthz"], "verbs": ["*"]])]),
            ]))
        #expect(!SF.has(r, "WH-A01"))
    }

    // MARK: WH-A02

    @Test func a02ClusterAdminBoundOutsideSystem() {
        let r = SF.run(SF.snapshot(
            roleBindings: [SF.binding("admin-in-dev", ns: "dev", role: "cluster-admin", subjects: [SF.subject("User", "bob")])],
            clusterRoleBindings: [
                SF.clusterBinding("alice-admin", role: "cluster-admin", subjects: [SF.subject("User", "alice"), SF.subject("ServiceAccount", "ci", ns: "build")]),
            ]))
        let a02 = r.findings.filter { $0.ruleID == "WH-A02" }
        #expect(a02.count == 3)
        #expect(a02.allSatisfy { $0.severity == .critical })
        #expect(a02.contains { $0.object.kind == "ServiceAccount" && $0.object.name == "ci" && $0.object.namespace == "build" })
        #expect(a02.contains { $0.object.name == "bob" && $0.namespace == "dev" })
    }

    @Test func a02NegativeSystemSubjectsAndOtherRoles() {
        let r = SF.run(SF.snapshot(clusterRoleBindings: [
            SF.clusterBinding("cluster-admin", role: "cluster-admin", subjects: [SF.subject("Group", "system:masters")], labels: bootstrap),
            SF.clusterBinding("system:kcm", role: "cluster-admin", subjects: [SF.subject("User", "system:kube-controller-manager")], labels: bootstrap),
            SF.clusterBinding("viewers", role: "view", subjects: [SF.subject("User", "alice")]),
        ]))
        #expect(!SF.has(r, "WH-A02"))
    }

    @Test func a02ReportsUserCreatedBindingsToSystemSubjects() {
        let r = SF.run(SF.snapshot(clusterRoleBindings: [
            SF.clusterBinding("boot", role: "cluster-admin", subjects: [SF.subject("Group", "system:bootstrappers")]),
            SF.clusterBinding("nodes", role: "cluster-admin", subjects: [SF.subject("Group", "system:nodes"), SF.subject("User", "system:node:worker-1")]),
            // the default binding Kubernetes creates stays silent, and so does system:masters under any name
            SF.clusterBinding("cluster-admin", role: "cluster-admin", subjects: [SF.subject("Group", "system:masters")], labels: bootstrap),
            SF.clusterBinding("my-masters", role: "cluster-admin", subjects: [SF.subject("Group", "system:masters")]),
        ]))
        #expect(Set(r.findings.filter { $0.ruleID == "WH-A02" }.map(\.object.name)) == ["system:bootstrappers", "system:nodes", "system:node:worker-1"])
    }

    @Test func a02ReportsASystemNamedBindingThatIsNotLabelledAsADefault() {
        let r = SF.run(SF.snapshot(clusterRoleBindings: [
            SF.clusterBinding("system:sneaky-nodes", role: "cluster-admin", subjects: [SF.subject("Group", "system:nodes")]),
            SF.clusterBinding("cluster-admin", role: "cluster-admin", subjects: [SF.subject("Group", "system:masters")], labels: bootstrap),
        ]))
        #expect(Set(r.findings.filter { $0.ruleID == "WH-A02" }.map(\.object.name)) == ["system:nodes"])
    }

    @Test func aBindingWithASystemNameIsNotADefaultWhenItBindsAnOrdinarySubject() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("secret-reader", rules: [SF.rule(resources: ["secrets"], verbs: ["get", "list"])])],
            roleBindings: [SF.binding("system:sneaky", ns: "dev", role: "edit", subjects: [SF.subject("ServiceAccount", "default", ns: "dev")])],
            clusterRoleBindings: [SF.clusterBinding("system:sneaky", role: "secret-reader", subjects: [SF.subject("User", "mallory")]),
                                  SF.clusterBinding("system:admin-ish", role: "cluster-admin", subjects: [SF.subject("User", "mallory")])]))
        #expect(SF.has(r, "WH-A03", object: "mallory"))
        #expect(SF.has(r, "WH-A02", object: "mallory"))
        #expect(SF.has(r, "WH-A07"))
    }

    @Test func aSystemNamedRoleWithoutTheBootstrapLabelIsStillJudged() {
        let r = SF.run(SF.snapshot(roles: [SF.role("system:foo", ns: "kube-system", rules: [SF.rule(resources: ["*"], verbs: ["get"])])],
                                   clusterRoles: [SF.clusterRole("system:coredns-like", rules: [SF.rule(resources: ["*"], verbs: ["*"])]),
                                                  SF.clusterRole("system:labelled", rules: [SF.rule(resources: ["*"], verbs: ["*"])], labels: bootstrap)]))
        #expect(Set(r.findings.filter { $0.ruleID == "WH-A01" }.map(\.object.name)) == ["system:coredns-like", "system:foo"])
    }

    @Test func idsAndLocationsKeepServiceAccountsOfDifferentNamespacesApart() {
        let r = SF.run(SF.snapshot(clusterRoleBindings: [SF.clusterBinding("a", role: "cluster-admin", subjects: [SF.subject("ServiceAccount", "deployer", ns: "team-a")]),
                                                         SF.clusterBinding("b", role: "cluster-admin", subjects: [SF.subject("ServiceAccount", "deployer", ns: "team-b")])]))
        let f = r.findings.filter { $0.ruleID == "WH-A02" }
        #expect(f.count == 2)
        #expect(Set(f.map(\.id)).count == 2)
        #expect(Set(f.map(\.logicalLocation)).count == 2)
        #expect(f.contains { $0.logicalLocation.contains("team-a/deployer") })
        // the same subject bound twice by the same binding name in different namespaces' ServiceAccounts, through capability findings
        let caps = SF.run(SF.snapshot(clusterRoles: [SF.clusterRole("sr", rules: [SF.rule(resources: ["secrets"], verbs: ["get"])])],
                                      clusterRoleBindings: [SF.clusterBinding("x", role: "sr", subjects: [SF.subject("ServiceAccount", "deployer", ns: "team-a"), SF.subject("ServiceAccount", "deployer", ns: "team-b")])]))
        #expect(Set(caps.findings.filter { $0.ruleID == "WH-A03" }.map(\.id)).count == 2)
    }

    @Test func podAccessCapabilityCoversAttachGetAndWorkloadControllersInKubeSystem() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("attach", ns: "kube-system", rules: [SF.rule(resources: ["pods/attach"], verbs: ["create"])]),
                    SF.role("exec-get", ns: "kube-system", rules: [SF.rule(resources: ["pods/exec"], verbs: ["get"])]),
                    SF.role("deployer", ns: "kube-system", rules: [SF.rule(groups: ["apps"], resources: ["deployments"], verbs: ["create"])]),
                    SF.role("cron", ns: "kube-system", rules: [SF.rule(groups: ["batch"], resources: ["cronjobs"], verbs: ["create"])]),
                    SF.role("reader", ns: "kube-system", rules: [SF.rule(groups: ["apps"], resources: ["deployments"], verbs: ["get", "list"])])],
            roleBindings: ["attach", "exec-get", "deployer", "cron", "reader"].map {
                SF.binding("rb-\($0)", ns: "kube-system", roleKind: "Role", role: $0, subjects: [SF.subject("User", "u-\($0)")])
            }))
        #expect(Set(r.findings.filter { $0.ruleID == "WH-A05" }.map(\.object.name)) == ["u-attach", "u-exec-get", "u-deployer", "u-cron"])
    }

    // MARK: WH-A03

    @Test func a03ReadSecretsClusterWide() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("secret-reader", rules: [SF.rule(resources: ["secrets"], verbs: ["get", "list"])])],
            clusterRoleBindings: [SF.clusterBinding("sr", role: "secret-reader", subjects: [SF.subject("ServiceAccount", "bot", ns: "ops")])]))
        let f = r.findings.first { $0.ruleID == "WH-A03" }
        #expect(f?.severity == .high)
        #expect(f?.object.name == "bot")
        #expect(f?.related.map(\.name).contains("sr") == true)
    }

    @Test func a03NegativeNamespacedNamedAndWriteOnly() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [
                SF.clusterRole("secret-reader", rules: [SF.rule(resources: ["secrets"], verbs: ["get", "list"])]),
                SF.clusterRole("named", rules: [SF.rule(resources: ["secrets"], verbs: ["get"], names: ["one"])]),
                SF.clusterRole("writer", rules: [SF.rule(resources: ["secrets"], verbs: ["create", "delete"])]),
            ],
            roleBindings: [SF.binding("rb", ns: "dev", role: "secret-reader", subjects: [SF.subject("User", "carol")])],
            clusterRoleBindings: [
                SF.clusterBinding("n", role: "named", subjects: [SF.subject("User", "dave")]),
                SF.clusterBinding("w", role: "writer", subjects: [SF.subject("User", "erin")]),
            ]))
        #expect(!SF.has(r, "WH-A03"))
    }

    @Test func a03IsNotRepeatedForSubjectsAlreadyReportedAsClusterAdmin() {
        let r = SF.run(SF.snapshot(clusterRoles: [SF.clusterRole("cluster-admin", rules: [SF.rule(groups: ["*"], resources: ["*"], verbs: ["*"])])],
                                   clusterRoleBindings: [SF.clusterBinding("x", role: "cluster-admin", subjects: [SF.subject("User", "alice")])]))
        #expect(SF.has(r, "WH-A02"))
        #expect(!SF.has(r, "WH-A03"))
        #expect(!SF.has(r, "WH-A04"))
    }

    // MARK: WH-A04

    @Test func a04EscalateBindImpersonate() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [
                SF.clusterRole("esc", rules: [SF.rule(groups: ["rbac.authorization.k8s.io"], resources: ["clusterroles"], verbs: ["escalate"])]),
                SF.clusterRole("bnd", rules: [SF.rule(groups: ["rbac.authorization.k8s.io"], resources: ["roles"], verbs: ["bind"])]),
                SF.clusterRole("imp", rules: [SF.rule(resources: ["users", "groups"], verbs: ["impersonate"])]),
            ],
            clusterRoleBindings: [
                SF.clusterBinding("e", role: "esc", subjects: [SF.subject("User", "u1")]),
                SF.clusterBinding("b", role: "bnd", subjects: [SF.subject("User", "u2")]),
                SF.clusterBinding("i", role: "imp", subjects: [SF.subject("User", "u3")]),
            ]))
        let names = Set(r.findings.filter { $0.ruleID == "WH-A04" }.map(\.object.name))
        #expect(names == ["u1", "u2", "u3"])
        #expect(r.findings.filter { $0.ruleID == "WH-A04" }.allSatisfy { $0.severity == .critical })
    }

    @Test func a04ApplicableInANamespaceScope() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("binder", ns: "dev", rules: [SF.rule(groups: ["rbac.authorization.k8s.io"], resources: ["roles"], verbs: ["bind"])])],
            roleBindings: [SF.binding("rb", ns: "dev", roleKind: "Role", role: "binder", subjects: [SF.subject("User", "u1")])]))
        let f = r.findings.first { $0.ruleID == "WH-A04" }
        #expect(f?.namespace == "dev")
    }

    @Test func a04NegativeOrdinaryRoleVerbsAndNamedImpersonation() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [
                SF.clusterRole("roles-reader", rules: [SF.rule(groups: ["rbac.authorization.k8s.io"], resources: ["roles"], verbs: ["get", "list"])]),
                SF.clusterRole("imp-one", rules: [SF.rule(resources: ["users"], verbs: ["impersonate"], names: ["gateway-user"])]),
                // the verb on the wrong API group does not escalate
                SF.clusterRole("wrong-group", rules: [SF.rule(groups: ["apps"], resources: ["roles"], verbs: ["escalate"])]),
            ],
            clusterRoleBindings: [
                SF.clusterBinding("a", role: "roles-reader", subjects: [SF.subject("User", "u1")]),
                SF.clusterBinding("b", role: "imp-one", subjects: [SF.subject("User", "u2")]),
                SF.clusterBinding("c", role: "wrong-group", subjects: [SF.subject("User", "u3")]),
            ]))
        #expect(!SF.has(r, "WH-A04"))
    }

    // MARK: WH-A05

    @Test func a05CreatePodsAndExecInKubeSystem() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("pod-exec", ns: "kube-system", rules: [SF.rule(resources: ["pods/exec"], verbs: ["create"])])],
            clusterRoles: [SF.clusterRole("pod-maker", rules: [SF.rule(resources: ["pods"], verbs: ["create"])])],
            roleBindings: [SF.binding("rb", ns: "kube-system", roleKind: "Role", role: "pod-exec", subjects: [SF.subject("User", "ops")])],
            clusterRoleBindings: [SF.clusterBinding("crb", role: "pod-maker", subjects: [SF.subject("User", "dev")])]))
        let names = Set(r.findings.filter { $0.ruleID == "WH-A05" }.map(\.object.name))
        #expect(names == ["ops", "dev"])
        #expect(r.findings.first { $0.ruleID == "WH-A05" }?.severity == .high)
    }

    @Test func a05NegativeOtherNamespaceAndReadOnly() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("pod-exec", ns: "dev", rules: [SF.rule(resources: ["pods/exec"], verbs: ["create"])]),
                    SF.role("pod-get", ns: "kube-system", rules: [SF.rule(resources: ["pods"], verbs: ["get", "list"])])],
            roleBindings: [SF.binding("rb1", ns: "dev", roleKind: "Role", role: "pod-exec", subjects: [SF.subject("User", "ops")]),
                           SF.binding("rb2", ns: "kube-system", roleKind: "Role", role: "pod-get", subjects: [SF.subject("User", "ops")])]))
        #expect(!SF.has(r, "WH-A05"))
    }

    // MARK: WH-A06

    @Test func a06AnonymousAndUnauthenticatedBindings() {
        let r = SF.run(SF.snapshot(
            roleBindings: [SF.binding("rb", ns: "dev", role: "edit", subjects: [SF.subject("User", "system:anonymous")])],
            clusterRoleBindings: [SF.clusterBinding("open", role: "view", subjects: [SF.subject("Group", "system:unauthenticated")])]))
        let a06 = r.findings.filter { $0.ruleID == "WH-A06" }
        #expect(a06.count == 2)
        #expect(a06.allSatisfy { $0.severity == .critical })
    }

    @Test func a06NegativeDiscoveryRolesAndAuthenticated() {
        let r = SF.run(SF.snapshot(clusterRoleBindings: [
            SF.clusterBinding("system:discovery", role: "system:discovery", subjects: [SF.subject("Group", "system:authenticated"), SF.subject("Group", "system:unauthenticated")]),
            SF.clusterBinding("system:public-info-viewer", role: "system:public-info-viewer", subjects: [SF.subject("Group", "system:unauthenticated")]),
            SF.clusterBinding("auth", role: "view", subjects: [SF.subject("Group", "system:authenticated")]),
        ]))
        #expect(!SF.has(r, "WH-A06"))
    }

    // MARK: WH-A07

    @Test func a07DefaultServiceAccountWithExtraBindings() {
        let r = SF.run(SF.snapshot(
            roleBindings: [SF.binding("rb", ns: "dev", role: "edit", subjects: [SF.subject("ServiceAccount", "default", ns: "dev")]),
                           SF.binding("rb2", ns: "dev", role: "view", subjects: [SF.subject("ServiceAccount", "default")])],
            clusterRoleBindings: [SF.clusterBinding("crb", role: "view", subjects: [SF.subject("ServiceAccount", "default", ns: "ops")])]))
        let f = r.findings.filter { $0.ruleID == "WH-A07" }
        #expect(f.count == 2)
        #expect(f.first { $0.namespace == "dev" }?.evidence.count == 2)
        #expect(f.allSatisfy { $0.severity == .medium })
    }

    @Test func a07NegativeOtherServiceAccountsAndDefaultBootstrapBindings() {
        let r = SF.run(SF.snapshot(
            roleBindings: [SF.binding("rb", ns: "dev", role: "edit", subjects: [SF.subject("ServiceAccount", "builder", ns: "dev")])],
            clusterRoleBindings: [SF.clusterBinding("system:x", role: "system:y", subjects: [SF.subject("ServiceAccount", "default", ns: "kube-system")], labels: bootstrap)]))
        #expect(!SF.has(r, "WH-A07"))
    }

    // MARK: WH-A08

    private func powerfulSnapshot(automountOnPod: Bool? = nil, automountOnAccount: Bool? = nil, role: JSONValue = SF.rule(resources: ["secrets"], verbs: ["get", "list"]),
                                  sa: String = "bot") -> SurveySnapshot {
        var extra: [String: JSONValue] = ["serviceAccountName": .string(sa)]
        if let automountOnPod { extra["automountServiceAccountToken"] = .bool(automountOnPod) }
        return SF.snapshot(
            clusterRoles: [SF.clusterRole("power", rules: [role])],
            roleBindings: [SF.binding("rb", ns: "shop", role: "power", subjects: [SF.subject("ServiceAccount", "bot", ns: "shop")])],
            serviceAccounts: [SF.serviceAccount("bot", ns: "shop", automount: automountOnAccount)],
            workloads: [SF.deployment("web", spec: SF.podSpec(containers: [SF.container()], extra: extra))])
    }

    @Test func a08PowerfulServiceAccountWithMountedToken() {
        let r = SF.run(powerfulSnapshot())
        let f = r.findings.first { $0.ruleID == "WH-A08" }
        #expect(f?.object.name == "web")
        #expect(f?.severity == .medium)
        #expect(f?.workload?.kind == "Deployment")
    }

    @Test func a08NegativeTokenNotMountedOrAccountNotPowerful() {
        #expect(!SF.has(SF.run(powerfulSnapshot(automountOnPod: false)), "WH-A08"))
        #expect(!SF.has(SF.run(powerfulSnapshot(automountOnAccount: false)), "WH-A08"))
        #expect(!SF.has(SF.run(powerfulSnapshot(role: SF.rule(resources: ["configmaps"], verbs: ["get"]))), "WH-A08"))
        // the Pod setting wins over the ServiceAccount's
        #expect(SF.has(SF.run(powerfulSnapshot(automountOnPod: true, automountOnAccount: false)), "WH-A08"))
        // a workload on another ServiceAccount
        #expect(!SF.has(SF.run(powerfulSnapshot(sa: "other")), "WH-A08"))
    }

    // MARK: WH-A09

    @Test func a09WebhookConfigurationWrites() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("hooks", rules: [SF.rule(groups: ["admissionregistration.k8s.io"], resources: ["mutatingwebhookconfigurations"], verbs: ["patch"])])],
            clusterRoleBindings: [SF.clusterBinding("h", role: "hooks", subjects: [SF.subject("User", "u")])]))
        #expect(SF.has(r, "WH-A09", object: "u"))
        #expect(r.findings.first { $0.ruleID == "WH-A09" }?.severity == .high)
    }

    @Test func a09NegativeReadOnlyAndNamespaceBinding() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("hooks-read", rules: [SF.rule(groups: ["admissionregistration.k8s.io"], resources: ["validatingwebhookconfigurations"], verbs: ["get", "list"])]),
                           SF.clusterRole("hooks", rules: [SF.rule(groups: ["admissionregistration.k8s.io"], resources: ["validatingwebhookconfigurations"], verbs: ["create"])])],
            roleBindings: [SF.binding("rb", ns: "dev", role: "hooks", subjects: [SF.subject("User", "v")])],
            clusterRoleBindings: [SF.clusterBinding("h", role: "hooks-read", subjects: [SF.subject("User", "u")])]))
        #expect(!SF.has(r, "WH-A09"))
    }

    // MARK: WH-A10

    @Test func a10NodesProxyAndServiceAccountTokens() {
        let r = SF.run(SF.snapshot(
            roles: [SF.role("tokener", ns: "dev", rules: [SF.rule(resources: ["serviceaccounts/token"], verbs: ["create"])])],
            clusterRoles: [SF.clusterRole("np", rules: [SF.rule(resources: ["nodes/proxy"], verbs: ["get"])])],
            roleBindings: [SF.binding("rb", ns: "dev", roleKind: "Role", role: "tokener", subjects: [SF.subject("User", "t")])],
            clusterRoleBindings: [SF.clusterBinding("np", role: "np", subjects: [SF.subject("User", "n")])]))
        #expect(SF.has(r, "WH-A10", object: "t"))
        #expect(SF.has(r, "WH-A10", object: "n"))
    }

    @Test func a10NegativeNodesMetricsAndTokenRead() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("m", rules: [SF.rule(resources: ["nodes/metrics", "nodes/stats"], verbs: ["get"]),
                                                      SF.rule(resources: ["serviceaccounts"], verbs: ["get", "list"])])],
            clusterRoleBindings: [SF.clusterBinding("m", role: "m", subjects: [SF.subject("User", "mon")])]))
        #expect(!SF.has(r, "WH-A10"))
    }

    // MARK: exclusions and effective permissions

    @Test func systemSubjectsAndDefaultBindingsAreExcluded() {
        let r = SF.run(SF.snapshot(
            clusterRoles: [SF.clusterRole("system:controller:x", rules: [SF.rule(resources: ["secrets"], verbs: ["get", "list"])], labels: bootstrap)],
            clusterRoleBindings: [SF.clusterBinding("system:controller:x", role: "system:controller:x", subjects: [SF.subject("ServiceAccount", "x", ns: "kube-system")], labels: bootstrap),
                                  SF.clusterBinding("system:sched", role: "system:controller:x", subjects: [SF.subject("User", "system:kube-scheduler")])]))
        #expect(r.accessFindings.isEmpty)
    }

    @Test func serviceAccountUserNamesAreFoldedIntoServiceAccounts() {
        let s = SubjectKey(Subject(kind: "User", name: "system:serviceaccount:ops:bot", namespace: nil, apiGroup: nil), bindingNamespace: nil)
        #expect(s == .serviceAccount("bot", namespace: "ops"))
    }

    @Test func aggregatedClusterRolesAreResolvedByLabelSelection() {
        let s = SF.snapshot(
            clusterRoles: [
                SF.clusterRole("agg", rules: [], aggregate: [["rbac.example/aggregate": "true"]]),
                SF.clusterRole("part", rules: [SF.rule(resources: ["secrets"], verbs: ["list"])], labels: ["rbac.example/aggregate": "true"]),
                SF.clusterRole("other", rules: [SF.rule(resources: ["pods"], verbs: ["delete"])]),
            ],
            clusterRoleBindings: [SF.clusterBinding("b", role: "agg", subjects: [SF.subject("User", "u")])])
        let index = PermissionIndex(snapshot: s)
        #expect(index.can(.user("u"), verb: "list", resource: "secrets"))
        #expect(!index.can(.user("u"), verb: "delete", resource: "pods", namespace: "x"))
        // a server-populated aggregate uses its own rules
        let populated = SF.snapshot(clusterRoles: [SF.clusterRole("agg", rules: [SF.rule(resources: ["pods"], verbs: ["get"])], aggregate: [["a": "b"]])],
                                    clusterRoleBindings: [SF.clusterBinding("b", role: "agg", subjects: [SF.subject("User", "u")])])
        #expect(PermissionIndex(snapshot: populated).can(.user("u"), verb: "get", resource: "pods", namespace: "x"))
    }

    @Test func canEvaluatesScopesGroupsAndSubresources() {
        let s = SF.snapshot(
            roles: [SF.role("r", ns: "dev", rules: [SF.rule(resources: ["pods/exec"], verbs: ["create"])])],
            clusterRoles: [SF.clusterRole("all-sa", rules: [SF.rule(resources: ["configmaps"], verbs: ["get"])]),
                           SF.clusterRole("star-sub", rules: [SF.rule(resources: ["*/log"], verbs: ["get"])]),
                           SF.clusterRole("named", rules: [SF.rule(resources: ["secrets"], verbs: ["get"], names: ["only"])])],
            roleBindings: [SF.binding("rb", ns: "dev", roleKind: "Role", role: "r", subjects: [SF.subject("User", "u")])],
            clusterRoleBindings: [SF.clusterBinding("sa", role: "all-sa", subjects: [SF.subject("Group", "system:serviceaccounts")]),
                                  SF.clusterBinding("sl", role: "star-sub", subjects: [SF.subject("User", "u")]),
                                  SF.clusterBinding("nm", role: "named", subjects: [SF.subject("User", "u")])])
        let i = PermissionIndex(snapshot: s)
        #expect(i.can(.user("u"), verb: "create", resource: "pods/exec", namespace: "dev"))
        #expect(!i.can(.user("u"), verb: "create", resource: "pods/exec", namespace: "prod"))
        #expect(!i.can(.user("u"), verb: "create", resource: "pods/exec"))                    // cluster scope only
        #expect(i.can(.serviceAccount("any", namespace: "x"), verb: "get", resource: "configmaps", namespace: "x"))   // implied group
        #expect(!i.can(.user("u"), verb: "get", resource: "configmaps", namespace: "x"))
        #expect(i.can(.user("u"), verb: "get", resource: "pods/log", namespace: "x"))
        #expect(i.can(.user("u"), verb: "get", resource: "secrets", name: "only"))
        #expect(!i.can(.user("u"), verb: "get", resource: "secrets", name: "other"))
        #expect(!i.can(.user("u"), verb: "list", resource: "secrets"))
        #expect(i.whoCan(verb: "create", resource: "pods/exec", namespace: "dev") == [.user("u")])
    }

    @Test func resourceMatchingFollowsTheAuthorizer() {
        #expect(PolicyRule.resourceMatches("*", requested: "pods/exec"))
        #expect(PolicyRule.resourceMatches("pods", requested: "pods"))
        #expect(!PolicyRule.resourceMatches("pods", requested: "pods/exec"))
        #expect(!PolicyRule.resourceMatches("pods/*", requested: "pods/exec"))      // not upstream syntax
        #expect(PolicyRule.resourceMatches("*/exec", requested: "pods/exec"))
        #expect(!PolicyRule.resourceMatches("*/exec", requested: "pods"))
    }

    @Test func findingsAreStableAcrossRuns() {
        let s = SF.snapshot(clusterRoleBindings: [SF.clusterBinding("a", role: "cluster-admin", subjects: [SF.subject("User", "alice")])])
        #expect(SF.run(s).findings.map(\.id) == SF.run(s).findings.map(\.id))
        #expect(SF.run(s).findings[0].id == "WH-A02|test-cluster||User/alice|CRB:a")
    }

    @Test func forbiddenKindsDegradeWithAnExplanation() async {
        var s = SF.snapshot()
        s.limitations = [SurveyLimitation(kind: "ClusterRoles", message: "Not allowed to list ClusterRoles")]
        #expect(SF.run(s).limitations.map(\.kind) == ["ClusterRoles"])
    }
}
