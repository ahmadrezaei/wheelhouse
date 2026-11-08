#!/bin/bash
# Idle and soak sampler (ARCHITECTURE-MAC section 12.3.5).
#
#   scripts/perf-sample.sh --scenario <name> --minutes <m> [--hide-after <s>] [--settle <s>] [--app <path>] [--build]
#                          [--leaks] [--record <baseline.json>] [--key <name>] [--app-arg <launch argument>]...
#                          [--no-keep-visible] [--no-connection-check]
#   scripts/perf-sample.sh --self-test
#
# Launches the PROFILE app (Debug identity, safety gate on) with `-WHPerfScenario <name>`, waits for it to settle (60 s by
# default), samples `top -l N -s 10 -pid <pid> -stats pid,cpu,idlew,power,threads` continuously and, every minute (on a fixed
# schedule), `footprint -p <pid>` (fallback `vmmap --summary`), `lsof -p <pid> | wc -l`, the ESTABLISHED connections to the test
# cluster and whether a workspace window is visible. Writes `.build/perf/<scenario>-<date>.csv` and a summary `.json`
# (scripts/perf-summary.py), compares the summary with perf/budgets.json (scripts/perf-check.sh) and exits non-zero on any breach.
#
# A run only counts when it measured what it claims (exit 4 otherwise):
#   - connected: after the settle period the app holds an ESTABLISHED TCP connection to the server host:port of the perf kubeconfig
#     (`lsof -nP -a -p PID -iTCP -sTCP:ESTABLISHED`), and keeps one in at least 90 % of the minute samples. Scenarios that close
#     their windows (`hideWindowsAfterSeconds`) must have been connected at some point during the settle period instead, since their
#     stores stop once hidden. Earlier runs "passed" against a test cluster that had moved to another port.
#   - visible: a scenario that keeps its window must have it visible in every minute sample, and a hidden scenario must not. The
#     app publishes its own verdict (the energy coordinator's, occlusion included) as the state of the Darwin notification
#     `com.ahmadrezaei.wheelhouse.perf.windows-visible` (development builds only), read with `notifyutil -g`. Visible scenarios start
#     with `-WHPerfKeepVisible` (the window floats on every Space, so a full-screen app elsewhere cannot cover it); `--no-keep-visible`
#     turns that off. The sampler holds `caffeinate -dis -w <pid>` so the display does not sleep during the run.
#
# Caveats: `energyImpact` is top's POWER column and tracks CPU% (informational, see perf/budgets.json); IDLEW undercounts
# wakeups, so `idleWakeupsPerSec` is a lower bound. The derived data defaults to ~/Library/Caches/wheelhouse-perf (WH_PERF_DERIVED_DATA).
#
# SAFETY: refuses any app that is not a dev-safe build (bundle ID ending .debug and WHDevSafety = YES) and always points the app
# at the performance kubeconfig under .testcluster/. It never reads ~/.kube and never touches the default kubeconfig.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="" ; MINUTES=5 ; HIDE_AFTER="" ; SETTLE=60 ; APP="" ; BUILD=0 ; LEAKS=0 ; RECORD="" ; KEY="" ; APP_ARGS=()
KEEP_VISIBLE=1 ; CONNECTION_CHECK=1
VISIBILITY_NOTE="com.ahmadrezaei.wheelhouse.perf.windows-visible"

usage() { sed -n '2,33p' "$0"; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --scenario) SCENARIO="$2"; shift 2 ;;
    --minutes) MINUTES="$2"; shift 2 ;;
    --hide-after) HIDE_AFTER="$2"; shift 2 ;;
    --settle) SETTLE="$2"; shift 2 ;;
    --app) APP="$2"; shift 2 ;;
    --build) BUILD=1; shift ;;
    --leaks) LEAKS=1; shift ;;
    --record) RECORD="$2"; shift 2 ;;
    --key) KEY="$2"; shift 2 ;;
    --app-arg) APP_ARGS+=("$2"); shift 2 ;;
    --no-keep-visible) KEEP_VISIBLE=0; shift ;;
    --no-connection-check) CONNECTION_CHECK=0; shift ;;
    --self-test) exec python3 -I "$REPO/scripts/perf-summary.py" self-test ;;
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
[ -n "$SCENARIO" ] || usage
SCENARIO_FILE="$REPO/perf/scenarios/$SCENARIO.json"
[ -f "$SCENARIO_FILE" ] || { echo "no such scenario: perf/scenarios/$SCENARIO.json" >&2; exit 2; }
KUBECONFIG_FILE="$REPO/.testcluster/perf-kubeconfig"
[ -f "$KUBECONFIG_FILE" ] || { echo "no performance kubeconfig: run scripts/testcluster-fixtures.sh --perf" >&2; exit 2; }

