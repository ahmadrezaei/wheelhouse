# Sourced by scripts/testcluster-fixtures.sh AFTER its safety preamble (KC, CTX and REPO are set; KUBECONFIG is unset).
# Seeds the Manifest Editor fixtures (M7) on the TEST cluster only: one CRD with a structured OpenAPI v3 schema, labelled
# wheelhouse.test/fixture=m7-schema, and namespace wh-m7 with a ConfigMap and a ServiceAccount to complete references against.
#
#   scripts/testcluster-fixtures.sh --section m7-schema          seed (idempotent)
#   scripts/testcluster-fixtures.sh --section m7-schema clean    delete namespace wh-m7 and the CRD this section added
# Owned by M7.

M7_NS=wh-m7
M7_LABEL="wheelhouse.test/fixture=m7-schema"

m7_seed() {
  echo "Seeding schema fixtures (CRD widgets.m7.wheelhouse.test, namespace $M7_NS) on context $CTX ..."
  cat <<'YAML' | kc apply -f -
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: widgets.m7.wheelhouse.test
  labels: { wheelhouse.test/fixture: m7-schema }
spec:
  group: m7.wheelhouse.test
  scope: Namespaced
  names: { kind: Widget, plural: widgets, singular: widget, listKind: WidgetList }
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              description: The desired state of the widget.
              oneOf:
                - required: [size]
                - required: [tier]
              properties:
                tier:
                  type: string
                  description: A named tier, used instead of a size.
                size:
                  type: string
                  description: How big the widget is.
                  enum: [small, medium, large]
                replicas:
                  type: integer
                  minimum: 0
                  description: How many copies to keep.
                tags:
                  type: array
                  items: { type: string }
                  description: Free-form tags.
            status:
              type: object
              x-kubernetes-preserve-unknown-fields: true
YAML
  kc wait --for=condition=Established crd/widgets.m7.wheelhouse.test --timeout=60s >/dev/null
  cat <<YAML | kc apply -f -
apiVersion: v1
kind: Namespace
metadata: { name: $M7_NS, labels: { wheelhouse.test/fixture: m7-schema } }
---
apiVersion: v1
kind: ConfigMap
metadata: { name: m7-config, namespace: $M7_NS }
data: { greeting: hello }
---
apiVersion: v1
kind: ServiceAccount
metadata: { name: m7-sa, namespace: $M7_NS }
YAML
  echo "Done."
}

m7_clean() {
  kc delete namespace "$M7_NS" --ignore-not-found --wait=true
  kc delete crd -l "$M7_LABEL" --ignore-not-found --wait=true
  echo "Removed namespace $M7_NS and the CRDs labelled $M7_LABEL."
}

case "${3:-}" in
  clean) m7_clean ;;
  "")    m7_seed ;;
  *)     echo "usage: --section m7-schema [clean]" >&2; return 2 ;;
esac
