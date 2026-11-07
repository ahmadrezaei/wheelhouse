#!/bin/bash
# Compile-time proof that the toolbox has no mutating API (ARCHITECTURE-MAC section 9.2, milestone M11a).
#
# Builds WheelhouseKit, then type-checks small programs against it:
#   - the read-only calls MUST compile (so a failure below is not just a broken setup);
#   - every attempt to mutate through ClusterToolbox, ReadOnlyKubeAccess, ProposalTools or ProposalCoordinator, or to use
#     them as a KubeClientProtocol, MUST be rejected by the compiler with a "no member" / "cannot convert" error.
# Exits non-zero on any surprise.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO/Packages/WheelhouseKit"

swift build --product WheelhouseKit >/dev/null 2>&1 || { echo "check-toolbox-readonly: WheelhouseKit failed to build" >&2; exit 1; }
BIN="$(swift build --show-bin-path)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/toolbox-readonly.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

CYAML="$PWD/.build/checkouts/Yams/Sources/CYaml/include"
typecheck() {
    swiftc -typecheck -swift-version 6 -I "$BIN" -F "$BIN/PackageFrameworks" \
        -Xcc "-fmodule-map-file=$CYAML/module.modulemap" -Xcc "-I$CYAML" "$1" 2>&1
}

cat > "$WORK/ok.swift" <<'EOF'
import WheelhouseKit
func ok(_ toolbox: ClusterToolbox, _ access: ReadOnlyKubeAccess, _ proposals: ProposalTools, _ coordinator: ProposalCoordinator) async throws {
    _ = await toolbox.call(.listClusters, input: [:])
    _ = try await access.listRaw(.pod, nil, ListOptions())
    _ = try await access.getRaw(.pod, "x", "y")
    _ = proposals.tools
    _ = await coordinator.proposals
}
EOF
if ! out="$(typecheck "$WORK/ok.swift")"; then
    echo "check-toolbox-readonly: the read-only program did not compile (setup problem):" >&2
    echo "$out" >&2
    exit 1
fi

fail=0
# reject <name> <body> <expected error regex>
# Member probes use unapplied references (`_ = toolbox.patch`), so the only possible reason to fail is that the member does not
# exist. Conversion probes must fail because the type is not a KubeClientProtocol.
reject() {
    local name="$1" body="$2" expect="$3" file="$WORK/$1.swift"
    printf 'import WheelhouseKit\nimport Foundation\nfunc probe(_ toolbox: ClusterToolbox, _ access: ReadOnlyKubeAccess, _ proposals: ProposalTools, _ coordinator: ProposalCoordinator) async {\n%s\n}\n' "$body" > "$file"
    if out="$(typecheck "$file")"; then
        echo "FAIL $name: compiled, but must be rejected" >&2
        fail=1
    elif ! grep -Eq "$expect" <<<"$out"; then
        echo "FAIL $name: rejected for an unexpected reason (wanted /$expect/):" >&2
        echo "$out" | head -5 >&2
        fail=1
    else
        echo "ok   $name is rejected"
    fi
}

MEMBER='has no member'
CONVERT='cannot convert|does not conform'
for member in patch create replace delete scale restartRollout evict execWebSocket portForwardWebSocket proxyRequest proxyGET portForward; do
    reject "toolbox-$member"   "_ = toolbox.$member"   "$MEMBER"
    reject "access-$member"    "_ = access.$member"    "$MEMBER"
    reject "proposals-$member" "_ = proposals.$member" "$MEMBER"
done
for member in apply execute run send submitToCluster; do
    reject "coordinator-$member" "_ = coordinator.$member" "$MEMBER"
done
reject toolbox-as-client   'let _: any KubeClientProtocol = toolbox'   "$CONVERT"
reject access-as-client    'let _: any KubeClientProtocol = access'    "$CONVERT"
reject proposals-as-client 'let _: any KubeClientProtocol = proposals' "$CONVERT"
reject coordinator-as-client 'let _: any KubeClientProtocol = coordinator' "$CONVERT"
# The closure initialiser is internal: the app cannot build an access from arbitrary closures.
reject access-closure-init '_ = ReadOnlyKubeAccess(listRaw: { _, _, _ in [:] })' 'extraneous argument label|inaccessible'

exit $fail
