# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset; KUBECACHEDIR points
# into .testcluster). Run it with:
#   scripts/testcluster-fixtures.sh --section m5b-terminal          (seed)
#   scripts/testcluster-fixtures.sh --section m5b-terminal clean    (remove everything it made)
#
# Fixtures of the Deck Terminal live tests (M5b), on the TEST cluster only: namespace wh-m5b with a Deployment `web` (one idle busybox
# replica, so `kubectl rollout restart` has something to restart) and a ConfigMap `base`.

M5B_NS=wh-m5b

m5b_seed() {
  echo "Seeding namespace $M5B_NS on context $CTX ..."
  kc create namespace "$M5B_NS" --dry-run=client -o yaml | kc apply -f -
  kc -n "$M5B_NS" create configmap base --from-literal=hello=terminal --dry-run=client -o yaml | kc apply -f -
  kc -n "$M5B_NS" apply -f - <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata: { name: web, labels: { app: web } }
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata: { labels: { app: web } }
    spec:
      terminationGracePeriodSeconds: 0
      containers:
        - name: web
          image: busybox:1.36
          command: ["sh", "-c", "while true; do sleep 3600; done"]
          resources: { requests: { cpu: 1m, memory: 4Mi } }
YAML
  kc -n "$M5B_NS" rollout status deployment/web --timeout=120s
  echo "Done. Namespace $M5B_NS: deployment web, configmap base."
}

m5b_clean() {
  kc delete namespace "$M5B_NS" --ignore-not-found --wait=true
  echo "Removed namespace $M5B_NS."
}

case "${3:-}" in
  clean) m5b_clean ;;
  "")    m5b_seed ;;
  *)     echo "usage: --section m5b-terminal [clean]" >&2; return 2 ;;
esac
