#!/bin/bash
# Fetches and verifies the bundled Helm 4 (ARCHITECTURE-MAC section 2.4).
#
#   scripts/fetch-helm.sh                download helm-v<VERSION>-darwin-arm64.tar.gz from https://get.helm.sh into Vendor/helm/
#   scripts/fetch-helm.sh --verify-only  check that Vendor/helm/bin/helm exists and matches Vendor/helm/SHA256SUMS (the
#                                        Release and Distribution pre-build check; Debug and Profile skip it)
#   scripts/fetch-helm.sh --print-sha <version>   print the release's published SHA-256 (copy it into SHA256SUMS after checking
#                                        the release signature; the maintainer does this when the version is bumped)
#
# Vendor/helm/VERSION (for example `4.0.0`) and Vendor/helm/SHA256SUMS (`<sha256>  helm-v<version>-darwin-arm64.tar.gz` and
# `<sha256>  bin/helm`) are committed by M2; Vendor/helm/bin/ and the archive are git-ignored.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
DIR="$REPO/Vendor/helm"
BIN="$DIR/bin/helm"

sha256() { shasum -a 256 "$1" | awk '{print $1}'; }
expected() { awk -v f="$1" '$2 == f { print $1 }' "$DIR/SHA256SUMS" 2>/dev/null; }

case "${1:-}" in
  --verify-only)
    [ -f "$DIR/SHA256SUMS" ] || { echo "error: Vendor/helm/SHA256SUMS is missing (added by M2). Release builds need the bundled helm." >&2; exit 1; }
    [ -f "$BIN" ] || { echo "error: Vendor/helm/bin/helm is missing. Run scripts/fetch-helm.sh." >&2; exit 1; }
    want="$(expected bin/helm)"
    [ -n "$want" ] || { echo "error: SHA256SUMS has no entry for bin/helm" >&2; exit 1; }
    got="$(sha256 "$BIN")"
    [ "$got" = "$want" ] || { echo "error: bundled helm checksum differs (got $got, want $want)" >&2; exit 1; }
    echo "bundled helm verified"
    exit 0 ;;
  --print-sha)
    v="${2:?usage: --print-sha <version>}"
    curl -fsSL "https://get.helm.sh/helm-v$v-darwin-arm64.tar.gz.sha256sum"
    exit 0 ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

[ -f "$DIR/VERSION" ] && [ -f "$DIR/SHA256SUMS" ] || { echo "error: Vendor/helm/VERSION and SHA256SUMS are missing (added by M2)." >&2; exit 1; }
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
ARCHIVE="helm-v$VERSION-darwin-arm64.tar.gz"
want_archive="$(expected "$ARCHIVE")"
[ -n "$want_archive" ] || { echo "error: SHA256SUMS has no entry for $ARCHIVE" >&2; exit 1; }

mkdir -p "$DIR/bin"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
curl -fsSL -o "$TMP/$ARCHIVE" "https://get.helm.sh/$ARCHIVE"
got_archive="$(sha256 "$TMP/$ARCHIVE")"
[ "$got_archive" = "$want_archive" ] || { echo "error: $ARCHIVE checksum differs (got $got_archive)" >&2; exit 1; }
tar -xzf "$TMP/$ARCHIVE" -C "$TMP"
install -m 0755 "$TMP/darwin-arm64/helm" "$BIN"
"$0" --verify-only
