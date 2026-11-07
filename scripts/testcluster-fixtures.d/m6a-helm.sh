# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
#
#   scripts/testcluster-fixtures.sh --section m6a-helm           seed the Helm fixtures of ARCHITECTURE-MAC section 13.3 (M6a)
#   scripts/testcluster-fixtures.sh --section m6a-helm clean     remove them again
#
# Seeds the TEST cluster only:
#   wh-m6a        chart `wh-fixture` in two revisions (release `wh-fixture`, installed and upgraded by the helm on PATH, which writes the
#                 Helm 3 release Secrets), a failed release `wh-failed`, and `wh-helm4`: a Helm 4 style record (see below)
#   wh-m6a-cm     release `wh-cm` stored in ConfigMaps (HELM_DRIVER=configmap)
#   wh-m6a-many   200 release Secrets (r001 .. r200, revision 1), metadata-complete copies of a real record, for the 1 s list budget
#   wh-m6a-rbac   a ServiceAccount with no permissions; its token goes to .testcluster/m6a-nobody.token (git-ignored) for the
#                 forbidden-Secrets live test
#
# The Helm 4 record: no Helm 4 binary is installed here, and Helm 4 writes the same `helm.sh/release.v1` format as Helm 3, so the
# record is the Helm 3 one re-encoded under a new name with the fields a newer chart format adds (info.resources, chart.metadata
# apiVersion/type, an unknown top-level field). It proves lenient decoding; it is not a recording from a Helm 4 binary.
#
# Every kubectl and helm call passes --kubeconfig "$KC" with the test context explicitly. Nothing reads ~/.kube or .secrets/.

M6A_NS=wh-m6a
M6A_CM_NS=wh-m6a-cm
M6A_MANY_NS=wh-m6a-many
M6A_RBAC_NS=wh-m6a-rbac

# helm must never touch the user's real configuration, cache or data: everything it writes goes under .testcluster/helm.
export HELM_CONFIG_HOME="$REPO/.testcluster/helm/config" HELM_CACHE_HOME="$REPO/.testcluster/helm/cache" HELM_DATA_HOME="$REPO/.testcluster/helm/data"
mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"

m6a_kc() { kubectl --kubeconfig "$KC" --context "$CTX" "$@"; }
m6a_helm() { helm --kubeconfig "$KC" --kube-context "$CTX" "$@"; }

m6a_clean() {
  echo "Removing Helm fixtures from context $CTX ..."
  for ns in "$M6A_NS" "$M6A_CM_NS" "$M6A_MANY_NS" "$M6A_RBAC_NS"; do
    m6a_kc delete namespace "$ns" --ignore-not-found --wait=true
  done
  rm -f "$REPO/.testcluster/m6a-nobody.token"
  rm -r -f "$REPO/.testcluster/helm"
}

m6a_chart() {   # m6a_chart <dir> <version> <replicas> <breakService>
  local dir="$1" version="$2" replicas="$3" broken="$4"
  mkdir -p "$dir/wh-fixture/templates"
  cat > "$dir/wh-fixture/Chart.yaml" <<YAML
apiVersion: v2
name: wh-fixture
description: Wheelhouse Chart Room fixture
type: application
version: $version
appVersion: "1.$replicas.0"
keywords: [wheelhouse, fixture]
maintainers:
  - name: Wheelhouse
YAML
  cat > "$dir/wh-fixture/values.yaml" <<YAML
replicas: $replicas
image:
  repository: registry.k8s.io/pause
  tag: "3.10"
auth:
  username: demo
  password: ""
apiToken: ""
service:
  port: 8080
YAML
  cat > "$dir/wh-fixture/values.schema.json" <<'JSON'
{"$schema":"http://json-schema.org/draft-07/schema#","type":"object","properties":{"replicas":{"type":"integer","minimum":0}}}
JSON
  cat > "$dir/wh-fixture/templates/configmap.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-config
data:
  replicas: {{ .Values.replicas | quote }}
  image: {{ .Values.image.repository }}:{{ .Values.image.tag }}
YAML
  if [ "$broken" = "yes" ]; then
    cat > "$dir/wh-fixture/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-svc
spec:
  ports:
    - port: 0
      targetPort: -1
YAML
  else
    cat > "$dir/wh-fixture/templates/service.yaml" <<'YAML'
apiVersion: v1
kind: Service
metadata:
  name: {{ .Release.Name }}-svc
spec:
  selector:
    app: {{ .Release.Name }}
  ports:
    - port: {{ .Values.service.port }}
YAML
  fi
  cat > "$dir/wh-fixture/templates/hook.yaml" <<'YAML'
apiVersion: v1
kind: ConfigMap
metadata:
  name: {{ .Release.Name }}-hook
  annotations:
    "helm.sh/hook": post-install,post-upgrade
    "helm.sh/hook-weight": "5"
    "helm.sh/hook-delete-policy": before-hook-creation
data:
  note: ran
YAML
  cat > "$dir/wh-fixture/templates/NOTES.txt" <<'TXT'
wh-fixture {{ .Release.Name }} is installed in {{ .Release.Namespace }}. See https://example.com/docs
TXT
}

