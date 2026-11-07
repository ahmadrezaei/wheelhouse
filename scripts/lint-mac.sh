#!/bin/bash
# Resource-use and structure lint for the Mac app (ARCHITECTURE-MAC section 12.3.4). Run by every milestone's CI and by
# scripts/release-mac.sh (step 3). Exits non-zero on any finding.
#
# Rules (comment lines are ignored):
#   1. `repeatForever` anywhere in Mac-compiled code
#   2. `Timer.scheduledTimer`, `Timer.publish` or `DispatchSource.makeTimerSource` outside Kit's Energy/PeriodicTask.swift
#   3. `Task.detached` outside the allowlist below (app-lifetime services only)
#   4. `import WebKit` outside PortForwardBrowserView+macOS.swift (and the iOS-only +iOS file)
#   5. `import JavaScriptCore` anywhere
#   6. `reloadData()` in KubeTable outside KubeTable+Diff.swift
#   7. an unconditional `import UIKit` in a file the Mac target compiles (outside *+iOS.swift and `#if` blocks)
# "Mac-compiled code" = Wheelhouse/ (minus *+iOS.swift), WheelhouseMac/, Packages/WheelhouseKit/Sources/*.
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"
exec python3 -I - <<'PY'
import os, re, sys

# Files (repo-relative) allowed to use Task.detached. Add an app-lifetime service here only with a reviewer's sign-off.
TASK_DETACHED_ALLOWLIST = {
    "Packages/WheelhouseKit/Sources/WheelhouseKit/Client/LiveKubeClient.swift",   # shipped iOS code: lazy client identity, utility QoS
}

roots = ["Wheelhouse", "WheelhouseMac", "Packages/WheelhouseKit/Sources"]
files = []
for r in roots:
    for d, _, names in os.walk(r):
        for n in names:
            if n.endswith(".swift"):
                p = os.path.join(d, n)
                if p.startswith("Wheelhouse/") and n.endswith("+iOS.swift"): continue
                files.append(p)

def code_lines(path):
    """Yields (lineNumber, text, inIOSBlock) for non-comment lines, tracking `#if canImport(UIKit)` / `#if os(iOS)` blocks."""
    stack = []   # True when the enclosing #if is an iOS/UIKit-only branch
    for i, line in enumerate(open(path, encoding="utf-8", errors="replace"), 1):
        s = line.strip()
        if s.startswith("#if"):
            stack.append(("canImport(UIKit)" in s or "os(iOS)" in s) and "!" not in s.split("#if", 1)[1][:3])
        elif s.startswith("#else") or s.startswith("#elseif"):
            if stack: stack[-1] = not stack[-1] if stack[-1] is not None else False
        elif s.startswith("#endif"):
            if stack: stack.pop()
        if s.startswith("//") or s.startswith("///"): continue
        yield i, line.split("//")[0] if "//" in line and '"' not in line else line, any(stack)

findings = []
for p in files:
    base = os.path.basename(p)
    for i, text, in_ios in code_lines(p):
        def hit(msg): findings.append(f"{p}:{i}: {msg}")
        if "repeatForever" in text: hit("repeatForever (no infinite animations, 12.3.4 item 5)")
        if re.search(r"Timer\.scheduledTimer|Timer\.publish|DispatchSource\.makeTimerSource", text) and not p.endswith("Energy/PeriodicTask.swift"):
            hit("timer outside PeriodicTask.swift (use PeriodicTask, 12.3.4 item 7)")
        if "Task.detached" in text and p not in TASK_DETACHED_ALLOWLIST: hit("Task.detached outside the allowlist (12.3.4 item 6)")
        if re.match(r"\s*import WebKit\b", text) and base != "PortForwardBrowserView+macOS.swift": hit("import WebKit outside PortForwardBrowserView+macOS.swift (12.3.4 item 11)")
        if re.match(r"\s*import JavaScriptCore\b", text): hit("import JavaScriptCore (no JavaScript runtime, 12.3.4 item 11)")
        if "reloadData()" in text and "KubeTable" in base and base != "KubeTable+Diff.swift": hit("reloadData() outside KubeTable+Diff.swift (12.3.4 item 2)")
        if re.match(r"import UIKit\b", text) and not in_ios and not p.startswith("Packages/"): hit("unconditional import UIKit in Mac-compiled code")

if findings:
    print("\n".join(findings), file=sys.stderr)
    print(f"lint-mac: {len(findings)} finding(s)", file=sys.stderr)
    sys.exit(1)
print(f"lint-mac: clean ({len(files)} files)")
PY
