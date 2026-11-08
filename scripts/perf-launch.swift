import CoreGraphics
import Foundation
import notify
// Launch timer for the Profile app (perf budgets `testLaunch.coldLaunchP90Sec` and `testLaunch.firstContentP90Sec`,
// ARCHITECTURE-MAC section 12.3.2).
//
//   swiftc -O scripts/perf-launch.swift -o /tmp/perf-launch      (any output path outside the repository)
//   perf-launch <Wheelhouse.app> <runs> -ApplePersistenceIgnoreState YES -WHPerfScenario idle-1 -WHKubeconfigPath <perf-kubeconfig> | tee launch.log
//   scripts/perf-check.sh --launch launch.log [--record perf/baselines/<milestone>.json]
//
// Times `open -n -a` until (1) the new process owns an on-screen window wider than 300 pt (window metadata only, no screen capture):
// `WHLAUNCH_RUNS`, and (2) the app posts the Darwin notification `com.ahmadrezaei.wheelhouse.perf.first-content` (development builds,
// after the first frame that shows the workspace or the welcome screen instead of the Starting view; the same moment is the
// `FirstContent` signpost): `WHLAUNCH_CONTENT_RUNS`. Then it quits the app, waits, and repeats. A run that does not get there within
// 30 s is -1. XCUITest's own launch time is not used for the budget: on macOS `XCTApplicationLaunchMetric` records nothing, and
// `XCUIApplication.launch()` adds about a second of accessibility and automation setup.
let argv = CommandLine.arguments
let app = argv[1], runs = Int(argv[2]) ?? 5, extra = Array(argv.dropFirst(3))
let exe = app + "/Contents/MacOS/Wheelhouse"
let firstContent = "com.ahmadrezaei.wheelhouse.perf.first-content"

func pids() -> Set<Int32> {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-f", "^" + exe]
    let pipe = Pipe(); p.standardOutput = pipe
    try? p.run(); p.waitUntilExit()
    let s = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    return Set(s.split(separator: "\n").compactMap { Int32($0) })
}
func hasWindow(_ pid: Int32) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    for w in list where (w[kCGWindowOwnerPID as String] as? Int32) == pid {
        let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
        if ((b["Width"] as? Double) ?? 0) > 300 { return true }
    }
    return false
}
precondition(pids().isEmpty, "an instance is already running")
var token: Int32 = 0
precondition(notify_register_check(firstContent, &token) == UInt32(NOTIFY_STATUS_OK), "notify_register_check failed")
func contentPosted() -> Bool {
    var changed: Int32 = 0
    notify_check(token, &changed)
    return changed != 0
}
var windowRuns: [Double] = [], contentRuns: [Double] = []
for _ in 0..<runs {
    _ = contentPosted()                                   // clear anything posted before this launch
    let t0 = ProcessInfo.processInfo.systemUptime
    let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", "-a", app, "--args"] + extra
    try open.run()
    var pid: Int32 = 0, window = -1.0, content = -1.0
    while ProcessInfo.processInfo.systemUptime - t0 < 30, window < 0 || content < 0 {
        let now = ProcessInfo.processInfo.systemUptime - t0
        if content < 0, contentPosted() { content = now }
        if pid == 0, let p = pids().first { pid = p }
        if window < 0, pid != 0, hasWindow(pid) { window = now }
        usleep(5_000)
    }
    windowRuns.append(window); contentRuns.append(content)
    if pid != 0 { kill(pid, SIGTERM) }
    for _ in 0..<200 where !pids().isEmpty { usleep(50_000) }
    sleep(3)
}
notify_cancel(token)
let fmt = { (v: [Double]) in "[" + v.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]" }
print("WHLAUNCH_RUNS " + fmt(windowRuns))
print("WHLAUNCH_CONTENT_RUNS " + fmt(contentRuns))
