#!/bin/bash
# Seeds the TEST cluster only (ARCHITECTURE-MAC section 13.3). Run by the owner; no automated step runs it.
#
#   scripts/testcluster-fixtures.sh --record-host     record .testcluster/server-host from the test kubeconfig (once, after
#                                                     checking that the server is the minikube test cluster)
#   scripts/testcluster-fixtures.sh --perf            seed namespace wh-perf and write .testcluster/perf-kubeconfig
#   scripts/testcluster-fixtures.sh --perf-clean      delete namespace wh-perf and the perf kubeconfig
#   scripts/testcluster-fixtures.sh --section <name>  source scripts/testcluster-fixtures.d/<name>.sh (m6a-helm, m9-gitops, ...)
#
# SAFETY PREAMBLE (runs before anything else; every step aborts the script on failure):
#   1. unset KUBECONFIG, HELM_KUBECONTEXT, HELM_KUBEAPISERVER, HELM_KUBETOKEN so nothing from the shell can redirect it, and set
#      KUBECACHEDIR to .testcluster/kubectl-cache (kubectl would otherwise write to ~/.kube/cache);
#   2. resolve KC = realpath(<repo>/.testcluster/kubeconfig) and abort if it is under realpath(~/.kube);
#   3. read the server of context wheelhouse-test and abort unless its host equals .testcluster/server-host;
#   4. `get --raw /version` and abort on failure.
# Every later kubectl, helm or flux command passes --kubeconfig "$KC" --context wheelhouse-test explicitly
# (helm: --kubeconfig "$KC" --kube-context wheelhouse-test). It never reads ~/.kube or .secrets/.
set -euo pipefail

# ---- 1. nothing from the environment may redirect us
unset KUBECONFIG HELM_KUBECONTEXT HELM_KUBEAPISERVER HELM_KUBETOKEN HELM_KUBEASUSER HELM_KUBEASGROUPS HELM_KUBECAFILE

REPO="$(cd "$(dirname "$0")/.." && pwd)"
CTX=wheelhouse-test
# kubectl writes its discovery cache to ~/.kube/cache even with --kubeconfig; keep it inside the repository's test folder instead.
mkdir -p "$REPO/.testcluster/kubectl-cache"
export KUBECACHEDIR="$REPO/.testcluster/kubectl-cache"

# ---- 2. the kubeconfig must be the repository's test file and must not be under ~/.kube
[ -f "$REPO/.testcluster/kubeconfig" ] || { echo "abort: $REPO/.testcluster/kubeconfig does not exist" >&2; exit 1; }
KC="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REPO/.testcluster/kubeconfig")"
KUBE_HOME="$(python3 -c 'import os,sys; print(os.path.realpath(os.path.expanduser(sys.argv[1])))' "~/.kube")"
case "$KC" in
  "$KUBE_HOME"|"$KUBE_HOME"/*) echo "abort: the test kubeconfig resolves under ~/.kube ($KC)" >&2; exit 1 ;;
esac

kc() { kubectl --kubeconfig "$KC" --context "$CTX" "$@"; }

SERVER="$(kc config view --minify -o jsonpath='{.clusters[0].cluster.server}')"
HOST="$(python3 -c 'import sys,urllib.parse; print(urllib.parse.urlparse(sys.argv[1]).hostname or "")' "$SERVER")"

if [ "${1:-}" = "--record-host" ]; then
  printf '%s\n' "$HOST" > "$REPO/.testcluster/server-host"
  echo "recorded server host '$HOST' in .testcluster/server-host. Check that this is the minikube test cluster."
  exit 0
fi

# ---- 3. the server host must be the recorded one
[ -f "$REPO/.testcluster/server-host" ] || { echo "abort: .testcluster/server-host is missing. Check the server ($HOST) and run: $0 --record-host" >&2; exit 1; }
RECORDED="$(tr -d '[:space:]' < "$REPO/.testcluster/server-host")"
[ -n "$HOST" ] && [ "$HOST" = "$RECORDED" ] || { echo "abort: server host '$HOST' differs from the recorded '$RECORDED'" >&2; exit 1; }

# ---- 4. the cluster must answer
kc get --raw /version >/dev/null || { echo "abort: the test cluster did not answer /version" >&2; exit 1; }
echo "preamble ok: context $CTX, host $HOST"

export REPO KC CTX
case "${1:-}" in
  --perf)       # shellcheck source=testcluster-fixtures.d/m1a-perf.sh
                . "$REPO/scripts/testcluster-fixtures.d/m1a-perf.sh"; perf_seed ;;
  --perf-clean) . "$REPO/scripts/testcluster-fixtures.d/m1a-perf.sh"; perf_clean ;;
  --section)    f="$REPO/scripts/testcluster-fixtures.d/${2:?usage: --section <name>}.sh"
                [ -f "$f" ] || { echo "no such section: $f" >&2; exit 2; }
                . "$f" ;;
  *) echo "usage: $0 --record-host | --perf | --perf-clean | --section <name>" >&2; exit 2 ;;
esac
