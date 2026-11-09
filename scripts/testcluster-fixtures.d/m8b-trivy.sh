# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
# Seeds the Survey vulnerability fixtures of ARCHITECTURE-MAC section 6.1 and 13.3 on the TEST cluster only:
#   * the Trivy Operator VulnerabilityReport CRD, DEFINITION ONLY (no operator, no image): group aquasecurity.github.io, version
#     v1alpha1, labelled wheelhouse.test/fixture=m8b-trivy. The seed REFUSES if that CRD already exists without the label (a real
#     operator's CRD must never be replaced by this permissive one);
#   * namespace wh-m8b with 0-replica workloads (nothing runs, nothing pulls) and sample VulnerabilityReport objects carrying the
#     labels the operator sets (trivy-operator.resource.kind/name/namespace and trivy-operator.container.name).
#
#   scripts/testcluster-fixtures.sh --section m8b-trivy          seed (idempotent)
#   scripts/testcluster-fixtures.sh --section m8b-trivy clean    delete namespace wh-m8b and the CRD this section added
#
# EXPECTED ROLL-UP (the live test in Packages/WheelhouseKit/Tests/.../Security/TrivyOperatorLiveTests.swift asserts exactly this; reports in
# other namespaces are ignored). Newest report per workload and container wins:
#   Deployment web (reports sit on its ReplicaSet web-7d9f8c6b5d):  app 2C 3H 1M 0L 0U, sidecar 0C 1H 1M 0L 0U
#     (an OLDER report of ReplicaSet web-5c6b7d8e9f, container app, 9 of each, must be ignored)
#   StatefulSet db:  pg 1C 0H 0M 2L 1U
#   Pod tool:        c  0C 0H 3M 0L 0U
#   namespace total: 3 critical, 4 high, 5 medium, 2 low, 1 unknown = 15; 3 workload entries (web, db, tool; web has 2 containers).
# Owned by M8b.

M8B_NS=wh-m8b
M8B_LABEL="wheelhouse.test/fixture=m8b-trivy"
M8B_CRD=vulnerabilityreports.aquasecurity.github.io

m8b_crd() {
  local existing
  existing="$(kc get crd "$M8B_CRD" -o jsonpath='{.metadata.labels.wheelhouse\.test/fixture}' --ignore-not-found)"
  if kc get crd "$M8B_CRD" >/dev/null 2>&1 && [ "$existing" != "m8b-trivy" ]; then
    echo "abort: CRD $M8B_CRD already exists and was not created by this fixture. Not touching it." >&2
    return 1
  fi
  cat <<YAML | kc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $M8B_CRD
  labels: { wheelhouse.test/fixture: m8b-trivy }
spec:
  group: aquasecurity.github.io
  scope: Namespaced
  names: { kind: VulnerabilityReport, plural: vulnerabilityreports, singular: vulnerabilityreport, listKind: VulnerabilityReportList, shortNames: [vuln, vulns] }
  versions:
    - name: v1alpha1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
YAML
  kc wait --for=condition=Established "crd/$M8B_CRD" --timeout=60s >/dev/null
}

# m8b_report <name> <owner-kind> <owner-name> <container> <image-repo> <tag> <C> <H> <M> <L> <U> <timestamp> [vulnerabilities-json]
m8b_report() {
  local name=$1 kind=$2 owner=$3 container=$4 repo=$5 tag=$6 c=$7 h=$8 m=$9 l=${10} u=${11} stamp=${12} vulns=${13:-[]}
  cat <<YAML | kc apply -f -
apiVersion: aquasecurity.github.io/v1alpha1
kind: VulnerabilityReport
metadata:
  name: $name
  namespace: $M8B_NS
  labels:
    wheelhouse.test/fixture: m8b-trivy
    trivy-operator.resource.kind: $kind
    trivy-operator.resource.name: $owner
    trivy-operator.resource.namespace: $M8B_NS
    trivy-operator.container.name: $container
report:
  updateTimestamp: "$stamp"
  scanner: { name: Trivy, vendor: Aqua Security, version: 0.99.0 }
  registry: { server: registry.example.com }
  artifact: { repository: $repo, tag: "$tag" }
  summary: { criticalCount: $c, highCount: $h, mediumCount: $m, lowCount: $l, unknownCount: $u }
  vulnerabilities: $vulns
YAML
}

