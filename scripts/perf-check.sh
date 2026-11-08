#!/bin/bash
# Compares performance results with perf/budgets.json and the previous baseline (ARCHITECTURE-MAC section 12.3.5).
#
#   scripts/perf-check.sh --result <summary.json> [--scenario <name>] [--record <baseline.json> --key <name>]
#   scripts/perf-check.sh --xcresult <path.xcresult> [--record <baseline.json>]
#
# --result   a sampler summary (scripts/perf-sample.sh writes one). Every metric with a budget for the scenario must be within it.
# --xcresult the WheelhouseMacPerf test result: reads the launch and CPU/memory metrics with `xcrun xcresulttool`.
# --launch   the output of scripts/perf-launch.swift: `WHLAUNCH_RUNS [...]` (launch to the first window) and `WHLAUNCH_CONTENT_RUNS [...]`
#            (launch to the first content: the workspace instead of the Starting view): p90 (nearest rank) and median of each.
# --record   merges the measured numbers into a baseline file (perf/baselines/<milestone>.json, one new file per milestone).
# The previous baseline is --previous <file>, else the newest file before the current milestone in the ordered `milestones` list of
# budgets.json (--milestone <name>, default: the --record file name). A budgeted metric that is missing FAILS unless budgets.json lists it
# under notMeasuredUntil. A metric more than the tolerance worse than it
# needs a written justification. Exits 1 on a budget breach, 0 otherwise (regressions are reported as warnings with exit 0 unless
# --strict is given).
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
exec python3 -I - "$REPO" "$@" <<'PY'
import sys, json, os, glob, math, subprocess, statistics

def p90(values):
    """Nearest-rank 90th percentile: the smallest value with at least 90 % of the runs at or below it (7 runs: the 7th)."""
    v = sorted(values)
    return v[max(0, math.ceil(0.9 * len(v)) - 1)]

repo = sys.argv[1]; args = sys.argv[2:]
opt = {"strict": False}
i = 0
while i < len(args):
    a = args[i]
    if a == "--strict": opt["strict"] = True; i += 1
    elif a.startswith("--") and i + 1 < len(args): opt[a[2:]] = args[i + 1]; i += 2
    else: print("bad argument", a, file=sys.stderr); sys.exit(2)

budgets = json.load(open(os.path.join(repo, "perf/budgets.json")))
tol = budgets.get("regressionTolerancePct", 10)
measured = {}   # key -> {metric: value}

if "result" in opt:
    r = json.load(open(opt["result"]))
    key = opt.get("key") or opt.get("scenario") or r["scenario"]
    measured[key] = {k: v for k, v in r.items() if isinstance(v, (int, float))}
    measured[key]["_scenario"] = opt.get("scenario") or r["scenario"]

if "launch" in opt:
    lines = list(open(opt["launch"], errors="replace"))
    def runs(tag):
        line = next((l for l in lines if l.startswith(tag + " ")), None)
        return None if line is None else json.loads(line.split(" ", 1)[1])
    vals = runs("WHLAUNCH_RUNS")
    if vals is None: print("no WHLAUNCH_RUNS line in", opt["launch"], file=sys.stderr); sys.exit(2)
    if any(x < 0 for x in vals): print("a launch timed out (a run is -1):", vals, file=sys.stderr); sys.exit(2)
    e = measured.setdefault("testLaunch", {"_scenario": "testLaunch"})
    e["coldLaunchP90Sec"] = round(p90(vals), 3); e["coldLaunchMedianSec"] = round(statistics.median(vals), 3)
    e["runsSec"] = [round(x, 3) for x in vals]
    content = runs("WHLAUNCH_CONTENT_RUNS")
    if content is not None:
        if any(x < 0 for x in content): print("first content never arrived in a run (-1):", content, file=sys.stderr); sys.exit(2)
        e["firstContentP90Sec"] = round(p90(content), 3); e["firstContentMedianSec"] = round(statistics.median(content), 3)
        e["contentRunsSec"] = [round(x, 3) for x in content]

