# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
# Seeds the Rigging (M13) fixtures on the TEST cluster only:
#   * CRDs ONLY (no operators, nothing pulled from the internet) for cert-manager, KEDA, External Secrets and Velero, labelled
#     wheelhouse.test/fixture=m13-rigging, each with the status subresource as upstream;
#   * namespace wh-m13 with sample custom resources: ready, failing and about-to-expire Certificates, an Issuer and a ClusterIssuer, KEDA
#     ScaledObjects (ready, not ready, in fallback), ExternalSecrets (synced, failing) and Velero Backups (completed, failed).
#
#   scripts/testcluster-fixtures.sh --section m13          seed (idempotent)
#   scripts/testcluster-fixtures.sh --section m13 clean    delete namespace wh-m13 and the CRDs this section added
# Owned by M13.

M13_NS=wh-m13
M13_LABEL="wheelhouse.test/fixture=m13-rigging"

m13_crd() {   # group kind plural singular version scope
  cat <<YAML | kc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: $3.$1
  labels: { wheelhouse.test/fixture: m13-rigging }
spec:
  group: $1
  scope: $6
  names: { kind: $2, plural: $3, singular: $4, listKind: ${2}List }
  versions:
    - name: $5
      served: true
      storage: true
      subresources: { status: {} }
      schema:
        openAPIV3Schema:
          type: object
          x-kubernetes-preserve-unknown-fields: true
YAML
}

m13_status() {   # kind name json-status [namespaced: yes|no]
  if [ "${4:-yes}" = no ]; then
    kc patch "$1" "$2" --subresource=status --type=merge -p "{\"status\": $3}" >/dev/null
  else
    kc -n "$M13_NS" patch "$1" "$2" --subresource=status --type=merge -p "{\"status\": $3}" >/dev/null
  fi
}

m13_cond() {   # type status reason lastTransitionTime
  printf '{"type":"%s","status":"%s","reason":"%s","lastTransitionTime":"%s"}' "$1" "$2" "$3" "$4"
}

m13_seed() {
  local now past soon
  now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  past="$(date -u -v-3H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '3 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
  soon="$(date -u -v+10d +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '10 days' +%Y-%m-%dT%H:%M:%SZ)"
  echo "Seeding Rigging fixtures (CRDs and namespace $M13_NS) on context $CTX ..."

  m13_crd cert-manager.io Certificate certificates certificate v1 Namespaced
  m13_crd cert-manager.io Issuer issuers issuer v1 Namespaced
  m13_crd cert-manager.io ClusterIssuer clusterissuers clusterissuer v1 Cluster
  m13_crd keda.sh ScaledObject scaledobjects scaledobject v1alpha1 Namespaced
  m13_crd external-secrets.io ExternalSecret externalsecrets externalsecret v1beta1 Namespaced
  m13_crd velero.io Backup backups backup v1 Namespaced
  kc wait --for=condition=Established crd -l "$M13_LABEL" --timeout=60s >/dev/null

  kc create namespace "$M13_NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
  kc label namespace "$M13_NS" "$M13_LABEL" --overwrite >/dev/null

  cat <<YAML | kc -n "$M13_NS" apply -f -
apiVersion: cert-manager.io/v1
kind: Issuer
metadata: { name: selfsigned }
spec: { selfSigned: {} }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: web-tls }
spec: { secretName: web-tls, issuerRef: { name: selfsigned, kind: Issuer }, dnsNames: [web.example.test] }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: api-tls }
spec: { secretName: api-tls, issuerRef: { name: selfsigned, kind: Issuer }, dnsNames: [api.example.test] }
---
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: { name: broken-tls }
spec: { secretName: broken-tls, issuerRef: { name: missing-issuer, kind: Issuer }, dnsNames: [broken.example.test] }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: queue-worker }
spec: { scaleTargetRef: { name: queue-worker }, minReplicaCount: 1, maxReplicaCount: 20 }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: cron-scaler }
spec: { scaleTargetRef: { name: cron-scaler }, minReplicaCount: 0, maxReplicaCount: 5 }
---
apiVersion: keda.sh/v1alpha1
kind: ScaledObject
metadata: { name: flaky-scaler }
spec: { scaleTargetRef: { name: flaky-scaler }, minReplicaCount: 2, maxReplicaCount: 8 }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: db-credentials }
spec: { secretStoreRef: { name: vault, kind: SecretStore }, target: { name: db-credentials }, refreshInterval: 1h }
---
apiVersion: external-secrets.io/v1beta1
kind: ExternalSecret
metadata: { name: stale-credentials }
spec: { secretStoreRef: { name: vault, kind: SecretStore }, target: { name: stale-credentials }, refreshInterval: 15m }
---
apiVersion: velero.io/v1
kind: Backup
metadata: { name: nightly-1 }
spec: { storageLocation: default }
---
apiVersion: velero.io/v1
kind: Backup
metadata: { name: nightly-2 }
spec: { storageLocation: default }
YAML

  m13_status certificates web-tls "{\"notAfter\":\"$soon\",\"renewalTime\":\"$soon\",\"conditions\":[$(m13_cond Ready True Ready "$past")]}"
  m13_status certificates api-tls "{\"notAfter\":\"$soon\",\"conditions\":[$(m13_cond Ready True Ready "$past")]}"
  m13_status certificates broken-tls "{\"conditions\":[$(m13_cond Ready False IssuerNotFound "$past")]}"
  m13_status scaledobjects queue-worker "{\"conditions\":[$(m13_cond Ready True ScaledObjectReady "$past"),$(m13_cond Active True ScalerActive "$past")]}"
  m13_status scaledobjects cron-scaler "{\"conditions\":[$(m13_cond Ready True ScaledObjectReady "$past"),$(m13_cond Active False ScalerNotActive "$past")]}"
  m13_status scaledobjects flaky-scaler "{\"conditions\":[$(m13_cond Ready False ScaledObjectCheckFailed "$past"),$(m13_cond Fallback True FallbackExists "$past")]}"
  m13_status externalsecrets db-credentials "{\"refreshTime\":\"$now\",\"conditions\":[$(m13_cond Ready True SecretSynced "$past")]}"
  m13_status externalsecrets stale-credentials "{\"refreshTime\":\"$past\",\"conditions\":[$(m13_cond Ready False SecretSyncedError "$past")]}"
  m13_status backups nightly-1 "{\"phase\":\"Completed\",\"errors\":0,\"warnings\":1,\"startTimestamp\":\"$past\",\"expiration\":\"$soon\"}"
  m13_status backups nightly-2 "{\"phase\":\"PartiallyFailed\",\"errors\":3,\"warnings\":0,\"startTimestamp\":\"$now\"}"
  echo "Done. Namespace $M13_NS: cert-manager, KEDA, External Secrets and Velero sample resources (CRDs only, no operators)."
}

m13_clean() {
  kc delete namespace "$M13_NS" --ignore-not-found --wait=true
  kc delete crd -l "$M13_LABEL" --ignore-not-found --wait=true
  echo "Removed namespace $M13_NS and the CRDs labelled $M13_LABEL."
}

case "${3:-}" in
  clean) m13_clean ;;
  "")    m13_seed ;;
  *)     echo "usage: --section m13 [clean]" >&2; return 2 ;;
esac
