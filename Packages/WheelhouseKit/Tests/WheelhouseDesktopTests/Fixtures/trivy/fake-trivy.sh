#!/bin/sh
# A fake trivy for tests: replays Fixtures/trivy/image-report.json (next to this script) and records what it was given.
# Behaviour by image name: "unauth" fails like a registry that refuses the pull; "slow" waits; "broken" prints text, not JSON;
# "nojar" replays the report without its JAR result; "jarapp" needs the Java DB (fails with trivy's first-run message until --download-java-db-only has run).
# A file named java-download-fails in the cache makes the Java DB download fail with a ghcr 401.
# A file named java-download-noop makes it succeed without touching the Java DB metadata (trivy before its next update time).
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
  if [ "$a" = "--download-java-db-only" ]; then
    if [ -f "$cache/java-download-fails" ]; then
      echo "FATAL failed to download java DB: GET https://ghcr.io/v2/aquasecurity/trivy-java-db/manifests/1: 401 Unauthorized" >&2
      exit 1
    fi
    [ -f "$cache/java-download-noop" ] && exit 0
    mkdir -p "$cache/java-db"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"Version":1,"NextUpdate":"%s","UpdatedAt":"%s","DownloadedAt":"%s"}' "$now" "$now" "$now" > "$cache/java-db/metadata.json"
    exit 0
  fi
  if [ "$a" = "--download-db-only" ]; then
    mkdir -p "$cache/db"
    now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf '{"Version":2,"NextUpdate":"%s","UpdatedAt":"%s","DownloadedAt":"%s"}' "$now" "$now" "$now" > "$cache/db/metadata.json"
    exit 0
  fi
done
case "$last" in
  *nojar*) grep -v "app.jar" "$here/image-report.json"; exit 0 ;;
  *unauth*) echo "FATAL image scan error: UNAUTHORIZED: authentication required" >&2; exit 1 ;;
  *slow*) sleep 30; exit 0 ;;
  *broken*) echo "not json"; exit 0 ;;
  *jarapp*)
    if [ ! -f "$cache/java-db/metadata.json" ]; then
      echo "FATAL --skip-java-db-update cannot be specified with the first run" >&2
      exit 1
    fi ;;
esac
cat "$here/image-report.json"
