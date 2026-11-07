# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
# Seeds the performance fixtures of ARCHITECTURE-MAC section 12.3.1 on the TEST cluster only:
#   namespace wh-perf with 5 Deployments x 20 replicas of registry.k8s.io/pause:3.10 (100 Pods), 40 Services, 2,000 ConfigMaps and
#   one `chatter` Pod logging 10 lines per second, plus .testcluster/perf-kubeconfig with 10 contexts wh-perf-01 .. wh-perf-10.
# Owned by M1a.

PERF_NS=wh-perf

perf_seed() {
  echo "Seeding namespace $PERF_NS on context $CTX ..."
  kubectl --kubeconfig "$KC" --context "$CTX" create namespace "$PERF_NS" --dry-run=client -o yaml \
    | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -

  # 5 Deployments x 20 replicas
  for i in 1 2 3 4 5; do
    cat <<YAML | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -
apiVersion: apps/v1
kind: Deployment
metadata: { name: perf-app-$i, namespace: $PERF_NS, labels: { app: perf-app-$i, wh-perf: "true" } }
spec:
  replicas: 20
  selector: { matchLabels: { app: perf-app-$i } }
  template:
    metadata: { labels: { app: perf-app-$i, wh-perf: "true" } }
    spec:
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.10
          resources: { requests: { cpu: 1m, memory: 4Mi } }
YAML
  done

  # 40 Services (8 per app)
  for n in $(seq 1 40); do
    app=$(( (n - 1) % 5 + 1 ))
    cat <<YAML
---
apiVersion: v1
kind: Service
metadata: { name: perf-svc-$n, namespace: $PERF_NS, labels: { wh-perf: "true" } }
spec: { selector: { app: perf-app-$app }, ports: [ { port: 80, targetPort: 80 } ] }
YAML
  done | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -

  # 2,000 ConfigMaps, applied in chunks of 250
  for chunk in $(seq 0 7); do
    for j in $(seq 1 250); do
      n=$(( chunk * 250 + j ))
      printf -- '---\napiVersion: v1\nkind: ConfigMap\nmetadata: { name: perf-cm-%04d, namespace: %s, labels: { wh-perf: "true" } }\ndata: { index: "%d" }\n' "$n" "$PERF_NS" "$n"
    done | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -
  done

  # The log source: 10 lines per second
  cat <<YAML | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -
apiVersion: v1
kind: Pod
metadata: { name: chatter, namespace: $PERF_NS, labels: { app: chatter, wh-perf: "true" } }
spec:
  containers:
    - name: chatter
      image: busybox:1.36
      command: ["sh", "-c", "i=0; while true; do i=\$((i+1)); echo \"chatter line \$i\"; sleep 0.1; done"]
      resources: { requests: { cpu: 1m, memory: 4Mi } }
YAML

  # perf-kubeconfig: 10 contexts that all point at the test cluster, with the test user and default namespace wh-perf.
  local out="$REPO/.testcluster/perf-kubeconfig"
  local cluster user
  cluster="$(kubectl --kubeconfig "$KC" --context "$CTX" config view --minify -o jsonpath='{.contexts[0].context.cluster}')"
  user="$(kubectl --kubeconfig "$KC" --context "$CTX" config view --minify -o jsonpath='{.contexts[0].context.user}')"
  kubectl --kubeconfig "$KC" --context "$CTX" config view --raw --minify --flatten > "$out"
  chmod 600 "$out"
  for n in $(seq -w 1 10); do
    kubectl --kubeconfig "$out" config set-context "wh-perf-$n" --cluster="$cluster" --user="$user" --namespace="$PERF_NS" >/dev/null
  done
  kubectl --kubeconfig "$out" config delete-context "$CTX" >/dev/null 2>&1 || true
  kubectl --kubeconfig "$out" config use-context wh-perf-01 >/dev/null
  echo "Wrote $out (contexts wh-perf-01 .. wh-perf-10). Wait for the pods: kubectl --kubeconfig $KC --context $CTX -n $PERF_NS get pods"
}

perf_clean() {
  kubectl --kubeconfig "$KC" --context "$CTX" delete namespace "$PERF_NS" --ignore-not-found
  rm -f "$REPO/.testcluster/perf-kubeconfig"
}
