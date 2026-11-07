# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX, REPO and kc() are set; KUBECONFIG is unset).
#
#   scripts/testcluster-fixtures.sh --section m8a-survey            seed the Survey fixtures (default)
#   scripts/testcluster-fixtures.sh --section m8a-survey clean      delete every one of them again
#
# Survey rule fixtures (ARCHITECTURE-MAC section 13.3) on the TEST cluster only. Owned by M8a.
#   * namespaces wh-m8a and wh-m8a-nopsa; every cluster-scoped object is named wh-m8a-* and labelled wh-m8a=true;
#   * the RBAC grants go to users and groups that do not exist (and to ServiceAccounts that never get a token), over roles whose
#     powerful rules are real, so the rules fire but nobody can use them;
#   * the unauthenticated binding uses a role that names a resource that does not exist, so it grants nothing;
#   * workloads are Deployments with 0 replicas (judged through their pod template, nothing runs), plus one running Deployment and one
#     running bare Pod with the pause image.
#
# EXPECTED FINDINGS for objects named wh-m8a* (the live test in Packages/WheelhouseKit/Tests/.../Security/SurveyLiveTests.swift asserts
# exactly this set; findings about other objects of the cluster are ignored):
#   WH-A01  Role wh-m8a/wh-m8a-wild-role, ClusterRole wh-m8a-wild-verbs
#   WH-A02  User wh-m8a-admin-user (CRB wh-m8a-admin), Group system:bootstrappers:wh-m8a (CRB wh-m8a-bootstrappers, a user-created binding to a system subject)
#   WH-A03  User wh-m8a-secrets-user (CRB wh-m8a-secrets)
#   WH-A04  User wh-m8a-binder-user (CRB wh-m8a-binder)
#   WH-A05  User wh-m8a-kubesystem-user (RoleBinding in kube-system)
#   WH-A06  Group system:unauthenticated (CRB wh-m8a-anon)
#   WH-A07  ServiceAccount wh-m8a/default
#   WH-A08  Deployment wh-m8a/wh-m8a-powerful (not wh-m8a-powerful-nomount)
#   WH-A09  User wh-m8a-hooks-user
#   WH-A10  User wh-m8a-proxy-user (nodes/proxy, cluster-wide), User wh-m8a-token-user (serviceaccounts/token in wh-m8a)
#   WH-W01  wh-m8a-w01    WH-W02  wh-m8a-w02 (critical), wh-m8a-w02b (high)    WH-W03  wh-m8a-w03    WH-W04  wh-m8a-w04
#   WH-W05  wh-m8a-w05, wh-m8a-w01 (a privileged container cannot set allowPrivilegeEscalation: false)    WH-W06  wh-m8a-w06    WH-W07  wh-m8a-w07    WH-W08  wh-m8a-w08    WH-W09  wh-m8a-w09, wh-m8a-running, wh-m8a-bare
#   WH-W10  Namespace wh-m8a-nopsa                                        WH-W11  wh-m8a-w11
#   no finding at all: Deployment wh-m8a-hardened, ServiceAccount wh-m8a/viewer-sa and the negative RBAC fixtures
#   (wh-m8a-explicit, the namespaced secrets binding, the pod-exec Role in wh-m8a, the other-sa binding).

M8A_NS=wh-m8a
M8A_NS_NOPSA=wh-m8a-nopsa
M8A_DIGEST="sha256:0000000000000000000000000000000000000000000000000000000000000001"

m8a_clean() {
  echo "Deleting the m8a-survey fixtures from context $CTX ..."
  kc delete clusterrole,clusterrolebinding -l wh-m8a=true --ignore-not-found
  kc -n kube-system delete role,rolebinding -l wh-m8a=true --ignore-not-found
  kc delete namespace "$M8A_NS" "$M8A_NS_NOPSA" --ignore-not-found --wait=false
}

