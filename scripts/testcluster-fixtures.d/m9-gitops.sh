# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
# Seeds the Tides (GitOps) fixtures of ARCHITECTURE-MAC section 13.3 on the TEST cluster only:
#   * Flux and Argo CD CRDs ONLY (no controllers, so every status is static fixture data), labelled wheelhouse.test/fixture=m9-gitops;
#   * namespace wh-m9 with sample Flux Kustomizations, HelmReleases, a GitRepository and a HelmRepository, sample Argo CD
#     Applications (synced, out of sync with a prune candidate, running a sync) and an AppProject;
#   * objects carrying the ownership labels and annotations the detector reads;
#   * an `echo` Service and Pod that return the request headers they receive, to check what the API server's service proxy forwards
#     (Cookie versus Authorization), because there is no argocd-server.
#
#   scripts/testcluster-fixtures.sh --section m9-gitops          seed (idempotent)
#   scripts/testcluster-fixtures.sh --section m9-gitops clean    delete namespace wh-m9 and the CRDs this section added
# Owned by M9.

M9_NS=wh-m9
M9_LABEL="wheelhouse.test/fixture=m9-gitops"

m9_crd() {   # group kind plural singular version scope status-subresource(yes|no) [shortname]
  local group=$1 kind=$2 plural=$3 singular=$4 version=$5 scope=$6 sub=$7
  local subres=""
  [ "$sub" = yes ] && subres="subresources: { status: {} }"
  cat <<YAML | kc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $plural.$group
  labels: { wheelhouse.test/fixture: m9-gitops }
spec:
  group: $group
  scope: $scope
  names: { kind: $kind, plural: $plural, singular: $singular, listKind: ${kind}List }
  versions:
    - name: $version
      served: true
      storage: true
      $subres
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
YAML
}

m9_status() {   # kind name json-status  (Flux CRDs have a status subresource)
  kc -n "$M9_NS" patch "$1" "$2" --subresource=status --type=merge -p "{\"status\": $3}" >/dev/null
}

