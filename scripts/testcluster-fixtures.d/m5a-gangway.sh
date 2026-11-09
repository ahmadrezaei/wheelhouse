# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset; KUBECACHEDIR points
# into .testcluster). Run it with:
#   scripts/testcluster-fixtures.sh --section m5a-gangway          (seed)
#   scripts/testcluster-fixtures.sh --section m5a-gangway clean    (remove everything it made)
#
# Fixtures of the Gangway live kubectl matrix (M5a), on the TEST cluster only: namespace wh-m5a with one pod `probe` that prints a line
# every second (logs -f), answers HTTP on 8080 (port-forward) and accepts exec, and a ConfigMap `base`. The matrix itself creates and
# deletes its own `matrix-*` ConfigMaps and `doomed-*` pods inside that namespace.

M5A_NS=wh-m5a

m5a_seed() {
  echo "Seeding namespace $M5A_NS on context $CTX ..."
  kc create namespace "$M5A_NS" --dry-run=client -o yaml | kc apply -f -
  kc -n "$M5A_NS" create configmap base --from-literal=hello=gangway --dry-run=client -o yaml | kc apply -f -
  kc -n "$M5A_NS" apply -f - <<'YAML'
apiVersion: v1
kind: Pod
metadata: { name: probe, labels: { app: probe } }
spec:
  terminationGracePeriodSeconds: 0
  containers:
    - name: probe
      image: busybox:1.36
      command: ["sh", "-c", "mkdir -p /www; echo gangway-ok > /www/index.html; httpd -f -p 8080 -h /www & while true; do echo tick; sleep 1; done"]
      ports: [ { containerPort: 8080 } ]
      resources: { requests: { cpu: 1m, memory: 4Mi } }
YAML
  kc -n "$M5A_NS" wait --for=condition=Ready pod/probe --timeout=120s
  echo "Done. Namespace $M5A_NS: pod probe, configmap base."
}

m5a_clean() {
  kc delete namespace "$M5A_NS" --ignore-not-found --wait=true
  echo "Removed namespace $M5A_NS."
}

case "${3:-}" in
  clean) m5a_clean ;;
  "")    m5a_seed ;;
  *)     echo "usage: --section m5a-gangway [clean]" >&2; return 2 ;;
esac