# A Deployment with 0 replicas whose container is hardened except for the one trait named by $2 (an extra container/pod field set).
#   m8a_deploy <name> <namespace> <replicas> <image> <container-security-yaml> <pod-extra-yaml> <limits yes|no>
m8a_deploy() {
  local name="$1" ns="$2" replicas="$3" image="$4" security="$5" extra="$6" limits="$7"
  local limitsYaml="" automount="automountServiceAccountToken: false"
  case "$extra" in *automountServiceAccountToken*) automount="" ;; esac
  [ "$limits" = yes ] && limitsYaml='resources: { limits: { cpu: 100m, memory: 64Mi } }'
  cat <<YAML | kc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: $name, namespace: $ns, labels: { wh-m8a: "true", app: $name } }
spec:
  replicas: $replicas
  selector: { matchLabels: { app: $name } }
  template:
    metadata: { labels: { app: $name, wh-m8a: "true" } }
    spec:
      $automount
$(printf '%s\n' "$extra" | sed 's/^/      /')
      containers:
        - name: app
          image: $image
          $limitsYaml
          securityContext:
$(printf '%s\n' "$security" | sed 's/^/            /')
YAML
}

M8A_HARDENED='allowPrivilegeEscalation: false
runAsNonRoot: true
runAsUser: 65532
readOnlyRootFilesystem: true
capabilities: { drop: ["ALL"] }
seccompProfile: { type: RuntimeDefault }'

m8a_seed() {
  echo "Seeding the m8a-survey fixtures on context $CTX ..."
  cat <<YAML | kc apply -f -
apiVersion: v1
kind: Namespace
metadata:
  name: $M8A_NS
  labels: { wh-m8a: "true", pod-security.kubernetes.io/warn: restricted }
---
apiVersion: v1
kind: Namespace
metadata: { name: $M8A_NS_NOPSA, labels: { wh-m8a: "true" } }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: viewer-sa, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: power-sa, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
---
# ---- roles ---------------------------------------------------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: wh-m8a-wild-role, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["*"], verbs: ["get"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-wild-verbs, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["configmaps"], verbs: ["*"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-explicit, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["configmaps"], verbs: ["get", "list"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-secrets, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["secrets"], verbs: ["get", "list"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-binder, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: ["rbac.authorization.k8s.io"], resources: ["clusterroles"], verbs: ["bind"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-noop, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: ["wh-m8a.invalid"], resources: ["nothings"], verbs: ["get"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-hooks, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: ["admissionregistration.k8s.io"], resources: ["mutatingwebhookconfigurations"], verbs: ["create", "patch"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-node-proxy, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["nodes/proxy"], verbs: ["get"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata: { name: wh-m8a-sa-token, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["serviceaccounts/token"], verbs: ["create"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: wh-m8a-pod-exec, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["pods/exec"], verbs: ["create"] } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: { name: wh-m8a-pod-exec, namespace: kube-system, labels: { wh-m8a: "true" } }
rules: [ { apiGroups: [""], resources: ["pods/exec"], verbs: ["create"] } ]
---
# ---- bindings -------------------------------------------------------------------------------------------------------------------
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-admin, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-admin-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-bootstrappers, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: cluster-admin }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: Group, name: "system:bootstrappers:wh-m8a" } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-view, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-explicit }
subjects: [ { kind: ServiceAccount, name: viewer-sa, namespace: $M8A_NS } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-secrets, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-secrets }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-secrets-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-secrets-ns, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-secrets }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-secrets-ns-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-binder, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-binder }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-binder-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-kubesystem, namespace: kube-system, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: wh-m8a-pod-exec }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-kubesystem-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-pod-exec, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: Role, name: wh-m8a-pod-exec }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-dev-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-anon, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-noop }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: Group, name: "system:unauthenticated" } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-default-sa, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-noop }
subjects: [ { kind: ServiceAccount, name: default, namespace: $M8A_NS } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-other-sa, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-noop }
subjects: [ { kind: ServiceAccount, name: viewer-sa, namespace: $M8A_NS } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-power-sa, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-secrets }
subjects: [ { kind: ServiceAccount, name: power-sa, namespace: $M8A_NS } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-hooks, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-hooks }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-hooks-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata: { name: wh-m8a-node-proxy, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-node-proxy }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-proxy-user } ]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: { name: wh-m8a-sa-token, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
roleRef: { apiGroup: rbac.authorization.k8s.io, kind: ClusterRole, name: wh-m8a-sa-token }
subjects: [ { apiGroup: rbac.authorization.k8s.io, kind: User, name: wh-m8a-token-user } ]
YAML

  # ---- workloads (0 replicas: judged through the pod template, nothing runs)
  local img="registry.k8s.io/pause@$M8A_DIGEST"
  local hardened="$M8A_HARDENED"
  m8a_deploy wh-m8a-hardened "$M8A_NS" 0 "$img" "$hardened" "" yes
  m8a_deploy wh-m8a-w01 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | grep -v allowPrivilegeEscalation; echo 'privileged: true')" "" yes
  m8a_deploy wh-m8a-w02 "$M8A_NS" 0 "$img" "$hardened" 'volumes: [ { name: sock, hostPath: { path: /var/run/docker.sock } } ]' yes
  m8a_deploy wh-m8a-w02b "$M8A_NS" 0 "$img" "$hardened" 'volumes: [ { name: data, hostPath: { path: /data/logs } } ]' yes
  m8a_deploy wh-m8a-w03 "$M8A_NS" 0 "$img" "$hardened" 'hostNetwork: true' yes
  m8a_deploy wh-m8a-w04 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | sed 's/capabilities: .*/capabilities: { drop: ["ALL"], add: ["SYS_ADMIN"] }/')" "" yes
  m8a_deploy wh-m8a-w05 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | grep -v allowPrivilegeEscalation)" "" yes
  m8a_deploy wh-m8a-w06 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | grep -v -e runAsNonRoot -e runAsUser)" "" yes
  m8a_deploy wh-m8a-w07 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | grep -v readOnlyRootFilesystem)" "" yes
  m8a_deploy wh-m8a-w08 "$M8A_NS" 0 "$img" "$hardened" "" no
  m8a_deploy wh-m8a-w09 "$M8A_NS" 0 "registry.k8s.io/pause:3.10" "$hardened" "" yes
  m8a_deploy wh-m8a-w11 "$M8A_NS" 0 "$img" "$(printf '%s' "$hardened" | grep -v seccompProfile)" "" yes
  m8a_deploy wh-m8a-nopsa-app "$M8A_NS_NOPSA" 0 "$img" "$hardened" "" yes

  # A08: a workload whose ServiceAccount can read Secrets (through wh-m8a-power-sa), with and without the token mounted.
  m8a_deploy wh-m8a-powerful "$M8A_NS" 0 "$img" "$hardened" 'serviceAccountName: power-sa