# From the scenario: does it hide its windows, and how long is its navigation cycle.
read -r HIDES CYCLE < <(python3 -I -c 'import json,sys; s=json.load(open(sys.argv[1])); print("1" if s.get("hideWindowsAfterSeconds") is not None else "0", s.get("cycleSeconds", 300))' "$SCENARIO_FILE")
[ -n "$HIDE_AFTER" ] && HIDES=1
# host:port of every server in the perf kubeconfig (127.0.0.1:52192 style), as lsof prints them.
SERVERS="$(python3 -I -c '
import re, sys, urllib.parse
for line in open(sys.argv[1]):
    m = re.match(r"\s*server:\s*[\x22\x27]?([^\s\x22\x27]+)", line)
    if m:
        u = urllib.parse.urlparse(m.group(1))
        print("%s:%d" % (u.hostname, u.port or (443 if u.scheme == "https" else 80)))
' "$KUBECONFIG_FILE" | sort -u | tr '\n' ' ')"
[ -n "$SERVERS" ] || { echo "no server in $KUBECONFIG_FILE" >&2; exit 2; }

DD="${WH_PERF_DERIVED_DATA:-$HOME/Library/Caches/wheelhouse-perf/dd}"   # outside ~/Documents (a synced, indexed folder)
if [ -z "$APP" ]; then
  APP="$DD/Build/Products/Profile/Wheelhouse.app"
  if [ "$BUILD" = 1 ] || [ ! -d "$APP" ]; then
    echo "Building the Profile configuration into $DD ..."
    mkdir -p "$REPO/.build/perf"
    ( cd "$REPO" && xcodebuild -project Wheelhouse.xcodeproj -scheme WheelhouseMac -configuration Profile \
        -destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" build >"$REPO/.build/perf/build.log" 2>&1 ) \
      || { echo "build failed; see .build/perf/build.log" >&2; exit 1; }
  fi
fi
[ -d "$APP" ] || { echo "app not found: $APP" >&2; exit 2; }

PLIST="$APP/Contents/Info.plist"
BID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")"
GATE="$(/usr/libexec/PlistBuddy -c 'Print :WHDevSafety' "$PLIST" 2>/dev/null || echo MISSING)"
case "$BID" in *.debug) ;; *) echo "refusing: $BID is not a Debug/Profile identity build" >&2; exit 3 ;; esac
[ "$GATE" = "YES" ] || { echo "refusing: WHDevSafety is '$GATE' (must be YES)" >&2; exit 3 ;}

mkdir -p "$REPO/.build/perf"
DATE="$(date +%Y%m%d-%H%M%S)"
CSV="$REPO/.build/perf/$SCENARIO-$DATE.csv"
TOPOUT="$REPO/.build/perf/$SCENARIO-$DATE.top.txt"
SUMMARY="$REPO/.build/perf/$SCENARIO-$DATE.json"
EXE="$APP/Contents/MacOS/Wheelhouse"

# Never start a second instance on top of a running one: the pid would be ambiguous (and a second instance of the same bundle ID
# hangs Mac test hosts).
# A stopped instance (state T, e.g. left behind by a debugger or an aborted `xctrace --launch`) does no work and is only reported.
for other in $(pgrep -f 'Wheelhouse[.]app/Contents/MacOS/Wheelhouse' || true); do
  case "$(ps -o stat= -p "$other" 2>/dev/null)" in
    T*) echo "note: ignoring stopped Wheelhouse instance $other" >&2 ;;
    "") ;;
    *) echo "refusing: a Wheelhouse instance is already running (pid $other); quit it first" >&2; exit 3 ;;
  esac
done

KEEPS=0
[ "$KEEP_VISIBLE" = 1 ] && [ "$HIDES" = 0 ] && KEEPS=1
ARGS=(-ApplePersistenceIgnoreState YES -WHPerfScenario "$SCENARIO" -WHKubeconfigPath "$KUBECONFIG_FILE")
[ -n "$HIDE_AFTER" ] && ARGS+=(-WHPerfHideAfter "$HIDE_AFTER")
[ "$KEEPS" = 1 ] && ARGS+=(-WHPerfKeepVisible)
ARGS+=("${APP_ARGS[@]+"${APP_ARGS[@]}"}")
open -n -a "$APP" --args "${ARGS[@]}"

PID=""
for _ in $(seq 1 50); do
  PID="$(pgrep -n -f "^$EXE" || true)"; [ -n "$PID" ] && break; sleep 0.2
done
[ -n "$PID" ] || { echo "the app did not start" >&2; exit 1; }
echo "pid $PID, scenario $SCENARIO, servers $SERVERS, keep visible $KEEPS, settling ${SETTLE}s ..."

cleanup() {
  kill "$PID" 2>/dev/null || true
  [ -n "${TOP_PID:-}" ] && kill "$TOP_PID" 2>/dev/null || true
  [ -n "${CAF_PID:-}" ] && kill "$CAF_PID" 2>/dev/null || true
}
trap cleanup EXIT
caffeinate -dis -w "$PID" & CAF_PID=$!

# ESTABLISHED TCP connections from the app to any server of the perf kubeconfig.
established() {
  local n=0 s
  local out; out="$(lsof -nP -a -p "$PID" -iTCP -sTCP:ESTABLISHED 2>/dev/null || true)"
  for s in $SERVERS; do n=$(( n + $(printf '%s\n' "$out" | grep -c -- "->$s " || true) )); done
  echo "$n"
}
visible_state() { notifyutil -g "$VISIBILITY_NOTE" 2>/dev/null | awk '{ print $2 }'; }