if "xcresult" in opt:
    path = opt["xcresult"]
    out = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "metrics", "--path", path], capture_output=True, text=True)
    if out.returncode != 0:
        print("xcresulttool failed:", out.stderr.strip(), file=sys.stderr); sys.exit(2)
    # Seconds of the idle block the CPU metric covers (testIdleOneWindow and testBusyTen measure a 60 s block).
    BLOCK_SEC = 60.0
    for t in json.loads(out.stdout):
        name = (t.get("testIdentifierURL") or t.get("testIdentifier") or "").split("/")[-1].replace("()", "")
        for run in t.get("testRuns", []):
            for m in run.get("metrics", []):
                vals = m.get("measurements") or []
                mid = m.get("identifier", "")
                if not vals: continue
                if "ApplicationLaunch" in mid and mid.endswith("duration") and "Responsive" in mid:
                    e = measured.setdefault("testLaunch", {"_scenario": "testLaunch"})
                    e["coldLaunchP90Sec"] = round(p90(vals), 3); e["coldLaunchMedianSec"] = round(statistics.median(vals), 3)
                    e["runsSec"] = [round(x, 3) for x in vals]
                elif "XCTMetric_CPU" in mid and mid.endswith(".time"):
                    key = {"testIdleOneWindow": "idle-1", "testBusyTen": "busy-10"}.get(name, name)
                    e = measured.setdefault(key, {"_scenario": key})
                    e["xctestCpuAvgPct"] = round(statistics.mean(vals) / BLOCK_SEC * 100, 3)
                elif mid.endswith("physical_peak"):
                    key = {"testIdleOneWindow": "idle-1", "testBusyTen": "busy-10"}.get(name, name)
                    e = measured.setdefault(key, {"_scenario": key})
                    unit = m.get("unitOfMeasurement", "kB")
                    div = {"kB": 1024.0, "B": 1048576.0, "MB": 1.0}.get(unit, 1024.0)
                    e["xctestPeakFootprintMB"] = round(max(vals) / div, 1)

if not measured:
    print("nothing to check", file=sys.stderr); sys.exit(2)

breaches, regressions = [], []
milestones = budgets.get("milestones", [])
current = opt.get("milestone") or (os.path.splitext(os.path.basename(opt["record"]))[0] if "record" in opt else None)

def before(a, b):
    """True when milestone a comes strictly before b in the ordered list."""
    return a in milestones and b in milestones and milestones.index(a) < milestones.index(b)

# The previous baseline: --previous <file>, else the newest baseline file BEFORE the current milestone in the ordered list.
prev = {}
if "previous" in opt:
    prev = json.load(open(opt["previous"]))
elif current in milestones:
    cands = []
    for p in glob.glob(os.path.join(repo, "perf/baselines/*.json")):
        stem = os.path.splitext(os.path.basename(p))[0]
        if before(stem, current): cands.append((milestones.index(stem), p))
    if cands: prev = json.load(open(max(cands)[1]))
informational = set(budgets.get("informationalMetrics", []))
not_until = budgets.get("notMeasuredUntil", {})

for key, m in measured.items():
    scen = m.get("_scenario", key)
    b = budgets.get(scen, {})
    for metric, limit in b.items():
        if limit is None or metric.startswith("_") or not isinstance(limit, (int, float)): continue
        if metric not in m:
            until = not_until.get(f"{scen}.{metric}")
            if until and current and before(current, until):
                print(f"skip  {key}: {metric} is not measured until {until}")
            else:
                breaches.append(f"{key}: budgeted metric {metric} was not measured")
            continue
        v = m[metric]
        if v > limit:
            (regressions if metric in informational else breaches).append(f"{key}: {metric} = {v} exceeds budget {limit}" + (" (informational)" if metric in informational else ""))
        else: print(f"ok    {key}: {metric} = {v} (budget {limit})")
    pm = prev.get(key, {}) if isinstance(prev.get(key), dict) else {}
    for metric, v in m.items():
        if metric.startswith("_") or not isinstance(v, (int, float)) or metric not in pm or not isinstance(pm[metric], (int, float)): continue
        base = pm[metric]
        if base > 0 and v > base * (1 + tol / 100.0): regressions.append(f"{key}: {metric} = {v} is more than {tol}% worse than the previous baseline {base}")

for r in regressions: print("WARN  " + r)
for b in breaches: print("FAIL  " + b)

if "record" in opt:
    path = opt["record"]
    doc = json.load(open(path)) if os.path.exists(path) else {"milestone": os.path.splitext(os.path.basename(path))[0]}
    for key, m in measured.items(): doc.setdefault(key, {}).update({k: v for k, v in m.items() if not k.startswith("_")})
    json.dump(doc, open(path, "w"), indent=2, sort_keys=False); open(path, "a").write("\n")
    print("recorded into", path)

sys.exit(1 if breaches or (opt["strict"] and regressions) else 0)
PY