m9_seed() {
  local now past
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  past="$(date -u -v-2H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '2 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  echo "Seeding Tides fixtures (CRDs and namespace $M9_NS) on context $CTX ..."

  # ---- Flux CRDs (status subresource, as upstream) and Argo CD CRDs (no status subresource for Application, as upstream)
  m9_crd kustomize.toolkit.fluxcd.io Kustomization kustomizations kustomization v1 Namespaced yes
  m9_crd helm.toolkit.fluxcd.io HelmRelease helmreleases helmrelease v2 Namespaced yes
  m9_crd source.toolkit.fluxcd.io GitRepository gitrepositories gitrepository v1 Namespaced yes
  m9_crd source.toolkit.fluxcd.io HelmRepository helmrepositories helmrepository v1 Namespaced yes
  m9_crd source.toolkit.fluxcd.io OCIRepository ocirepositories ocirepository v1 Namespaced yes
  m9_crd argoproj.io Application applications application v1alpha1 Namespaced no
  m9_crd argoproj.io ApplicationSet applicationsets applicationset v1alpha1 Namespaced no
  m9_crd argoproj.io AppProject appprojects appproject v1alpha1 Namespaced no
  for crd in kustomizations.kustomize.toolkit.fluxcd.io helmreleases.helm.toolkit.fluxcd.io gitrepositories.source.toolkit.fluxcd.io \
             helmrepositories.source.toolkit.fluxcd.io ocirepositories.source.toolkit.fluxcd.io applications.argoproj.io \
             applicationsets.argoproj.io appprojects.argoproj.io; do
    kc wait --for=condition=Established "crd/$crd" --timeout=60s >/dev/null
  done

  kc create namespace "$M9_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null

  # ---- Flux sources
  cat <<YAML | kc apply -f -
apiVersion: source.toolkit.fluxcd.io/v1
kind: GitRepository
metadata: { name: fleet, namespace: $M9_NS }
spec: { interval: 1m, url: "https://github.com/acme/fleet", ref: { branch: main } }
---
apiVersion: source.toolkit.fluxcd.io/v1
kind: HelmRepository
metadata: { name: podinfo, namespace: $M9_NS }
spec: { interval: 10m, url: "https://stefanprodan.github.io/podinfo" }
YAML
  m9_status gitrepository fleet "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"Succeeded\",\"message\":\"stored artifact for revision 'main@sha1:3f2a9c1d0e7b'\",\"lastTransitionTime\":\"$now\"}],\"artifact\":{\"revision\":\"main@sha1:3f2a9c1d0e7b\",\"lastUpdateTime\":\"$now\",\"path\":\"gitrepository/$M9_NS/fleet/3f2a9c1d.tar.gz\",\"url\":\"http://source-controller/x.tar.gz\",\"digest\":\"sha256:0\"}}"
  m9_status helmrepository podinfo "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"Succeeded\",\"message\":\"stored artifact: revision 'sha256:aabbccdd'\",\"lastTransitionTime\":\"$now\"}],\"artifact\":{\"revision\":\"sha256:aabbccddeeff\",\"lastUpdateTime\":\"$now\",\"path\":\"p\",\"url\":\"http://source-controller/i.yaml\",\"digest\":\"sha256:0\"}}"

  # ---- Flux Kustomizations: one healthy, one failing (stalled), one suspended
  cat <<YAML | kc apply -f -
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: apps, namespace: $M9_NS }
spec: { interval: 10m, path: ./apps/prod, prune: true, sourceRef: { kind: GitRepository, name: fleet }, dependsOn: [ { name: infra } ] }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: infra, namespace: $M9_NS }
spec: { interval: 10m, path: ./infra, prune: true, sourceRef: { kind: GitRepository, name: fleet } }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: broken, namespace: $M9_NS }
spec: { interval: 5m, path: ./broken, sourceRef: { kind: GitRepository, name: fleet } }
---
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata: { name: paused, namespace: $M9_NS }
spec: { interval: 5m, path: ./paused, suspend: true, sourceRef: { kind: GitRepository, name: fleet } }
YAML
  m9_status kustomization apps "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"ReconciliationSucceeded\",\"message\":\"Applied revision: main@sha1:3f2a9c1d0e7b\",\"lastTransitionTime\":\"$now\"}],\"lastAppliedRevision\":\"main@sha1:3f2a9c1d0e7b\",\"lastAttemptedRevision\":\"main@sha1:3f2a9c1d0e7b\",\"inventory\":{\"entries\":[{\"id\":\"${M9_NS}_owned-by-flux__ConfigMap\",\"v\":\"v1\"},{\"id\":\"_${M9_NS}__Namespace\",\"v\":\"v1\"},{\"id\":\"${M9_NS}_web_apps_Deployment\",\"v\":\"v1\"}]}}"
  m9_status kustomization infra "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"ReconciliationSucceeded\",\"message\":\"Applied revision: main@sha1:3f2a9c1d0e7b\",\"lastTransitionTime\":\"$past\"}],\"lastAppliedRevision\":\"main@sha1:3f2a9c1d0e7b\",\"lastAttemptedRevision\":\"main@sha1:3f2a9c1d0e7b\"}"
  m9_status kustomization broken "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"reason\":\"BuildFailed\",\"message\":\"kustomize build failed: accumulating resources: no such file ./broken\",\"lastTransitionTime\":\"$past\"},{\"type\":\"Stalled\",\"status\":\"True\",\"reason\":\"BuildFailed\",\"message\":\"kustomize build failed\",\"lastTransitionTime\":\"$past\"}],\"lastAppliedRevision\":\"main@sha1:1111111aaaaa\",\"lastAttemptedRevision\":\"main@sha1:3f2a9c1d0e7b\"}"
  m9_status kustomization paused "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"ReconciliationSucceeded\",\"message\":\"Applied revision: main@sha1:1111111aaaaa\",\"lastTransitionTime\":\"$past\"}],\"lastAppliedRevision\":\"main@sha1:1111111aaaaa\",\"lastAttemptedRevision\":\"main@sha1:1111111aaaaa\"}"

  # ---- Flux HelmReleases: one deployed, one with exhausted retries
  cat <<YAML | kc apply -f -
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: podinfo, namespace: $M9_NS }
spec:
  interval: 5m
  releaseName: podinfo
  targetNamespace: $M9_NS
  chart: { spec: { chart: podinfo, version: "6.x", sourceRef: { kind: HelmRepository, name: podinfo } } }
