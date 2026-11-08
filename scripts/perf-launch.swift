import CoreGraphics
import Foundation
// Launch-to-window timer for the Profile app (perf budget `testLaunch.coldLaunchP90Sec`, ARCHITECTURE-MAC section 12.3.2).
//
//   swiftc -O scripts/perf-launch.swift -o /tmp/perf-launch      (any output path outside the repository)
//   perf-launch <Wheelhouse.app> <runs> -ApplePersistenceIgnoreState YES -WHPerfScenario idle-1 -WHKubeconfigPath <perf-kubeconfig> | tee launch.log
//   scripts/perf-check.sh --launch launch.log [--record perf/baselines/<milestone>.json]
//
// Times `open -n -a` until the new process owns an on-screen window wider than 300 pt (window metadata only, no screen capture), then
// quits the app, waits, and repeats. XCUITest's own launch time is not used for the budget: on macOS `XCTApplicationLaunchMetric`
// records nothing, and `XCUIApplication.launch()` adds about a second of accessibility and automation setup.
let argv = CommandLine.arguments
let app = argv[1], runs = Int(argv[2]) ?? 5, extra = Array(argv.dropFirst(3))
let exe = app + "/Contents/MacOS/Wheelhouse"

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
var results: [Double] = []
for _ in 0..<runs {
    let t0 = ProcessInfo.processInfo.systemUptime
    let open = Process(); open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    open.arguments = ["-n", "-a", app, "--args"] + extra
    try open.run()
    var pid: Int32 = 0, dt = -1.0
    while ProcessInfo.processInfo.systemUptime - t0 < 30 {
        if pid == 0, let p = pids().first { pid = p }
        if pid != 0, hasWindow(pid) { dt = ProcessInfo.processInfo.systemUptime - t0; break }
        usleep(10_000)
    }
    results.append(dt)
    if pid != 0 { kill(pid, SIGTERM) }
    for _ in 0..<200 where !pids().isEmpty { usleep(50_000) }
    sleep(3)
}
print("WHLAUNCH_RUNS [" + results.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]")
