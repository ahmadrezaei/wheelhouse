# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
#
#   scripts/testcluster-fixtures.sh --section m6b-helm           create namespace wh-m6b for the Chart Room write-path suite (M6b)
#   scripts/testcluster-fixtures.sh --section m6b-helm clean     remove it, its releases and the fixture CRD
#
# The suite installs the local chart scripts/testcluster-fixtures.d/m6b-chart (ConfigMaps, a Service, a pre-install hook and a CRD:
# no pods, so no image is pulled and no chart is downloaded) into wh-m6b under release names of its own, and removes them again.
# helm is only used for the clean-up here, with HELM_* under .testcluster/helm-m6b and the test kubeconfig passed explicitly.

M6B_NS=wh-m6b

m6b_clean() {
  echo "Removing the M6b fixtures from context $CTX ..."
  export HELM_CONFIG_HOME="$REPO/.testcluster/helm-m6b/config" HELM_CACHE_HOME="$REPO/.testcluster/helm-m6b/cache" HELM_DATA_HOME="$REPO/.testcluster/helm-m6b/data"
  mkdir -p "$HELM_CONFIG_HOME" "$HELM_CACHE_HOME" "$HELM_DATA_HOME"
  for rel in $(helm --kubeconfig "$KC" --kube-context "$CTX" list -n "$M6B_NS" -q 2>/dev/null); do
    helm --kubeconfig "$KC" --kube-context "$CTX" uninstall "$rel" -n "$M6B_NS" >/dev/null
  done
  kubectl --kubeconfig "$KC" --context "$CTX" delete namespace "$M6B_NS" --ignore-not-found --wait=true
  kubectl --kubeconfig "$KC" --context "$CTX" delete crd whm6bwidgets.wheelhouse.test --ignore-not-found
  rm -r -f "$REPO/.testcluster/helm-m6b"
}

m6b_seed() {
  kubectl --kubeconfig "$KC" --context "$CTX" create namespace "$M6B_NS" --dry-run=client -o yaml | kubectl --kubeconfig "$KC" --context "$CTX" apply -f -
  echo "Done. Chart: $REPO/scripts/testcluster-fixtures.d/m6b-chart"
}

if [ "${3:-}" = "clean" ]; then m6b_clean; else m6b_seed; fi