m8b_seed() {
  echo "Seeding the Trivy Operator fixtures (CRD definition and namespace $M8B_NS) on context $CTX ..."
  m8b_crd || return 1
  kc create namespace "$M8B_NS" --dry-run=client -o yaml | kc apply -f -
  # Workloads at 0 replicas: nothing runs and nothing is pulled.
  cat <<YAML | kc apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, namespace: $M8B_NS, labels: { wheelhouse.test/fixture: m8b-trivy } }
spec:
  replicas: 0
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      containers:
        - { name: app, image: "registry.example.com/team/web:1.0" }
        - { name: sidecar, image: "registry.example.com/team/proxy:2.1" }
---
apiVersion: apps/v1
kind: StatefulSet
metadata: { name: db, namespace: $M8B_NS, labels: { wheelhouse.test/fixture: m8b-trivy } }
spec:
  replicas: 0
  serviceName: db
  selector: { matchLabels: { app: db } }
  template:
    metadata: { labels: { app: db } }
    spec:
      containers:
        - { name: pg, image: "registry.example.com/team/postgres:16" }
YAML
  local vulns='[{"vulnerabilityID":"CVE-2026-0001","resource":"libexpat1","installedVersion":"2.5.0-1","fixedVersion":"2.5.0-1+deb12u1","severity":"CRITICAL","title":"expat: integer overflow","primaryLink":"https://avd.aquasec.com/nvd/cve-2026-0001"},{"vulnerabilityID":"CVE-2026-0002","resource":"openssl","installedVersion":"3.0.11-1","fixedVersion":"","severity":"HIGH","title":"openssl: timing leak","primaryLink":""}]'
  m8b_report replicaset-web-7d9f8c6b5d-app ReplicaSet web-7d9f8c6b5d app registry.example.com/team/web 1.0 2 3 1 0 0 2026-11-08T10:00:00Z "$vulns"
  m8b_report replicaset-web-7d9f8c6b5d-sidecar ReplicaSet web-7d9f8c6b5d sidecar registry.example.com/team/proxy 2.1 0 1 1 0 0 2026-11-08T10:00:00Z
  m8b_report replicaset-web-5c6b7d8e9f-app ReplicaSet web-5c6b7d8e9f app registry.example.com/team/web 0.9 9 9 9 9 9 2026-11-01T10:00:00Z
  m8b_report statefulset-db-pg StatefulSet db pg registry.example.com/team/postgres 16 1 0 0 2 1 2026-11-08T10:00:00Z
  m8b_report pod-tool-c Pod tool c registry.example.com/team/tool 3 0 0 3 0 0 2026-11-08T10:00:00Z
  echo "Done. Namespace $M8B_NS: 5 VulnerabilityReports (see the header for the expected roll-up)."
}

m8b_clean() {
  # Refuse to remove the CRD while reports exist outside our namespace (they would be deleted with it).
  local others
  others="$(kc get vulnerabilityreports.aquasecurity.github.io -A --no-headers 2>/dev/null | awk -v ns="$M8B_NS" '$1 != ns' | wc -l | tr -d ' ')"
  kc delete namespace "$M8B_NS" --ignore-not-found --wait=true
  if [ "${others:-0}" != "0" ]; then
    echo "Kept the CRD $M8B_CRD: $others VulnerabilityReport(s) exist outside $M8B_NS." >&2
    return 0
  fi
  kc delete crd -l "$M8B_LABEL" --ignore-not-found --wait=true
  echo "Removed namespace $M8B_NS and the CRD labelled $M8B_LABEL."
}

case "${3:-}" in
  clean) m8b_clean ;;
  "")    m8b_seed ;;
  *)     echo "usage: --section m8b-trivy [clean]" >&2; return 2 ;;
esac
