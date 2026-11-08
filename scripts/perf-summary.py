#!/usr/bin/env python3
"""Summary of one sampler run (ARCHITECTURE-MAC section 12.3.5), used by scripts/perf-sample.sh.

    perf-summary.py summarize --scenario <name> --top <top.txt> --csv <minutes.csv> --out <summary.json> --pid <pid>
                              --interval <s> --bundle-id <id> [--leaks <n>] [--cycle-seconds <s>] [--extra key=value ...]
    perf-summary.py self-test

The minute CSV has the columns `t,minute,footprintMB,fds,threads,established,visible` (t = seconds since the first minute sample).

Soak growth (`footprintGrowthMB`) is measured over whole navigation cycles, so the phase of the cycle at the two ends cannot decide the
result. The soak's cycle (perf/scenarios/soak-5.json `cycleSeconds`, 300 s) builds and releases the ConfigMaps store, so the
footprint is a sawtooth of 15-20 MB; "last minute minus minute 10" landed on a high or a low step by chance (+19 MB and -9 MB for the
same build in M1b). Instead: the LOW of the window that starts at minute 10 and the low of the window that ends at the last sample,
each window spanning `1.1 x cycleSeconds + one sample interval` (the cycle runs on a timer with up to 1 s tolerance and the minute
samples drift by a second or two), so each window contains at least one sample from the released phase of a cycle. Steady state is
the same low at both ends; a leak raises the later lows. The two lows lie closer together than minute 10 and the last sample (about
42 of 50 minutes), so the difference is scaled to the whole span: growth = (last low - first low) x span / (time between the lows).
Without that, a steady leak of 17 MB per 50 minutes measured under the 15 MB budget. Informational next to it: the least-squares slope of every sample from minute
10 on (MB per hour, `footprintSlopeMBPerHour`), and the old definition (`footprintLastMinusMin10MB`) for comparison with older
baselines.
"""
import datetime
import json
import re
import sys

SOAK_START_MINUTE = 10


def window_seconds(cycle_seconds, interval_seconds=60.0):
    """Span of a window that always holds one sample of the low phase of a cycle."""
    return 1.1 * cycle_seconds + interval_seconds


def soak_growth(samples, cycle_seconds):
    """samples: [(t_seconds, footprint_mb)] in time order. Returns (growth over the span from minute 10 to the last sample, first_low,
    last_low) or None when too short."""
    if not samples:
        return None
    start = next((i for i, (t, _) in enumerate(samples) if t >= samples[0][0] + SOAK_START_MINUTE * 60 - 1), None)
    if start is None:
        return None
    w = window_seconds(cycle_seconds)
    t0 = samples[start][0]
    t_end = samples[-1][0]
    if t_end - t0 < 2 * w:                       # the two windows must not overlap
        return None
    first = [(mb, t) for t, mb in samples[start:] if t <= t0 + w]
    last = [(mb, t) for t, mb in samples if t >= t_end - w]
    (low1, t1), (low2, t2) = min(first), min(last)          # lowest footprint, earliest sample on a tie
    if t2 <= t1:
        return None
    return round((low2 - low1) * (t_end - t0) / (t2 - t1), 1), low1, low2


def slope_mb_per_hour(samples):
    """Least-squares slope of footprint over time, from minute 10 on."""
    if not samples:
        return None
    pts = [(t, mb) for t, mb in samples if t >= samples[0][0] + SOAK_START_MINUTE * 60 - 1]
    if len(pts) < 3:
        return None
    n = len(pts)
    mt = sum(t for t, _ in pts) / n
    mf = sum(mb for _, mb in pts) / n
    var = sum((t - mt) ** 2 for t, _ in pts)
    if var == 0:
        return None
    return round(sum((t - mt) * (mb - mf) for t, mb in pts) / var * 3600, 2)


def parse_top(path, pid):
    rows = []
    for line in open(path, errors="replace"):
        p = line.split()
        if len(p) >= 5 and p[0] == pid:
            num = lambda s: float(re.sub(r"[+\-]$", "", s))
            rows.append((num(p[1]), num(p[2]), num(p[3]), int(num(re.sub(r"/.*$", "", p[4])))))   # threads print as "12/1" while some run
    return rows[1:]                                                                           # the since-launch sample is discarded


def parse_csv(path):
    out = []
    lines = list(open(path))
    header = lines[0].strip().split(",")
    for line in lines[1:]:
        p = dict(zip(header, line.strip().split(",")))
        out.append({"t": float(p["t"]), "minute": int(p["minute"]), "footprintMB": float(p["footprintMB"]), "fds": int(p["fds"]),
                    "threads": int(re.sub(r"/.*$", "", p["threads"])), "established": int(p["established"]),
                    "visible": p.get("visible", "")})
    return out


