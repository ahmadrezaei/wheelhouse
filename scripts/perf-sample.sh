#!/bin/bash
# Idle and soak sampler (ARCHITECTURE-MAC section 12.3.5).
#
#   scripts/perf-sample.sh --scenario <name> --minutes <m> [--hide-after <s>] [--settle <s>] [--app <path>] [--build]
#                          [--leaks] [--record <baseline.json>] [--key <name>] [--app-arg <launch argument>]...
#
# Launches the PROFILE app (Debug identity, safety gate on) with `-WHPerfScenario <name>`, waits for it to settle (60 s by
# default), samples `top -l N -s 10 -pid <pid> -stats pid,cpu,idlew,power,threads` continuously and, every minute,
# `footprint -p <pid>` (fallback `vmmap --summary`) and `lsof -p <pid> | wc -l`. Writes `.build/perf/<scenario>-<date>.csv` and a
# summary `.json`, compares the summary with perf/budgets.json (scripts/perf-check.sh) and exits non-zero on any breach.
#
# Caveats: `energyImpact` is top's POWER column and tracks CPU% (informational, see perf/budgets.json); IDLEW undercounts
# wakeups, so `idleWakeupsPerSec` is a lower bound. The derived data defaults to ~/Library/Caches/wheelhouse-perf (WH_PERF_DERIVED_DATA).
#
# SAFETY: refuses any app that is not a dev-safe build (bundle ID ending .debug and WHDevSafety = YES) and always points the app
# at the performance kubeconfig under .testcluster/. It never reads ~/.kube and never touches the default kubeconfig.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
SCENARIO="" ; MINUTES=5 ; HIDE_AFTER="" ; SETTLE=60 ; APP="" ; BUILD=0 ; LEAKS=0 ; RECORD="" ; KEY="" ; APP_ARGS=()

usage() { sed -n '2,15p' "$0"; exit 2; }
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
    -h|--help) usage ;;
    *) echo "unknown option: $1" >&2; usage ;;
  esac
done
[ -n "$SCENARIO" ] || usage
[ -f "$REPO/perf/scenarios/$SCENARIO.json" ] || { echo "no such scenario: perf/scenarios/$SCENARIO.json" >&2; exit 2; }

DD="${WH_PERF_DERIVED_DATA:-$HOME/Library/Caches/wheelhouse-perf/dd}"   # outside ~/Documents (a synced, indexed folder)
if [ -z "$APP" ]; then
  APP="$DD/Build/Products/Profile/Wheelhouse.app"
  if [ "$BUILD" = 1 ] || [ ! -d "$APP" ]; then
    echo "Building the Profile configuration into $DD ..."
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

# Never start a second instance on top of a running one: the pid would be ambiguous.
if pgrep -f "^$EXE" >/dev/null 2>&1; then echo "refusing: $EXE is already running; quit it first" >&2; exit 3; fi

ARGS=(-WHPerfScenario "$SCENARIO" -WHKubeconfigPath "$REPO/.testcluster/perf-kubeconfig")
[ -n "$HIDE_AFTER" ] && ARGS+=(-WHPerfHideAfter "$HIDE_AFTER")
ARGS+=("${APP_ARGS[@]+"${APP_ARGS[@]}"}")
open -n -a "$APP" --args "${ARGS[@]}"

PID=""
for _ in $(seq 1 50); do
  PID="$(pgrep -n -f "^$EXE" || true)"; [ -n "$PID" ] && break; sleep 0.2
done
[ -n "$PID" ] || { echo "the app did not start" >&2; exit 1; }
echo "pid $PID, scenario $SCENARIO, settling ${SETTLE}s ..."

cleanup() { kill "$PID" 2>/dev/null || true; [ -n "${TOP_PID:-}" ] && kill "$TOP_PID" 2>/dev/null || true; }
trap cleanup EXIT

