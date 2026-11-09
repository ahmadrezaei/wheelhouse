#!/bin/bash
# Downloads official kubectl releases for the Gangway live matrix (ARCHITECTURE-MAC section 15.1, M5a) into .build/kubectl/<version>/.
#
#   scripts/fetch-kubectl-matrix.sh v1.30.14 v1.31.14 ...
#
# Source: https://dl.k8s.io/release/<version>/bin/darwin/arm64/kubectl ONLY. Each binary is verified against the matching .sha256 from the
# same host before it is made executable. Nothing is put on PATH or outside the repository's .build folder (git-ignored).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
[ $# -gt 0 ] || { echo "usage: $0 v1.30.14 ..." >&2; exit 2; }
for v in "$@"; do
  case "$v" in v1.[0-9][0-9].[0-9]*) ;; *) echo "bad version: $v" >&2; exit 2 ;; esac
  dir="$REPO/.build/kubectl/$v"
  if [ -x "$dir/kubectl" ]; then echo "have $v"; continue; fi
  mkdir -p "$dir"
  base="https://dl.k8s.io/release/$v/bin/darwin/arm64/kubectl"
  curl -fsSL -o "$dir/kubectl.download" "$base"
  want="$(curl -fsSL "$base.sha256" | tr -d '[:space:]')"
  got="$(shasum -a 256 "$dir/kubectl.download" | cut -d' ' -f1)"
  if [ "$want" != "$got" ]; then rm -f "$dir/kubectl.download"; echo "CHECKSUM MISMATCH for $v" >&2; exit 1; fi
  mv "$dir/kubectl.download" "$dir/kubectl"
  chmod 755 "$dir/kubectl"
  echo "ok   $v  sha256 $got"
done