def summarize(a):
    interval = float(a["interval"])
    rows = parse_top(a["top"], a["pid"])
    minutes = parse_csv(a["csv"])
    out = {"scenario": a["scenario"], "bundleID": a["bundle-id"], "date": datetime.datetime.now().isoformat(timespec="seconds"),
           "samples": len(rows), "intervalSec": interval}
    if rows:
        cpu = [r[0] for r in rows]; idlew = [r[1] for r in rows]; power = [r[2] for r in rows]
        out["cpuAvgPct"] = round(sum(cpu) / len(cpu), 3)
        out["cpuMaxSamplePct"] = round(max(cpu), 3)
        span = interval * (len(rows) - 1)
        out["idleWakeupsPerSec"] = round((idlew[-1] - idlew[0]) / span, 3) if span > 0 else 0.0
        out["energyImpact"] = round(sum(power) / len(power), 3)
        out["threads"] = rows[-1][3]
    if minutes:
        foot = [m["footprintMB"] for m in minutes]
        samples = [(m["t"], m["footprintMB"]) for m in minutes]
        cycle = float(a.get("cycle-seconds") or 300)
        growth = soak_growth(samples, cycle)
        if growth is not None:
            out["footprintGrowthMB"], out["footprintFirstLowMB"], out["footprintLastLowMB"] = growth
        else:
            out["footprintGrowthMB"] = round(foot[-1] - foot[0], 1)   # short runs: whole run (no cycle to average over)
        slope = slope_mb_per_hour(samples)
        if slope is not None:
            out["footprintSlopeMBPerHour"] = slope
        out["footprintLastMinusMin10MB"] = round(foot[-1] - foot[min(SOAK_START_MINUTE, len(foot) - 1)], 1)
        out["threadsOverBaseline"] = minutes[-1]["threads"] - minutes[0]["threads"]
        out["fdsOverBaseline"] = minutes[-1]["fds"] - minutes[0]["fds"]
        out["footprintMB"] = round(max(foot), 1)
        out["footprintFirstMB"] = foot[0]; out["footprintLastMB"] = foot[-1]
        out["fds"] = minutes[-1]["fds"]
        out["minutes"] = len(minutes)
        out["connectedMinutesPct"] = round(100.0 * sum(1 for m in minutes if m["established"] > 0) / len(minutes), 1)
        # The app's verdict: 1 visible, 2 hidden, 0 never published (an older build, or not a development build).
        vis = [m["visible"] for m in minutes if m["visible"] in ("1", "2")]
        if vis:
            out["windowVisibleMinutesPct"] = round(100.0 * vis.count("1") / len(vis), 1)
        if len(vis) < len(minutes):
            out["windowVisibilityUnknownMinutes"] = len(minutes) - len(vis)
    if a.get("leaks", "") != "":
        out["leaks"] = int(a["leaks"])
    for kv in a.get("extra", []):
        k, v = kv.split("=", 1)
        out[k] = json.loads(v) if v in ("true", "false") or re.fullmatch(r"-?[0-9.]+", v) else v
    json.dump(out, open(a["out"], "w"), indent=2)
    open(a["out"], "a").write("\n")
    print(json.dumps(out, indent=2))


def self_test():
    """Synthetic sawtooth soaks: flat at every phase and with sampling drift must measure ~0; a leak must show."""
    import math

    def run(phase_s, leak_mb_per_hour, drift_s=1.5, minutes=60, cycle=300.0, high=18.0):
        samples, t = [], 0.0
        for _ in range(minutes):
            in_cycle = (t + phase_s) % cycle
            mb = 120.0 + (high if in_cycle < 150 else 0.0) + leak_mb_per_hour * t / 3600
            samples.append((t, mb))
            t += 60 + drift_s
        return samples

    worst_flat = 0.0
    for phase in range(0, 300, 20):
        g = soak_growth(run(phase, 0.0), 300)
        assert g is not None, "a 60-minute run must measure growth"
        worst_flat = max(worst_flat, abs(g[0]))
    assert worst_flat <= 1.0, f"a flat sawtooth measured {worst_flat} MB"
    for phase in range(0, 300, 20):
        g = soak_growth(run(phase, 30.0), 300)[0]          # 30 MB/h over the 50 measured minutes: 25 MB
        assert 23.0 <= g <= 27.5, f"a 30 MB/h leak measured {g} MB at phase {phase}"
    # A pure linear leak of 15 MB between minute 10 and minute 60 measures 15 MB (no sawtooth, no drift).
    linear = [(m * 60.0, 120.0 + 15.0 * (m - 10) / 50.0) for m in range(61)]
    g = soak_growth(linear, 300)[0]
    assert abs(g - 15.0) <= 0.5, f"a linear 15 MB leak measured {g} MB"
    # The same leak under the sawtooth, at every phase: within the 15 MB budget's resolution.
    for phase in range(0, 300, 20):
        g = soak_growth(run(phase, 18.0, drift_s=0.0, minutes=61), 300)[0]
        assert 13.0 <= g <= 17.0, f"an 18 MB/h leak under the sawtooth measured {g} MB at phase {phase}"
    assert soak_growth(run(0, 0.0, minutes=15), 300) is None, "a 15-minute run is too short for two whole-cycle windows"
    s = slope_mb_per_hour(run(0, 30.0))
    assert s is not None and 20 <= s <= 40, f"slope {s}"
    print(f"self-test ok (worst flat growth {worst_flat} MB)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(__doc__); sys.exit(2)
    if sys.argv[1] == "self-test":
        self_test(); sys.exit(0)
    if sys.argv[1] != "summarize":
        print(__doc__); sys.exit(2)
    args, extra, i = {}, [], 2
    while i < len(sys.argv):
        k = sys.argv[i][2:]
        if k == "extra":
            extra.append(sys.argv[i + 1])
        else:
            args[k] = sys.argv[i + 1]
        i += 2
    args["extra"] = extra
    summarize(args)
