#!/usr/bin/env python3 -I
"""Builds the bundled fallback schema (ARCHITECTURE-MAC M7) from OpenAPI v3 documents saved from a cluster.

usage: scripts/build-schema-bundle.py <minor, e.g. 1.32> <dir with one file per group-version> <output file>

The input directory holds the raw `kubectl get --raw /openapi/v3/<group-version>` output, named with `/` replaced by `_`
(api_v1.json, apis_apps_v1.json, ...). The output is a lzfse-compressed JSON file for WheelhouseKit/BundledData/openapi/.
Only the schemas reachable from top-level kinds are kept, descriptions are cut to their first sentence and every field the
editor does not read is dropped, so the file stays small. Run it with the docs of a test cluster of the wanted minor; it
needs `compression_tool` (macOS).
"""
import json, os, re, subprocess, sys, tempfile

KEEP = {"type", "format", "properties", "required", "items", "additionalProperties", "enum", "const", "pattern", "minimum", "maximum",
        "minLength", "maxLength", "minItems", "maxItems", "allOf", "anyOf", "oneOf", "$ref", "description", "nullable",
        "x-kubernetes-int-or-string", "x-kubernetes-preserve-unknown-fields", "x-kubernetes-embedded-resource",
        "x-kubernetes-group-version-kind"}
SKIP_KINDS = {"DeleteOptions", "Status", "WatchEvent", "Patch", "Preconditions", "ListOptions", "CreateOptions", "UpdateOptions"}
GROUP_VERSIONS = {"api_v1": "api/v1", "apis_apps_v1": "apis/apps/v1", "apis_batch_v1": "apis/batch/v1",
                  "apis_networking.k8s.io_v1": "apis/networking.k8s.io/v1", "apis_rbac.authorization.k8s.io_v1": "apis/rbac.authorization.k8s.io/v1",
                  "apis_policy_v1": "apis/policy/v1", "apis_autoscaling_v2": "apis/autoscaling/v2", "apis_storage.k8s.io_v1": "apis/storage.k8s.io/v1",
                  "apis_apiextensions.k8s.io_v1": "apis/apiextensions.k8s.io/v1"}


def first_sentence(text, limit=140):
    text = re.sub(r"\s+", " ", text).strip()
    m = re.match(r"(.+?[.!?])(\s|$)", text)
    sentence = m.group(1) if m else text
    return sentence if len(sentence) <= limit else sentence[: limit - 1].rstrip() + "…"


def trim(node):
    if isinstance(node, dict):
        out = {}
        for k, v in node.items():
            if k not in KEEP:
                continue
            if k == "description" and isinstance(v, str):
                out[k] = first_sentence(v)
            elif k == "properties" and isinstance(v, dict):
                out[k] = {name: trim(p) for name, p in v.items()}
            elif k in ("enum", "required", "x-kubernetes-group-version-kind", "const"):
                out[k] = v
            else:
                out[k] = trim(v)
        return out
    if isinstance(node, list):
        return [trim(x) for x in node]
    return node


def refs(node, acc):
    if isinstance(node, dict):
        r = node.get("$ref")
        if isinstance(r, str):
            acc.add(r.rsplit("/", 1)[-1])
        for v in node.values():
            refs(v, acc)
    elif isinstance(node, list):
        for v in node:
            refs(v, acc)


def reachable(schemas):
    roots = [name for name, s in schemas.items()
             if any(g.get("kind") not in SKIP_KINDS and not g.get("kind", "").endswith("List") for g in s.get("x-kubernetes-group-version-kind", []))]
    seen, todo = set(), list(roots)
    while todo:
        name = todo.pop()
        if name in seen or name not in schemas:
            continue
        seen.add(name)
        found = set()
        refs(schemas[name], found)
        todo.extend(found)
    return seen


def main():
    minor, src, dest = sys.argv[1:4]
    groups = {}
    for stem, gv in GROUP_VERSIONS.items():
        path = os.path.join(src, stem + ".json")
        if not os.path.exists(path):
            continue
        schemas = json.load(open(path))["components"]["schemas"]
        keep = reachable(schemas)
        groups[gv] = {"components": {"schemas": {n: trim(schemas[n]) for n in sorted(keep)}}}
    payload = json.dumps({"minor": minor, "groupVersions": groups}, separators=(",", ":"), sort_keys=True).encode()
    with tempfile.NamedTemporaryFile(suffix=".json") as tmp:
        tmp.write(payload)
        tmp.flush()
        subprocess.run(["compression_tool", "-encode", "-a", "lzfse", "-i", tmp.name, "-o", dest], check=True)
    print("%s: %d bytes JSON, %d bytes compressed" % (dest, len(payload), os.path.getsize(dest)))


if __name__ == "__main__":
    main()