m6a_seed() {
  command -v helm >/dev/null || { echo "abort: no helm on PATH" >&2; return 1; }
  command -v python3 >/dev/null || { echo "abort: no python3" >&2; return 1; }
  local work; work="$(mktemp -d)"

  for ns in "$M6A_NS" "$M6A_CM_NS" "$M6A_MANY_NS" "$M6A_RBAC_NS"; do
    m6a_kc create namespace "$ns" --dry-run=client -o yaml | m6a_kc apply -f -
  done

  echo "== wh-fixture: install (revision 1), upgrade (revision 2)"
  m6a_chart "$work/v1" 0.1.0 1 no
  m6a_chart "$work/v2" 0.2.0 2 no
  if ! m6a_helm status wh-fixture -n "$M6A_NS" >/dev/null 2>&1; then
    m6a_helm install wh-fixture "$work/v1/wh-fixture" -n "$M6A_NS" --set auth.password=fixture-password-1 --set apiToken=fixture-token-1
    m6a_helm upgrade wh-fixture "$work/v2/wh-fixture" -n "$M6A_NS" --set auth.password=fixture-password-2 --set apiToken=fixture-token-2 --set replicas=2
  fi

  echo "== wh-failed: a release whose Service is rejected by the API server"
  if ! m6a_helm status wh-failed -n "$M6A_NS" >/dev/null 2>&1; then
    m6a_chart "$work/bad" 0.1.0 1 yes
    m6a_helm install wh-failed "$work/bad/wh-fixture" -n "$M6A_NS" || echo "(expected failure: release recorded as failed)"
  fi

  echo "== wh-cm: stored in ConfigMaps"
  if ! HELM_DRIVER=configmap m6a_helm status wh-cm -n "$M6A_CM_NS" >/dev/null 2>&1; then
    HELM_DRIVER=configmap m6a_helm install wh-cm "$work/v1/wh-fixture" -n "$M6A_CM_NS"
  fi

  echo "== wh-helm4 (Helm 4 style) and 200 releases"
  m6a_kc get secret sh.helm.release.v1.wh-fixture.v2 -n "$M6A_NS" -o json > "$work/secret.json"
  M6A_WORK="$work" M6A_NS="$M6A_NS" M6A_MANY_NS="$M6A_MANY_NS" python3 -I - <<'PY'
import base64, gzip, json, os
work, ns, many = os.environ["M6A_WORK"], os.environ["M6A_NS"], os.environ["M6A_MANY_NS"]
secret = json.load(open(os.path.join(work, "secret.json")))
record = json.loads(gzip.decompress(base64.b64decode(base64.b64decode(secret["data"]["release"]))))

def encode(rec):
    gz = gzip.compress(json.dumps(rec, separators=(",", ":")).encode(), 9)
    return base64.b64encode(base64.b64encode(gz)).decode()

def manifest(name, namespace, rev, status, payload):
    return {"apiVersion": "v1", "kind": "Secret", "type": "helm.sh/release.v1",
            "metadata": {"name": f"sh.helm.release.v1.{name}.v{rev}", "namespace": namespace,
                         "labels": {"name": name, "owner": "helm", "status": status, "version": str(rev), "modifiedAt": "1762500000"}},
            "data": {"release": payload}}

h4 = json.loads(json.dumps(record))
h4["name"] = "wh-helm4"
h4["version"] = 1
h4["info"]["status"] = "deployed"
h4["info"]["resources"] = {}                       # fields a newer Helm adds: kept in `extra`, never required
h4["chart"]["metadata"]["apiVersion"] = "v2"
h4["chart"]["metadata"]["type"] = "application"
h4["future_field"] = {"added": "by a newer helm"}
items = [manifest("wh-helm4", ns, 1, "deployed", encode(h4))]
payload = encode(record)
for i in range(1, 201):
    items.append(manifest(f"r{i:03d}", many, 1, "deployed", payload))
json.dump({"apiVersion": "v1", "kind": "List", "items": items}, open(os.path.join(work, "list.json"), "w"))
PY
  # `create`, not `apply`: client-side apply would copy the whole payload into a last-applied-configuration annotation.
  m6a_kc delete -f "$work/list.json" --ignore-not-found >/dev/null
  m6a_kc create -f "$work/list.json" >/dev/null

  echo "== wh-m6a-rbac: a subject that may not list anything"
  m6a_kc create serviceaccount wh-m6a-nobody -n "$M6A_RBAC_NS" --dry-run=client -o yaml | m6a_kc apply -f -
  ( umask 077; m6a_kc create token wh-m6a-nobody -n "$M6A_RBAC_NS" --duration=2h > "$REPO/.testcluster/m6a-nobody.token" )

  rm -rf "$work"
  echo "Done. Releases:"
  m6a_helm list -A --all 2>/dev/null | grep -E "wh-fixture|wh-failed" || true
  echo "ConfigMap-stored: $(m6a_kc get configmap -n "$M6A_CM_NS" -l owner=helm -o name | wc -l | tr -d ' ') record(s); many: $(m6a_kc get secret -n "$M6A_MANY_NS" -l owner=helm -o name | wc -l | tr -d ' ') record(s)"
}

if [ "${3:-}" = "clean" ]; then m6a_clean; else m6a_seed; fi
