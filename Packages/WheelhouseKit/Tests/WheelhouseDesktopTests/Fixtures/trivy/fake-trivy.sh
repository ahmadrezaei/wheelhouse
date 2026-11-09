#!/bin/sh
# A fake trivy for tests: replays Fixtures/trivy/image-report.json (next to this script) and records what it was given.
# Behaviour by image name: "unauth" fails like a registry that refuses the pull; "slow" waits; "broken" prints text, not JSON.
here="$(cd "$(dirname "$0")" && pwd)"
cache=""
prev=""
for a in "$@"; do
  [ "$prev" = "--cache-dir" ] && cache="$a"
  prev="$a"
  last="$a"
done
log="${cache:-$here}/fake-trivy.log"
case "$1" in
  --version) echo "Version: 0.99.0"; exit 0 ;;
esac
echo "ARGS $*" >> "$log"
echo "DOCKER_CONFIG=${DOCKER_CONFIG-}" >> "$log"
if [ -n "${DOCKER_CONFIG-}" ] && [ -f "$DOCKER_CONFIG/config.json" ]; then
  echo "DIRMODE $(stat -f %Lp "$DOCKER_CONFIG")" >> "$log"
  echo "FILEMODE $(stat -f %Lp "$DOCKER_CONFIG/config.json")" >> "$log"
  echo "CONFIG $(tr -d '\n ' < "$DOCKER_CONFIG/config.json")" >> "$log"
fi
echo "ENV $(env | sort | tr '\n' ' ')" >> "$log"
for a in "$@"; do
  if [ "$a" = "--download-db-only" ]; then
    mkdir -p "$cache/db"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"Version":2,"NextUpdate":"%s","UpdatedAt":"%s","DownloadedAt":"%s"}' "$now" "$now" "$now" > "$cache/db/metadata.json"
    exit 0
  fi
done
case "$last" in
  *unauth*) echo "FATAL image scan error: UNAUTHORIZED: authentication required" >&2; exit 1 ;;
  *slow*) sleep 30; exit 0 ;;
  *broken*) echo "not json"; exit 0 ;;
esac
cat "$here/image-report.json"
