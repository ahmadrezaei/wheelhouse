#!/bin/bash
# Downloads official kubectl releases for the Gangway live matrix (ARCHITECTURE-MAC section 15.1, M5a) into .build/kubectl/<version>/.
#
#   scripts/fetch-kubectl-matrix.sh v1.30.14 v1.31.14 ...
#
# Source: https://dl.k8s.io/release/<version>/bin/darwin/arm64/kubectl ONLY, over HTTPS (no downgrade, no redirect to another scheme).
# Each binary must match the sha256 PINNED in scripts/kubectl-matrix.sha256 (a version that is not listed there is refused: add it with a
# reviewed value) and dl.k8s.io's own .sha256. Nothing is put on PATH or outside the repository's .build folder (git-ignored).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
PINS="$REPO/scripts/kubectl-matrix.sha256"
[ $# -gt 0 ] || { echo "usage: $0 v1.30.14 ..." >&2; exit 2; }
for v in "$@"; do
  printf '%s' "$v" | grep -Eq '^v1\.[0-9]{2}\.[0-9]{1,2}$' || { echo "bad version: $v" >&2; exit 2; }
  pinned="$(grep -E "^$v " "$PINS" | cut -d' ' -f2 || true)"
  [ -n "$pinned" ] || { echo "no pinned checksum for $v in scripts/kubectl-matrix.sha256" >&2; exit 2; }
  dir="$REPO/.build/kubectl/$v"
  if [ -x "$dir/kubectl" ] && [ "$(shasum -a 256 "$dir/kubectl" | cut -d' ' -f1)" = "$pinned" ]; then echo "have $v"; continue; fi
  mkdir -p "$dir"
  base="https://dl.k8s.io/release/$v/bin/darwin/arm64/kubectl"
  curl -fsSL --proto '=https' --proto-redir '=https' -o "$dir/kubectl.download" "$base"
  want="$(curl -fsSL --proto '=https' --proto-redir '=https' "$base.sha256" | tr -d '[:space:]')"
  got="$(shasum -a 256 "$dir/kubectl.download" | cut -d' ' -f1)"
  if [ "$want" != "$got" ] || [ "$pinned" != "$got" ]; then rm -f "$dir/kubectl.download"; echo "CHECKSUM MISMATCH for $v (dl.k8s.io $want, pinned $pinned, got $got)" >&2; exit 1; fi
  mv "$dir/kubectl.download" "$dir/kubectl"
  chmod 755 "$dir/kubectl"
  echo "ok   $v  sha256 $got"
done
