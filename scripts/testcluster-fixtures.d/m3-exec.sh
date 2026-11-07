# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset; KUBECACHEDIR points
# into .testcluster). Run it with:  scripts/testcluster-fixtures.sh --section m3-exec        (seed)
#                                    M3_CLEAN=1 scripts/testcluster-fixtures.sh --section m3-exec   (remove everything it made)
#
# Seeds the exec-credential fixtures of ARCHITECTURE-MAC section 13.3 (owned by M3), on the TEST cluster only:
#   - namespace wh-m3 with one ConfigMap (the live exec suite reads it through the plugin credential);
#   - .testcluster/exec-plugin.sh: a credential plugin that prints an ExecCredential whose token is read from .testcluster/admin.token AT RUN
#     TIME (the token is never copied into a committed file or into the kubeconfig);
#   - .testcluster/exec-kubeconfig: contexts wheelhouse-exec (v1, expiring) and wheelhouse-exec-beta (v1beta1, no expiry) that use the plugin
#     and point at the same API server as the test kubeconfig.
# Everything it creates lives under the gitignored .testcluster/ folder, except the namespace.

M3_NS=wh-m3
M3_PLUGIN="$REPO/.testcluster/exec-plugin.sh"
M3_KUBECONFIG="$REPO/.testcluster/exec-kubeconfig"

m3_kc() { kubectl --kubeconfig "$KC" --context "$CTX" "$@"; }

m3_clean() {
  echo "Removing namespace $M3_NS and the exec fixtures ..."
  m3_kc delete namespace "$M3_NS" --ignore-not-found --wait=true
  rm -f "$M3_PLUGIN" "$M3_KUBECONFIG" "$REPO/.testcluster/exec-plugin-runs"
}

m3_seed() {
  [ -f "$REPO/.testcluster/admin.token" ] || { echo "abort: .testcluster/admin.token is missing" >&2; return 1; }

  echo "Seeding namespace $M3_NS on context $CTX ..."
  m3_kc create namespace "$M3_NS" --dry-run=client -o yaml | m3_kc apply -f -
  m3_kc -n "$M3_NS" create configmap m3-fixture --from-literal=hello=exec --dry-run=client -o yaml | m3_kc apply -f -

  # The plugin: prints a v1 ExecCredential (or v1beta1 when asked) with the test token read from disk now, and counts its runs.
  cat > "$M3_PLUGIN" <<'PLUGIN'
#!/bin/sh
# Test-cluster exec credential plugin (written by scripts/testcluster-fixtures.d/m3-exec.sh; not part of the product).
dir="$(cd "$(dirname "$0")" && pwd)"
n=0
[ -f "$dir/exec-plugin-runs" ] && n=$(cat "$dir/exec-plugin-runs")
printf '%s' $((n + 1)) > "$dir/exec-plugin-runs"
token="$(tr -d '\n' < "$dir/admin.token")"
version="client.authentication.k8s.io/v1"
[ "$1" = "--beta" ] && version="client.authentication.k8s.io/v1beta1"
expiry=""
if [ "$1" != "--beta" ]; then
  expiry=",\"expirationTimestamp\":\"$(date -u -v+10M +%Y-%m-%dT%H:%M:%SZ)\""
fi
printf '{"apiVersion":"%s","kind":"ExecCredential","status":{"token":"%s"%s}}' "$version" "$token" "$expiry"
PLUGIN
  chmod 755 "$M3_PLUGIN"
  : > "$REPO/.testcluster/exec-plugin-runs"; printf '0' > "$REPO/.testcluster/exec-plugin-runs"

  # The kubeconfig: same server and CA as the test kubeconfig, user authenticated through the plugin.
  SERVER="$(m3_kc config view --minify --raw -o jsonpath='{.clusters[0].cluster.server}')"
  CA="$(m3_kc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority}')"
  CAD="$(m3_kc config view --minify --raw -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')"
  if [ -n "$CAD" ]; then CALINE="certificate-authority-data: $CAD"; else CALINE="certificate-authority: $CA"; fi
  umask 077
  cat > "$M3_KUBECONFIG" <<YAML
apiVersion: v1
kind: Config
current-context: wheelhouse-exec
clusters:
- name: wheelhouse-test-exec
  cluster:
    server: $SERVER
    $CALINE
users:
- name: exec-v1
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1
      command: $M3_PLUGIN
      interactiveMode: Never
      provideClusterInfo: true
- name: exec-v1beta1
  user:
    exec:
      apiVersion: client.authentication.k8s.io/v1beta1
      command: $M3_PLUGIN
      args: ["--beta"]
contexts:
- name: wheelhouse-exec
  context: {cluster: wheelhouse-test-exec, user: exec-v1, namespace: $M3_NS}
- name: wheelhouse-exec-beta
  context: {cluster: wheelhouse-test-exec, user: exec-v1beta1, namespace: $M3_NS}
YAML

  # Prove the fixture works with kubectl itself (kubectl runs the plugin).
  got="$(kubectl --kubeconfig "$M3_KUBECONFIG" --context wheelhouse-exec -n "$M3_NS" get configmap m3-fixture -o jsonpath='{.data.hello}')"
  [ "$got" = "exec" ] || { echo "abort: kubectl through the exec plugin did not read the fixture (got '$got')" >&2; return 1; }
  echo "m3-exec ready: $M3_KUBECONFIG (contexts wheelhouse-exec, wheelhouse-exec-beta), namespace $M3_NS"
}

if [ "${M3_CLEAN:-}" = "1" ]; then m3_clean; else m3_seed; fi