automountServiceAccountToken: true' yes
  m8a_deploy wh-m8a-powerful-nomount "$M8A_NS" 0 "$img" "$hardened" 'serviceAccountName: power-sa
automountServiceAccountToken: false' yes

  # Running workloads (the pause image, 1 replica): the Deployment is judged once through its template, its Pod not at all.
  m8a_deploy wh-m8a-running "$M8A_NS" 1 "registry.k8s.io/pause:3.10" "$hardened" "" yes
  cat <<YAML | kc apply -f -
apiVersion: v1
kind: Pod
metadata: { name: wh-m8a-bare, namespace: $M8A_NS, labels: { wh-m8a: "true" } }
spec:
  automountServiceAccountToken: false
  containers:
    - name: app
      image: registry.k8s.io/pause:3.10
      resources: { limits: { cpu: 100m, memory: 64Mi } }
      securityContext:
        allowPrivilegeEscalation: false
        runAsNonRoot: true
        runAsUser: 65532
        readOnlyRootFilesystem: true
        capabilities: { drop: ["ALL"] }
        seccompProfile: { type: RuntimeDefault }
YAML
  echo "m8a-survey fixtures applied. Clean up with: $0 --section m8a-survey clean"
}

case "${3:-seed}" in
  seed) m8a_seed ;;
  clean) m8a_clean ;;
  *) echo "usage: $0 --section m8a-survey [seed|clean]" >&2; exit 2 ;;
esac