SEEN=0
SETTLE_END=$(( $(date +%s) + SETTLE ))
while [ "$(date +%s)" -lt "$SETTLE_END" ]; do
  kill -0 "$PID" 2>/dev/null || { echo "the app exited during settle" >&2; exit 1; }
  [ "$(established)" -gt 0 ] && SEEN=1
  sleep 2
done
NOW_CONNECTED="$(established)"
if [ "$CONNECTION_CHECK" = 1 ]; then
  if [ "$HIDES" = 0 ] && [ "$NOW_CONNECTED" -eq 0 ]; then
    echo "INVALID: after ${SETTLE}s the app has no ESTABLISHED connection to $SERVERS (test cluster down or moved? check .testcluster/perf-kubeconfig)" >&2; exit 4
  fi
  if [ "$HIDES" = 1 ] && [ "$SEEN" = 0 ]; then
    echo "INVALID: the app never connected to $SERVERS during the ${SETTLE}s settle period" >&2; exit 4
  fi
fi

INTERVAL=10
SAMPLES=$(( MINUTES * 60 / INTERVAL + 1 ))      # the first top sample is since process start and is discarded
top -l "$SAMPLES" -s "$INTERVAL" -pid "$PID" -stats pid,cpu,idlew,power,threads >"$TOPOUT" 2>&1 &
TOP_PID=$!

fp_mb() {
  local out; out="$(footprint -p "$PID" 2>/dev/null | grep -m1 'Footprint:' || true)"
  if [ -n "$out" ]; then
    echo "$out" | sed -E 's/.*Footprint: ([0-9.]+) (KB|MB|GB).*/\1 \2/' | awk '{ v=$1; if ($2=="KB") v/=1024; else if ($2=="GB") v*=1024; printf "%.1f", v }'
  else
    vmmap --summary "$PID" 2>/dev/null | awk '/Physical footprint:/ { v=$3; u=$3; gsub(/[0-9.]/,"",u); gsub(/[A-Za-z]/,"",v); if (u=="K") v/=1024; else if (u=="G") v*=1024; printf "%.1f", v; exit }'
  fi
}

# One row per minute on a fixed schedule (deadline-based, so the samples do not drift by the time the probes take).
echo "t,minute,footprintMB,fds,threads,established,visible" >"$CSV"
T0="$(date +%s)"
for m in $(seq 0 $(( MINUTES - 1 ))); do
  kill -0 "$PID" 2>/dev/null || { echo "the app exited while sampling" >&2; break; }
  FP="$(fp_mb)"; FDS="$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')"
  TH="$(top -l 1 -pid "$PID" -stats pid,threads 2>/dev/null | awk -v p="$PID" '$1==p {print $2}' | tail -1)"
  echo "$(( $(date +%s) - T0 )),$m,${FP:-0},${FDS:-0},${TH:-0},$(established),$(visible_state)" >>"$CSV"
  NEXT=$(( T0 + (m + 1) * 60 ))
  while [ "$(date +%s)" -lt "$NEXT" ]; do sleep 1; done
done
wait "$TOP_PID" 2>/dev/null || true

LEAK_COUNT=""
if [ "$LEAKS" = 1 ] && kill -0 "$PID" 2>/dev/null; then
  LEAK_COUNT="$(leaks "$PID" 2>/dev/null | awk '/leaks for/ { print $3; exit }' || true)"
fi

python3 -I "$REPO/scripts/perf-summary.py" summarize --scenario "$SCENARIO" --top "$TOPOUT" --csv "$CSV" --out "$SUMMARY" --pid "$PID" \
  --interval "$INTERVAL" --bundle-id "$BID" --leaks "${LEAK_COUNT:-}" --cycle-seconds "$CYCLE" \
  --extra "keepVisible=$([ "$KEEPS" = 1 ] && echo true || echo false)" --extra "connectedAfterSettle=$NOW_CONNECTED"

# Validity over the whole run (see the header).
python3 -I - "$SUMMARY" "$HIDES" "$CONNECTION_CHECK" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); hides = sys.argv[2] == "1"; check = sys.argv[3] == "1"
problems = []
vis = s.get("windowVisibleMinutesPct")
if vis is None or s.get("windowVisibilityUnknownMinutes", 0) > 0: problems.append("the app did not publish its window visibility in every minute (is it a development build of this version?)")
elif not hides and vis < 100: problems.append(f"the window was visible in only {vis} % of the minute samples")
elif hides and vis > 0: problems.append(f"a hidden scenario had a visible window in {vis} % of the minute samples")
if check and not hides and s.get("connectedMinutesPct", 0) < 90: problems.append(f"connected to the test cluster in only {s.get('connectedMinutesPct')} % of the minute samples")
for p in problems: print("INVALID: " + p, file=sys.stderr)
sys.exit(4 if problems else 0)
PY

CHECK=(--result "$SUMMARY" --scenario "$SCENARIO")
[ -n "$RECORD" ] && CHECK+=(--record "$RECORD" --key "${KEY:-$SCENARIO}")
"$REPO/scripts/perf-check.sh" "${CHECK[@]}"