---
apiVersion: helm.toolkit.fluxcd.io/v2
kind: HelmRelease
metadata: { name: stuck, namespace: $M9_NS }
spec:
  interval: 5m
  chart: { spec: { chart: stuck, version: "1.x", sourceRef: { kind: HelmRepository, name: podinfo } } }
YAML
  m9_status helmrelease podinfo "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"True\",\"reason\":\"UpgradeSucceeded\",\"message\":\"Helm upgrade succeeded for release $M9_NS/podinfo.v2 with chart podinfo@6.5.3\",\"lastTransitionTime\":\"$now\"}],\"lastAppliedRevision\":\"6.5.3\",\"lastAttemptedRevision\":\"6.5.3\",\"history\":[{\"version\":2,\"chartName\":\"podinfo\",\"chartVersion\":\"6.5.3\",\"appVersion\":\"6.5.3\",\"status\":\"deployed\",\"lastDeployed\":\"$now\"},{\"version\":1,\"chartName\":\"podinfo\",\"chartVersion\":\"6.5.2\",\"status\":\"superseded\",\"lastDeployed\":\"$past\"}]}"
  m9_status helmrelease stuck "{\"conditions\":[{\"type\":\"Ready\",\"status\":\"False\",\"reason\":\"RetriesExceeded\",\"message\":\"Failed to install after 3 attempt(s)\",\"lastTransitionTime\":\"$past\"},{\"type\":\"Stalled\",\"status\":\"True\",\"reason\":\"RetriesExceeded\",\"lastTransitionTime\":\"$past\"}],\"lastAttemptedRevision\":\"1.4.0\"}"

  # ---- Argo CD: AppProject and three Applications (the CRD has no status subresource, so status goes in with the object)
  cat <<YAML | kc apply -f -
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata: { name: shop, namespace: $M9_NS }
spec: { sourceRepos: ["*"], destinations: [ { server: "https://kubernetes.default.svc", namespace: "*" } ] }
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: checkout, namespace: $M9_NS }
spec:
  project: shop
  source: { repoURL: "https://github.com/acme/deploy.git", path: checkout, targetRevision: main }
  destination: { server: "https://kubernetes.default.svc", namespace: checkout }
  syncPolicy: {}