sleep "$SETTLE"
kill -0 "$PID" 2>/dev/null || { echo "the app exited during settle" >&2; exit 1; }

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

echo "minute,footprintMB,fds,threads" >"$CSV"
for m in $(seq 0 $(( MINUTES - 1 ))); do
  kill -0 "$PID" 2>/dev/null || { echo "the app exited while sampling" >&2; break; }
  FP="$(fp_mb)"; FDS="$(lsof -p "$PID" 2>/dev/null | wc -l | tr -d ' ')"
  TH="$(top -l 1 -pid "$PID" -stats pid,threads 2>/dev/null | awk -v p="$PID" '$1==p {print $2}' | tail -1)"
  echo "$m,${FP:-0},${FDS:-0},${TH:-0}" >>"$CSV"
  sleep 60
done
wait "$TOP_PID" 2>/dev/null || true

LEAK_COUNT=""
if [ "$LEAKS" = 1 ] && kill -0 "$PID" 2>/dev/null; then
  LEAK_COUNT="$(leaks "$PID" 2>/dev/null | awk '/leaks for/ { print $3; exit }' || true)"
fi

python3 - "$SCENARIO" "$TOPOUT" "$CSV" "$SUMMARY" "$PID" "$INTERVAL" "${LEAK_COUNT:-}" "$BID" <<'PY'
import sys, json, re, datetime
scenario, topout, csvf, summary, pid, interval, leaks, bid = sys.argv[1:9]
interval = float(interval)
rows = []
for line in open(topout, errors='replace'):
    p = line.split()
    if len(p) >= 5 and p[0] == pid:
        num = lambda s: float(re.sub(r'[+\-]$', '', s))
        rows.append((num(p[1]), num(p[2]), num(p[3]), int(num(re.sub(r'/.*$', '', p[4])))))   # top prints threads as "12/1" while some run
rows = rows[1:]                                    # discard the since-launch sample
cpu = [r[0] for r in rows]; idlew = [r[1] for r in rows]; power = [r[2] for r in rows]
foot = []; fds = []; thr = []
for line in list(open(csvf))[1:]:
    p = line.strip().split(',')
    foot.append(float(p[1])); fds.append(int(p[2])); thr.append(int(re.sub(r'/.*$', '', p[3])))
out = {"scenario": scenario, "bundleID": bid, "date": datetime.datetime.now().isoformat(timespec='seconds'),
       "samples": len(rows), "intervalSec": interval}
if rows:
    out["cpuAvgPct"] = round(sum(cpu) / len(cpu), 3)
    out["cpuMaxSamplePct"] = round(max(cpu), 3)
    span = interval * (len(rows) - 1)
    out["idleWakeupsPerSec"] = round((idlew[-1] - idlew[0]) / span, 3) if span > 0 else 0.0
    out["energyImpact"] = round(sum(power) / len(power), 3)
    out["threads"] = rows[-1][3]
if foot:
    # Soak budgets: growth from minute 10 to the last minute, threads and open files against the first sample.
    out["footprintGrowthMB"] = round(foot[-1] - foot[min(10, len(foot) - 1)], 1)
    out["threadsOverBaseline"] = thr[-1] - thr[0]
    out["fdsOverBaseline"] = fds[-1] - fds[0]
    out["footprintMB"] = round(max(foot), 1)
    out["footprintFirstMB"] = foot[0]; out["footprintLastMB"] = foot[-1]
    out["fds"] = fds[-1]
if leaks != "": out["leaks"] = int(leaks)
json.dump(out, open(summary, "w"), indent=2); open(summary, "a").write("\n")
print(json.dumps(out, indent=2))
PY

CHECK=(--result "$SUMMARY" --scenario "$SCENARIO")
[ -n "$RECORD" ] && CHECK+=(--record "$RECORD" --key "${KEY:-$SCENARIO}")
"$REPO/scripts/perf-check.sh" "${CHECK[@]}"