status:
  sync: { status: OutOfSync, revision: "0123456789abcdef0123456789abcdef01234567" }
  health: { status: Degraded, message: "1 pod crashing" }
  reconciledAt: "$now"
  resources:
    - { group: apps, version: v1, kind: Deployment, namespace: checkout, name: web, status: OutOfSync, health: { status: Degraded } }
    - { group: "", version: v1, kind: Service, namespace: checkout, name: web, status: Synced, health: { status: Healthy } }
    - { group: "", version: v1, kind: ConfigMap, namespace: checkout, name: old-config, status: OutOfSync, requiresPruning: true }
    - { group: "", version: v1, kind: ConfigMap, namespace: checkout, name: legacy-flags, status: OutOfSync, requiresPruning: true }
  history:
    - { id: 3, revision: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", deployedAt: "$past", source: { repoURL: "https://github.com/acme/deploy.git", path: checkout, targetRevision: main } }
    - { id: 4, revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", deployedAt: "$now", source: { repoURL: "https://github.com/acme/deploy.git", path: checkout, targetRevision: main } }
  operationState: { phase: Succeeded, message: "successfully synced (all tasks run)", startedAt: "$past", finishedAt: "$past", syncResult: { revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" } }
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: catalog, namespace: $M9_NS }
spec:
  project: shop
  source: { repoURL: "https://github.com/acme/deploy.git", path: catalog, targetRevision: main }
  destination: { server: "https://kubernetes.default.svc", namespace: catalog }
  syncPolicy: { automated: { prune: true, selfHeal: true } }
status:
  sync: { status: Synced, revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" }
  health: { status: Healthy }
  reconciledAt: "$now"
  resources:
    - { group: apps, version: v1, kind: Deployment, namespace: catalog, name: api, status: Synced, health: { status: Healthy } }
  history:
    - { id: 1, revision: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", deployedAt: "$past" }
---
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata: { name: syncing, namespace: $M9_NS }
spec:
  project: shop
  source: { repoURL: "https://github.com/acme/deploy.git", path: syncing, targetRevision: main }
  destination: { server: "https://kubernetes.default.svc", namespace: syncing }
status:
  sync: { status: OutOfSync, revision: "cccccccccccccccccccccccccccccccccccccccc" }
  health: { status: Progressing }
  operationState: { phase: Running, message: "one or more tasks are running", startedAt: "$now" }
YAML

  # ---- Objects with ownership labels, for the detector (plain ConfigMaps; nothing reconciles them)
  cat <<YAML | kc apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: owned-by-flux
  namespace: $M9_NS
  labels: { kustomize.toolkit.fluxcd.io/name: apps, kustomize.toolkit.fluxcd.io/namespace: $M9_NS }
data: { a: b }
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: owned-by-argo
  namespace: $M9_NS
  labels: { app.kubernetes.io/instance: checkout }
  annotations: { argocd.argoproj.io/tracking-id: "checkout:/ConfigMap:$M9_NS/owned-by-argo" }
data: { a: b }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: unmanaged, namespace: $M9_NS }
data: { a: b }
YAML

  # ---- Echo service: returns the request headers it receives (checks what the API server proxy forwards)
  cat <<'YAML' | kc -n "$M9_NS" apply -f -
apiVersion: v1
kind: ConfigMap
metadata: { name: echo-script }
data:
  echo.sh: |
    #!/bin/sh
    f=/tmp/req.$$
    : > $f
    while IFS= read -r line; do
      line=$(printf '%s' "$line" | tr -d '\r')
      [ -z "$line" ] && break
      echo "$line" >> $f
    done
    printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n'
    cat $f
    rm -f $f
---
apiVersion: v1
kind: Pod
metadata: { name: echo, labels: { app: echo } }
spec:
  containers:
    - name: echo
      image: busybox:1.36
      command: ["nc", "-ll", "-p", "8080", "-e", "/echo/echo.sh"]
      ports: [ { containerPort: 8080 } ]
      resources: { requests: { cpu: 1m, memory: 4Mi } }
      volumeMounts: [ { name: script, mountPath: /echo } ]
  volumes: [ { name: script, configMap: { name: echo-script, defaultMode: 0755 } } ]
---
apiVersion: v1
kind: Service
metadata: { name: echo }
spec: { selector: { app: echo }, ports: [ { port: 8080, targetPort: 8080 } ] }
YAML
  echo "Done. Namespace $M9_NS: Flux (apps, infra, broken, paused, podinfo, stuck, fleet) and Argo CD (checkout, catalog, syncing) fixtures, echo service on 8080."
}

m9_clean() {
  kc delete namespace "$M9_NS" --ignore-not-found --wait=true
  kc delete crd -l "$M9_LABEL" --ignore-not-found --wait=true
  echo "Removed namespace $M9_NS and the CRDs labelled $M9_LABEL."
}

case "${3:-}" in
  clean) m9_clean ;;
  "")    m9_seed ;;
  *)     echo "usage: --section m9-gitops [clean]" >&2; return 2 ;;
esac
